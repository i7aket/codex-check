# codex-check v1.3.0 — simplify, test, harden

Ticket: none

## Goal

Make the plugin **smaller, provably correct, and easier to install** — without
adding feature bloat. After v1.2.0 the engine is a single ~454-line bash script
with zero automated tests. This release shrinks it, pins its load-bearing
fail-closed guarantees with tests, fixes two real correctness leaks, and clears
up the install/update confusion that already forced a manual
`installed_plugins.json` edit.

Derived from two independent audits (a multi-agent adversarial brainstorm and
Codex `xhigh`): 34 ideas generated, 22 survived critique, 12 dropped. The
guiding rule throughout: **keep the honest-disclosure / diagnostic half of each
idea, drop the speculative self-healing / locking / auto-relocation half.**

## Non-goals (explicitly rejected, for the record)

Rejected by adversarial critique as bloat or as conflicting with the v1.2.0
safety design — **not** in scope:

- Result caching / skip-if-unchanged (the only viable cache key is wrong by
  construction).
- Posting the verdict as a PR comment.
- Multi-model / multi-provider parallel review.
- Reviewing a diff/PR directly with no plan (`--diff-only` / `--pr`).
- A `--dry-run` mode and live-streaming of `codex exec` stdout.
- Any startup worktree "sweep", prune+retry self-heal, or auto-relocation of the
  repo root — these can mutate or prune a concurrent session's live worktree.

## Scope

| # | Change | Files | Risk |
|---|--------|-------|------|
| QW1 | Delete dead `BASE_BRANCH` variable | run.sh | ~none |
| QW2 | Parse ahead/behind with one `read` instead of two `awk` subshells | run.sh | ~none |
| QW3 | Broaden cleanup trap `EXIT` → `EXIT INT TERM HUP` | run.sh | ~none |
| QW4 | Surface git's real error on `worktree add` failure | run.sh | ~none |
| QW5 | Install/update identity table + reconcile repo-name drift | README.md, run.sh | low |
| CI  | shellcheck + bats in GitHub Actions | `.github/workflows/`, `test/` | low |
| F7  | Disclose plan/commit skew (one `PLAN STATUS` line) | run.sh | medium |
| F8  | Severity gating via a stable `GATE=` token (opt-in, fail-closed) | run.sh, command.md | medium |

All line numbers below reference run.sh at v1.2.0 (commit `7838387`); the
implementer must re-confirm them against the live file before editing.

## Architecture

The engine stays a single linear bash script (`set -euo pipefail`); nothing here
changes that shape. Each change is local to one section. The script remains
`bash` 3.2-safe (stock macOS): no `mapfile`, no associative arrays — new code
must hold that line even though CI runs on Ubuntu.

---

## QW1 — Delete dead `BASE_BRANCH` (run.sh ~L145)

`BASE_BRANCH="${BASE_REF#origin/}"` is assigned once and never read (the fetch is
a whole-remote `git fetch origin --prune`, not a single-branch fetch). Its
comment ("bare name for fetch") is actively misleading. Delete the line and the
comment. `shellcheck` confirms zero readers.

## QW2 — One `read` for ahead/behind (run.sh ~L332)

`git rev-list --left-right --count "$BASE_REF...$TARGET_OID"` emits exactly two
integers separated by whitespace: **`<behind>\t<ahead>`** (left = base-only
commits = behind; right = target-only = ahead). Replace the two `awk` subshell
pipelines with:

```sh
read -r _behind _ahead <<<"$ab"
AHEAD_BEHIND="ahead $_ahead / behind $_behind vs $BASE_REF"
```

Identical output; fewer forks. Field order (behind, then ahead) is the one thing
to get right — a bats banner assertion covers it.

## QW3 — Broaden cleanup trap (run.sh ~L319)

