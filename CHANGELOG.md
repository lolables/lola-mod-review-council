# Changelog

All notable changes to the Review Council module are documented here.

## [Unreleased]

### Added

- React framework convention pack (`fw-react.md`) with severity
  calibration for error boundaries (HIGH), god components (HIGH),
  prop drilling (MEDIUM), and direct DOM manipulation (MEDIUM)
- Framework pack support in pack loading rules — `fw-{framework}.md`
  packs load alongside the language pack when a framework is detected
- Verdict coherence rule in verification phase — unanimous agent
  APPROVE with no HIGH/CRITICAL findings enforces APPROVE mechanically
- Completeness check in decompose phase — every file in
  `changeset.txt` must be assigned to a subsystem; unassigned files
  fall into a catch-all `infrastructure`/`other` subsystem so no file
  is silently dropped from deep-mode review
- Merge-base advisory concept — verification Step 3b converts findings
  stripped for base-branch divergence (not branch defects) into
  advisories, surfaced in a separate report section without inflating
  the finding count or affecting the council verdict
- LLM provenance disclosure — every rendered report opens with a
  mandatory banner stating it was LLM-generated, plus the models used
  (read from `${session_dir}/models.txt`, with an honest fallback when
  the host does not expose model identity). The delegation phase records
  each reviewer's model (or tier) to `models.txt` at dispatch, and the
  renderer dedupes repeated lines from deep-mode per-subsystem dispatch
- Source/issue-tracker footer on every report, linking back to the
  Review Council repository. Overridable via the `REVIEW_COUNCIL_REPO`
  environment variable so forks point at their own tracker

### Changed

- Extended Go/Tester detection hints with the shallow-assertion
  pattern — integration tests asserting only `require.NoError` +
  `require.NotNil` without verifying response fields, detected by
  comparing assertion depth across tests in the same file
- **BREAKING**: Renamed convention packs: `go.md` → `lang-go.md`,
  `typescript.md` → `lang-typescript.md`. Pack filenames now encode
  their type: `lang-*` for language packs, `fw-*` for framework packs
- Fixed detection hint routing: error boundary detection moved from
  Tester to Adversary (resilience domain)
- Lowered god component detection thresholds from >300 lines / >10
  state variables to >200 lines / >5 state hooks (aligns with
  `fw-react.md` calibration)

## [0.1.0] — 2026-06-30

### Added

- Initial release as a standalone Lola module, extracted from the
  [Unbound Force](https://github.com/unbound-force/unbound-force)
  monorepo (`internal/scaffold/assets/opencode/commands/review-council.md`)
- Five reviewer agents (Guard, Adversary, Tester, Operator,
  Curator), each split into `-code.md` and `-spec.md` variants for
  mode-specific reviews
- Six convention packs: `severity.md`, `base.md`, `go.md`,
  `typescript.md`, `reviewer-protocol.md`, `model-guidance.md`
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

### Migration from Unbound Force

The following documents the structural changes from the original
Unbound Force review-council command to this standalone module.

**Command structure: monolithic to modular** — In Unbound Force, the
entire review pipeline lives in a single file
(`.opencode/commands/review-council.md`, ~283 lines). The extracted
version uses a hybrid architecture: a `SKILL.md` state machine
coordinates bash scripts (`rc-prepare.sh`, `rc-verify-evidence.sh`,
`rc-render-report.sh`) for deterministic work and LLM phase files
(`delegate.md`, `verify.md`, `report.md`) for judgment work. Each
phase loads only when reached.

**Agent split: one file per mode** — Unbound Force uses one agent
file per persona (e.g., `divisor-guard.md`) containing both code
review and spec review logic. The extracted version splits each
reviewer persona into `-code.md` and `-spec.md` variants.

| Unbound Force          | Extracted                                                |
|------------------------|----------------------------------------------------------|
| `divisor-guard.md`     | `divisor-guard-code.md`, `divisor-guard-spec.md`         |
| `divisor-adversary.md` | `divisor-adversary-code.md`, `divisor-adversary-spec.md` |
| `divisor-testing.md`   | `divisor-testing-code.md`, `divisor-testing-spec.md`     |
| `divisor-sre.md`       | `divisor-sre-code.md`, `divisor-sre-spec.md`             |
| `divisor-curator.md`   | `divisor-curator-code.md`, `divisor-curator-spec.md`     |


**Shared procedures extracted to `reviewer-protocol.md`** — In
Unbound Force, each agent file embeds its own copy of shared
procedures (evidence discipline, pack loading rules, prior learnings
queries, output format, self-attestation). The extracted version moves
these into a single convention pack, eliminating duplication.

**Convention pack changes:**
- *Renamed*: `default.md` → `base.md` (language-agnostic fallback)
- *Removed*: `-custom.md` companion files. Unbound Force shipped
  tool-owned packs alongside user-owned `-custom.md` files in the same
  directory. The extracted version uses a priority-based override
  system: module < user (`$XDG_CONFIG_HOME/review-council/packs/`) <
  project (`.review-council/packs/`).
- *Added*: `reviewer-protocol.md`

**UF-specific tool references replaced with extension points:**
- Gaze (`gaze-reporter` agent) → configurable Quality tool
- Dewey (`dewey_semantic_search` MCP tool) → configurable Knowledge tool
- Speckit/OpenSpec workflow tier detection → removed entirely

**Mode detection generalized** — Unbound Force mode detection
recognizes project-specific branch patterns (`NNN-*` for Speckit,
`opsx/*` for OpenSpec). The extracted version uses a file-path
heuristic: files under `specs/`, `docs/specs/`, `docs/design/`,
`docs/superpowers/`, `design/`, or named `spec.md`, `plan.md`,
`tasks.md`, `design.md`, `research.md` are treated as spec artifacts.

**Superpowers spec directory support (new)** — The extracted version
adds `docs/superpowers/` as a recognized spec artifact location for
the [superpowers](https://github.com/obra/superpowers) brainstorming
and planning skills. This is a net-new addition, not a migration from
an existing UF path.

**Directory layout comparison:**

| Purpose         | Unbound Force                | Extracted                                           |
|-----------------|------------------------------|-----------------------------------------------------|
| Agents          | `.opencode/agents/`          | `module/agents/`                                    |
| Entry point     | `.opencode/commands/`        | `module/skills/review-council/SKILL.md`             |
| Pipeline phases | (embedded in single command) | `module/skills/review-council/phases/` + `scripts/` |
| Convention refs | `.opencode/uf/packs/`        | `module/references/`                                |
| Skills          | `.opencode/skills/` (shared) | `module/skills/review-council/`                     |
| Module metadata | `AGENTS.md` (project-level)  | `module/AGENTS.md` (module-level)                   |

[Unreleased]: https://github.com/trevor-vaughan/review-council/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/trevor-vaughan/review-council/releases/tag/v0.1.0
