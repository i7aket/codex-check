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

This spec was then reviewed pre-implementation by an independent adversarial pass
(verdict: implement with changes). Its findings are folded in: F7's compare is
pinned to `TARGET_OID` with a filter-safe byte compare; F8 adds a command.md
exit-code contract and a fence-safe `tail -n1` parse; CI gains five branch cases
and a blocking shellcheck; QW5's repo-name "drift" is flagged verify-first
(likely a no-op).

A second independent review by **Codex `xhigh`** then ran live shell/git fixtures
and confirmed/extended the above: it **proved QW3's naive shared trap is unsafe**
(a `SIGTERM`'d run resumes and exits 0 — fixed here with a separate signal
handler exiting `128+signal`), confirmed QW2's field order (`rev-list
--left-right` → `behind  ahead`), confirmed the F7 CRLF normalization and flagged
the F7 **symlink** edge (handled as `symlink (skew not checked)`), and confirmed
QW5's repo identity is already consistent (drift = no-op). Both reviews are folded
in.

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
concurrent sessions.

**CORRECTION (Codex review, proven by a live signal fixture):** the naive
`trap cleanup EXIT INT TERM HUP` is **NOT safe**. A signal trap that just runs
`cleanup` does not terminate the script — bash runs the handler and then
*resumes* execution, so a `SIGTERM`'d run continues past the interrupted point
and exits `0`. The fixture showed `rc=0, log=cleanup|after|cleanup` — i.e. the
cancelled run looked successful and `codex exec` would have been launched anyway.
`cleanup()`'s idempotency is real (double-fire is harmless) but irrelevant to
this bug.

Correct form: keep the `EXIT` trap for normal/`die` paths, and add a SEPARATE
signal handler that cleans up and exits with `128+signal` so the script actually
aborts:

```sh
trap cleanup EXIT
trap 'cleanup; trap - INT TERM HUP EXIT; exit 130' INT
trap 'cleanup; trap - INT TERM HUP EXIT; exit 143' TERM
trap 'cleanup; trap - INT TERM HUP EXIT; exit 129' HUP
```

(Clearing the `EXIT` trap inside the signal handler avoids a redundant — though
harmless — second cleanup.) The bats SIGTERM case must assert BOTH no leaked
worktree AND a non-zero exit (not 0). (Do NOT add the rejected startup age-based
sweep.)

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
2. **Reconcile the repo-name drift — verify before assuming:** a review found
   run.sh (version URL ~L90, update hint ~L98) and the README already agree on
   `i7aket/tools` (marketplace `tools`, plugin `i7aket`). So "drift" may be a
   **no-op** — the implementer must confirm against the live `marketplace.json`
   and the recorded marketplace source before changing anything. If all three
   already agree, this item is docs-only (the identity table) and the URL
   reconciliation is dropped.

---

## F7 — Disclose plan/commit skew (one `PLAN STATUS` line)

**Problem:** the plan's working-tree content is read for review, but the code is
reviewed at `TARGET_OID`. A plan edited after the target commit is silently
out of sync.

**Fail-safe check order.** Two traps a review caught: (a) `git diff --quiet --
<path>` returns 0 ("matches") for an untracked/out-of-repo path; (b) "tracked"
must mean tracked **at `TARGET_OID`**, not in the current working tree — a plan
added *after* the target commit is tracked-now but absent-at-target and would
falsely read "matches".

1. **In-repo?** The plan is in-repo iff `PLAN_REL` was prefix-stripped (i.e.
   `PLAN_REL` is relative, not still absolute). If still absolute (e.g. the plan
   lives in a *different* worktree of the same repo, or outside any repo) →
   `PLAN STATUS: out-of-repo`. Do not compare.
2. **Tracked at the target commit?** `git cat-file -e "${TARGET_OID}:${PLAN_REL}"`.
   If it fails → `PLAN STATUS: untracked` (not present at the target). Do not
   compare.
3. **Compare** the plan's working-tree content to its content at `TARGET_OID`.
   Use a byte compare of the rendered (smudged) content, which sidesteps
   gitattributes/CRLF blob-id subtleties and is one line:
   `cmp -s <(git show "${TARGET_OID}:${PLAN_REL}") "$PLAN_PATH"` →
   `PLAN STATUS: matches` (rc 0) or `PLAN STATUS: DIFFERS` (rc 1).
   (NB: `git show` outputs smudged content; for plan skew this human-readable
   compare is sufficient. A filter-faithful alternative is
   `git hash-object --path "$PLAN_REL" -- "$PLAN_PATH"` vs
   `git rev-parse "${TARGET_OID}:${PLAN_REL}"` — Codex verified this normalizes
   CRLF correctly (`hash_equal=yes` under `*.md eol=lf` with a CRLF working
   copy), so adopt it if a real gitattributes false-DIFFERS shows up.)

**Known limitation (Codex review):** if the plan path is a **symlink**,
`git show "${TARGET_OID}:${PLAN_REL}"` returns the symlink *target path*, not the
linked file's content, so the compare is meaningless. This is rare for a plan
file; treat it as out-of-scope — if `PLAN_PATH` is a symlink, emit
`PLAN STATUS: symlink (skew not checked)` and do not compare.

Emit the single `PLAN STATUS:` line into (a) the REVIEWING banner, (b) the
report header block, and (c) the Codex prompt. Diagnostic only — it never
changes target selection. The DIRTY banner already covers uncommitted source
changes; this specifically covers plan-vs-commit skew.

## F8 — Severity gating via a stable `GATE=` token (opt-in, fail-closed)

**Why a token, not VERDICT:** this user's reviews come back with the VERDICT
phrased in Russian ("доработать"), so free-text VERDICT parsing is unreliable.
Use a separate ASCII token the prompt mandates.

**Prompt change (command.md + the heredoc prompt in run.sh):** require Codex to
emit, as the **last line of its answer with nothing after it**, verbatim one of:
`GATE=READY` | `GATE=REVISE` | `GATE=REWORK` (always ASCII, regardless of the
review's language). Parse with `grep -E '^GATE=(READY|REVISE|REWORK)$' | tail -n1`
(last anchored match). A token Codex echoes inside a fenced code block could in
principle also match; "last line, nothing after it" + `tail -n1` + fail-closed
bounds this to a low residual risk — document it.

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

**command.md exit-code contract (required, caught by review):** the command runs
the script as a background task and reports the result from the last stdout line.
Under `CODEX_CHECK_GATE`, a `2`/`3` exit **with a report path printed on stdout**
is a *successful* REVISE/REWORK verdict, **not** a failure. Only a
`[codex-check] ERROR: …` message (and no report) is a real failure. Add this to
command.md's "Report the result" and "Error handling" sections so the calling
assistant doesn't misreport a good gated review as an error.

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
  edited after the target commit reports `DIFFERS`; a plan absent at TARGET_OID
  reports `untracked`/`out-of-repo` (NOT `matches`).
- `--pre-implementation` → reviews the base ref (stub gets base OID).
- `CODEX_CHECK_REF` env resolves the target; an explicit `--ref` flag overrides
  the env (precedence).
- An `origin/`-prefixed `--branch` resolves to the remote branch.
- Failed-fetch is fatal for Mode B (ticket resolution) → `die`; with
  `CODEX_CHECK_ALLOW_STALE=1` it proceeds.
- The divergent local-vs-origin **note** path fires when a local branch and its
  origin mirror differ (the fail-closed disclosure promise).
- **QW3 signal handling (Codex)**: a `SIGTERM`'d run exits **non-zero** (not 0)
  AND leaves no leaked worktree — pins that the signal handler actually aborts
  rather than resuming. This is the case the naive shared-EXIT-trap fails.
- **F7 symlink**: a symlinked plan reports `symlink (skew not checked)`, never a
  bogus `matches`/`DIFFERS`.

Test helpers must stay bash-3.2-safe even though CI runs on Ubuntu, so the suite
can also be run locally on stock macOS. **CI runs bash 5, so Ubuntu bats cannot
catch a bash-3.2-only regression** — note in the suite that local macOS bats is
the real 3.2 gate. **shellcheck is BLOCKING** (the whole point is to pin the
guarantees); the `.shellcheckrc` disables carry inline rationale and must land in
the FIRST commit so shellcheck is green before/at the dead-var delete.

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
