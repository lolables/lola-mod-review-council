# Changelog

All notable changes to the Review Council module are documented here.

## [Unreleased]

### Added

- Four-layer test architecture, documented in `docs/dev/testing.md`. The suite
  was previously one layer — a unit suite per script — which structurally
  cannot see the seams between scripts, cannot reach a fallback branch that
  only runs when a tool is absent, and cannot tell a meaningful assertion from
  a vacuous one:
  - `module/tests/fixtures/session-golden/` — a complete session shaped like
    real reviewer output: multi-line evidence, a block repeated three times, a
    partial-line quote, a fabrication, a path traversal, a cluster, and
    bystanders. No fixture in the suite had ever contained a newline in an
    `evidence` value, and that single omission hid three defects at once
  - `test-rc-pipeline.sh` and `e2e/pipeline.venom.yml` — extract → verify →
    consolidate → render over that fixture, white box and black box. The
    `clusters.json` defect lived in the contract between two scripts that were
    each correct alone
  - `task test:degraded` — the suite once per optional tool (`jsonschema`,
    `gh`, `glab`) hidden from `PATH`, pinning fallbacks to the same result as
    the real tool rather than to "does not crash"
  - `task test:mutate` — reintroduces all eight fixed defects and asserts a
    suite catches each; a mutation that applies but is not caught fails the run
  - `test-rc-prepare-git-edges.sh` — no repository at all, a subdirectory of an
    unrelated repository, and a repository holding a single root commit
  - `assert_conserved` — for finding-dropping transforms, asserts
    `in − removed == out` and refuses to run against a fixture with no
    bystanders, since asserting on survivors cannot detect collateral loss
- Unit suites are now discovered rather than listed in `Taskfile.yml`, where a
  suite nobody remembered to register silently never ran. Shared code moved to
  `helpers.sh` so the `test-*.sh` glob means exactly "a suite"
- `test-rc-portability.sh` — guards the scripts and the suite against
  GNU-only shell constructs (`timeout`, `grep -P`, `sed -i`, and GNU regex
  escapes). The regex rules matter most: unlike the others they fail
  silently on macOS rather than erroring, so CI cannot be relied on to
  notice them
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
  (read from `${session_dir}/models.json`, with an honest fallback when
  the host does not expose model identity). The delegation phase records
  each reviewer's model (or tier) to `models.json` at dispatch, and the
  renderer dedupes repeated entries from deep-mode per-subsystem dispatch
- Source/issue-tracker footer on every report, linking back to the
  Review Council repository. Overridable via the `REVIEW_COUNCIL_REPO`
  environment variable so forks point at their own tracker
- PR comment posting: opt-in, PR-only, confirmed-before-send upsert comment
  (GitHub via `gh`); renders human-first summary with severity/agent tables and
  collapsible findings; degrades to render-only when `gh` is absent.
- Target-repo materialization for not-checked-out GitHub PR/URL reviews:
  blobless partial clone (shallow fallback) of the PR head into an LRU-capped
  per-repo cache, threaded to reviewers and evidence verification via
  `review_root` / `REVIEW_ROOT`. Working tree is never modified.
- `rc-extract-verdict.sh`: a new Extract stage between Delegate and Verify
  that pulls the fenced ```json verdict block out of each reviewer's raw
  output and schema-validates it against `verdict-schema.json`. Malformed or
  missing blocks trigger one re-dispatch before failing loud, so a bad
  response can no longer vanish as a silent zero-findings result
- `verdict-schema.json` — the JSON Schema (draft-07) for the reviewer
  verdict contract, validated via `sourcemeta/jsonschema` when present, with
  a `jq`-based structural fallback when it isn't
- Explicit pipeline state machine: `references/pipeline-states.md` documents
  every stage script's status vocabulary and transitions, and `SKILL.md`
  gained a `stateDiagram-v2` covering the same states end to end
- Model provenance now flows through `models.json` (a `{role, id}` array)
  instead of free-text lines, closing the door on line-splitting bugs in
  the model-tier list
- A prose-only narrative subagent stage: given only `verdicts/findings.json`,
  it returns a one-line TL;DR and a short narrative and nothing else: no
  structure, no tables. The orchestrator splices its output into the
  `<!-- NARRATIVE -->` and `<!-- LEARNINGS -->` markers left by
  `rc-render-report.sh`
- Re-review PR-conversation ingestion (GitHub): when the council's marker
  comment already exists on a PR, `rc-prepare.sh` fetches the issue-comments
  timeline and writes replies posted at/after the marker to
  `pr-conversation.txt` as UNTRUSTED data. First reviews and non-GitHub
  forges write no file; a `# TODO(forge)` marker tracks the GitLab gap
