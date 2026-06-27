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
  # Make codex hang so we can SIGTERM mid-run. run.sh resolves codex via
  # `command -v codex` and calls `codex exec`, so a stub named `codex` placed
  # FIRST on PATH shadows the real test stub. It must hang (sleep) so the script
  # is parked inside the codex call with the worktree already created.
  cat > "$TESTTMP/codex" <<'SC'
#!/usr/bin/env bash
sleep 30
SC
  chmod +x "$TESTTMP/codex"
  cd "$repo"
  PATH="$TESTTMP:$PATH" bash "$RUN" plan.md --pre-implementation >/dev/null 2>&1 &
  pid=$!
  # wait until a codex-check worktree exists, then TERM the script
  appeared=0
  for _ in $(seq 1 100); do
    if git -C "$repo" worktree list | grep -q codex-check; then appeared=1; break; fi
    sleep 0.1
  done
  [ "$appeared" -eq 1 ]                              # worktree must have been created
  kill -TERM "$pid" 2>/dev/null || true
  # Capture the script's exit status without letting a non-zero `wait` abort the
  # test body (bats fails the test on the first non-zero command otherwise).
  rc=0; wait "$pid" || rc=$?
  [ "$rc" -ne 0 ]                                    # MUST abort, not exit 0
  ! git -C "$repo" worktree list | grep -q codex-check   # no leaked worktree
}
