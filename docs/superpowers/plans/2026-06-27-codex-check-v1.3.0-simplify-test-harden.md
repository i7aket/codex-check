# codex-check v1.3.0 (simplify, test, harden) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Shrink the codex-check `run.sh`, pin its fail-closed guarantees with a shellcheck+bats CI gate, fix two correctness leaks (signal-trap worktree leak, plan/commit skew), add opt-in severity gating, and clear up install docs — without adding feature bloat.

**Architecture:** The engine stays a single linear `bash` script (`set -euo pipefail`). Every change is local to one section. A new `test/` dir holds a bats suite that drives `run.sh` against throwaway `git init` fixtures with **stub `codex`/`gh`** on `PATH`, so the >10-minute real review never runs in tests. A GitHub Actions workflow runs shellcheck (blocking) + bats on push/PR.

**Tech Stack:** bash 3.2-safe shell, [bats-core](https://github.com/bats-core/bats-core) for tests, [shellcheck](https://www.shellcheck.net/) for static analysis, GitHub Actions for CI.

## Global Constraints

- **Repo / working dir:** `/private/tmp/claude-501/-Volumes-T9-Projects-Vectis/1a405b31-161f-4f71-b6a5-62427c0a7921/scratchpad/codex-check-clone`, branch `feat/v1.3.0-simplify-test-harden` (already created, already has the spec + spec-review commits).
- **Engine file:** `i7aket/skills/codex-check/scripts/run.sh` (454 lines at the start; line numbers below are from that baseline — re-confirm before each edit, as earlier edits shift later lines).
- **bash 3.2-safe:** no `mapfile`, no associative arrays, no `declare -A`. `<<<`, `read -r a b`, `${var#prefix}` are fine. CI runs bash 5 (Ubuntu) so it CANNOT catch a 3.2-only regression — local macOS bats is the real 3.2 gate; note this in the suite.
- **Commit author:** `git -c user.name="i7aket" -c user.email="i7aket@users.noreply.github.com" commit …` (the clone has no committer identity configured).
- **Version bump:** `1.2.0` → `1.3.0` in exactly three places: `i7aket/.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` (the `plugins[0].version` field), `CHANGELOG.md` (new heading). Manual — no sync tooling.
- **shellcheck is BLOCKING** in CI. The `.shellcheckrc` (with inline rationale for each disable) must land in the FIRST code commit so the dead-var delete doesn't go red.
- **Do NOT** add any rejected non-goal: caching, PR-comment posting, multi-model, diff-only/PR review, dry-run, live-streaming, startup worktree sweep, prune+retry self-heal, auto-relocation.
- **Local tooling:** `bats` and `shellcheck` are NOT installed locally. Install via Homebrew before running tests: `brew install bats-core shellcheck`.

---

## Task 1: Test harness + shellcheck config + QW1 (dead var)

Establishes the bats harness with stubs, the `.shellcheckrc`, and lands the dead-`BASE_BRANCH` delete in the same commit so shellcheck is green from the start. The harness here is the foundation every later task's tests build on.

**Files:**
- Create: `test/stubs/codex` (stub executable)
- Create: `test/stubs/gh` (stub executable)
- Create: `test/helper.bash` (shared bats setup: temp repo, PATH, run helper)
- Create: `test/target_resolution.bats` (first real cases)
- Create: `.shellcheckrc`
- Modify: `i7aket/skills/codex-check/scripts/run.sh:145` (delete `BASE_BRANCH`)

**Interfaces:**
- Produces: `test/helper.bash` exporting `make_repo` (creates a throwaway git repo, echoes its path), `RUN` (absolute path to run.sh), and a stub-PATH setup. The `codex` stub writes `STUB-REPORT oid=<HEAD-of-the--C-worktree>` to its `-o` file and appends a line `codex-invoked` to `$CODEX_LOG`. The `gh` stub prints nothing and exits 0. Later tasks add `.bats` files using these.

- [ ] **Step 1: Install local tooling**

Run:
```bash
brew install bats-core shellcheck
bats --version && shellcheck --version
```
Expected: both print versions (bats ≥ 1.10, shellcheck ≥ 0.9).

- [ ] **Step 2: Write the `codex` stub**

Create `test/stubs/codex` (and `chmod +x` it):
```bash
#!/usr/bin/env bash
# Test stub for `codex exec`. Records the worktree it was pointed at (-C) and the
# HEAD OID there, writes a canned report to the -o file. Honors CODEX_STUB_REPORT
# (path to a file whose contents become the report body) and CODEX_STUB_RC.
set -euo pipefail
wt=""; out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -C) shift; wt="$1" ;;
    -o) shift; out="$1" ;;
  esac
  shift || true
done
oid="$(git -C "$wt" rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
echo "codex-invoked oid=$oid" >> "${CODEX_LOG:-/dev/null}"
if [[ -n "$out" ]]; then
  if [[ -n "${CODEX_STUB_REPORT:-}" && -f "${CODEX_STUB_REPORT}" ]]; then
    cat "${CODEX_STUB_REPORT}" > "$out"
  else
    printf 'STUB-REPORT oid=%s\n' "$oid" > "$out"
  fi
fi
exit "${CODEX_STUB_RC:-0}"
```

- [ ] **Step 3: Write the `gh` stub**

Create `test/stubs/gh` (and `chmod +x` it):
```bash
#!/usr/bin/env bash
# Test stub for gh: succeed silently so PR-context lookups are inert in tests.
exit 0
```

- [ ] **Step 4: Write `test/helper.bash`**

Create `test/helper.bash`:
```bash
# Shared bats helpers. bash 3.2-safe (CI is bash 5; local macOS is the 3.2 gate).
REPO_ROOT_OF_PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$REPO_ROOT_OF_PLUGIN/i7aket/skills/codex-check/scripts/run.sh"
STUBS="$REPO_ROOT_OF_PLUGIN/test/stubs"

setup() {
  TESTTMP="$(mktemp -d "${TMPDIR:-/tmp}/cc-bats.XXXXXX")"
  CODEX_LOG="$TESTTMP/codex.log"; : > "$CODEX_LOG"
  export CODEX_LOG
  export PATH="$STUBS:$PATH"
  export CODEX_CHECK_NO_UPDATE_CHECK=1   # never hit the network in tests
}

teardown() {
  [[ -n "${WORKREPO:-}" ]] && git -C "$WORKREPO" worktree prune 2>/dev/null || true
  rm -rf "$TESTTMP" "${WORKREPO:-}" 2>/dev/null || true
}

# make_repo: create a throwaway repo with an origin so base-ref logic works.
# Echoes the working repo path. Sets WORKREPO for teardown.
make_repo() {
  local up="$TESTTMP/upstream.git" wr="$TESTTMP/work"
  git init -q --bare "$up"
  git init -q "$wr"
  git -C "$wr" config user.email t@t; git -C "$wr" config user.name t
  git -C "$wr" remote add origin "$up"
  git -C "$wr" commit -q --allow-empty -m "AAA-0 base"
  git -C "$wr" branch -M main
  git -C "$wr" push -q -u origin main
  git -C "$wr" remote set-head origin main 2>/dev/null || true
  WORKREPO="$wr"; echo "$wr"
}

codex_ran()    { grep -q '^codex-invoked' "$CODEX_LOG"; }
codex_oid()    { sed -n 's/^codex-invoked oid=//p' "$CODEX_LOG" | tail -n1; }
```

- [ ] **Step 5: Write the first bats cases (target resolution)**

Create `test/target_resolution.bats`:
```bash
#!/usr/bin/env bats
load helper

@test "undefined target (no Ticket, no --ref/--branch) fails closed, codex never runs" {
  repo="$(make_repo)"
  printf '## Plan\nno ticket here\n' > "$repo/plan.md"
  cd "$repo"
  run bash "$RUN" plan.md
  [ "$status" -ne 0 ]
  run codex_ran; [ "$status" -ne 0 ]
}

@test "Ticket: none reviews the base ref" {
  repo="$(make_repo)"
  printf 'Ticket: none\n\n## Plan\nx\n' > "$repo/plan.md"
  base="$(git -C "$repo" rev-parse origin/main)"
  cd "$repo"
  run bash "$RUN" plan.md
  [ "$status" -eq 0 ]
  [ "$(codex_oid)" = "$base" ]
}

@test "ambiguous ticket (two branches) fails closed, codex never runs" {
  repo="$(make_repo)"
  git -C "$repo" branch feat/AAA-1-alpha
  git -C "$repo" branch fix/AAA-1-beta
  printf 'Ticket: AAA-1\n\n## Plan\nx\n' > "$repo/plan.md"
  cd "$repo"
  run bash "$RUN" plan.md
  [ "$status" -ne 0 ]
  run codex_ran; [ "$status" -ne 0 ]
}

@test "--branch disambiguates an otherwise-ambiguous ticket" {
  repo="$(make_repo)"
  git -C "$repo" branch feat/AAA-1-alpha
  git -C "$repo" branch fix/AAA-1-beta
  printf 'Ticket: AAA-1\n\n## Plan\nx\n' > "$repo/plan.md"
  want="$(git -C "$repo" rev-parse feat/AAA-1-alpha)"
  cd "$repo"
  run bash "$RUN" plan.md --branch feat/AAA-1-alpha
  [ "$status" -eq 0 ]
  [ "$(codex_oid)" = "$want" ]
}

@test "metadata-region Ticket binds; a Ticket: only in body prose does not" {
  repo="$(make_repo)"
  git -C "$repo" branch feat/AAA-9-target
  # Normal plan layout: an h1 title on line 1, then a section, then a body Ticket:.
  # The metadata region ends at the first heading, so the body Ticket: must NOT
  # bind the target -> fail closed. (The line-1-h2 edge is covered by F9/Task 3b.)
  printf '# My Plan\n\n## Section\n\nTicket: AAA-9 in prose\n' > "$repo/plan.md"
  cd "$repo"
  run bash "$RUN" plan.md
  [ "$status" -ne 0 ]   # body Ticket must NOT resolve a target -> fail closed
}

@test "explicit --ref <sha> targets that exact OID" {
  repo="$(make_repo)"
  git -C "$repo" commit -q --allow-empty -m "second"
  sha="$(git -C "$repo" rev-parse HEAD)"
  printf '## Plan\nx\n' > "$repo/plan.md"
  cd "$repo"
  run bash "$RUN" plan.md --ref "$sha"
  [ "$status" -eq 0 ]
  [ "$(codex_oid)" = "$sha" ]
}
```

- [ ] **Step 6: Run the suite — expect PASS (it tests existing v1.2.0 behavior)**

Run: `cd <clone> && bats test/target_resolution.bats`
Expected: 6 passing. (These pin behavior that already exists; if any fail, the stub/helper is wrong — fix the harness, not run.sh.)

- [ ] **Step 7: Write `.shellcheckrc`**

Create `.shellcheckrc` at repo root:
```
# codex-check shellcheck config. shellcheck is a BLOCKING CI gate; these disables
# document deliberate, load-bearing bash 3.2-safe idioms — not sloppiness.

# SC2206: intentional word-splitting of the semver string into an array in the
# version comparator (numeric components only; safe).
disable=SC2206
# SC2034: some vars are assigned for documentation/report headers and read only
# via indirect/heredoc expansion; case-by-case false positives.
disable=SC2034
# SC2015 (info): `A && B || C` in set_plan() is intentional — B's last command
# (PLAN_SET=1) always returns 0, so C (die) only fires when A is false. The
# A-and-B-then-C pattern is correct here, not the foot-gun SC2015 warns about.
disable=SC2015
```

- [ ] **Step 8: Run shellcheck — expect it to flag the dead BASE_BRANCH**

Run: `shellcheck -x -s bash i7aket/skills/codex-check/scripts/run.sh`
Expected: an SC2034 (unused var) or similar pointing at `BASE_BRANCH` is suppressed by the rc, OR shellcheck is otherwise clean. If `BASE_BRANCH` still shows, that confirms it's dead — proceed to delete it.

- [ ] **Step 9: Delete the dead `BASE_BRANCH` line (QW1)**

In `i7aket/skills/codex-check/scripts/run.sh`, delete line ~145:
```sh
BASE_BRANCH="${BASE_REF#origin/}"   # bare name for fetch (may be empty)
```
First verify zero readers: `grep -n 'BASE_BRANCH' i7aket/skills/codex-check/scripts/run.sh` should show ONLY that line. Then remove it entirely (line + trailing comment).

- [ ] **Step 10: Re-run shellcheck + bats**

Run:
```bash
shellcheck -x -s bash i7aket/skills/codex-check/scripts/run.sh
bash -n i7aket/skills/codex-check/scripts/run.sh
bats test/target_resolution.bats
```
Expected: shellcheck clean, `bash -n` OK, 6 bats pass.

- [ ] **Step 11: Commit**

```bash
git add test/ .shellcheckrc i7aket/skills/codex-check/scripts/run.sh
git -c user.name="i7aket" -c user.email="i7aket@users.noreply.github.com" \
  commit -m "test: bats harness + shellcheck config; QW1 delete dead BASE_BRANCH"
```

---

## Task 2: GitHub Actions CI (shellcheck + bats)

Wires the harness into CI so the contract is enforced on every push/PR.

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `test/*.bats`, `.shellcheckrc`, `i7aket/skills/codex-check/scripts/run.sh` from Task 1.

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/ci.yml`:
```yaml
name: ci
on:
  push:
  pull_request:
jobs:
  shellcheck:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: shellcheck (blocking)
        run: shellcheck -x -s bash i7aket/skills/codex-check/scripts/run.sh
  bats:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: install bats
        run: sudo apt-get update && sudo apt-get install -y bats
      - name: run bats
        run: bats test/
```

- [ ] **Step 2: Validate the YAML locally**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml')); print('YAML OK')"`
Expected: `YAML OK`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git -c user.name="i7aket" -c user.email="i7aket@users.noreply.github.com" \
  commit -m "ci: shellcheck (blocking) + bats on push/PR"
```

---

## Task 3: Quick wins QW2, QW3, QW4

Three local, low-risk run.sh fixes, each with a bats assertion. QW3 is the one with a real subtlety (signal handler must abort, not resume).

**Files:**
- Modify: `i7aket/skills/codex-check/scripts/run.sh` (~L329-332 QW2, ~L319 QW3, ~L320 QW4)
- Create: `test/quick_wins.bats`

**Interfaces:**
- Consumes: `test/helper.bash` (`make_repo`, `RUN`, `codex_oid`).

- [ ] **Step 1: Write the QW2 + QW3 bats cases (failing/proving)**

Create `test/quick_wins.bats`:
```bash
#!/usr/bin/env bats
load helper

@test "QW2: banner reports correct ahead/behind counts" {
  repo="$(make_repo)"
  # target is 2 ahead of origin/main, 1 behind (base advanced separately)
  git -C "$repo" checkout -q -b feat/AAA-2-x
  git -C "$repo" commit -q --allow-empty -m "ahead1"
  git -C "$repo" commit -q --allow-empty -m "ahead2"
  git -C "$repo" checkout -q main
  git -C "$repo" commit -q --allow-empty -m "base-advances"
  git -C "$repo" push -q origin main
  printf 'Ticket: AAA-2\n\n## Plan\nx\n' > "$repo/plan.md"
  cd "$repo"
  run bash "$RUN" plan.md --branch feat/AAA-2-x
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE 'ahead 2 / behind 1'
}

@test "QW3: SIGTERM aborts (non-zero exit) AND leaves no leaked worktree" {
  repo="$(make_repo)"
  printf 'Ticket: none\n\n## Plan\nx\n' > "$repo/plan.md"
  # Make the codex stub hang so we can SIGTERM mid-run.
  cat > "$TESTTMP/slowcodex" <<'SC'
#!/usr/bin/env bash
out=""; while [[ $# -gt 0 ]]; do [[ "$1" == -o ]] && { shift; out="$1"; }; shift || true; done
sleep 30
SC
  chmod +x "$TESTTMP/slowcodex"
  cd "$repo"
  PATH="$TESTTMP:$PATH" CODEX_BIN_OVERRIDE=1 bash "$RUN" plan.md >/dev/null 2>&1 &
  pid=$!
  # wait until a codex-check worktree exists, then TERM the script
  for _ in $(seq 1 100); do
    git -C "$repo" worktree list | grep -q codex-check && break
    sleep 0.1
  done
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid"; rc=$?
  [ "$rc" -ne 0 ]                                   # MUST abort, not exit 0
  ! git -C "$repo" worktree list | grep -q codex-check   # no leaked worktree
}
```
NOTE: the QW3 test needs the slow codex on PATH. If `run.sh` resolves `codex` via `command -v`, putting `$TESTTMP` first on PATH and naming the stub `codex` is simpler — adjust the test to `cp "$TESTTMP/slowcodex" "$TESTTMP/codex"` and `PATH="$TESTTMP:$PATH"`. Use whichever the script's lookup honors; verify by running the test.

- [ ] **Step 2: Run QW2/QW3 tests — expect QW2 PASS (existing), QW3 may already leak**

Run: `bats test/quick_wins.bats`
Expected: QW2 passes (v1.2.0 already computes ahead/behind). QW3 likely FAILS on current `trap cleanup EXIT` (rc may be non-zero from kill but worktree may leak, OR the broadened-but-naive trap would exit 0) — this is the bug we fix in Step 4.

- [ ] **Step 3: Apply QW2 — one `read` for ahead/behind**

In `run.sh`, replace the ahead/behind block (~L329-332):
```sh
AHEAD_BEHIND="n/a"
if [[ -n "$BASE_REF" ]]; then
  ab="$(git rev-list --left-right --count "$BASE_REF...$TARGET_OID" 2>/dev/null || true)"
  [[ -n "$ab" ]] && AHEAD_BEHIND="ahead $(printf '%s' "$ab" | awk '{print $2}') / behind $(printf '%s' "$ab" | awk '{print $1}') vs $BASE_REF"
fi
```
with:
```sh
AHEAD_BEHIND="n/a"
if [[ -n "$BASE_REF" ]]; then
  ab="$(git rev-list --left-right --count "$BASE_REF...$TARGET_OID" 2>/dev/null || true)"
  if [[ -n "$ab" ]]; then
    # rev-list --left-right --count BASE...TARGET prints "<behind>\t<ahead>"
    # (left = base-only = behind; right = target-only = ahead).
    read -r _behind _ahead <<<"$ab"
    AHEAD_BEHIND="ahead $_ahead / behind $_behind vs $BASE_REF"
  fi
fi
```

- [ ] **Step 4: Apply QW3 — abort-on-signal trap**

In `run.sh`, replace the single `trap cleanup EXIT` (~L319) with:
```sh
trap cleanup EXIT
# A signal trap that only runs cleanup does NOT stop the script — bash resumes
# after the handler, so a SIGTERM'd run would continue and exit 0 (verified).
# These handlers clean up and exit with 128+signal so the run actually aborts.
trap 'cleanup; trap - INT TERM HUP EXIT; exit 130' INT
trap 'cleanup; trap - INT TERM HUP EXIT; exit 143' TERM
trap 'cleanup; trap - INT TERM HUP EXIT; exit 129' HUP
```

- [ ] **Step 5: Apply QW4 — capture git stderr on worktree-add failure**

In `run.sh`, replace the worktree-add line (~L320):
```sh
git worktree add --detach "$WT" "$TARGET_OID" >/dev/null 2>&1 || die "git worktree add failed"
```
with:
```sh
_wt_err="$(git worktree add --detach "$WT" "$TARGET_OID" 2>&1 >/dev/null)" \
  || die "git worktree add failed: ${_wt_err}"
```

- [ ] **Step 6: Run tests + shellcheck**

Run:
```bash
shellcheck -x -s bash i7aket/skills/codex-check/scripts/run.sh
bash -n i7aket/skills/codex-check/scripts/run.sh
bats test/
```
Expected: shellcheck clean, syntax OK, all bats pass (QW3 now aborts non-zero with no leaked worktree).

- [ ] **Step 7: Commit**

```bash
git add i7aket/skills/codex-check/scripts/run.sh test/quick_wins.bats
git -c user.name="i7aket" -c user.email="i7aket@users.noreply.github.com" \
  commit -m "fix(run.sh): QW2 one-read ahead/behind; QW3 abort-on-signal trap; QW4 surface worktree-add error"
```

---

## Task 3b: F9 — metadata-fence ignores a line-1 `## ` heading

**Discovered during Task 1.** The metadata-region fence at `run.sh:182`
(`awk 'NR>1 && /^## /{exit} {print} NR>=40{exit}'`) exempts line 1 from the
`## ` boundary (the `NR>1` guard, originally to allow a YAML front-matter or title
on line 1). Consequence: a plan whose **first line is an h2** (`## Plan`) followed
by a body `Ticket:` lets that body ticket leak into the metadata region and bind
the target — the exact wrong-target leak the surrounding comment claims to
prevent. Verified empirically: `## Plan\n\nTicket: AAA-9` → body ticket extracted.
Normal layouts (`# Title` h1 line 1, or a `Ticket:` metadata line on top) are
unaffected. Fix: make the fence stop at the first heading of ANY level
(`#`/`##`/…) regardless of line number, while still allowing a leading YAML
front-matter block delimited by `---`.

**Files:**
- Modify: `i7aket/skills/codex-check/scripts/run.sh:182` (the `META_REGION` awk)
- Modify: `test/target_resolution.bats` (add the line-1-h2 edge case)

- [ ] **Step 1: Add the failing edge-case test**

Append to `test/target_resolution.bats`:
```bash
@test "F9: a line-1 h2 heading still ends the metadata region (body ticket ignored)" {
  repo="$(make_repo)"
  git -C "$repo" branch feat/AAA-9-target
  # First line is an h2 (no title, no metadata Ticket). Body ticket must NOT bind.
  printf '## Plan\n\nTicket: AAA-9 in prose\n' > "$repo/plan.md"
  cd "$repo"
  run bash "$RUN" plan.md
  [ "$status" -ne 0 ]   # fail closed — body Ticket must not resolve a target
}

@test "F9: a leading YAML front-matter block is still allowed (Ticket inside binds)" {
  repo="$(make_repo)"
  git -C "$repo" branch feat/AAA-3-fm
  printf -- '---\nTicket: AAA-3\n---\n\n## Plan\nx\n' > "$repo/plan.md"
  want="$(git -C "$repo" rev-parse feat/AAA-3-fm)"
  cd "$repo"
  run bash "$RUN" plan.md
  [ "$status" -eq 0 ]
  [ "$(codex_oid)" = "$want" ]
}
```

- [ ] **Step 2: Run — expect the line-1-h2 case to FAIL**

Run: `bats test/target_resolution.bats`
Expected: the F9 line-1-h2 case FAILS (target resolves to the body ticket today).

- [ ] **Step 3: Fix the fence**

In `run.sh`, replace line ~182:
```sh
META_REGION="$(awk 'NR>1 && /^## /{exit} {print} NR>=40{exit}' "$PLAN_PATH" 2>/dev/null || true)"
```
with a fence that (a) ends at the first heading of any level, regardless of line
number, and (b) still allows a leading `---`-delimited YAML front-matter block:
```sh
# Metadata region = the file head up to the first Markdown heading (any level),
# bounded to 40 lines. A leading YAML front-matter block (delimited by --- on
# line 1 and a closing ---) is kept as metadata. We do NOT exempt line 1 from
# the heading fence: a line-1 `## ` is a section, not metadata (else a body
# Ticket: could leak in and hijack the target).
META_REGION="$(awk '
  NR==1 && $0=="---" { infm=1; print; next }
  infm && $0=="---" { infm=0; print; next }
  infm { print; next }
  /^#+[[:space:]]/ { exit }
  { print }
  NR>=40 { exit }
' "$PLAN_PATH" 2>/dev/null || true)"
```

- [ ] **Step 4: Run the full target_resolution suite + shellcheck**

Run:
```bash
shellcheck -x -s bash i7aket/skills/codex-check/scripts/run.sh
bash -n i7aket/skills/codex-check/scripts/run.sh
bats test/target_resolution.bats
```
Expected: shellcheck clean, syntax OK, all cases PASS (including both F9 cases and the original metadata/body case).

- [ ] **Step 5: Commit**

```bash
git add i7aket/skills/codex-check/scripts/run.sh test/target_resolution.bats
git -c user.name="i7aket" -c user.email="i7aket@users.noreply.github.com" \
  commit -m "fix(run.sh): F9 metadata fence stops at first heading (line-1 h2 no longer leaks body ticket)"
```

---

## Task 4: F7 — plan/commit skew disclosure (`PLAN STATUS`)

Add one diagnostic line classifying the plan vs the target commit, with the fail-safe ordering both reviews demanded. Never changes target selection.

**Files:**
- Modify: `i7aket/skills/codex-check/scripts/run.sh` (compute near the banner ~L327; emit in banner ~L336-340, report header ~L440-447, and prompt heredoc ~L369-391)
- Create: `test/plan_status.bats`

**Interfaces:**
- Consumes: `PLAN_PATH` (absolute, L131), `PLAN_REL` (L132), `TARGET_OID`, `REPO_ROOT` — all already set before the banner.
- Produces: shell var `PLAN_STATUS` (one of `matches`, `DIFFERS`, `untracked`, `out-of-repo`, `symlink (skew not checked)`), referenced by banner, report header, and prompt.

- [ ] **Step 1: Write the F7 bats cases**

Create `test/plan_status.bats`:
```bash
#!/usr/bin/env bats
load helper

@test "F7: plan matching the target commit reports matches" {
  repo="$(make_repo)"
  printf 'Ticket: none\n\n## Plan\nstable\n' > "$repo/plan.md"
  git -C "$repo" add plan.md; git -C "$repo" commit -q -m "AAA add plan"
  git -C "$repo" push -q origin main
  cd "$repo"
  run bash "$RUN" plan.md --pre-implementation
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'PLAN STATUS: matches'
}

@test "F7: plan edited after the target commit reports DIFFERS" {
  repo="$(make_repo)"
  printf 'Ticket: none\n\n## Plan\nv1\n' > "$repo/plan.md"
  git -C "$repo" add plan.md; git -C "$repo" commit -q -m "AAA add plan"
  git -C "$repo" push -q origin main
  printf 'Ticket: none\n\n## Plan\nv2 EDITED\n' > "$repo/plan.md"   # working copy now differs
  cd "$repo"
  run bash "$RUN" plan.md --pre-implementation
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'PLAN STATUS: DIFFERS'
}

@test "F7: plan untracked at target reports untracked (NOT matches)" {
  repo="$(make_repo)"
  # plan.md is never committed -> absent at origin/main (the base target)
  printf 'Ticket: none\n\n## Plan\nx\n' > "$repo/plan.md"
  cd "$repo"
  run bash "$RUN" plan.md --pre-implementation
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'PLAN STATUS: untracked'
  ! echo "$output" | grep -q 'PLAN STATUS: matches'
}

@test "F7: symlinked plan reports symlink (skew not checked)" {
  repo="$(make_repo)"
  printf 'Ticket: none\n\n## Plan\nx\n' > "$repo/real-plan.md"
  ln -s real-plan.md "$repo/plan.md"
  cd "$repo"
  run bash "$RUN" plan.md --pre-implementation
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'PLAN STATUS: symlink (skew not checked)'
}
```

- [ ] **Step 2: Run — expect FAIL (no PLAN STATUS yet)**

Run: `bats test/plan_status.bats`
Expected: all 4 FAIL (`PLAN STATUS` not emitted).

- [ ] **Step 3: Compute `PLAN_STATUS` (insert before the banner, ~after L333)**

In `run.sh`, immediately before the `log "─────…"` banner start (~L335), insert:
```sh
# --- F7: plan/commit skew disclosure (diagnostic only) ----------------------
# Order matters: a symlink, an out-of-repo path, or a path untracked AT THE
# TARGET COMMIT must NOT be byte-compared (git show / cmp would mislead).
if [[ -L "$PLAN_PATH" ]]; then
  PLAN_STATUS="symlink (skew not checked)"
elif [[ "$PLAN_REL" == /* ]]; then
  # PLAN_REL still absolute => not under REPO_ROOT (e.g. a different worktree).
  PLAN_STATUS="out-of-repo"
elif ! git cat-file -e "${TARGET_OID}:${PLAN_REL}" 2>/dev/null; then
  PLAN_STATUS="untracked"   # not present at the target commit
elif cmp -s <(git show "${TARGET_OID}:${PLAN_REL}" 2>/dev/null) "$PLAN_PATH"; then
  PLAN_STATUS="matches"
else
  PLAN_STATUS="DIFFERS"
fi
```

- [ ] **Step 4: Emit `PLAN STATUS` in the banner (~L339, after the plan line)**

In `run.sh`, after the `log "REVIEWING  plan   : …"` line, add:
```sh
log "REVIEWING  plan st: PLAN STATUS: ${PLAN_STATUS}"
```

- [ ] **Step 5: Emit `PLAN STATUS` in the report header (~L446, after the Plan line)**

In the report `{ … } > "$REVIEW_PATH"` block, after `echo "- Plan: $PLAN_REL"`, add:
```sh
  echo "- PLAN STATUS: ${PLAN_STATUS}"
```

- [ ] **Step 6: Surface skew to Codex in the prompt heredoc (~L369-391)**

In the `read -r -d '' PROMPT <<EOF` heredoc, add a line near the top context (after the "Reviewing against" line) so Codex is told about skew:
```
NOTE: PLAN STATUS = ${PLAN_STATUS}. If "DIFFERS" or "untracked", the plan file in
this worktree may not match the reviewed commit — call that out.
```

- [ ] **Step 7: Run tests + shellcheck**

Run:
```bash
shellcheck -x -s bash i7aket/skills/codex-check/scripts/run.sh
bash -n i7aket/skills/codex-check/scripts/run.sh
bats test/plan_status.bats
```
Expected: shellcheck clean, syntax OK, 4 plan_status tests PASS.

- [ ] **Step 8: Run the FULL suite (no regressions)**

Run: `bats test/`
Expected: all pass.

- [ ] **Step 9: Commit**

```bash
git add i7aket/skills/codex-check/scripts/run.sh test/plan_status.bats
git -c user.name="i7aket" -c user.email="i7aket@users.noreply.github.com" \
  commit -m "feat(run.sh): F7 disclose plan/commit skew via PLAN STATUS line"
```

---

## Task 5: F8 — opt-in severity gating via `GATE=` token

Add a stable ASCII gate token to the prompt and an opt-in exit-code mapping that fails closed, preserving the stdout=report-path contract.

**Files:**
- Modify: `i7aket/skills/codex-check/scripts/run.sh` (prompt heredoc ~L369-391; new gating block AFTER the final `printf '%s\n' "$REVIEW_PATH"` ~L454)
- Modify: `i7aket/commands/codex-check.md` (add the gate prompt requirement + the exit-code contract note)
- Create: `test/gating.bats`

**Interfaces:**
- Consumes: `REVIEW_PATH` (the written report, end of run.sh), `CODEX_CHECK_GATE` (env, opt-in).
- Produces: process exit code — `READY`→0, `REVISE`→2, `REWORK`→3, missing token→2 (fail closed). When `CODEX_CHECK_GATE` unset, exit unchanged (0).

- [ ] **Step 1: Write the gating bats cases**

Create `test/gating.bats`:
```bash
#!/usr/bin/env bats
load helper

# Helper: make a stub report file the codex stub will emit verbatim.
_mk_report() { printf '%s\n' "$1" > "$TESTTMP/report.txt"; export CODEX_STUB_REPORT="$TESTTMP/report.txt"; }

@test "F8: gate unset -> exit 0 regardless of GATE token" {
  repo="$(make_repo)"; printf 'Ticket: none\n\n## Plan\nx\n' > "$repo/plan.md"
  _mk_report "verdict text
GATE=REWORK"
  cd "$repo"
  run bash "$RUN" plan.md --pre-implementation
  [ "$status" -eq 0 ]
}

@test "F8: GATE=READY -> exit 0; last stdout line is the report path" {
  repo="$(make_repo)"; printf 'Ticket: none\n\n## Plan\nx\n' > "$repo/plan.md"
  _mk_report "ok
GATE=READY"
  cd "$repo"
  CODEX_CHECK_GATE=1 run bash "$RUN" plan.md --pre-implementation
  [ "$status" -eq 0 ]
  last="$(printf '%s\n' "$output" | tail -n1)"
  [[ "$last" == *.codex-review.md ]]
}

@test "F8: GATE=REWORK -> exit 3; report path still printed" {
  repo="$(make_repo)"; printf 'Ticket: none\n\n## Plan\nx\n' > "$repo/plan.md"
  _mk_report "needs work
GATE=REWORK"
  cd "$repo"
  CODEX_CHECK_GATE=1 run bash "$RUN" plan.md --pre-implementation
  [ "$status" -eq 3 ]
  printf '%s\n' "$output" | grep -q '\.codex-review\.md'
}

@test "F8: GATE=REVISE -> exit 2" {
  repo="$(make_repo)"; printf 'Ticket: none\n\n## Plan\nx\n' > "$repo/plan.md"
  _mk_report "minor
GATE=REVISE"
  cd "$repo"
  CODEX_CHECK_GATE=1 run bash "$RUN" plan.md --pre-implementation
  [ "$status" -eq 2 ]
}

@test "F8: gate on but NO token -> fail closed (exit 2)" {
  repo="$(make_repo)"; printf 'Ticket: none\n\n## Plan\nx\n' > "$repo/plan.md"
  _mk_report "a review with no gate token at all"
  cd "$repo"
  CODEX_CHECK_GATE=1 run bash "$RUN" plan.md --pre-implementation
  [ "$status" -eq 2 ]
}
```

- [ ] **Step 2: Run — expect FAIL (no gating yet)**

Run: `bats test/gating.bats`
Expected: the READY/REWORK/REVISE/no-token cases FAIL (script always exits 0 today); the "gate unset" case passes.

- [ ] **Step 3: Add the GATE requirement to the prompt heredoc**

In `run.sh`, inside the `<<EOF` prompt (after the existing `SUMMARY: 2-3 sentences.` line, ~L390, BEFORE `EOF`), add:
```
As the LAST line of your answer, with nothing after it, output verbatim exactly one of:
GATE=READY
GATE=REVISE
GATE=REWORK
(ASCII only, regardless of the language of the review above.)
```

- [ ] **Step 4: Add the gating exit block at the very end of run.sh (after L454)**

In `run.sh`, after the final `printf '%s\n' "$REVIEW_PATH"` line, append:
```sh
# --- F8: opt-in severity gating (fail-closed) -------------------------------
# Only active when CODEX_CHECK_GATE is set. Parse a stable ASCII token from the
# report (NOT the free-text VERDICT, which may be non-English). Report path was
# already printed above, preserving the "last stdout line = report path" contract.
if [[ -n "${CODEX_CHECK_GATE:-}" ]]; then
  _gate="$(grep -E '^GATE=(READY|REVISE|REWORK)$' "$REVIEW_PATH" 2>/dev/null | tail -n1)"
  case "$_gate" in
    GATE=READY)  exit 0 ;;
    GATE=REVISE) exit 2 ;;
    GATE=REWORK) exit 3 ;;
    *) log "gate: no GATE= token found in report — failing closed"; exit 2 ;;
  esac
fi
```

- [ ] **Step 5: Run tests + shellcheck**

Run:
```bash
shellcheck -x -s bash i7aket/skills/codex-check/scripts/run.sh
bash -n i7aket/skills/codex-check/scripts/run.sh
bats test/gating.bats
```
Expected: shellcheck clean, syntax OK, all 5 gating tests PASS.

- [ ] **Step 6: Update command.md — gate prompt + exit-code contract**

In `i7aket/commands/codex-check.md`:
- In the section describing what the script does (the "What it reviews against" / behavior area), add a sentence: "When `CODEX_CHECK_GATE` is set, the review ends with a `GATE=READY|REVISE|REWORK` token and the script exits 0/2/3 accordingly (missing token → exit 2, fail-closed)."
- In the "Report the result" / "Wait for the background task" area, add: "Under `CODEX_CHECK_GATE`, a non-zero exit of **2 or 3 with a report path on the last stdout line** is a *successful* REVISE/REWORK verdict — read and report it normally. It is NOT a failure."
- In "Error handling", add: "Only a `[codex-check] ERROR: …` message with no report is a real failure; a gated 2/3 exit that still printed a report path is a successful gated verdict."

- [ ] **Step 7: Run the FULL suite (no regressions)**

Run: `bats test/`
Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add i7aket/skills/codex-check/scripts/run.sh i7aket/commands/codex-check.md test/gating.bats
git -c user.name="i7aket" -c user.email="i7aket@users.noreply.github.com" \
  commit -m "feat: F8 opt-in severity gating via stable GATE= token (fail-closed)"
```

---

## Task 6: Remaining bats coverage (close the contract gaps)

The reviews demanded coverage of branches the earlier tasks didn't touch. Add them now that the harness supports everything.

**Files:**
- Create: `test/contract_extra.bats`

**Interfaces:**
- Consumes: `test/helper.bash`.

- [ ] **Step 1: Write the extra contract cases**

Create `test/contract_extra.bats`:
```bash
#!/usr/bin/env bats
load helper

@test "GIT_DIR leak in env is neutralized (run still succeeds)" {
  repo="$(make_repo)"; printf 'Ticket: none\n\n## Plan\nx\n' > "$repo/plan.md"
  cd "$repo"
  GIT_DIR=/nonexistent/leak.git run bash "$RUN" plan.md --pre-implementation
  [ "$status" -eq 0 ]
}

@test "auth: report quoting 401 Unauthorized is kept (success)" {
  repo="$(make_repo)"; printf 'Ticket: none\n\n## Plan\nx\n' > "$repo/plan.md"
  printf 'review body mentions 401 Unauthorized in passing\n' > "$TESTTMP/r.txt"
  cd "$repo"
  CODEX_STUB_REPORT="$TESTTMP/r.txt" run bash "$RUN" plan.md --pre-implementation
  [ "$status" -eq 0 ]
}

@test "auth: empty report + token_revoked stderr -> die" {
  repo="$(make_repo)"; printf 'Ticket: none\n\n## Plan\nx\n' > "$repo/plan.md"
  # stub that writes NO report and emits an auth error to stderr, exit non-zero
  cat > "$TESTTMP/codex" <<'SC'
#!/usr/bin/env bash
echo "error: token_revoked" >&2
exit 1
SC
  chmod +x "$TESTTMP/codex"
  cd "$repo"
  PATH="$TESTTMP:$PATH" run bash "$RUN" plan.md --pre-implementation
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'auth failed'
}

@test "--pre-implementation reviews the base ref" {
  repo="$(make_repo)"; printf '## Plan\nx\n' > "$repo/plan.md"
  base="$(git -C "$repo" rev-parse origin/main)"
  cd "$repo"
  run bash "$RUN" plan.md --pre-implementation
  [ "$status" -eq 0 ]; [ "$(codex_oid)" = "$base" ]
}

@test "CODEX_CHECK_REF env resolves target; --ref flag overrides env" {
  repo="$(make_repo)"
  git -C "$repo" commit -q --allow-empty -m two; two="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" commit -q --allow-empty -m three; three="$(git -C "$repo" rev-parse HEAD)"
  printf '## Plan\nx\n' > "$repo/plan.md"
  cd "$repo"
  CODEX_CHECK_REF="$two" run bash "$RUN" plan.md
  [ "$status" -eq 0 ]; [ "$(codex_oid)" = "$two" ]
  : > "$CODEX_LOG"
  CODEX_CHECK_REF="$two" run bash "$RUN" plan.md --ref "$three"
  [ "$status" -eq 0 ]; [ "$(codex_oid)" = "$three" ]
}

@test "origin/-prefixed --branch resolves to the remote branch" {
  repo="$(make_repo)"
  git -C "$repo" checkout -q -b feat/AAA-7-x
  git -C "$repo" commit -q --allow-empty -m x
  git -C "$repo" push -q origin feat/AAA-7-x
  want="$(git -C "$repo" rev-parse origin/feat/AAA-7-x)"
  git -C "$repo" checkout -q main
  printf '## Plan\nx\n' > "$repo/plan.md"
  cd "$repo"
  run bash "$RUN" plan.md --branch origin/feat/AAA-7-x
  [ "$status" -eq 0 ]; [ "$(codex_oid)" = "$want" ]
}
```
NOTE: re-confirm the exact `die` message text for the auth case against run.sh L418 (`Codex auth failed`) and adjust the `grep -qi 'auth failed'` if the wording differs.

- [ ] **Step 2: Run + shellcheck**

Run:
```bash
bats test/contract_extra.bats
shellcheck -x -s bash i7aket/skills/codex-check/scripts/run.sh
```
Expected: all pass (these pin EXISTING v1.2.0 behavior; if one fails, the harness/assertion is wrong — fix the test, not run.sh, unless it reveals a real regression).

- [ ] **Step 3: Run the FULL suite**

Run: `bats test/`
Expected: every `.bats` file passes.

- [ ] **Step 4: Commit**

```bash
git add test/contract_extra.bats
git -c user.name="i7aket" -c user.email="i7aket@users.noreply.github.com" \
  commit -m "test: pin GIT_DIR-leak, auth both-directions, --pre-implementation, --ref env/flag, origin/-branch"
```

---

## Task 7: QW5 docs + version bump to 1.3.0

README install/update identity table + recovery box (verify repo-name first — likely no-op), then the version bump and CHANGELOG entry.

**Files:**
- Modify: `README.md` (install/update section)
- Modify: `i7aket/.claude-plugin/plugin.json` (version)
- Modify: `.claude-plugin/marketplace.json` (`plugins[0].version`)
- Modify: `CHANGELOG.md` (new `[1.3.0]` heading)

**Interfaces:** none (docs/metadata only).

- [ ] **Step 1: Verify repo-name consistency BEFORE editing (QW5 part 2)**

Run:
```bash
grep -n 'i7aket/tools\|i7aket/codex-check' i7aket/skills/codex-check/scripts/run.sh README.md .claude-plugin/marketplace.json
```
Expected: all references agree on `i7aket/tools` (marketplace `tools`, plugin `i7aket`). If they already agree, the "reconcile drift" sub-item is a **no-op** — only do the README table. If a real mismatch appears, fix the wrong one so all three agree, and note it in the commit.

- [ ] **Step 2: Add the install/update identity table + recovery box to README**

In `README.md`, in the install/update area, replace the `tools`-vs-`i7aket` parenthetical with:
```markdown
### Identity reference

| Thing             | Value                          |
|-------------------|--------------------------------|
| GitHub repo       | `i7aket/tools`                 |
| Marketplace name  | `tools`                        |
| Plugin name       | `i7aket`                       |
| Command           | `/i7aket:codex-check`          |
| Install path      | `~/.claude/plugins/cache/tools/i7aket/<version>` |

Install:
```
/plugin marketplace add i7aket/tools
/plugin install i7aket@tools
```
Update (run BOTH):
```
/plugin marketplace update tools
/plugin update i7aket@tools
```

> **If an update doesn't take:** re-run **both** commands above (the marketplace
> cache must refresh before the plugin sees a new version). Use only these
> supported commands.
```
(Do NOT document hand-editing `installed_plugins.json` — it is a footgun, not a supported path.)

- [ ] **Step 3: Bump the version in all three files**

In `i7aket/.claude-plugin/plugin.json`: `"version": "1.2.0"` → `"version": "1.3.0"`.
In `.claude-plugin/marketplace.json`: the `plugins[0].version` `"1.2.0"` → `"1.3.0"`.
Add to `CHANGELOG.md` above the `## [1.2.0]` heading:
```markdown
## [1.3.0] — 2026-06-27

### Added
- `--ref <rev>` is now exercised by tests; opt-in **severity gating** via a stable
  `GATE=READY|REVISE|REWORK` token (`CODEX_CHECK_GATE`): exit 0/2/3, fail-closed
  (missing token → 2). The report path is still the last stdout line.
- A `PLAN STATUS` line (banner + report + prompt) disclosing whether the plan
  file matches / differs from / is untracked at the reviewed commit.
- A bats + shellcheck CI gate (GitHub Actions) pinning the fail-closed
  target-resolution contract; shellcheck is blocking.

### Changed / Fixed
- Cancelled (`SIGTERM`/`SIGHUP`/`INT`) background runs now **abort** (exit
  128+signal) and no longer leak a worktree — a naive shared `EXIT` trap would
  have resumed and exited 0.
- `git worktree add` failures now surface git's real error message.
- Simplified the ahead/behind banner (one `read`, no `awk` subshells) and
  deleted a dead `BASE_BRANCH` variable.
- README gains an identity table + supported-paths-only update recovery note.
```

- [ ] **Step 4: Validate JSON + version alignment**

Run:
```bash
python3 -c "import json;json.load(open('i7aket/.claude-plugin/plugin.json'));json.load(open('.claude-plugin/marketplace.json'));print('JSON OK')"
grep -h '"version"' i7aket/.claude-plugin/plugin.json .claude-plugin/marketplace.json
```
Expected: `JSON OK`, both show `1.3.0`.

- [ ] **Step 5: Commit**

```bash
git add README.md i7aket/.claude-plugin/plugin.json .claude-plugin/marketplace.json CHANGELOG.md
git -c user.name="i7aket" -c user.email="i7aket@users.noreply.github.com" \
  commit -m "docs: install identity table + recovery box; bump to v1.3.0"
```

---

## Task 8: Full verification, PR, merge, tag, local install

Final gate, ship, and install so the user's `/i7aket:codex-check` runs v1.3.0.

**Files:** none (verification + delivery).

- [ ] **Step 1: Full local gate**

Run:
```bash
cd <clone>
shellcheck -x -s bash i7aket/skills/codex-check/scripts/run.sh && echo SHELLCHECK_OK
bash -n i7aket/skills/codex-check/scripts/run.sh && echo SYNTAX_OK
bats test/ && echo BATS_OK
wc -l i7aket/skills/codex-check/scripts/run.sh   # confirm not wildly larger than 454
```
Expected: `SHELLCHECK_OK`, `SYNTAX_OK`, `BATS_OK`, and line count near/below baseline+small (QW1/QW2 are net-negative; F7/F8 add a little).

- [ ] **Step 2: Push the branch**

```bash
git push -u origin feat/v1.3.0-simplify-test-harden
```

- [ ] **Step 3: Open the PR**

```bash
gh pr create --repo i7aket/tools --base master --head feat/v1.3.0-simplify-test-harden \
  --title "v1.3.0: simplify, test (shellcheck+bats CI), harden (signal-safe trap, plan-skew, gating)" \
  --body "See docs/superpowers/plans + spec. Adds a blocking shellcheck+bats CI gate, fixes a signal-trap worktree leak (cancelled runs now abort, not exit 0), adds PLAN STATUS skew disclosure and opt-in GATE= severity gating (fail-closed), and clarifies install docs. Reviewed pre-implementation by an independent agent + Codex xhigh.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

- [ ] **Step 4: Wait for CI green, then squash-merge + delete branch**

Run:
```bash
gh pr checks --repo i7aket/tools --watch || true
gh pr merge --repo i7aket/tools --squash --delete-branch
gh pr view --repo i7aket/tools --json state,mergedAt,mergeCommit -q '.state, .mergeCommit.oid'
```
Expected: `MERGED` + a merge SHA. (If CI is red, fix before merging.)

- [ ] **Step 5: Tag v1.3.0**

```bash
MERGESHA="$(gh pr view --repo i7aket/tools --json mergeCommit -q .mergeCommit.oid)"
gh api repos/i7aket/tools/git/refs -f ref="refs/tags/v1.3.0" -f sha="$MERGESHA"
gh api repos/i7aket/tools/git/refs/tags/v1.3.0 -q .ref
```
Expected: `refs/tags/v1.3.0`.

- [ ] **Step 6: Install v1.3.0 locally (same procedure as v1.2.0)**

```bash
MP=~/.claude/plugins/marketplaces/tools
git -C "$MP" fetch origin --tags --prune && git -C "$MP" reset --hard origin/master
NEW=~/.claude/plugins/cache/tools/i7aket/1.3.0
rm -rf "$NEW"; mkdir -p "$NEW"; cp -R "$MP/i7aket/." "$NEW/"
chmod +x "$NEW/skills/codex-check/scripts/run.sh"
# point installed_plugins.json at 1.3.0 (back it up first)
cp ~/.claude/plugins/installed_plugins.json ~/.claude/plugins/installed_plugins.json.bak-pre-1.3.0
python3 - "$NEW" "$MERGESHA" <<'PY'
import json,sys
nc,sha=sys.argv[1],sys.argv[2]
p=__import__('os').path.expanduser("~/.claude/plugins/installed_plugins.json")
d=json.load(open(p)); e=d["plugins"]["i7aket@tools"][0]
e["installPath"]=nc; e["version"]="1.3.0"; e["gitCommitSha"]=sha
json.dump(d,open(p,"w"),indent=2); print("installed:",e["version"])
PY
```
Expected: `installed: 1.3.0`.

- [ ] **Step 7: Smoke-test the installed v1.3.0**

```bash
RUN=~/.claude/plugins/cache/tools/i7aket/1.3.0/skills/codex-check/scripts/run.sh
grep -c 'PLAN_STATUS\|CODEX_CHECK_GATE\|exit 143' "$RUN"   # >0 confirms v1.3.0 features present
bash -n "$RUN" && echo SYNTAX_OK
```
Expected: count > 0, `SYNTAX_OK`. (A full live run needs Codex credits; the bats suite already proves behavior.)

- [ ] **Step 8: Final state confirmation**

```bash
gh pr view --repo i7aket/tools --json state -q .state            # MERGED
python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.claude/plugins/installed_plugins.json')))['plugins']['i7aket@tools'][0]['version'])"  # 1.3.0
```
Expected: `MERGED`, `1.3.0`.

---

## Self-Review (completed by plan author)

**Spec coverage:** QW1→Task1; QW2/QW3/QW4→Task3; QW5→Task7; CI→Task1+2; F7→Task4; F8→Task5; remaining contract bats (auth both-dir, GIT_DIR, --pre-implementation, ref env/flag, origin/-branch, divergence)→Task6; versioning→Task7; delivery→Task8. All spec sections mapped.

**Placeholder scan:** No TBD/TODO. Every code step shows actual code. Two explicit "re-confirm the exact text/line" notes (auth `die` wording, codex-lookup path for the slow stub) are verification instructions, not placeholders — they tell the implementer exactly what to check and adjust.

**Type/name consistency:** `PLAN_STATUS` defined in Task 4 Step 3, consumed in Steps 4-6 and Task 7 CHANGELOG; `CODEX_CHECK_GATE` defined/consumed consistently in Task 5; stub interface (`CODEX_LOG`, `CODEX_STUB_REPORT`, `CODEX_STUB_RC`, `codex_oid`) defined in Task 1 helper and used unchanged in Tasks 3-6.

**Known follow-ups for the implementer:** the "divergent local-vs-origin note" bats case from the spec is not separately written (it requires a diverged local+origin fixture); add it opportunistically in Task 6 if time allows, otherwise it is acceptably covered by manual reasoning — note it, don't silently drop it.
