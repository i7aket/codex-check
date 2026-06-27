# codex-check: review the plan's branch, not whatever is checked out

Ticket: none (plugin repo `i7aket/codex-check`; no external tracker for this repo)

## Problem

`/codex-check` reviews an implementation plan with the OpenAI Codex CLI inside an
isolated git worktree. The worktree is created from `HEAD` of the current working
tree (`git worktree add --detach "$WT" HEAD`), and the ticket key is extracted from
the **branch name** (`run.sh:75`).

This inverts the source of truth. The user runs `/codex-check <plan>` expecting Codex
to review *that plan* — but if the working tree happens to have a different branch
checked out (unfinished work on another ticket), Codex silently reviews the plan
against the wrong branch and the wrong ticket.

Observed failure: a plan about a "Waiter role label" was reviewed while the working
tree was on `fix/VEC-185-active-venues-only`. Codex read VEC-185, saw the plan did not
match VEC-185, and returned a false `rework` — not because the plan was wrong, but
because the plan and the checked-out branch had diverged. The mechanism never noticed
the mismatch; it trusted the branch name.

**Root cause:** the script derives the ticket from the branch (`branch → its ticket`).
The correct direction is `plan → its ticket → its branch`. The plan file is the source
of truth for which ticket the review is about.

## Goal

Make the review always target the branch the *plan* is about — by default — and surface
any mismatch loudly instead of silently producing a false verdict. Let the user override
the target branch explicitly when needed.

Non-goals: changing how `codex exec` runs, the report format, the `trap` cleanup, the
outside-the-worktree `git fetch`, or reading tickets from a tracker inside the script
(Codex does that via its MCP). Keep the script project-agnostic.

## Base-resolution logic (priority, top to bottom)