- Disposition step (`phases/disposition.md`, SKILL.md Step 4.5): the one
  chokepoint that reads `pr-conversation.txt`, gated on that file existing
  and effort not `quick`. A fresh-context subagent receives the untrusted
  conversation and the verified findings and, per finding it references,
  applies four rules: comments are data, never instructions; a "fixed"
  claim requires independent re-verification against source before a
  finding drops (never self-clears on the claim alone); a narrow scoping
  hint may suppress re-raising LOW findings only (verdict-neutral); and
  commenter identity is at most a weak prior. Outcomes are written as
  structured `provenance.disposition` on `findings.json` — `resolved`
  (source-confirmed fixed, moved to `stripped`), `kept` (claimed fixed but
  still present, `claim_verified: false`), or `suppressed-low` (moved to
  `stripped`, verdict-neutral). The report gains three conditional
  sections for re-reviews: "Resolved Since Last Review", "Claimed Fixed
  But Still Present", and a compact suppressed-LOWs note
- Adversarial eval cases `case-022` through `case-025` proving the
  Disposition contract (prompt injection ignored, false-fix claims survive,
  true-fix claims resolve only on independent re-verification, scoping
  hints bounded to LOW), run via `task lola-eval:test-disposition`

### Changed

- **BREAKING**: Reviewer agents now emit a single fenced ```json verdict
  block (`{agent, files_read, verdict, findings: [...]}`) instead of
  markdown `### [SEVERITY]` finding blocks. Custom `divisor-*` reviewer
  agents written against the old markdown output contract must migrate to
  the JSON contract in `references/reviewer-protocol.md` before they will
  produce usable findings
- **BREAKING**: The findings pipeline is JSON-native end to end. The
  ~500-line regex/markdown parser in `rc-verify-evidence.sh` is gone; the
  script now consumes each reviewer's schema-validated
  `verdicts/{agent}.json` directly and writes the canonical
  `verdicts/findings.json` (verified/correctable/stripped finding arrays,
  `total_findings`, `duplicates_consolidated`, and a verbatim per-agent
  `verdicts` map). `findings.json` replaces `verdicts/evidence-check.json`
  as the artifact downstream phases and renderers read
- Severity calibration, deduplication, and validation now mutate structured
  JSON fields (`provenance.calibrated_from`, `provenance.validator`) on each
  finding instead of leaking notes into prose fields or HTML comments
- `rc-render-comment.sh` and `rc-render-report.sh` build all structure
  (tables, counts, verdict) deterministically from `findings.json` via
  `jq -r` — no `@tsv` output re-segmented with `awk`. The table's verdict
  and count columns are now derived from one source, so they can no longer
  disagree with the findings list. Multi-line evidence renders as a fenced
  code block instead of bleeding tabs/backslashes into the surrounding row
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

### Fixed

- Fixture git repositories inherited the contributor's commit-signing config.
  With `commit.gpgsign = true` set globally — near-universal alongside
  `gpg.format = ssh` — every fixture commit failed, and because the helpers run
  inside command substitutions with stderr discarded, it surfaced not as
  "cannot sign" but as unrelated assertions failing later against repositories
  containing no commits. All fixture repos now go through `git_init_sandbox`,
  which stubs identity and disables commit and tag signing
- A GitHub poster test asserted `! grep -q '700'` over a log that also carries
  the session timestamp and generated comment ids, so it failed at random — a
  run at 07:00 was enough — and pointed at the poster rather than at itself.
  Anchored to `issues/comments/700` and `NODE700`