`trap cleanup EXIT` does **not** fire on `SIGTERM`/`SIGHUP`, so a cancelled
background run leaks a worktree every time — material in a ~40-worktree repo with
concurrent sessions. Change to `trap cleanup EXIT INT TERM HUP`. `cleanup()` is
already idempotent and `-d`-guarded, so multi-signal re-entry is safe. (Do NOT
add the rejected startup age-based sweep.)

## QW4 — Real error on worktree-add failure (run.sh ~L320)

Currently `git worktree add --detach "$WT" "$TARGET_OID" >/dev/null 2>&1 || die
"git worktree add failed"` discards the cause. Capture stderr:

```sh
_wt_err="$(git worktree add --detach "$WT" "$TARGET_OID" 2>&1 >/dev/null)" \
  || die "git worktree add failed: ${_wt_err}"
```

(Do NOT add the rejected prune+retry self-heal.)

## QW5 — Install/update docs + repo-name reconciliation

Two parts:

1. **README:** replace the one-line `tools`-vs-`i7aket` parenthetical with a
   source-of-truth identity table so every token in the install/update commands
   maps to a column (marketplace name = `tools`, plugin name = `i7aket`, command
   = `/i7aket:codex-check`, install path = `cache/tools/i7aket/<ver>`), plus a
   short **supported-paths-only** recovery box. Do **not** document the
   `installed_plugins.json` hand-edit (it is a footgun, not a supported path).
2. **Reconcile the repo-name drift:** run.sh's version-check URL (~L90) hardcodes
   one repo identity; confirm it matches the marketplace's recorded source and
   the README install command. Fix whichever is wrong so all three agree. (This
   pairs with F-version below if the URL is also made overridable.)

---

## F7 — Disclose plan/commit skew (one `PLAN STATUS` line)

**Problem:** the plan's working-tree content is read for review, but the code is
reviewed at `TARGET_OID`. A plan edited after the target commit is silently
out of sync.

**Fail-safe check order** (the critical trap: `git diff --quiet -- <path>`
returns 0 for an untracked or out-of-repo path, which would falsely read as
"matches"):

1. Is the plan **tracked AND inside `REPO_ROOT`**? If not →
   `PLAN STATUS: untracked` or `PLAN STATUS: out-of-repo`. Do not compare.
2. Only if tracked-in-repo → compare the working-tree blob to the plan's blob at
   `TARGET_OID`: `PLAN STATUS: matches` or `PLAN STATUS: DIFFERS`.

Emit the single `PLAN STATUS:` line into (a) the REVIEWING banner, (b) the
report header block, and (c) the Codex prompt. Diagnostic only — it never
changes target selection. The DIRTY banner already covers uncommitted source
changes; this specifically covers plan-vs-commit skew.

## F8 — Severity gating via a stable `GATE=` token (opt-in, fail-closed)

**Why a token, not VERDICT:** this user's reviews come back with the VERDICT
phrased in Russian ("доработать"), so free-text VERDICT parsing is unreliable.
Use a separate ASCII token the prompt mandates.

