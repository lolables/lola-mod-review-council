# Changelog

All notable changes to the Review Council module are documented here.

## [Unreleased]

### Added

- `title` is an optional finding property reviewers can supply — a short
  headline naming the defect, non-empty but **unbounded in length**. Both
  renderers had always headlined a finding with `.title // <fallback>`, but the
  property was never declared and `additionalProperties: false` rejected any
  verdict carrying one, so the fallback was the only path ever taken.
  `references/reviewer-protocol.md` now advertises the field and explains what
  the fallback is so the opening sentence of `description` gets written to stand
  on its own. An earlier iteration bounded the field at 120 characters at the
  schema boundary and in the minimal jq validator; that bound rejected a
  reviewer's entire finding set over a headline one character too long, which is
  a presentation concern answered by discarding data. The title has a single
  consumer, `rc_finding_block` in `scripts/lib/render-findings.sh`, which renders
  it as a markdown bullet headline that wraps, and the sibling path deriving a
  headline from `description` was already uncapped — so the bound is gone rather
  than moved. `minLength` stays: an empty headline renders as an empty bold span
- Per-forge preparation adapters at `scripts/lib/forge/<forge>.sh`, sourced once
  on the detected forge, mirroring the seam `rc-post-comment-<forge>.sh` already
  used for posting. Every difference between forges — CLI name, flags, API
  shapes, JSON field names — now lives behind one contract, and the preparation
  stages test capabilities with `declare -F` rather than branching on a forge
  name; a test fails the build if any `gh`/`glab` call reappears in a stage.
  Adapters return normalized field names, so the code that renders prior
  reviews and PR conversation never learns that GitHub spells an author
  `.user.login`. GitLab keeps exactly its previous behaviour, now as a file to
  extend rather than an `elif` to find, with the required contract and the
  optional capabilities documented in `references/forge-adapters.md`
- `REVIEW_COUNCIL_SESSION_CACHE_MAX` (default 20) caps the session cache per
  project, mirroring the clone LRU that has always capped
  `REVIEW_COUNCIL_CLONE_CACHE_MAX`. Sessions were uncapped, so every review ever
  run left a directory behind permanently — and so did every run that produced
  nothing, because the session directory is created before the changeset scan
  decides whether there is anything to review. A no-op review is therefore
  exactly the kind that accumulates. Pruning runs immediately after the
  directory is created, so it fires on every exit path including the `skip` and
  `empty` ones that abandon the session moments later. Same env-var shape, same
  POSIX `ls -dt` ordering and same non-numeric fallback as the clone cap; the
  session a run is using is never evicted, even at a cap of 0
- `REVIEW_COUNCIL_SPEC_DIRS` and `REVIEW_COUNCIL_SPEC_EXTS` override which
  directories spec mode scans and which extensions count as a spec, because no
  fixed list can describe someone else's layout. Bare `docs/` stays off the
  default list deliberately: projects keep tutorials and release notes there
  too, and sweeping all of it turns a spec review into a review of the whole
  site

- Verdict coherence gate in `rc-extract-verdict.sh`: an APPROVE filed by an
  agent over its own CRITICAL or HIGH finding is refused as
  `VERDICT_INCOHERENT`, not `SCHEMA_INVALID` — the block is schema-valid, and
  filing it as a schema break sends a maintainer chasing one that does not
  exist. Every firing is appended to `gate-firings.jsonl` at the session root
  before the rejection is filed, recording the agent, the verdict it claimed,
  and the findings that forced the rejection. Without that record an agent
  that resolves the gate by deleting the finding leaves a session
  byte-for-byte identical to one where the reviewer found nothing, since the
  re-dispatch the gate buys overwrites both `{agent}.raw.md` and
  `{agent}.json`. `verify.md` Step 6 reads the log back and discloses it; the
  rule is disclosure, not override, because the gate's own remediation text
  invites lowering a severity and keeping APPROVE, which can be an honest
  correction, and the verdict is already settled by the REQUEST CHANGES
  backstop. The log sits at the session root rather than in `verdicts/`
  because every verdict discovery globs that directory, and a test asserts no
  `-name` pattern in the shipped scripts can match it. Known gap: quick mode
  runs no narrative synthesis, so a firing reaches `verification.txt` and no
  further
