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
