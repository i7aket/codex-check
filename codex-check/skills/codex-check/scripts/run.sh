#!/usr/bin/env bash
# codex-check: send an implementation plan to the local Codex CLI for an
# independent high-reasoning review against the current branch, its tracker
# ticket (if an issue-tracker MCP is configured for Codex) and its PR.
#
# Codex runs in an isolated, detached git worktree (sandbox: workspace-write).
# The report is captured via `codex exec -o`. The worktree is always removed
# (trap EXIT). Works in any git repo; nothing here is project-specific.
#
# Usage: run.sh [PLAN_PATH]
#   PLAN_PATH optional. If omitted, the newest candidate is auto-detected from
#   common plan/spec locations (see locate step). Override search dirs with
#   CODEX_CHECK_PLAN_DIRS (colon-separated).
#
# Output: writes <plan>.codex-review.md next to the plan, and prints that path
# as the LAST stdout line. Progress goes to stderr as "[codex-check] ...".

set -euo pipefail

log() { printf '[codex-check] %s\n' "$*" >&2; }
die() { printf '[codex-check] ERROR: %s\n' "$*" >&2; exit 1; }

# --- 0. Preflight -----------------------------------------------------------
command -v codex >/dev/null 2>&1 || die "codex CLI not found in PATH (https://developers.openai.com/codex)"
command -v git   >/dev/null 2>&1 || die "git not found in PATH"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
cd "$REPO_ROOT"

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  GH_OK=1
else
  GH_OK=0; log "note: gh missing or not authenticated — PR context will be skipped"
fi

# --- 1. Locate the plan -----------------------------------------------------
PLAN_PATH="${1:-}"
if [[ -n "$PLAN_PATH" ]]; then
  [[ -f "$PLAN_PATH" ]] || die "given plan path does not exist: $PLAN_PATH"
else
  # Default search locations; override with CODEX_CHECK_PLAN_DIRS (colon-separated).
  IFS=':' read -r -a SEARCH_DIRS <<< "${CODEX_CHECK_PLAN_DIRS:-docs/plans:docs/specs:docs/superpowers/plans:docs/superpowers/specs:plans:specs}"
  for dir in "${SEARCH_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
      cand="$(ls -t "$dir"/*.md 2>/dev/null | grep -v '\.codex-review\.md$' | head -n1 || true)"
      [[ -n "$cand" ]] && { PLAN_PATH="$cand"; break; }
    fi
  done
  if [[ -z "$PLAN_PATH" ]]; then
    cand="$(ls -t scratchpad*/* .features/plan 2>/dev/null | head -n1 || true)"
    [[ -n "$cand" ]] && PLAN_PATH="$cand"
  fi
  [[ -n "$PLAN_PATH" ]] || die "no plan found (searched: ${SEARCH_DIRS[*]}, scratchpad*/, .features/plan) — pass a path explicitly"
fi
PLAN_PATH="$(cd "$(dirname "$PLAN_PATH")" && pwd)/$(basename "$PLAN_PATH")"  # absolute
log "plan: $PLAN_PATH"

# --- 2. Resolve the base branch (don't assume 'main') -----------------------
BASE_REF=""
if git symbolic-ref --quiet refs/remotes/origin/HEAD >/dev/null 2>&1; then
  BASE_REF="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"  # e.g. origin/main
fi
if [[ -z "$BASE_REF" ]]; then
  for c in origin/main origin/master main master; do
    if git rev-parse --verify --quiet "$c" >/dev/null 2>&1; then BASE_REF="$c"; break; fi
  done
fi
BASE_BRANCH="${BASE_REF#origin/}"   # bare name for fetch (may be empty)
log "base ref: ${BASE_REF:-<none>}"

# --- 3. Branch detection (detached-safe) + ticket ---------------------------
SOURCE_BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null \
  || git for-each-ref --format='%(refname:short)' --points-at HEAD refs/heads 2>/dev/null | head -n1 \
  || true)"
[[ -z "$SOURCE_BRANCH" ]] && log "branch: detached/unknown (will scan commits for a ticket key)"
# Ticket key: any Jira/Linear/YouTrack-style key like ABC-123. Branch name first.
TICKET="$(printf '%s' "$SOURCE_BRANCH" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -n1 || true)"
if [[ -z "$TICKET" && -n "$BASE_REF" ]]; then
  TICKET="$(git log "$BASE_REF"..HEAD --oneline 2>/dev/null | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -n1 || true)"
fi
log "branch: ${SOURCE_BRANCH:-<detached>} | ticket: ${TICKET:-<none>}"

# --- 4. Freshen the base ref BEFORE Codex (workspace-write can't write .git in a linked worktree) ---
if [[ -n "$BASE_BRANCH" ]] && git remote get-url origin >/dev/null 2>&1; then
  if git fetch origin "$BASE_BRANCH" --prune >/dev/null 2>&1; then
    log "fetched origin/$BASE_BRANCH"
  else
    log "note: git fetch origin $BASE_BRANCH failed — diff base may be stale"
  fi
fi