- `task doctor` — reports what `PATH` actually resolves for each prerequisite,
  which matters most on the platform the maintainer cannot test locally. It
  warns when coreutils' `libexec/gnubin` is on `PATH`: that directory shadows
  the BSD tools macOS ships, so a green local run stops meaning anything.
  `doctor.sh` is written for Bash 3.2 because it has to run on the stock macOS
  it diagnoses
- A repo-root `Brewfile` as the single source of truth for the macOS
  prerequisite set. The list previously lived in the CI workflow, in
  `rc-lib.sh`'s skip messages and in the README, free to drift; the macOS CI
  leg now installs from the same file a contributor runs `brew bundle`
  against
- CI runs the whole test matrix on Linux and macOS. It previously ran the unit
  layer only, so the e2e, degraded and mutation layers existed without ever
  gating a merge. Both legs always run to completion, so a failure on one
  cannot hide whether the other was platform-specific. Venom is pinned by tag
  and by the SHA-256 of each published asset, since ovh/venom publishes no
  checksum file
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
  - `task test:mutate` — reintroduces all sixteen fixed defects and asserts a
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
- `test-rc-idempotency.sh` — every phase script is re-run against a live
  session and its state asserted unchanged. SKILL.md Step 6 offers to fix
  findings and return to Step 3, so re-running is part of the contract, and the
  per-script suites only covered the specific defects that prompted them. A
  phase script added later is registered here or it is not covered at all.
  `rc-prepare.sh` is deliberately absent: a session *is* a run, so re-running
  must produce a new one, and its growth is bounded by the session LRU instead
- `assert_idempotent` — runs a command twice and asserts a named state path is
  unchanged, snapshotting *after* run 1 because the first run is the one
  legitimately allowed to do work. The state path is named rather than assumed
  to be the whole session, so a subtree required to grow — `gate-firings.jsonl`
  beside `verdicts/` — can be excluded from the claim
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
  per-endpoint cache, threaded to reviewers and evidence verification via
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
  forges write no file; SECTION 13's no-op `gitlab` branch marks the gap
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

- `rc-prepare.sh` split from 1,498 lines into a 48-line entry point plus six
  stages under `scripts/lib/`, sourced in execution order: `prepare-args.sh`
  (flags and scope), `prepare-repo.sh` (git, forge, tooling, base, session dir),
  `prepare-target.sh` (PR metadata, materialization, mode, agent discovery),
  `prepare-changes.sh` (changeset, language, constitution), `prepare-context.sh`
  (issues, prior reviews) and `prepare-emit.sh` (metadata, tracking, CI, JSON).
  No logic changed: the concatenated stages are byte-identical to the original
  body, the sections keep their source order — Section 16 still runs after
  Section 15 has written `tracking.md` — and because `source` runs in the same
  shell, globals still flow between stages and an `exit` on a skip path still
  ends the whole program. The suite is the proof: the same 769 assertions pass,
  unchanged. Each stage restates `set -uo pipefail` (a runtime no-op, since the
  entry point sets it before sourcing) and waives `SC2154`/`SC2034`, which are
  the artifacts of linting a fragment standalone — reading globals a predecessor
  set, and setting globals a successor reads. Standalone linting is kept rather
  than relying on `shellcheck -x` through the entry point, because `-x` resolves
  variables from a sourced file but reports no findings inside it; excluding the
  stages would have left them entirely unchecked
- **BREAKING (session layout)**: pipeline state the orchestrator writes between
  phases — `clusters.json`, `verification.txt`, `disposition.txt` — now lives in
  `${session_dir}/verdicts/_meta/` rather than beside the verdicts.
  `rc-prepare.sh` creates `_meta/` with the session, so it always exists.
  `verdicts/` proper holds per-agent verdict artifacts and the derived
  `findings.json`; every step that discovers verdicts globs it, and a phase
  artifact landing there is exactly RC-4 — `clusters.json` parsed as an agent
  verdict, aborting the phase and breaking the mid-run resume. The `divisor-*`
  allow-list stays as the second line: the split stops an artifact being written
  where the glob looks, the allow-list stops anything that lands there anyway
  from being read as a verdict. A session in flight when this lands will not
  resume; sessions are per-run cache directories, so start a new review