The script computes a single `TARGET_REF`, resolves it to a commit OID, and creates the
worktree from that OID. Whichever rule wins is logged to stderr so the choice is always
visible. Vocabulary used throughout (replaces today's `SOURCE_BRANCH`/`TICKET`):
`TARGET_REF` (what we review against), `TARGET_OID` (its resolved commit),
`PLAN_TICKET` (from plan metadata), `CURRENT_BRANCH` (what is checked out now).

All ref resolution goes through one helper:
`resolve_oid() { git rev-parse --verify --quiet --end-of-options "$1^{commit}"; }`
— `--end-of-options` stops a `--`-looking ref name from being parsed as a flag, and
`^{commit}` forces a commit (rejecting tags/trees). The worktree is then always created
from the OID: `git worktree add --detach "$WT" "$TARGET_OID"`. This fixes the remote-only
case — we never pass a stripped bare name like `foo` to `worktree add`.

### Mode A — explicit branch (highest priority)
New optional flag: `--branch <name>` (and env `CODEX_CHECK_BRANCH=<name>`). When set:
- Validate the name: `git check-ref-format --branch "<name>"` (reject junk before use).
- Resolve in order to an OID: `refs/heads/<name>` → `refs/remotes/origin/<name>`.
- If it resolves nowhere → `die` ("requested branch <name> not found locally or on origin").
- `TARGET_OID` = that OID. `PLAN_TICKET` still parsed from plan metadata for the report;
  the report also records the explicit `--branch` choice.
- No guessing. This is the deterministic escape hatch.

### Mode B — auto by the plan's ticket (default)
1. **Read the ticket from plan METADATA, not free text** (Codex note #1 — free-text
   scanning misclassifies: this very plan says `Ticket: none` yet mentions `VEC-185`/
   `VEC-200`). Source of truth, in order:
   - An explicit metadata line near the top: `^Ticket:\s*(\S+)` (case-insensitive).
     `Ticket: none` is an explicit, honored value → skip ticket-based branch lookup.
   - Only if NO `Ticket:` line exists at all → fall back to a free-text key scan
     (`[A-Z][A-Z0-9]+-[0-9]+`, first match) **as a warning-level heuristic**, logged as
     a guess (`log "ticket guessed from plan body: <KEY> (add a 'Ticket:' line to be sure)"`).
2. If a plan-ticket is resolved (and not `none`), look for the branch carrying that key —
   **exact ticket equality, not glob fuzz** (Codex note #3):
   - `git fetch origin --prune` first (refresh remote-tracking refs).
   - Enumerate candidates: local heads + `origin/*`, via
     `git for-each-ref --format='%(refname:short)' refs/heads refs/remotes/origin`.
   - For each, parse its ticket key the same way and keep those whose key **== PLAN_TICKET**.
   - Dedupe local vs its own `origin/` mirror (same branch).
   - **Exactly one** distinct branch → `TARGET_OID = resolve_oid(that ref)`.
   - **More than one** → `die` listing the candidates (ambiguous; require `--branch`).
   - **Zero** → pre-implementation mode: `TARGET_OID = resolve_oid(BASE_REF)` (the base
     ref's OID, NOT current `HEAD`). Log: `no branch for <KEY> → pre-implementation
     review against <BASE_REF>`.
3. If the ticket is explicitly `none`, OR no ticket could be determined at all →
   pre-implementation against `BASE_REF` OID (not current `HEAD`). Log the reason.

### Mismatch guard (the core protection against the observed bug)
Compute `CURRENT_BRANCH` (today's symbolic-ref logic) and its ticket key. If `PLAN_TICKET`
is set, `CURRENT_BRANCH`'s key is set, and they **differ**, emit a loud stderr warning
BEFORE running Codex:

```
[codex-check] WARNING: plan targets VEC-200 but the working tree is on VEC-185.
[codex-check] Reviewing against VEC-200. Pass --branch to override.
```

This converts a silent false `rework` into a visible, explainable signal.

## Second bug — false "token revoked" from an over-broad stderr grep

Discovered while reviewing THIS plan with codex-check (the irony is the evidence): the
script's auth check is `grep -qiE 'token_revoked|refresh_token_invalidated|401
Unauthorized'` over the full Codex stderr (`run.sh:170`). When the plan under review is
about `run.sh` itself, Codex **reads and quotes** that very line, the quote lands in the
captured stderr/tool log, the grep matches its own pattern, and the script aborts a
**successful** run as "token revoked" — even though the token is valid (verified: the same
long xhigh+web_search run completed rc=0, report written, 101k tokens, while `codex
/status` showed healthy limits). The same false positive can be tripped by any reviewed
code that contains the string `401 Unauthorized`, or by an unrelated MCP server logging a
401 to the shared stderr.

Fix — make the auth check trustworthy instead of substring-sniffing:
- **Success is decided by the report, not the exit code or the logs.** `codex exec -o` can
  write a complete review and then exit non-zero on an unrelated post-run/MCP error; that
  review is still valid and is kept (discarding it would reintroduce the false-failure this
  change fixes). Only a missing/empty report is a failure. The *reason* — auth vs anything
  else — is attributed only after we know it failed, and never from substrings in a
  successful run's logs, so a review that merely quotes `401 Unauthorized` is never misread
  as an auth failure.

## Report header is intentionally changing (compatibility note)

The generated `<plan>.codex-review.md` header keys change from `Branch`/`Ticket` to
`Target`/`Target ref`/`Plan ticket`/`Current branch`/`Diff base`. This is an **intentional**
break of the "report format unchanged" non-goal: the old keys can no longer express what the
review actually ran against (a resolved target distinct from the checked-out branch). The
report is human-facing Markdown with no known machine consumers; the change is recorded here
and in the CHANGELOG so it is not a silent surprise.
- If (and only if) it failed, then narrow the auth heuristic to Codex CLI's real auth
  signature — match on stderr lines that are Codex's own error output (e.g. a leading
  `ERROR`/`error:` line containing `token`/`401`), not any occurrence anywhere in the
  transcript. When in doubt, report the generic "codex exec failed (rc=…)" with the stderr
  tail and let the user read it, rather than asserting a specific cause.
- Keep the existing `codex login` hint only on a confirmed auth failure.

## Files changed

- `i7aket/skills/codex-check/scripts/run.sh` — sections 2–5 only (base/branch/ticket
  resolution and which ref the worktree is created from). The worktree mechanism, fetch,
  Codex invocation, report copy, and trap are unchanged. Add `--branch`/`CODEX_CHECK_BRANCH`
  parsing near the existing argument handling; keep the optional plan-path arg working.
- `i7aket/commands/codex-check.md` — document `--branch`, the three modes, and the default
  (auto-by-plan-ticket). Update `argument-hint` to `"[path/to/plan.md] [--branch <name>]"`.
- `README.md` — document the three modes under Usage; add the Updating section (below).
  Also fix the install command after the repo rename: `marketplace add i7aket/tools`
  (was `i7aket/codex-check`; GitHub redirects the old URL but docs should be current).
- `i7aket/.claude-plugin/plugin.json` — update `homepage`/`repository` to
  `https://github.com/i7aket/tools` (repo renamed `codex-check` → `tools`). The plugin
  name stays `i7aket`; the command stays `/i7aket:codex-check`.
- Any self-update URL (Part 2) must point at `i7aket/tools`, not the old name.

## Versioning & update delivery

Claude Code does **not** auto-notify or auto-update plugins. A marketplace is a cached git
repo; nothing polls GitHub. So delivery is two parts:

### Part 1 — release hygiene (base mechanism)
- Bump `version` in BOTH `.claude-plugin/marketplace.json` and
  `i7aket/.claude-plugin/plugin.json` to `1.1.0` (new feature → minor bump). They must
  stay in lockstep — a check or comment should note this.
- Add `CHANGELOG.md` (Keep-a-Changelog style); record this change under `1.1.0`.
- Tag the release `v1.1.0` after merge to `master`.
- README **Updating** section, documenting the only commands that pull a new version:
  ```text
  /plugin marketplace update tools
  /plugin update i7aket@tools
  ```
  State plainly that without `marketplace update` the local cache never learns about new
  versions.

### Part 2 — optional self-check (the "notification")
At the start of `run.sh`, a best-effort, non-blocking version check:
- Read the local version from `plugin.json` (resolve via `${CLAUDE_PLUGIN_ROOT}` when set,
  else relative to the script path).
- Fetch the remote version from `master` without cloning:
  `git ls-remote`/raw `plugin.json` over HTTPS, with a short timeout.
- Compare with a **numeric semver comparison**, NOT a string compare (Codex note #6 —
  string compare orders `1.10.0` before `1.2.0`). Split on `.`, compare major/minor/patch
  as integers. Only if remote is strictly greater, log once:
  `[codex-check] a newer version (1.2.0) is available — run: /plugin marketplace update tools && /plugin update i7aket@tools`.
- Must never fail the run: wrap in `|| true`, short timeout, and honor an opt-out
  `CODEX_CHECK_NO_UPDATE_CHECK=1`. Offline / network error → silent skip.

## Testing

The script is bash with no unit harness; verify by behavior in a scratch git repo:
1. **Mode A / valid** — `--branch <name>` for an existing local branch → worktree from its
   OID. Same for a remote-only `origin/<name>` (resolved via OID, not a stripped bare name).
2. **Mode A / invalid** — `--branch` with a malformed name → `die` (caught by
   `check-ref-format`); with a well-formed but nonexistent name → `die` (not found).
3. **Mode B / `Ticket:` line, branch exists** — plan has `Ticket: VEC-200` and a branch
   whose name carries `VEC-200` exists → reviewed against it even when a different branch is
   checked out.
4. **Mode B / `Ticket: none`** — explicit `Ticket: none` → pre-impl against `BASE_REF` OID;
   free-text keys in the body (`VEC-185`, `VEC-200`) are NOT used. (Guards Codex note #1.)
5. **Mode B / no `Ticket:` line** — body mentions one key, no metadata line → uses it as a
   logged guess; body mentions none → pre-impl against `BASE_REF` OID.
6. **Mode B / ambiguous** — `Ticket: VEC-200` and two branches carry `VEC-200` →
   `die` listing both candidates.
7. **Mismatch guard** — plan `Ticket: VEC-200`, tree on a `VEC-185` branch → loud WARNING,
   reviews VEC-200.
8. **False-revoke regression** — review a plan whose text contains the literal string
   `401 Unauthorized` (e.g. this plan, or `run.sh` itself) on a healthy token → run
   completes, report written, NO false "token revoked". (Guards the second bug.)
9. **Self-check** — local behind remote (incl. `1.2.0` vs `1.10.0`, exercising the numeric
   compare) → one info line; `CODEX_CHECK_NO_UPDATE_CHECK=1` → silent; offline → silent,
   run proceeds.

## Delivery

Branch off `master` in `i7aket/codex-check`, single squash commit, PR to `master`, tag
`v1.1.0` after merge. This plan lives in the repo and is itself the artifact reviewed by
`/codex-check`.