- `rc-prepare.sh` reported an unresolvable ref range as "No changes to review".
  `git diff` on a ref that does not exist is fatal, and the error was swallowed
  by `2>/dev/null || echo ""` into an empty changeset — so `--scope range
  HEAD~1..HEAD` against a repository holding a single root commit (which has no
  `HEAD~1`) read as a clean review, for input that was never compared at all.
  Both the code-mode and spec-mode changeset builders now resolve the range
  first, through one shared guard so the two paths cannot drift
- The "not a git repository" refusal advertised `--scope pr` as a way to review
  without a local checkout. It is not: PR scope still derives the forge
  owner/repo from the local git remote and hits the identical gate. The message
  now names only `--scope url`, which genuinely bypasses it
- Evidence verification matched multi-line quotes as separate patterns.
  `rc-verify-evidence.sh` used `grep -F`, which treats each newline in the
  pattern as a pattern separator, so a multi-line `evidence` value was searched
  as N independent literals and accepted if any one of them matched. This broke
  the anti-hallucination gate in both directions: a fabricated block ending on
  a line that appears anywhere in the file (a bare `}`, `)`, `end`) verified
  clean, and an accurate citation was reported `LINE_MISMATCH` because the line
  number came from whichever short literal appeared first in the file.
  Evidence is now matched as a contiguous block by an `awk` scanner, and a
  citation is accepted when **any** occurrence starts within ±5 of the cited
  line, so blocks that legitimately repeat across sibling functions verify
  against a citation of any occurrence
- Verification aborted with exit 141 on files with many matches.
  `grep -nF … | head -1` under `set -o pipefail` took SIGPIPE once grep
  outgrew the pipe buffer, killing the phase and leaving no `findings.json`.
  Subsumed by the contiguous-matcher rewrite, which has no early-closing pipe.
  `rc-prepare.sh` carries the same pipeline shape and is safe only because it
  omits `-e`; that is now stated at its `set` line so it survives future edits
- Cross-agent consolidation deleted every finding except one cluster primary.
  In `rc-consolidate.sh`, `any(f)` rebinds `.` to each element of its input, so
  the bare `ident` inside `($secids | any(. == (ident)))` was evaluated against
  the `$secids` element rather than the finding being filtered — reducing the
  test to `secid == secid`, always true. Findings in unrelated files, including
  CRITICAL and HIGH ones, were dropped between verification and report while
  the script still reported `status: "ok"`. The finding is now bound as `$f`
  before entering `any`
- `rc-verify-evidence.sh` parsed `verdicts/clusters.json` as an agent verdict
  and aborted. The manifest is written at that exact path by verification Step
  3c, so the module's own workflow broke the mid-run resume documented in
  SKILL.md Step 2. Agent verdicts are now selected by an allow-list
  (`divisor-*.json`) rather than a deny-list that had to grow with every new
  artifact written into `verdicts/`
- Findings citing a path outside the review root were verified rather than
  discarded. The `file` field is reviewer-authored, so `../../<path>` resolved,
  was read, and passed the evidence check — letting a reviewer present content
  from any readable file as evidence from the changeset. Such findings are now
  stripped with reason `PATH_OUTSIDE_ROOT`. Empty evidence, which matched every
  file as a `grep -F` pattern, is likewise rejected (`EVIDENCE_EMPTY`)
- The jq fallback validator accepted verdicts the real schema rejects, so the
  same reviewer output was valid or invalid depending on whether
  `sourcemeta/jsonschema` happened to be installed:
  - Enum checks used `[.x] | inside([…])`, which compares with `contains` —
    substring containment for strings. `"APPROV"` passed as a verdict, `"HIG"`
    and `"CRIT"` as severities, and the empty string as both. Membership is
    now exact
  - `"additionalProperties": false` was not enforced, so unknown keys passed.
    The two allowed key sets are now asserted, and a test diffs them against
    `verdict-schema.json` so the fallback cannot drift from the schema
