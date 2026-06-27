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
/plugin marketplace add i7aket/tools
/plugin install i7aket@tools
```

(The repository `i7aket/tools` is the marketplace `tools`; the plugin inside it is `i7aket`.)

## Usage

```text
/i7aket:codex-check                          # auto-detect the newest plan
/i7aket:codex-check path/to/plan.md          # review a specific plan
/i7aket:codex-check path/to/plan.md --branch feat/ABC-123   # review against an explicit branch
```

Plugin commands are namespaced as `/<plugin>:<command>`, so the command is `/i7aket:codex-check`.

The review takes ~10–13 minutes (high reasoning + web search), so it runs in the background;
you'll be notified when it's done. The verdict appears in chat and the full report is saved to
`<plan>.codex-review.md` next to the plan.

### What it reviews against

The **plan** is the source of truth — not whatever branch you happen to have checked out:

1. `--branch <name>` (or `CODEX_CHECK_BRANCH`) — reviews against that exact branch.
2. Otherwise the plan's own ticket: add a `Ticket: ABC-123` line near the top, and codex-check
   finds the unique branch carrying that key and reviews against it. `Ticket: none` (or no ticket)
   reviews the plan "pre-implementation" against the base ref. If two branches carry the key, it
   stops and asks you to pass `--branch`.

If the plan targets a different ticket than the branch you're on, it warns loudly and reviews the
plan's branch anyway — so a stray checkout can't silently produce a wrong verdict.

## Updating

Claude Code does **not** auto-notify or auto-update plugins — a marketplace is a cached git repo,
and nothing polls GitHub. To pull a new version, run **both**:

```text
/plugin marketplace update tools
/plugin update i7aket@tools
```

Without `marketplace update` first, the local cache never learns a new version exists. codex-check
also prints a one-line notice at the start of a run when a newer version is published (best-effort,
silent if offline; opt out with `CODEX_CHECK_NO_UPDATE_CHECK=1`).

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
