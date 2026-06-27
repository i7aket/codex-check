#!/usr/bin/env bash
# codex-check: send an implementation plan to the local Codex CLI for an
# independent high-reasoning review against the branch the PLAN targets, its
# tracker ticket (if an issue-tracker MCP is configured for Codex) and its PR.
#
# Codex runs in an isolated, detached git worktree (sandbox: workspace-write).
# The report is captured via `codex exec -o`. The worktree is always removed
# (trap EXIT). Works in any git repo; nothing here is project-specific.
#
# Usage: run.sh [PLAN_PATH] [--branch <name>]
#   PLAN_PATH optional. If omitted, the newest candidate is auto-detected from
#   common plan/spec locations (see locate step). Override search dirs with
#   CODEX_CHECK_PLAN_DIRS (colon-separated).
#   --branch <name> (or env CODEX_CHECK_BRANCH) reviews against that exact branch,
#   bypassing the plan-ticket auto-resolution.
#
# What it reviews against (TARGET), highest priority first:
#   A) --branch / CODEX_CHECK_BRANCH  -> that branch (validated, resolved to an OID)
#   B) the plan's own ticket          -> the unique branch carrying that ticket key,
#                                        else pre-implementation against the base ref
# The plan is the source of truth for the ticket (a `Ticket:` metadata line), NOT
# whatever branch happens to be checked out. A loud warning fires on mismatch.
#
# Output: writes <plan>.codex-review.md next to the plan, and prints that path
# as the LAST stdout line. Progress goes to stderr as "[codex-check] ...".

set -euo pipefail

log() { printf '[codex-check] %s\n' "$*" >&2; }
die() { printf '[codex-check] ERROR: %s\n' "$*" >&2; exit 1; }

# Ticket key (Jira/Linear/YouTrack style, e.g. ABC-123) out of an arbitrary string.
ticket_of() { printf '%s' "${1:-}" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -n1 || true; }
# Resolve a ref to a commit OID, safely (rejects flags via --end-of-options, forces a commit).
resolve_oid() { git rev-parse --verify --quiet --end-of-options "$1^{commit}" 2>/dev/null || true; }

# --- 0. Preflight -----------------------------------------------------------
command -v codex >/dev/null 2>&1 || die "codex CLI not found in PATH (https://developers.openai.com/codex)"
command -v git   >/dev/null 2>&1 || die "git not found in PATH"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
cd "$REPO_ROOT"

# --- 0a. Argument parsing: optional PLAN_PATH and optional --branch ----------
PLAN_PATH=""; PLAN_SET=0
REQ_BRANCH="${CODEX_CHECK_BRANCH:-}"   # env default; --branch overrides
set_plan() { [[ "$PLAN_SET" -eq 0 ]] && { PLAN_PATH="$1"; PLAN_SET=1; } || die "unexpected extra argument: $1"; }
END_OPTS=0
while [[ $# -gt 0 ]]; do
  if [[ "$END_OPTS" -eq 1 ]]; then set_plan "$1"; shift; continue; fi
  case "$1" in
    --branch)   shift; [[ $# -gt 0 ]] || die "--branch requires a value"; REQ_BRANCH="$1" ;;
    --branch=*) REQ_BRANCH="${1#--branch=}" ;;
    --)         END_OPTS=1 ;;                                 # everything after is positional
    -*)         die "unknown option: $1" ;;
    *)          set_plan "$1" ;;
  esac
  shift
done