# --- 5. Isolated worktree (mktemp, outside the project) + trap cleanup -------
SAFE_BRANCH="$(printf '%s' "${SOURCE_BRANCH:-detached}" | tr -cs 'A-Za-z0-9._-' '-')"
WT="$(mktemp -d "${TMPDIR:-/tmp}/codex-check-${SAFE_BRANCH}.XXXXXX")"
cleanup() {
  if [[ -n "${WT:-}" && -d "$WT" ]]; then
    git worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"
    git worktree prune >/dev/null 2>&1 || true
    log "worktree removed"
  fi
}
trap cleanup EXIT
git worktree add --detach "$WT" HEAD >/dev/null 2>&1 || die "git worktree add failed"
mkdir -p "$WT/.codex-check"
cp "$PLAN_PATH" "$WT/.codex-check/PLAN.md"
REVIEW_IN_WT="$WT/CODEX_REVIEW.md"
log "worktree: $WT"

# --- 6. Build the review prompt --------------------------------------------
DIFF_BASE="${BASE_REF:-HEAD~1}"
if [[ "$GH_OK" -eq 1 && -n "$SOURCE_BRANCH" ]]; then
  PR_LINE="2. PR: run \`gh pr list --state all --head \"$SOURCE_BRANCH\" --json number,title,url,state,mergedAt\` (NOT open-only, or merged/closed PRs are missed). If none, say 'PR: none' and continue."
else
  PR_LINE="2. PR: gh is unavailable or branch is detached — say 'PR: skipped' and continue."
fi
if [[ -n "$TICKET" ]]; then
  TICKET_LINE="1. Ticket: the branch/commits reference ticket key '$TICKET'. If you have an issue-tracker MCP (Jira/Linear/YouTrack/etc.) configured, read that ticket and use it as the requirements source. If not, say 'Ticket: $TICKET (no tracker MCP)' and continue."
else
  TICKET_LINE="1. Ticket: no ticket key found in the branch name or commits. Say 'Ticket: none' and continue."
fi

read -r -d '' PROMPT <<EOF || true
You are an independent reviewer of an implementation plan. The plan is at ./.codex-check/PLAN.md — read it first.

Branch under review: ${SOURCE_BRANCH:-<detached>} (you are in a detached worktree at its HEAD — this is expected). Gather context yourself:
$TICKET_LINE
$PR_LINE
3. What's already done: run \`git diff $DIFF_BASE...HEAD --stat\` (and inspect interesting hunks). Do NOT run \`git fetch\` (no write access to .git inside this worktree; the base ref was already refreshed outside). If there is no diff, treat the plan as "pre-implementation".

Then review the plan itself:
- Verify it: is it implementable, does it agree with the ticket (if any) and the existing code. NB: the plan may legitimately be out of the ticket's scope if the plan is not itself a change to this branch (the branch may just be a test carrier) — that is not an error.
- Augment it: what is missing (steps, files, checks, edge cases).
- Find defects and blind spots (risks, hidden dependencies, backward compatibility, tests).
- Search the web for best practices on the plan's topic and cite sources.
- If you see a better approach than the plan proposes, suggest it with rationale.

Return your final report as your LAST answer (it is saved via -o), in English, with this structure:
VERDICT: ready / revise / rework.
CONTEXT: branch, ticket, PR (what you found).
NOTES: numbered list (if none, say so).
BEST PRACTICES: with links.
BETTER APPROACHES: if any.
SUMMARY: 2-3 sentences.
EOF

# --- 7. Run Codex -----------------------------------------------------------
log "running codex exec (xhigh, web_search, workspace-write) ..."
set +e
codex exec \
  -C "$WT" \
  -s workspace-write \
  -c model_reasoning_effort='"xhigh"' \
  -c web_search='"live"' \
  -o "$REVIEW_IN_WT" \
  "$PROMPT" >"$WT/codex-stdout.log" 2>"$WT/codex-stderr.log"
CODEX_RC=$?
set -e

if grep -qiE 'token_revoked|refresh_token_invalidated|401 Unauthorized' "$WT/codex-stderr.log" 2>/dev/null; then
  die "Codex auth failed (token revoked) — run: codex login, then retry"
fi
if [[ $CODEX_RC -ne 0 || ! -s "$REVIEW_IN_WT" ]]; then
  log "codex stderr tail:"; tail -n 15 "$WT/codex-stderr.log" >&2 || true
  die "codex exec failed (rc=$CODEX_RC) or empty report — review not written"
fi

# --- 8. Copy the report next to the plan -----------------------------------
REVIEW_PATH="${PLAN_PATH%.*}.codex-review.md"
{
  echo "# Codex review — $(basename "$PLAN_PATH")"
  echo
  echo "- Branch: ${SOURCE_BRANCH:-<detached>}"
  echo "- Ticket: ${TICKET:-<none>}"
  echo "- Diff base: ${DIFF_BASE}"
  echo "- Plan: $PLAN_PATH"
  echo "- Model: Codex (xhigh, web_search), sandbox=workspace-write"
  echo
  echo "---"
  echo
  cat "$REVIEW_IN_WT"
} > "$REVIEW_PATH"
log "review written: $REVIEW_PATH"
printf '%s\n' "$REVIEW_PATH"   # LAST line = the review path (the command parses this)