- `session-manifest.json` at the session root records the council actually
  dispatched — mode, suffix, discovered agents, absent personas. Its consumer is
  `rc-verify-evidence.sh`, which diffs it against the verdict files that arrived
  and reports the difference as `missing_verdicts`, in both its JSON output and
  `findings.json`. A dispatched reviewer that returned nothing was previously
  indistinguishable from one that was never in the council: both are simply
  absent from a `verdicts/` glob, and only one is a hole in the review's
  coverage. Reported, never fatal, and a session with no manifest claims nothing
  rather than accusing every agent at once. `verify.md` requires the disclosure
  to reach `verification.txt` and the report narrative — the per-agent verdict
  table is built from the verdicts that arrived, so a silent agent has no row
  rather than a visibly empty one
- The two load-bearing jq reducers moved out of their shell wrappers into
  `scripts/jq/consolidate-clusters.jq` and `scripts/jq/dedup-findings.jq`,
  invoked with `jq -f`. Behaviour is unchanged; what changes is reachability.
  Each has already produced one silent-data-loss defect — RC-1 deleted every
  finding outside the cluster being reduced, RC-20 dropped a second reviewer's
  angle on an exact duplicate — and both survived as long as they did because
  exercising them meant building a session directory and running a shell script
  over it. As files they are pure functions from JSON to JSON, and
  `test-rc-jq-programs.sh` drives them straight from fixture documents: the
  `+-5` line window, order-independent max severity, unknown severities ranking
  below every real one, REQUEST-CHANGES-wins on a merged cluster, and the
  single-member cluster no-op are each now one assertion rather than a session
  fixture. The RC-1 and RC-20 mutations were repointed at the new files, so
  both defects stay guarded from the shorter path
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

- Forge-sourced context reached reviewers byte-capped. `prepare-context.sh`
  dropped every linked issue past the fifth, cut issue bodies at 2000 bytes,
  cut prior reviews and inline comments at 5000, and cut each inline comment
  body at 300 characters. All four bounds are gone. The worst was not lost
  prose: acceptance criteria were grepped out of the *already-capped* issue
  body, so any criterion past the cut was invisible to the reviewer whose job
  is checking the changeset against it, and a partially-linked PR was
  indistinguishable from a fully-linked one. `head -c` could also sever a
  multi-byte character and put invalid UTF-8 in a reviewer prompt. These
  artifacts carry `UNTRUSTED` headers, but that classifies *trust* — do not
  obey imperatives in them — which is a separate question from *size*: they
  come from the same owner/repo already being cloned and read in full, and
  `--scope all` writes an unbounded `diff.patch`, so capping the issue that
  explains the diff discarded first-party context the pipeline was happy to
  read from disk. Inline comment bodies are now kept whole and made cell-safe
  (newlines to `<br>`, `|` to `&#124;`) rather than cut, bounding the
  presentation instead of the data

- `report.md` findings carry the same detail as the PR comment. A finding used
  to render as one line — a 60-byte cut of the description plus `(file, agent)`
  — with no line number though the data held one, no evidence and no
  recommendation. A folded secondary got its full angle *and* its
  recommendation, so the finding that survived consolidation was the least
  documented thing in the section. The per-finding block now comes from
  `scripts/lib/render-findings.sh`, shared with the comment; only the
  severity-group wrapper stays per-artifact, because a heading and a `<details>`
  is the one place the two should differ. Three reader-visible consequences in
  `report.md`: severity headings carry the comment's severity emoji
  (`### 🟠 HIGH (1)`), the "Also flagged by" list names personas
  (`🧪 Tester (code)`) instead of agent filenames, and the Per-Agent Verdicts
  table does the same — it is the only place the report decodes the persona
  glyph each finding is now tagged with. The agent filename stays verbatim in
  `verdicts/findings.json` for anything parsing rather than reading