# --- 0b. Best-effort, non-blocking newer-version check ----------------------
# Never fails the run; opt out with CODEX_CHECK_NO_UPDATE_CHECK=1.
version_check() {
  [[ -n "${CODEX_CHECK_NO_UPDATE_CHECK:-}" ]] && return 0
  command -v curl >/dev/null 2>&1 || return 0
  local manifest local_v remote_v
  manifest="${CLAUDE_PLUGIN_ROOT:-}/.claude-plugin/plugin.json"
  [[ -f "$manifest" ]] || manifest="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null && pwd)/.claude-plugin/plugin.json"
  [[ -f "$manifest" ]] || return 0
  local_v="$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9.]+"' "$manifest" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
  [[ -n "$local_v" ]] || return 0
  remote_v="$(curl -fsS --max-time 3 \
    https://raw.githubusercontent.com/i7aket/tools/master/i7aket/.claude-plugin/plugin.json 2>/dev/null \
    | grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9.]+"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
  [[ -n "$remote_v" ]] || return 0
  # numeric semver compare: remote strictly greater than local?
  local IFS=.; local -a L=($local_v) R=($remote_v); local i
  for i in 0 1 2; do
    local l="${L[$i]:-0}" r="${R[$i]:-0}"
    if   (( r > l )); then
      log "a newer version ($remote_v) is available — run: /plugin marketplace update tools && /plugin update i7aket@tools"
      return 0
    elif (( r < l )); then return 0
    fi
  done
}
version_check || true

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  GH_OK=1
else
  GH_OK=0; log "note: gh missing or not authenticated — PR context will be skipped"
fi

# --- 1. Locate the plan -----------------------------------------------------
if [[ -n "$PLAN_PATH" ]]; then
  [[ -f "$PLAN_PATH" ]] || die "given plan path does not exist: $PLAN_PATH"
else
  # Default search locations; override with CODEX_CHECK_PLAN_DIRS (colon-separated).
  IFS=':' read -r -a SEARCH_DIRS <<< "${CODEX_CHECK_PLAN_DIRS:-docs/plans:docs/specs:plans:specs:docs}"
  for dir in "${SEARCH_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
      # newest regular *.md file, excluding previously generated reviews
      cand="$(find "$dir" -maxdepth 1 -type f -name '*.md' ! -name '*.codex-review.md' -print0 2>/dev/null \
        | xargs -0 ls -t 2>/dev/null | head -n1 || true)"
      [[ -n "$cand" ]] && { PLAN_PATH="$cand"; break; }
    fi
  done
  [[ -n "$PLAN_PATH" ]] || die "no plan found (searched: ${SEARCH_DIRS[*]}) — pass a plan path explicitly: /codex-check:codex-check path/to/plan.md"
fi
PLAN_PATH="$(cd "$(dirname "$PLAN_PATH")" && pwd)/$(basename "$PLAN_PATH")"  # absolute (for cp/read)
PLAN_REL="${PLAN_PATH#"$REPO_ROOT"/}"   # repo-relative for logs/report — never leak absolute local paths
log "plan: $PLAN_REL"

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

# --- 2a. Freshen ALL remote-tracking refs BEFORE picking a target ----------
# (workspace-write can't write .git inside a linked worktree, so fetch out here.)
# A plain `git fetch origin <branch>` only updates that one ref — it would NOT
# discover a remote-only ticket branch (origin/fix/ABC-123) during Mode B
# enumeration. Fetch the whole remote so origin/* is current, which also
# freshens the base ref.
if git remote get-url origin >/dev/null 2>&1; then
  git fetch origin --prune >/dev/null 2>&1 \
    && log "fetched origin/* (prune)" \
    || log "note: git fetch origin --prune failed — refs may be stale"
fi

# --- 3. Current branch (for the mismatch guard) and the plan's own ticket ----
CURRENT_BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null \
  || git for-each-ref --format='%(refname:short)' --points-at HEAD refs/heads 2>/dev/null | head -n1 \
  || true)"
CURRENT_TICKET="$(ticket_of "$CURRENT_BRANCH")"

# The plan is the source of truth. Look for a `Ticket:` line only in the METADATA
# REGION — the head of the file, up to the first Markdown section heading (`## `)
# or a YAML front-matter terminator. This stops a `Ticket:` inside body prose or a
# fenced code block from hijacking the target (which would recreate the very
# wrong-target bug we're fixing). Only if no metadata line exists do we fall back
# to a logged free-text guess over the whole file.
PLAN_TICKET=""; PLAN_TICKET_EXPLICIT=0
META_REGION="$(awk 'NR>1 && /^## /{exit} {print} NR>=40{exit}' "$PLAN_PATH" 2>/dev/null || true)"
META_LINE="$(printf '%s\n' "$META_REGION" | grep -iE '^[[:space:]]*Ticket:[[:space:]]*' | head -n1 || true)"
if [[ -n "$META_LINE" ]]; then
  PLAN_TICKET_EXPLICIT=1
  # Match "none" as a whole token (Ticket: none), not as a prefix of e.g. "noneABC".
  if printf '%s' "$META_LINE" | grep -qiE 'Ticket:[[:space:]]*none([[:space:]]|$)'; then
    PLAN_TICKET=""   # explicit "none" → no ticket-based branch lookup
  else
    PLAN_TICKET="$(ticket_of "$META_LINE")"
  fi
