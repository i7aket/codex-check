---
description: Send the current implementation plan to the local Codex CLI for an independent high-reasoning review against the branch the plan targets (+ ticket + PR), in an isolated git worktree
argument-hint: "[path/to/plan.md] [--branch <name>]"
disable-model-invocation: true
---
Send the current implementation plan to the local Codex CLI for an independent review. All logic lives in a deterministic script: `${CLAUDE_PLUGIN_ROOT}/skills/codex-check/scripts/run.sh` (preflight, plan-ticket resolution, base-ref auto-detect, `git fetch` outside the worktree, isolated worktree from the resolved target OID with trap cleanup, `codex exec -s workspace-write -o`, report copy). Optional arguments: a plan file path and/or `--branch <name>` — `$ARGUMENTS`.

The script picks what to review against from the **plan**, not the checked-out branch: an explicit `--branch` wins; otherwise the plan's own `Ticket:` line selects the unique branch carrying that key (or pre-implementation against the base ref); a ticket/branch mismatch with the working tree is warned about, not silently followed.

Do this:

# 1. Run the script in the BACKGROUND
Codex with high reasoning + web search takes well over 10 minutes, so launch the script as a **background task** (do not block the session). Pass each argument **separately quoted** (a path may contain spaces); never interpolate `$ARGUMENTS` raw into a larger shell string:

- Plan path only (background): `"${CLAUDE_PLUGIN_ROOT}/skills/codex-check/scripts/run.sh" "<the path>"`
- With an explicit branch: `"${CLAUDE_PLUGIN_ROOT}/skills/codex-check/scripts/run.sh" "<the path>" --branch "<the branch>"`
- No arguments (background): `"${CLAUDE_PLUGIN_ROOT}/skills/codex-check/scripts/run.sh"`

Never pass `$ARGUMENTS` raw/unquoted onto a command line — quote each token, or omit it when empty. The script accepts the plan path and `--branch <name>` in any order and rejects unknown options.

(With no argument, the script auto-detects the newest `*.md` plan from common locations: `docs/plans/`, `docs/specs/`, `plans/`, `specs/`, `docs/`. Override with the `CODEX_CHECK_PLAN_DIRS` env var, colon-separated. If nothing is found the script exits with a clear message asking for an explicit path.)

The script does everything itself: preflight (`codex`, `git`, optional `gh auth`), reading the plan's `Ticket:` line (the source of truth; falls back to a logged free-text guess only when there's no such line), resolving the review target to a commit OID (explicit `--branch` → unique branch for the plan's ticket → pre-implementation base ref), base-ref auto-detection (origin/HEAD → main/master → parent commit → none), `git fetch` OUTSIDE the worktree (inside `workspace-write` there is no write access to `.git`), creating a `mktemp` detached worktree at that OID, copying the plan into it, running `codex exec`, and ALWAYS removing the worktree via `trap EXIT`.

# 2. Wait for the background task to finish
You will be notified. Do not actively poll.

# 3. Report the result
- The script writes progress to stderr (`[codex-check] ...`) and, on its LAST stdout line, the absolute path to the review file.
- Read that review file (`<plan>.codex-review.md`, next to the plan).
- In chat, output: the VERDICT, 3-5 top notes, and the path to the review file.

# Error handling
The script exits with a clear `[codex-check] ERROR: ...` message and cleans up the worktree itself (trap). Possible causes: codex/git missing, plan not found, an ambiguous ticket (two branches carry the key — pass `--branch`), an unknown/missing branch, worktree creation failed, or Codex wrote no report. Success is decided by the report: if `-o` wrote a non-empty review it is kept even if Codex then exits non-zero (a stray post-run/MCP error must not discard a valid review). Only a missing/empty report is a failure, and only then is auth blamed (suggesting `codex login`) — and only when Codex's own error output looks like an auth problem, never because a successful review merely quoted a string like `401 Unauthorized`. Show the error message to the user verbatim.

# Notes
- Web search in `codex exec` is enabled via `-c web_search='"live"'` (there is NO `--search` flag). The report is captured via `-o/--output-last-message`. These details are already in the script.
- The reviewer reasoning effort is forced to `xhigh`; the model is whatever the user's Codex config (`~/.codex/config.toml`) selects.
- Ticket reading requires an issue-tracker MCP (Jira/Linear/YouTrack/etc.) configured for Codex; PR context requires `gh`. Both are optional — without them, Codex notes what's missing and reviews the plan against the branch diff anyway.
