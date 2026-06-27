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
