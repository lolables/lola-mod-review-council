# Changelog

All notable changes to the Review Council module are documented here.

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
