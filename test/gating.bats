#!/usr/bin/env bats
bats_require_minimum_version 1.5.0   # `run --separate-stderr` (CI installs bats 1.x; local is 1.13)
load helper

# Helper: make a stub report file the codex stub will emit verbatim.
_mk_report() { printf '%s\n' "$1" > "$TESTTMP/report.txt"; export CODEX_STUB_REPORT="$TESTTMP/report.txt"; }

# The "report path is the LAST stdout line" contract is about STDOUT only —
# run.sh's progress/cleanup logging goes to stderr (incl. the EXIT-trap
# "worktree removed" line that fires after the stdout path is printed). bats'
# default `run` merges both streams, so cases that assert the last *stdout*
# line use `run --separate-stderr` ($output = stdout only).

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
  CODEX_CHECK_GATE=1 run --separate-stderr bash "$RUN" plan.md --pre-implementation
  [ "$status" -eq 0 ]
  last="$(printf '%s\n' "$output" | tail -n1)"
  [[ "$last" == *.codex-review.md ]]
}

@test "F8: GATE=REWORK -> exit 3; report path still printed" {
  repo="$(make_repo)"; printf 'Ticket: none\n\n## Plan\nx\n' > "$repo/plan.md"
  _mk_report "needs work
GATE=REWORK"
  cd "$repo"
  CODEX_CHECK_GATE=1 run --separate-stderr bash "$RUN" plan.md --pre-implementation
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