- Finding headlines are the reviewer's `title`, or the first sentence of the
  description — never a 60-byte cut. The old limit fell mid-word with no
  ellipsis, in the report and in the PR comment alike. A single-sentence
  description no longer renders a "Full reviewer analysis" block that only
  repeats the headline above it
- `phases/report.md`'s Disposition sections instructed the same 60-character cut
  for the headlines the model writes itself, so the document carried two
  headline conventions
- Consolidation no longer accumulates phantom records across the review
  iteration loop. A cluster whose manifest named one member twice — or whose
  members shared `{file,line,agent}` because one agent filed two claims at the
  same line — matched two findings with nothing to fold between them, so the
  reducer appended a record asserting a merge that never happened, and, having
  removed nothing, appended another on every subsequent run. Clusters are now
  guarded on distinct identities, which is what the "one record per semantic
  cluster" invariant in `phases/verify.md` always meant
- A cluster holding two findings at the same `{file,line,agent}` no longer
  duplicates its primary. Secondaries were selected by identity, so a sibling
  sharing the primary's coordinates fell into neither the secondaries nor the
  survivors, and the array rewrite turned every identity match into the primary
  — emitting it twice while the sibling's angle was dropped entirely.
  Secondaries are selected by position and the primary is emitted on its first
  match only, so the sibling is folded into `consolidated_from` like any other
- `rc-consolidate.sh` reports the merges it performed rather than every merge
  the session has performed. The count summed the document's accumulated
  `consolidation_records`, so the second pass of the iteration loop re-claimed
  the first pass's work
- Step 6's Gate-Firing Disclosure collapses records that are identical apart
  from `ts` into one line carrying the count. Re-running the extractor
  re-evaluates every raw block, including those no re-dispatch touched, so an
  iterated session accumulated copies of a firing nothing new happened to and
  disclosed each one separately. The log itself is unchanged and stays
  append-only: a second firing can be a genuine second refusal, and the first
  record is the only one carrying what was originally claimed
- Every GitHub Actions check was dropped from Quality Gates.
  `statusCheckRollup` is a union of two GraphQL node types that share no field:
  `StatusContext` carries `.context`/`.state`, `CheckRun` carries
  `.name`/`.conclusion`. The extractor filtered on `select(.context != null)`,
  which keeps only the legacy type — on any Actions-based repository, zero
  checks of N. No `--- STATUS CHECKS ---` section was written, `ci-status.txt`
  never appeared, and the Quality Gates phase was silently inert. The legacy
  nodes that did survive were read for a `.conclusion` they do not have, so
  they graded `pending` whatever they actually reported. Measured on
  cli/cli#14054: 7 checks, all `CheckRun`, 0 extracted; after, all 7 correctly
  graded. Every prepare fixture stubbed `"statusCheckRollup": []`, so nothing
  exercised the extractor at all — `test-rc-forge-adapters.sh` now covers both
  node types, a mixed rollup, and an in-flight check. Grading covers the full
  vocabulary both node types report, taken from the live GraphQL enums:
  `ACTION_REQUIRED`, `TIMED_OUT`, `STARTUP_FAILURE` and `ERROR` are failures
  rather than absent signal, while `CANCELLED` and `STALE` carry no verdict and
  stay `unknown`
