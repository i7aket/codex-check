# Changelog

All notable changes to this plugin are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] — 2026-06-27

### Changed
- The review target now comes from the **plan**, not from whatever branch is checked out.
  Resolution priority: explicit `--branch <name>` (or `CODEX_CHECK_BRANCH`) → the unique
  branch carrying the plan's `Ticket:` key → pre-implementation against the base ref. The
  worktree is created from a resolved commit OID, so remote-only branches work too.
- Repository renamed `i7aket/codex-check` → `i7aket/tools`; install is now
  `/plugin marketplace add i7aket/tools`. (The old URL still redirects.)

### Added
- `--branch <name>` / `CODEX_CHECK_BRANCH` to review against an explicit branch.
- A loud warning when the plan's ticket differs from the checked-out branch's ticket.
- An ambiguity guard: if two branches carry the plan's ticket key, the run stops and asks
  for `--branch`.
- A best-effort newer-version notice at startup (numeric semver compare; silent if offline;
  opt out with `CODEX_CHECK_NO_UPDATE_CHECK=1`).

### Fixed
- False "token revoked" abort. The auth check used to grep the whole Codex stderr for
  `401 Unauthorized` / `token_revoked`, which matched when Codex merely *quoted* such a
  string (e.g. reviewing this very script) or when an unrelated MCP server logged a 401 —
  killing a successful run. Success is now decided by the report: a non-empty review from
  `-o` is kept even if Codex then exits non-zero; only a missing/empty report is a failure,
  and auth is blamed only when Codex's own error output looks like an auth problem.
- `bash` 3.2 portability (stock macOS): removed `mapfile` / associative arrays.

## [1.0.1]

- Initial published release: independent Codex review of an implementation plan in an
  isolated, auto-cleaned git worktree.
