#!/usr/bin/env bats
load helper

# NOTE: on macOS the bats tmpdir (/var/...) is a symlink to /private/var/...,
# so `git rev-parse --show-toplevel` (what run.sh uses for REPO_ROOT) returns a
# different string than make_repo's path. F7 strips REPO_ROOT off PLAN_PATH to
# get PLAN_REL; if the two disagree the plan looks "out-of-repo". Canonicalize
# the repo path to git's toplevel so the fixture matches run.sh's REPO_ROOT.
# (No-op on Linux CI where /tmp is not a symlink.)
_canon_repo() { cd "$1" && git rev-parse --show-toplevel; }

@test "F7: plan matching the target commit reports matches" {
  repo="$(_canon_repo "$(make_repo)")"
  printf 'Ticket: none\n\n## Plan\nstable\n' > "$repo/plan.md"
  git -C "$repo" add plan.md; git -C "$repo" commit -q -m "AAA add plan"
  git -C "$repo" push -q origin main
  cd "$repo"
  run bash "$RUN" plan.md --pre-implementation
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'PLAN STATUS: matches'
}

@test "F7: plan edited after the target commit reports DIFFERS" {
  repo="$(_canon_repo "$(make_repo)")"
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
  repo="$(_canon_repo "$(make_repo)")"
  # plan.md is never committed -> absent at origin/main (the base target)
  printf 'Ticket: none\n\n## Plan\nx\n' > "$repo/plan.md"
  cd "$repo"
  run bash "$RUN" plan.md --pre-implementation
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'PLAN STATUS: untracked'
  ! echo "$output" | grep -q 'PLAN STATUS: matches'
}

@test "F7: symlinked plan reports symlink (skew not checked)" {
  repo="$(_canon_repo "$(make_repo)")"
  printf 'Ticket: none\n\n## Plan\nx\n' > "$repo/real-plan.md"
  ln -s real-plan.md "$repo/plan.md"
  cd "$repo"
  run bash "$RUN" plan.md --pre-implementation
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'PLAN STATUS: symlink (skew not checked)'
}