- Failing CI aborted the review that would have explained it. Quality Gates
  (Step 2.5) presented the failing checks and asked whether to carry on, so a
  run with nobody to answer ended there having produced nothing — the same
  defect as Step 5's iteration prompt, one phase earlier. The gate was
  unreachable while the `statusCheckRollup` filter dropped every check run,
  because Quality Gates never had a failure to stop on; fixing that extraction
  activated it, and the first headless review to reach a PR with red checks
  (vitejs/vite#23130, two failing matrix legs) died here with a full session and
  no report. Red CI is also the wrong thing to abort on: a failing pipeline is
  when a review is most useful, and a test the changeset broke is a finding
  rather than a reason to stop looking. The failing checks now travel into
  delegation as reviewer context and fill the report's `<!-- CI-COMMENTARY -->`
  marker
- A headless review that reached REQUEST CHANGES produced no report at all.
  SKILL.md Step 5 presented findings and asked "Would you like me to fix these
  issues and re-review?" before Step 6, so a run with nobody to answer — CI, a
  piped prompt, any host without an interactive user — ended at the question,
  leaving a session with verified findings and a verdict in `tracking.md` but no
  `report.md`, `verdict.txt` or `comment-summary.md`. It was intermittent rather
  than reproducible: other runs on the same skill and model rendered first and
  asked afterwards. Step 6 now runs to completion first and the offer follows
  it, gated on an interactive session and an unexhausted iteration limit;
  accepting still returns to Step 3, and the next pass overwrites the artifacts
- The Verification pre-condition was prose-only. `verify.md` described it as a
  check the renderer makes — "it refuses unconditionally [...] because such an
  exemption would rest on the orchestrator's own account of a status only it
  observed" — but `rc-render-report.sh` had no reference to verification, so an
  orchestrator that skipped the phase got a full report. Observed on a real
  zero-finding run: `verdicts/_meta/` empty, no verification log ever written,
  and a complete report rendered anyway. Three of the five documented checks are
  mechanical and now live in the script — the log must exist, be non-empty,
  carry a `=== SUMMARY ===` section, and hold no `{N}`-shaped template
  placeholders — and the refusal renders no verdict. The remaining two stay
  prose because they are judgements a grep cannot make
- Spec mode could not see most real documentation repositories. Discovery
  recognised `.md`/`.txt` under five hardcoded directories, so the MCP
  specification repo — 142 spec files under `docs/specification/`, every one
  `.mdx` — missed on both axes and reported "No spec artifacts found to
  review."; `.mdx` is what Mintlify, Docusaurus and Nextra publish. The recovery
  the skill suggests for that case failed too, because the `--scope paths`
  branch carried its own copy of the same extension filter. The filter was
  written out four times and is now defined once for all four branches.
  Extensions gain `.mdx`, `.markdown`, `.rst` and `.adoc`; directories gain
  `docs/specification`, `docs/rfcs`, `docs/adr`, `rfcs` and `adr`. The empty
  message now names what it searched instead of leaving a user unable to tell an
  empty repository from a layout the scanner never looks at
- `--mode` accepted any value and fell through to a `code` default, so a typo
  silently ran a code review: the code personas, the code scope default, and a
  report naming a mode the caller never asked for. `--mode spec` is the typo
  that matters — the accepted token is `specs`, but the mode is called `spec` in
  the JSON `mode` field and in every `divisor-*-spec.md` filename, so the
  singular is the natural guess. It is now refused by name, as `--effort` has
  always refused its own junk values, rather than aliased to `specs`: one
  rejection listing the three valid values costs a retry, while a second
  accepted spelling is something every later reader has to carry
- The report misstated which branch it had reviewed. `rc-render-report.sh` read
  its seven tracking fields with `grep | cut | xargs`, and `xargs` applies shell
  quoting to its input: git permits both `'` and `"` in a refname, so a branch
  named `feature/don't-panic` made `xargs` exit non-zero and the report
  published `Branch: unknown` — a false statement of fact, with the only warning
  going to stderr. A `"` in a value was stripped instead. The `|| echo
  <default>` fallbacks on those lines were dead code besides: `xargs` exits 0 on
  empty input, so an absent key produced a successful empty pipeline and
  rendered blank rather than falling back. All seven now go through
  `rc_parse_kv`, the sed-based reader in `rc-lib.sh` that four other scripts
  already shared, with the defaults applied as parameter expansions where an
  empty result actually triggers them
- GNU `timeout` gated every script that sourced `rc-lib.sh`, a dependency only
  the three forge-calling ones use. On a macOS host without coreutils, evidence
  verification, consolidation, verdict extraction and comment rendering each
  printed a skip and did nothing, for want of a `timeout` none of them calls.
  The check moved into `rc_require_timeout`, called at the top of `rc-prepare.sh`,
  `rc-clone-target.sh` and `rc-post-comment-github.sh`. It stays eager rather
  than deferring into `rc_timeout`: `rc-prepare.sh` does not reach its first
  forge call until it has created the session directory and written to it, and
  failing there would leave a half-built session behind a message that reads
  like nothing happened
- `Agents absent` in the report was the literal string `none`. `rc-prepare.sh`
  wrote it, no phase ever updated it, and discovery is a bare glob with no
  roster to diff against — so a host carrying two of the five personas published
  a Discovery Summary claiming complete coverage. `RC_PERSONAS` in
  `rc-prepare.sh` now names the shipped council and absence is the set
  difference against what discovery found, per mode suffix.
  `phases/delegate.md`'s persona table remains the sole source for who is
  *dispatched*; the roster only answers who is *missing*, and
  `test-rc-doc-guards.sh` fails on drift between the roster, that table, and the
  `module/agents/` files, so a persona cannot be added or removed in one place
  alone
- Exact-duplicate dedup in `rc-verify-evidence.sh` kept the higher severity and
  discarded everything else about the duplicate, so when two reviewers cited the
  same line with the same evidence the second one's angle vanished with nothing
  recording that it was filed. Semantic consolidation describes the same event
  and preserves it in `provenance.consolidated_from`, which the report renders
  as "Also flagged by"; exact dedup now folds into the same field in the same
  shape. Only a duplicate from a *different* agent is credited — the dedup key
  is file + line + evidence and excludes the agent, so one reviewer listing a
  finding twice also merges here, and folding that would credit the survivor to
  its own author
- A materialized review could be grounded in the wrong repository entirely and
  still report `ok`. Both paths are closed, and both were reachable with no
  adversary — a same-named internal mirror or a second forge host is enough:
  - `rc-clone-target.sh` derived the clone host from the local checkout's
    `origin`. A repository whose origin named the same owner/repo on a hostile
    host redirected the clone there, and with a matching branch the script
    returned `in_place`, so the local tree was reviewed as the requested PR.
    The host now comes from the caller and never from `origin`. The `gh` fast
    path stays gated on github.com: the hazard is not that `gh` fails
    elsewhere but that `gh repo clone OWNER/REPO` resolves against `gh`'s own
    default host and would succeed, cloning a same-named github.com repository
  - The clone cache entry was named `<owner>-<repo>`, and an existing clone at
    that name was reused without re-checking its origin. Two hosts serve an
    `acme/widgets` just as happily, so one host's checkout was handed back for
    the other's, and the `git fetch origin pull/N/head` that followed ran
    against the wrong origin. Entries are now keyed on the endpoint. A remote
    `parse_remote` declines to name — a ported endpoint, deliberately — is
    keyed by a checksum of the URL rather than an empty slug, which would
    otherwise file every such endpoint under one key and reintroduce the
    collision for exactly the callers the fix protects. Entries under the old
    name are orphaned rather than migrated; nothing touches them, so they sort
    oldest under the LRU listing and evict first
- An unsupported forge host under `--scope url` reported "No changes to
  review". That is true and useless: the empty status routes the orchestrator
  into the recovery table and on to `--scope all`, turning "review PR 42" into
  a full review of the local checkout returned as `ok`. It now reports `skip`,
  which is terminal
- Verification silently truncated a review. Cited line numbers are
  LLM-authored and JSON Schema draft-07 defines `integer` by value, so `12.0`
  and `1e300` both validated and then reached `$((line - 5))` as literals bash
  rejects. That did not abort the run — it tore down the verification loop, so
  the offending finding and every finding after it vanished from all three
  buckets while `findings.json` was still written and `total_findings` still
  counted them. A truncated review was indistinguishable from a clean one. The
  value is now bounded in the schema and the shell side gates on a plain
  decimal integer; the schema half only bites where a real validator is
  installed, and the `jq` fallback checks integrality but not magnitude
- `path_in_root` resolved only the directory component of a cited path,
  leaving a symlink at the leaf free to point anywhere and still pass
  containment. On a materialized foreign-PR review the tree under the review
  root is PR-author-controlled. The chain is now walked a hop at a time with
  flagless `readlink`, since the canonicalising flags are GNU extensions,
  Homebrew leaves BSD `readlink` on `PATH`, and CI runs macOS
- Verification died with "Argument list too long" on large reviews. Findings
  reached `jq` through `argv`, so a review crossing Linux's per-entry
  `MAX_ARG_STRLEN` failed before `findings.json` was written. They now arrive
  via `--slurpfile` from files
- A finding whose evidence contained a code fence broke every finding after
  it out of the rendered comment. Evidence was wrapped in a fixed
  three-backtick fence indented two spaces — still a valid closing fence — so
  such evidence closed the block early, freed the rest as live markdown, and
  opened an unterminated fence that swallowed every later finding and the
  marker line the re-review upsert depends on. The single-line branch had the
  same defect via a code span. Both now size the delimiter to the content
- The assembled comment body was piped through a dash-normalising `sed`,
  rewriting bytes inside evidence that `reviewer-protocol.md` requires to be a
  byte-for-byte quote, and diverging from the report renderer, which has no
  such filter. Normalisation now happens where the LLM-authored prose is
  assigned
- A council comment could be matched — and overwritten — by anyone else's
  comment carrying the marker. Comment identity is now bound to marker AND
  author. Reports lead with the verdict and a TL;DR anchored to a marker that
  is never droppable, and its fallback keys on the summary file being absent
  or empty rather than on effort mode, since a dispatched narrative subagent
  can fail in any mode
- Forge identity was resolved wrongly in four ways, each aiming a forge call
  at the wrong service or the wrong project:
  - The host was matched as a substring, so `mygithub.com` and
    `github.company.com` both read as GitHub
  - Owner/repo kept a `.git` suffix
  - A GitLab URL's first two path segments were taken as owner/repo
    unconditionally, so every project under a subgroup collapsed onto one
    `project_id` and shared its learnings and prior-reviews cache with
    unrelated codebases
  - `parse_remote` demoted a nested GitLab subgroup's forge; it now parses the
    host independently. It also refuses the whole parse when a remote carries
    a port, because `host:8443/o/r` cannot be told apart from scp-style
    `host:1234/repo` where the digits are an owner
- The disposition subagent's write allowlist named `severity`, which no rule
  in the phase ever writes — and Step 3, which the phase declares the single
  source of truth for what the subagent is told, never mentioned severity at
  all. Read cold, severity was not even the only reachable field: a comment
  could argue a finding's `verdict` to APPROVE without touching severity. This
  is the one place attacker-controlled input reaches a decision procedure.
  Step 3 now states the closed set of permitted writes and forbids severity
  outright, naming the chain it blocks — rewrite a HIGH to LOW and rule 3's
  LOW-only scoping hint suppresses it legitimately. The allowlist is
  reconciled with what Step 3 actually mandates writing, including the
  top-level `reason` it had never named
- Forge-sourced reviewer input is now enveloped as untrusted data per
  artifact rather than once per prompt, so an imperative found in a PR body is
  content to report rather than a directive to obey
- `nothing_to_do` deadlocked against the report pre-condition gate: the
  verification phase produced no record, and the report phase refused to run
  without one. It is resolved by writing an abbreviated verification record
  rather than by exempting the status — an exemption's precondition would be
  the orchestrator's own account of a status only it observed, which is the
  unverifiable self-report shape the disposition gate had just closed. A
  zero-findings report now has an audit trail
- Absence findings carried a search transcript as `evidence`, which is matched
  against the cited file as a contiguous byte sequence and so could never
  verify — that pattern was the entire correctable-findings class. An absence
  finding now anchors to a verbatim quote of the thing whose counterpart is
  missing, and the search itself belongs in `description`
- The Curator was told to be forge-neutral and then given an escape hatch
  worded "`gh` not available", which is unconditionally true on GitLab, so its
  mandate to search for an existing issue before filing one could be satisfied
  by doing nothing. The hatch now names the tool from the delegation prompt —
  and that field had to start arriving: `rc-prepare.sh` writes `Tooling:` into
  `tracking.md`, the Curator's contract claimed the prompt carried it, and
  nothing propagated it. The blanket network prohibition that the same mandate
  contradicted is narrowed to the sanctioned query
- Four reviewer personas carried no CRITICAL row in their severity tables, so
  they could never file one. `severity.md`'s CRITICAL entry is a per-persona
  table, so each file gets its own persona's conditions rather than the
  Tester's; the literal reading would have made the Adversary mandate findings
  in a domain it disclaims. Each new row is narrowed until it partitions
  cleanly against the rows beneath it
- A host without `file(1)` was refused a review. `file(1)` classifies changeset
  candidates for the binary filter, but reporting "no changes to review" for a
  changeset that was never inspected is unrecoverable, while reviewing an
  extra file is not: `rc-lib.sh` now probes for it once and lets callers
  degrade. Scope resolution separately admitted binaries and mis-set
  spec-mode paths, so a review could be built from files nothing could
  sensibly read
- PR metadata was misread in three ways: CI checks were split on `IFS=': '`,
  and since `IFS` is a character set a check named "unit tests" graded as
  `unknown`; still-running checks were filtered out entirely rather than shown
  as pending; and an empty issue-reference array counted as one linked issue,
  because `mapfile` on an empty string yields one empty element
- The diagnostic skill reported green while testing nothing: its mock's agent
  name did not match the verdict glob, its finding path defeated the resolver,
  and `REVIEW_ROOT` went unset, so the evidence matcher never ran. Every block
  now echoes what its own checklist reads, so no assertion depends on a
  directory, a variable or a shell still being alive
- The manual-install instructions pointed at `module/references/`, which does
  not exist — both documented `cp` commands failed, and the troubleshooting
  entry for the resulting error sent readers back to the same path. The skill
  directory copy above them already installs the references
- Fixture git repositories inherited the contributor's git configuration.
  With `commit.gpgsign = true` set globally — near-universal alongside
  `gpg.format = ssh` — every fixture commit failed, and because the helpers run
  inside command substitutions with stderr discarded, it surfaced not as
  "cannot sign" but as unrelated assertions failing later against repositories
  containing no commits. Pinning settings per repo was not enough on its own:
  `core.hooksPath` ran a contributor's own hooks against every fixture commit,
  `init.templateDir` is applied by `git init` before any `git config` line
  could undo it, and an `includeIf` can pull in settings nobody can enumerate.
  `helpers.sh` now neutralises the config files wholesale (`GIT_CONFIG_GLOBAL`,
  `GIT_CONFIG_SYSTEM`, `GIT_CONFIG_NOSYSTEM`) and supplies identity from the
  environment, so it lives in one place; signing is still disabled per repo as
  the one setting with no environment equivalent. `GIT_CONFIG_GLOBAL` arrived
  in git 2.32, which is therefore the floor for the suite's hermeticity
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
  distinctly from a missing review mode, and points at `--scope url` or
  `git init` instead of asking the user to specify a mode they already
  gave
- Per-agent verdict table renders `UNKNOWN` instead of defaulting to `APPROVE`
  when an agent's verdict is missing or null — an unknown verdict no longer
  reads as approval in the rendered report
- Reviewer verdict contract tightened to `APPROVE` / `REQUEST CHANGES` in both
  `verdict-schema.json` and the extractor's fallback check; `APPROVE WITH
  ADVISORIES` is a council-only aggregate and is now rejected as a reviewer
  verdict, matching `reviewer-protocol.md`
- Evidence check no longer misreads a quote that begins with `-` as a command
  option, so Markdown-bullet / diff-line / CLI-flag evidence is verified
  instead of silently marked ungrounded. The `grep -F --` that first closed
  this is gone with the contiguous-matcher rewrite above; the `awk` scanner
  that replaced it takes the evidence through the environment and so has no
  option ambiguity to begin with. A matcher failure (unreadable file, `awk`
  error) is still distinguished from a genuine no-match
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
