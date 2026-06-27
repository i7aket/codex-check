---
description: Send the current implementation plan to the local Codex CLI for an independent high-reasoning review (branch + ticket + PR), in an isolated git worktree
argument-hint: "[path/to/plan.md]"
---
Send the current implementation plan to the local Codex CLI for an independent review. All logic lives in a deterministic script: `${CLAUDE_PLUGIN_ROOT}/skills/codex-check/scripts/run.sh` (preflight, detached-safe branch detection, base-ref auto-detect, `git fetch` outside the worktree, isolated worktree with trap cleanup, `codex exec -s workspace-write -o`, report copy). Optional argument: a plan file path — `$ARGUMENTS`.

Do this:

# 1. Run the script in the BACKGROUND
Codex with high reasoning + web search takes well over 10 minutes — do not block the session with a foreground call. Launch it as a background task:

```bash
"${CLAUDE_PLUGIN_ROOT}/skills/codex-check/scripts/run.sh" $ARGUMENTS
```

(If `$ARGUMENTS` is empty, the script auto-detects the newest plan from common locations: `docs/plans/`, `docs/specs/`, `docs/superpowers/plans|specs/`, `plans/`, `specs/`, then `scratchpad*/` / `.features/plan`. Override the search dirs with the `CODEX_CHECK_PLAN_DIRS` env var, colon-separated.)

The script does everything itself: preflight (`codex`, `git`, optional `gh auth`), detached-safe branch detection, ticket-key extraction (any `ABC-123`-style key), base-ref auto-detection (origin/HEAD → main/master), `git fetch` of the base ref OUTSIDE the worktree (inside `workspace-write` there is no write access to `.git`), creating a `mktemp` worktree, copying the plan into it, running `codex exec`, and ALWAYS removing the worktree via `trap EXIT`.

# 2. Wait for the background task to finish
You will be notified. Do not actively poll.

# 3. Report the result
- The script writes progress to stderr (`[codex-check] ...`) and, on its LAST stdout line, the path to the review file.
- Read that review file (`<plan>.codex-review.md`, next to the plan).
- In chat, output: the VERDICT, 3-5 top notes, and the path to the review file.

# Error handling
The script exits with a clear `[codex-check] ERROR: ...` message and cleans up the worktree itself (trap). Possible causes: codex/git missing, plan not found, worktree creation failed, Codex failed, or a revoked Codex token (then tell the user to run `codex login` and retry). Show the error message to the user verbatim.

# Notes
- Web search in `codex exec` is enabled via `-c web_search='"live"'` (there is NO `--search` flag). The report is captured via `-o/--output-last-message`. These details are already in the script.
- The reviewer model/effort inherit from the user's Codex config (`~/.codex/config.toml`); the script forces `model_reasoning_effort=xhigh` explicitly.
- Ticket reading requires an issue-tracker MCP (Jira/Linear/YouTrack/etc.) configured for Codex; without one, Codex notes the ticket key and continues.