else
  PLAN_TICKET="$(ticket_of "$(cat "$PLAN_PATH" 2>/dev/null)")"
  [[ -n "$PLAN_TICKET" ]] && log "ticket guessed from plan body: $PLAN_TICKET (add a 'Ticket:' line near the top to be sure)"
fi

# --- 3a. Resolve TARGET (what we review against) ----------------------------
# Priority: A) explicit --branch  B) the plan's ticket  C) pre-implementation base.
TARGET_REF="" ; TARGET_OID="" ; TARGET_DESC=""
if [[ -n "$REQ_BRANCH" ]]; then
  # Mode A — explicit branch. Accept both a bare head name (feat/ABC-123) and an
  # origin-prefixed name (origin/feat/ABC-123), since users copy the latter from
  # `git` output and from this script's own ambiguity error.
  _bare="${REQ_BRANCH#origin/}"
  git check-ref-format --branch "$_bare" >/dev/null 2>&1 || die "invalid branch name: $REQ_BRANCH"
  if [[ "$REQ_BRANCH" == origin/* ]]; then
    _cands=("refs/remotes/origin/$_bare" "refs/heads/$_bare")   # explicit origin/ → prefer remote
  else
    _cands=("refs/heads/$_bare" "refs/remotes/origin/$_bare")
  fi
  for cand in "${_cands[@]}"; do
    TARGET_OID="$(resolve_oid "$cand")"
    [[ -n "$TARGET_OID" ]] && { TARGET_REF="${cand#refs/heads/}"; TARGET_REF="${TARGET_REF#refs/remotes/}"; break; }
  done
  [[ -n "$TARGET_OID" ]] || die "requested branch '$REQ_BRANCH' not found locally or on origin"
  TARGET_DESC="explicit --branch $TARGET_REF"
elif [[ -n "$PLAN_TICKET" ]]; then
  # Mode B — the unique branch carrying the plan's ticket key (exact equality).
  # bash 3.2-safe (macOS stock): no mapfile, no associative arrays.
  # Enumerate origin/* FIRST so that when a local branch and its origin mirror
  # share a name we keep the remote (PR-backed review should track origin), and
  # warn if the two have diverged so a stale local checkout can't change the
  # target silently.
  _uniq=() ; _seen_keys=" "
  while IFS= read -r r; do
    [[ -z "$r" ]] && continue
    [[ "$(ticket_of "$r")" == "$PLAN_TICKET" ]] || continue
    key="${r#origin/}"
    case "$_seen_keys" in
      *" $key "*)
        # already kept the origin/ side; flag divergence if the local OID differs
        if [[ "$r" != origin/* ]]; then
          lo="$(resolve_oid "$r")"; ro="$(resolve_oid "origin/$key")"
          [[ -n "$lo" && -n "$ro" && "$lo" != "$ro" ]] && \
            log "note: local '$key' and 'origin/$key' differ — reviewing origin/$key (pass --branch '$key' to force local)"
        fi
        continue ;;
    esac
    _seen_keys="$_seen_keys$key "
    _uniq+=("$r")
    # NB: two separate for-each-ref passes (remote THEN heads) — a single call
    # sorts by full refname and would not honor argument order, letting a local
    # branch win over its origin mirror.
  done < <({ git for-each-ref --format='%(refname:short)' refs/remotes/origin 2>/dev/null; \
             git for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null; })
  if   [[ "${#_uniq[@]}" -eq 1 ]]; then
    TARGET_REF="${_uniq[0]}"; TARGET_OID="$(resolve_oid "$TARGET_REF")"
    TARGET_DESC="branch for $PLAN_TICKET: $TARGET_REF"
  elif [[ "${#_uniq[@]}" -gt 1 ]]; then
    die "ambiguous: multiple branches carry $PLAN_TICKET (${_uniq[*]}) — pass --branch to choose"
  else
    TARGET_REF="$BASE_REF"; TARGET_OID="$(resolve_oid "$BASE_REF")"
    TARGET_DESC="no branch for $PLAN_TICKET → pre-implementation against ${BASE_REF:-<none>}"
  fi
else
  # Mode C — explicit Ticket:none, or no ticket at all → pre-implementation.
  TARGET_REF="$BASE_REF"; TARGET_OID="$(resolve_oid "$BASE_REF")"
  if [[ "$PLAN_TICKET_EXPLICIT" -eq 1 ]]; then
    TARGET_DESC="plan has 'Ticket: none' → pre-implementation against ${BASE_REF:-<none>}"
  else
    TARGET_DESC="no ticket in plan → pre-implementation against ${BASE_REF:-<none>}"
  fi
fi
# Last resort: nothing resolved (e.g. empty repo with no base) → current HEAD.
[[ -z "$TARGET_OID" ]] && { TARGET_OID="$(resolve_oid HEAD)"; TARGET_DESC="${TARGET_DESC:-fallback} (HEAD)"; }
[[ -n "$TARGET_OID" ]] || die "could not resolve any commit to review against"
log "target: $TARGET_DESC"
log "plan ticket: ${PLAN_TICKET:-<none>} | current branch: ${CURRENT_BRANCH:-<detached>}"

# --- 3b. Mismatch guard -----------------------------------------------------
if [[ -z "$REQ_BRANCH" && -n "$PLAN_TICKET" && -n "$CURRENT_TICKET" && "$PLAN_TICKET" != "$CURRENT_TICKET" ]]; then
  log "WARNING: plan targets $PLAN_TICKET but the working tree is on $CURRENT_TICKET."
  log "Reviewing against $PLAN_TICKET. Pass --branch to override."
fi

# --- 5. Isolated worktree (mktemp, outside the project) + trap cleanup -------
SAFE_REF="$(printf '%s' "${TARGET_REF:-detached}" | tr -cs 'A-Za-z0-9._-' '-')"
WT="$(mktemp -d "${TMPDIR:-/tmp}/codex-check-${SAFE_REF}.XXXXXX")"
cleanup() {
  if [[ -n "${WT:-}" && -d "$WT" ]]; then
    git worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"
    git worktree prune >/dev/null 2>&1 || true
    log "worktree removed"
  fi
}
trap cleanup EXIT
git worktree add --detach "$WT" "$TARGET_OID" >/dev/null 2>&1 || die "git worktree add failed"
mkdir -p "$WT/.codex-check"
cp "$PLAN_PATH" "$WT/.codex-check/PLAN.md"
REVIEW_IN_WT="$WT/CODEX_REVIEW.md"
log "worktree: $WT"

# --- 6. Build the review prompt --------------------------------------------
# Diff base: the resolved base ref; else the parent of the target commit; else
# none (initial-commit repo / no base) → review the plan "pre-implementation".
if [[ -n "$BASE_REF" ]]; then
  DIFF_BASE="$BASE_REF"
elif git rev-parse --verify --quiet "${TARGET_OID}~1" >/dev/null 2>&1; then
  DIFF_BASE="${TARGET_OID}~1"
else
  DIFF_BASE=""
fi
if [[ -n "$DIFF_BASE" ]]; then
  DIFF_LINE="3. What's already done: run \`git diff $DIFF_BASE...HEAD --stat\` (and inspect interesting hunks). Do NOT run \`git fetch\` (no write access to .git inside this worktree; the base ref was already refreshed outside). If there is no diff, treat the plan as \"pre-implementation\"."
else
  DIFF_LINE="3. What's already done: no base ref or parent commit is available, so there is no diff to inspect — treat the plan as \"pre-implementation\"."
fi
if [[ "$GH_OK" -eq 1 && -n "$TARGET_REF" ]]; then
  PR_LINE="2. PR: run \`gh pr list --state all --head \"${TARGET_REF#origin/}\" --json number,title,url,state,mergedAt\` (NOT open-only, or merged/closed PRs are missed). If none, say 'PR: none' and continue."
else
  PR_LINE="2. PR: gh is unavailable or there is no target branch — say 'PR: skipped' and continue."
fi
if [[ -n "$PLAN_TICKET" ]]; then
  TICKET_LINE="1. Ticket: the plan targets ticket key '$PLAN_TICKET'. If you have an issue-tracker MCP (Jira/Linear/YouTrack/etc.) configured, read that ticket and use it as the requirements source. If not, say 'Ticket: $PLAN_TICKET (no tracker MCP)' and continue."
else
  TICKET_LINE="1. Ticket: the plan declares no ticket. Say 'Ticket: none' and continue."
fi

read -r -d '' PROMPT <<EOF || true
You are an independent reviewer of an implementation plan. The plan is at ./.codex-check/PLAN.md — read it first.

Reviewing against: ${TARGET_DESC} (you are in a detached worktree at that commit — this is expected). Gather context yourself:
$TICKET_LINE
$PR_LINE
$DIFF_LINE

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

# Success is decided by the REPORT, not by the exit code or by grepping logs.
# `-o` may write a complete report and then Codex exits non-zero on an unrelated
# post-run/MCP error — that report is still a valid review and must be kept.
# Likewise a successful run that merely *quotes* "401 Unauthorized" must never be
# read as our auth failing. So: a non-empty report wins; only an empty/missing
# report is a failure, and only then do we attribute a cause.
if [[ ! -s "$REVIEW_IN_WT" ]]; then
  # Genuinely no report. Decide whether it looks like an auth problem, and only
  # from Codex's own error lines (a leading ERROR/error: mentioning token/auth/401),
  # not from any occurrence anywhere in the transcript.
  log "codex stderr tail:"; tail -n 15 "$WT/codex-stderr.log" >&2 || true
  if grep -qiE '^[[:space:]]*(error[: ]).*(token_revoked|refresh_token_invalidated|unauthorized|401|re-?authenticate|codex login)' "$WT/codex-stderr.log" 2>/dev/null; then
    die "Codex auth failed — run: codex login, then retry"
  fi
  die "codex exec failed (rc=$CODEX_RC) and wrote no report"
fi
# Report exists. Note a non-zero exit but proceed — the review is usable.
[[ $CODEX_RC -ne 0 ]] && log "note: codex exited non-zero (rc=$CODEX_RC) but a report was written — keeping it"

# --- 8. Copy the report next to the plan -----------------------------------
# Strip only a real markdown extension from the basename (so e.g. ".features/plan"
# does NOT become "/repo/.codex-review.md" by treating ".features" as the extension).
PLAN_DIR="$(dirname "$PLAN_PATH")"
PLAN_BASE="$(basename "$PLAN_PATH")"
case "$PLAN_BASE" in
  *.md)       REVIEW_BASE="${PLAN_BASE%.md}.codex-review.md" ;;
  *.markdown) REVIEW_BASE="${PLAN_BASE%.markdown}.codex-review.md" ;;
  *)          REVIEW_BASE="${PLAN_BASE}.codex-review.md" ;;
esac
REVIEW_PATH="$PLAN_DIR/$REVIEW_BASE"
REVIEW_REL="${REVIEW_PATH#"$REPO_ROOT"/}"
{
  echo "# Codex review — $PLAN_BASE"
  echo
  echo "- Target: ${TARGET_DESC}"
  echo "- Target ref: ${TARGET_REF:-<detached>} (${TARGET_OID})"
  echo "- Plan ticket: ${PLAN_TICKET:-<none>}"
  echo "- Current branch: ${CURRENT_BRANCH:-<detached>}"
  echo "- Diff base: ${DIFF_BASE:-<none>}"
  echo "- Plan: $PLAN_REL"
  echo "- Model: Codex (xhigh, web_search), sandbox=workspace-write"
  echo
  echo "---"
  echo
  cat "$REVIEW_IN_WT"
} > "$REVIEW_PATH"
log "review written: $REVIEW_REL"
printf '%s\n' "$REVIEW_PATH"   # LAST line = the absolute review path (the command parses this to read the file)
