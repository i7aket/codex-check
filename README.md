# codex-check

A [Claude Code](https://code.claude.com) plugin that hands your implementation plan to the
local **[Codex CLI](https://developers.openai.com/codex)** for an independent, high-reasoning
review — against the current git branch, its tracker ticket, and its PR — and writes the
verdict next to your plan.

Use it after you've written a plan (and before you implement it) to get a fresh second opinion
that checks feasibility, finds gaps and risks, looks up best practices on the web, and proposes
better approaches.

## How it works

`/codex-check` runs a deterministic script that:

1. Auto-detects your plan (or takes a path argument).
2. Detects the branch (detached-worktree-safe) and any `ABC-123`-style ticket key.
3. Auto-detects the base ref (`origin/HEAD` → `main`/`master`) and fetches it **outside** the worktree.
4. Creates an **isolated, detached `git worktree`** so Codex can't touch your working tree.
5. Runs `codex exec -s workspace-write` with web search and `xhigh` reasoning; Codex reads the
   plan, the ticket (via an issue-tracker MCP if you have one), the PR (`gh`), and the branch diff.
6. Captures the report via `-o`, copies it to `<plan>.codex-review.md`, and **always removes the
   worktree** (`trap EXIT`).

Nothing is project-specific — it works in any git repo.

## Requirements

- A Unix-like shell with **Bash** and standard POSIX tools (`git`, `find`, `grep`, `mktemp`, `cp`, …).
  On Windows use WSL or Git Bash.
- [Codex CLI](https://developers.openai.com/codex) installed and authenticated (`codex login`).
- *(Optional)* `gh` authenticated — for PR context.
- *(Optional)* an issue-tracker MCP (Jira / Linear / YouTrack / …) configured **for Codex** — for ticket context.

## Install

```text
/plugin marketplace add i7aket/codex-check
/plugin install i7aket@tools
```

(The repository is the marketplace `tools`; the plugin inside it is `i7aket`.)

## Usage

```text
/i7aket:codex-check                      # auto-detect the newest plan
/i7aket:codex-check path/to/plan.md      # review a specific plan
```

Plugin commands are namespaced as `/<plugin>:<command>`, so the command is `/i7aket:codex-check`.

The review takes ~10–13 minutes (high reasoning + web search), so it runs in the background;
you'll be notified when it's done. The verdict appears in chat and the full report is saved to
`<plan>.codex-review.md` next to the plan.

### Where it looks for a plan

In order: `docs/plans/`, `docs/specs/`, `plans/`, `specs/`, `docs/` — the newest `*.md` (generated
`*.codex-review.md` files are ignored). Override the search list with the `CODEX_CHECK_PLAN_DIRS`
env var (colon-separated), or just pass an explicit path.

## Notes

- Web search in `codex exec` is enabled via the `web_search` config key (there is no `--search` flag).
- Runs Codex in `workspace-write` (not full bypass): writes are confined to the temporary worktree.
- The base ref is auto-detected — whatever `origin/HEAD` points to, else `main`/`master`, else the
  parent commit, else none (the plan is reviewed "pre-implementation").
- Generated reviews record the **repo-relative** plan path, not your absolute local path.

## License

MIT — see [LICENSE](LICENSE).