**Prompt change (command.md + the heredoc prompt in run.sh):** require Codex to
emit, as the **last line** of its answer, verbatim one of:
`GATE=READY` | `GATE=REVISE` | `GATE=REWORK` (always ASCII, regardless of the
review's language).

**Script behaviour:**

- Gating is **opt-in**: only active when `CODEX_CHECK_GATE` is set.
- When active, parse the last matching `^GATE=(READY|REVISE|REWORK)$` line from
  the report. Fixed mapping (no configurable threshold in this release — keep it
  simple): `READY`→exit 0, `REVISE`→exit 2, `REWORK`→exit 3.
- **Fail closed:** if gating is active but no valid `GATE=` token is found →
  **exit 2**. The rejected "default 0 on parse miss" must never ship.
- **Preserve the stdout contract:** the last stdout line must remain the report
  path. Order of operations: write report → print report path (stdout) → parse
  `GATE=` → `exit <code>`.
- Layer over the existing success rule: a non-empty report still "wins" for
  determining the run succeeded; the gate exit code is applied only to a valid
  report (never masks a real codex/auth failure, which still `die`s first).

When `CODEX_CHECK_GATE` is unset, behaviour is unchanged (exit 0 on success).

---

## CI — shellcheck + bats (GitHub Actions)

One workflow file (`.github/workflows/ci.yml`) on push/PR, two jobs (or one with
two steps):

1. **shellcheck:** `shellcheck -x -s bash` over run.sh, plus a committed
   `.shellcheckrc` that pre-disables the deliberate bash-3.2 idioms (e.g. the
   semver word-split, the dedup-loop expansions) each with an inline rationale
   comment, so CI documents intent rather than pressuring rewrites of
   load-bearing code. Pin the action version.
2. **bats:** a small suite driving run.sh against throwaway `git init` fixtures
   with **stub `codex` and `gh`** on `PATH` (the stub records the target OID it
   was handed and writes a canned report via `-o`). The stubs make the >10-min
   real review irrelevant to tests.

**bats cases (the load-bearing contract):**

- Undefined target (no `Ticket:`, no `--ref`/`--branch`) → non-zero, codex stub
  never invoked.
- `Ticket: none` → reviews the base ref.
- Ambiguous: two branches carry the ticket → non-zero, stub never invoked.
- `--branch` disambiguates an otherwise-ambiguous ticket → proceeds.
- Metadata-region `Ticket:` binds the target; a `Ticket:` only in body prose does
  **not**.
- Explicit `--ref <sha>` targets that exact OID.
- `GIT_DIR` leak in env is neutralized (run still succeeds).
- Auth regex **both directions**: a report that merely *quotes* `401
  Unauthorized` → kept (success); a real leading `error: token_revoked` with no
  report → `die`.
- ahead/behind banner shows correct ahead and behind counts (covers QW2 field
  order).
- **Gating fail-closed**: `CODEX_CHECK_GATE=1` + stub report without a `GATE=`
  line → exit 2.
- **Gating maps**: stub emitting `GATE=REWORK` → exit 3; `GATE=READY` → exit 0;
  stdout last line is still the report path in all gated cases.
- **PLAN STATUS**: an untracked plan reports `untracked` (NOT `matches`); a plan
  edited after the target commit reports `DIFFERS`.

Test helpers must stay bash-3.2-safe even though CI runs on Ubuntu, so the suite
can also be run locally on stock macOS.

## Versioning

Bump `1.2.0` → `1.3.0` in all three places (`i7aket/.claude-plugin/plugin.json`,
`.claude-plugin/marketplace.json`, `CHANGELOG.md`) — manual for this release.
(Single-source version tooling was considered and deferred: low value, and a
sync script is itself untested surface. The CHANGELOG heading must stay
hand-written regardless.)

## Delivery

One PR into `master` (squash → one commit), tagged `v1.3.0`, then install
locally (sync marketplace clone → materialize `cache/tools/i7aket/1.3.0` →
update `installed_plugins.json`), and smoke-test the installed copy from a stale
CWD plus a gated run. Logical commits within the branch: (a) CI + bats + QW1
together so shellcheck goes green on the dead-var delete; (b) the remaining
quick wins; (c) F7; (d) F8; (e) docs + version bump.

## Success criteria

- `run.sh` is shorter than v1.2.0 (net negative LOC from QW1/QW2, even after F7/F8).
- CI is green: shellcheck clean, all bats cases pass.
- A cancelled (`SIGTERM`) background run leaves no leaked worktree.
- `CODEX_CHECK_GATE=1` exits non-zero on `REWORK` and on a missing token; exits 0
  on `READY`; report path is still the last stdout line.
- The README install/update table + recovery box exist; the three repo-name
  references agree.
- Re-running the v1.2.0 live target-resolution checks (stale-CWD `--branch`,
  Mode B, fail-closed, `--ref`, ambiguity) still all pass.