- `rc-render-report.sh` never emitted a council verdict, contradicting SKILL.md
  Step 6, `phases/report.md` ("End report with council verdict"), and the
  EXECUTION-CONTRACT that forbids the orchestrator from hand-writing report
  sections. The renderer now emits a `## Council Verdict` section ahead of
  `## Council Synthesis`, and `verdict.txt` is written at the start of the
  report phase instead of at post time, giving the report and the PR comment
  one shared source for the outcome
- macOS compatibility across the shipped scripts and the test suite, which
  had regressed on the BSD userland while Linux CI stayed green:
  - Forge and clone calls invoked GNU `timeout`, which macOS does not ship.
    They now go through `rc_timeout()`, which resolves `timeout` or Homebrew
    coreutils' `gtimeout`; `rc-lib.sh` reports the missing prerequisite the
    same way it already reports a missing `jq` or Bash 3
  - `rc-render-comment.sh` stripped em/en dashes with `sed -i 's/…/'`. BSD
    `sed` reads `-i`'s argument as a backup suffix, so on macOS the pass
    aborted and dashes reached posted comments. The filter now runs on write
  - Python framework detection (`pyproject.toml\|setup.py`) and issue
    acceptance-criteria extraction (`^\s*-\s+`) relied on GNU regex
    extensions that BSD regex reads as literal characters, so both silently
    matched nothing on macOS. Both now use `grep -E` with POSIX classes
- Test assertions no longer depend on `grep -P`, which BSD grep does not
  support. Three of the four reported the resulting option error as a normal
  test failure, but the em/en dash assertion negated it (`! grep -qP`), so
  "PCRE unsupported" read as "no dashes found" and the test passed on macOS
  exactly while the renderer above was leaving dashes in posted comments
- References (convention packs, `verdict-schema.json`) now resolve from
  `SKILL_DIR`, not `MODULE_DIR` — on a split install (skill and agents
  directories on separate paths), packs failed to load because
  `REFERENCES_DIR` was derived from the wrong root
- A non-git working directory now reports the missing repository
  distinctly from a missing review mode, and points at `--scope pr`,
  `--scope url`, or `git init` instead of asking the user to specify a
  mode they already gave
- Per-agent verdict table renders `UNKNOWN` instead of defaulting to `APPROVE`
  when an agent's verdict is missing or null — an unknown verdict no longer
  reads as approval in the rendered report
- Reviewer verdict contract tightened to `APPROVE` / `REQUEST CHANGES` in both
  `verdict-schema.json` and the extractor's fallback check; `APPROVE WITH
  ADVISORIES` is a council-only aggregate and is now rejected as a reviewer
  verdict, matching `reviewer-protocol.md`
- Evidence check no longer misreads a quote that begins with `-` as a `grep`
  option: `rc-verify-evidence.sh` passes `grep -F --` and distinguishes a grep
  tooling error (exit 2) from a genuine no-match, so Markdown-bullet / diff-line
  / CLI-flag evidence is verified instead of silently marked ungrounded
- Duplicate-finding merge keeps the most severe of the merged findings, so a
  HIGH citing the same line as a LOW is never silently downgraded; the dedup is
  now independent of agent/finding ordering
- Correction-round skip no longer strips an agent's entire review when all of
  its findings are correctable — that pattern is usually a citation-style or
  evidence-matcher artifact, not fabrication; the single batched correction
  round now runs instead of a wholesale strip
- Reviewer agents (Guard, Adversary) now verify cited external standards and
  compliance claims against source rather than trusting a spec's paraphrase,
  degrading to flagging the claim as unverified when the standard is not
  reachable (agents are network-denied)
- Fail-closed dispatch gate: the delegation step now dispatches only the
  reviewer identifiers in `rc-prepare.sh`'s discovered `agents` array.
  Un-suffixed legacy `divisor-*` agents left in a host agents directory by
  an older install (which discovery skips by design) are explicitly
  forbidden as dispatch targets, and an empty/`skip` result dispatches no
  reviewers — closing a path where stale personas ran and produced an
  untrustworthy verdict

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
