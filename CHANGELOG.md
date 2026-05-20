# Changelog

All notable changes to the Review Council module are documented here.

## [1.2.0] — 2026-05-21

### Changed

- **Decision criteria**: all 12 reviewer agents now use HIGH/CRITICAL
  threshold for REQUEST CHANGES, aligning with the severity pack's own
  definition that MEDIUM "does not block the merge." Previously, a single
  MEDIUM finding triggered REQUEST CHANGES.
- **Go convention TC-003**: relaxed from MUST to SHOULD. The
  `TestXxx_Description` naming pattern is a readability convention, not
  a Go language requirement.
- **Go convention CS-005**: clarified that constructor-based
  initialization and nil-receiver panics are idiomatic Go, not violations
  of the "no panic for errors" rule.
- **Severity pack**: Adversary CRITICAL example changed from "panic in
  library code" to "explicit `panic()` used for expected error
  conditions." HIGH boundary now explicitly excludes style preferences
  and idiomatic language patterns.
- **Reviewer protocol**: added Proportionality section — not every review
  must produce findings; clean code warrants APPROVE with zero findings.
- **Adversary agent**: added calibration note excluding standard Go
  nil-receiver behavior from security findings.
- **Tester agent**: added calibration note — test coverage suggestions
  for well-tested code should be MEDIUM/LOW, not HIGH.
- **Delegation phase**: appended clean-code awareness guidance to every
  delegation prompt.
- **Verification phase**: added common false positive patterns to the
  independent validator prompt; added severity calibration rules for
  standard language semantics and test style preferences.

## [1.0.0] — 2026-05-08

### Added

- Initial release as a standalone Lola module, extracted from the
  Unbound Force monorepo
- Six reviewer agents (Guard, Architect, Adversary, Tester, Operator,
  Curator), each split into `-code.md` and `-spec.md` variants for
  mode-specific reviews
- Three content production agents (Scribe, Herald, Envoy) for
  documentation, blog, and communications tasks
- Six convention packs: `severity.md`, `base.md`, `go.md`,
  `typescript.md`, `content.md`, `reviewer-protocol.md`
- `/review-council` command with auto-detection, CI gate, parallel
  delegation, iterative fix loop, and unified verdict
- Four extension points: Constitution, Knowledge tool, Docs repo,
  Quality tool — all optional with graceful degradation
- Lola module format compatibility (Claude Code, Cursor, Gemini CLI,
  OpenCode)

### Changed

- Renamed `default.md` pack to `base.md` for clarity
- Split reviewer agents into `-code.md` / `-spec.md` pairs to enable
  mode-specific prompts (supersedes the unsplit design in the
  extraction spec)

### Removed

- All Unbound Force-specific references (tool names, internal paths,
  UF hero branding) — the module is now fully generic
