# Review Council

Instead of one AI reviewer catching what it can, five specialized agents review your code in parallel — security,
testing, operations, governance, and documentation — then produce a unified verdict.

A multi-persona code and specification review [harness](https://martinfowler.com/articles/harness-engineering.html) for
AI coding tools. Installs as a [Lola](https://github.com/LobsterTrap/lola) module and works with Claude Code, Cursor,
Gemini CLI, and OpenCode.

## Review Council as a Harness

Review Council is a **harness** — the infrastructure around AI agents that guides their behavior and validates their
output. Following [harness engineering principles](https://martinfowler.com/articles/harness-engineering.html), it
combines feedforward and feedback controls to increase the probability of correct initial results and enable
self-correction:

**Guides (feedforward controls)** — anticipatory controls that steer reviewer behavior before action:
- Convention packs defining coding and documentation standards
- Reviewer protocol specifying evidence discipline and output format
- Project governance documents (Constitution extension point)
- Prior learnings from previous review runs (Knowledge tool extension point)

**Sensors (feedback controls)** — observational controls that enable self-correction after action:
- Self-attestation verification against the changeset
- Evidence checking to confirm quoted code exists in cited files
- Correction round for fixable errors (hallucinations, stale evidence)
- Quality gates (CI checks, build/test/lint results)
- Deduplication to strip redundant findings

Both control types operate computationally (deterministic CI checks, evidence verification) and inferentially (semantic
analysis by specialized reviewer agents).

## What It Does

Review Council runs a panel of specialized reviewer agents against your code or specifications:

| Persona           | Focus                                | Temperature |
|-------------------|--------------------------------------|-------------|
| **The Guard**     | Intent drift, governance, zero-waste | 0.1         |
| **The Adversary** | Security, resilience, secrets, CVEs  | 0.1         |
| **The Tester**    | Test quality, coverage, isolation    | 0.1         |
| **The Operator**  | Operations, deployment, dependencies | 0.1         |
| **The Curator**   | Documentation gaps, content triage   | 0.2         |

Each reviewer agent reviews independently and returns a verdict. The council verifies every finding against actual file
content — stripping fabricated evidence — then produces a unified result: **APPROVE** or **REQUEST CHANGES**.

## Model Performance

Review Council has been evaluated across Claude model tiers and AI coding tools using a suite of six test cases
covering security flaws (Go), architecture issues (TypeScript/React), multi-concern codebases (Python), false-positive
resistance (clean Go), per-persona coverage (Python), and convention pack detection (TypeScript). Each case has a rubric
with weighted dimensions and a pass threshold.

Results from the latest eval run (30 cells, 6 cases x 5 CLI/model combinations):

| Model    | CLI         | Avg Score | Cases Passed | Cost/Review |
|----------|-------------|-----------|--------------|-------------|
| Sonnet 4 | OpenCode    | **0.94**  | 6/6          | ~$1.30      |
| Sonnet 4 | Claude Code | 0.90      | 6/6          | ~$2.20      |
| Opus 4   | Claude Code | 0.89      | 6/6          | ~$5.35      |
| Opus 4   | OpenCode    | 0.88      | 6/6          | ~$2.50      |
| Haiku 4  | Claude Code | 0.72      | 4/6          | ~$0.34      |

**Sonnet 4 is the recommended model.** It achieves the highest average score across all test cases, passes every case
on both CLIs, and costs roughly half of what Opus does per review. Opus matches Sonnet on detection quality but does not
meaningfully outperform it on any dimension while costing 2-4x more.

Haiku passes the majority of cases but struggles with false-positive suppression on clean codebases and convention pack
attribution. It is suitable for quick scans where cost matters more than precision.

Per-case scores:

| Case                              | CC/Opus | CC/Sonnet | CC/Haiku | OC/Opus | OC/Sonnet |
|-----------------------------------|---------|-----------|----------|---------|-----------|
| Go security (4 flaws)             | 1.00    | 1.00      | 0.85     | 1.00    | 1.00      |
| TS/React architecture (5 flaws)   | 0.73    | 0.73      | 0.73     | 0.73    | **1.00**  |
| Python multi-concern (7 flaws)    | 0.88    | 1.00      | 1.00     | 0.88    | 1.00      |
| Go clean code (0 flaws)           | 1.00    | 1.00      | 0.40     | 1.00    | 1.00      |
| Python per-persona (6 flaws)      | 1.00    | 0.84      | 0.90     | 0.90    | 0.84      |
| TS convention pack (5 violations) | 0.75    | 0.85      | 0.45     | 0.79    | 0.79      |

The eval harness lives in `.lola-eval/` and uses `lola-eval` with custom providers and a trajectory judge. Run
`task lola-eval:test` to reproduce.

## Install

### Prerequisites

Every script needs Bash 4+ and [`jq`](https://jqlang.github.io/jq/). If either
is missing the scripts report it and skip rather than misbehave.

GNU `timeout` (from coreutils) is needed only by the three scripts that call a
forge — session preparation, target cloning, and comment posting — where it
bounds every call so a hung `gh` or `git` cannot stall a review. The rest of the
pipeline, including evidence verification and report rendering, runs without it.
Install it anyway if you review pull requests; skip it only if you never leave
the local-diff path.

macOS ships none of the three: its Bash is 3.2, and there is no `timeout` at
all. Homebrew installs GNU tools under a `g` prefix, so `coreutils` provides
`gtimeout` — the scripts accept either name, and no `PATH` changes are needed.

```bash
brew install bash jq coreutils     # macOS
sudo apt-get install jq coreutils  # Debian/Ubuntu
sudo dnf install jq coreutils      # Fedora/RHEL
```

### Via Lola (recommended)

```bash
lola mod add https://github.com/lolables/lola-mod-review-council.git
lola install review-council
```

### Manual

Clone and copy the module directory into your project's AI tool configuration:

```bash
git clone https://github.com/lolables/lola-mod-review-council.git
# For Claude Code:
mkdir -p .claude/agents .claude/skills
cp lola-mod-review-council/module/agents/divisor-*.md .claude/agents/
cp -r lola-mod-review-council/module/skills/review-council/ .claude/skills/review-council/
```

The convention packs ship inside the skill directory, so the copy above installs them — including
`reviewer-protocol.md`, which every reviewer agent depends on. To override a shipped pack or add your own, see
Customization under Convention Packs.

Adjust agent and skill paths for your AI tool (`.cursor/`, `.gemini/`, etc.).

### Optional Dependency: `gh` CLI

The Curator agent can file GitHub issues for documentation gaps when a Docs repo is configured (see Extension Points).
This requires the [GitHub CLI](https://cli.github.com/) (`gh`) to be installed and authenticated (`gh auth login`).
Without `gh`, the Curator reports gaps as review findings instead.

## Quick Start

```
/review-council              # auto-detect from current branch
/review-council code         # force code review mode
/review-council specs        # force spec review mode
/review-council 42           # review PR #42
/review-council main..feat   # review a ref range
/review-council HEAD         # review only the latest commit
```

See `AGENTS.md` for the full list of input forms including directory paths,
URLs, aliases, and review instructions.

### Posting the verdict to a PR

For PR/URL reviews you can ask the council to post its verdict back to the PR
("review PR 42 and post the result"). Posting is **opt-in and PR-only**. The
council renders a human-first summary comment — verdict, TL;DR, severity and
per-agent tables, findings in collapsible sections — and **shows it to you and
asks before sending** (say "post without asking" to skip the prompt). Re-reviews
edit the same comment (matched by a hidden marker) instead of posting new ones.

GitHub is supported via `gh`. When `gh` is absent or the forge is not GitHub,
the comment body is rendered to a file and you post it manually — nothing is
sent silently.

On a re-review, that same marker also tells Prepare where the council's prior
verdict landed: it fetches PR conversation replies posted since then so the
Disposition step (below) can triage maintainer follow-up against the surviving
findings. GitHub only today, behind the forge seam — see "Pipeline" for what
Disposition does with that conversation.

### Reviewing PRs you haven't checked out

When you review a GitHub PR by number or URL and are not already on that
branch, the council materializes the PR head (a blobless partial clone, shallow
fallback) into a per-repo cache under `$XDG_CACHE_HOME/review-council/clones/`
so reviewers read real files instead of only the diff. Your working tree is
never touched. The cache keeps the newest `REVIEW_COUNCIL_CLONE_CACHE_MAX`
(default 10) repositories.

## How It Works

The `/review-council` command is a re-entrant state machine implemented in `SKILL.md` that orchestrates six phases
using a hybrid of bash scripts (deterministic work) and LLM phase files (judgment work):

| Phase             | Implementation                                    | Purpose                                                   |
|-------------------|---------------------------------------------------|-----------------------------------------------------------|
| **Prepare**       | `rc-prepare.sh`                                   | Mode detection, discovery, session setup                  |
| **Quality Gates** | `SKILL.md` Step 2.5, CI data from `rc-prepare.sh` | Forge CI status checks (Code Review only)                 |
| **Delegate**      | `phases/delegate.md`                              | Prompt construction, dispatch                             |
| **Extract**       | `rc-extract-verdict.sh`                           | Schema-validate each reviewer's JSON verdict              |
| **Verify**        | `rc-verify-evidence.sh` + `phases/verify.md`      | Evidence, correction, calibration, dedup                  |
| **Disposition**   | `phases/disposition.md` (re-review only)          | Triage untrusted PR-conversation replies against findings |
| **Report**        | `rc-render-report.sh` + `phases/report.md`        | Final report, learnings feedback                          |

Scripts live in `skills/review-council/scripts/`. Phase files live in `skills/review-council/phases/`. Each phase
loads only when reached — the orchestrating LLM never needs to hold the full pipeline in context. The full
state-by-state status vocabulary (including the extraction re-dispatch and the verify sub-states) is documented in
`references/pipeline-states.md`, alongside a `stateDiagram-v2` in `SKILL.md`.

### Pipeline

```mermaid
%%{init: {'theme': 'base', 'themeVariables': {
  'primaryColor': '#2f6dab',
  'primaryTextColor': '#1e1e1e',
  'primaryBorderColor': '#7c8ba1',
  'lineColor': '#7c8ba1',
  'edgeLabelBackground': '#eef2f8',
  'tertiaryColor': 'transparent',
  'tertiaryTextColor': '#7c8ba1',
  'tertiaryBorderColor': '#7c8ba1',
  'clusterBkg': 'transparent',
  'clusterBorder': '#7c8ba1',
  'titleColor': '#7c8ba1',
  'noteBkgColor': '#eef2f8',
  'noteTextColor': '#1e1e1e',
  'fontFamily': 'system-ui, sans-serif'
}, 'themeCSS': '.node .nodeLabel{color:#ffffff!important;fill:#ffffff!important;}'}}%%
flowchart TD
  prep["Prepare: detect mode, discover agents, capture changeset"]
  qg{"Code review mode?"}
  qgrun["Quality Gates: run CI checks"]
  del["Delegate: construct prompts, dispatch agents in parallel"]
  ver["Verify: attestation, evidence, correction, dedup"]
  dispgate{"Re-review conversation to triage? (not quick effort)"}
  disp["Disposition: triage untrusted PR conversation (GitHub only)"]
  iter{"Verified findings remain? Iterations < 3?"}
  report["Report: produce verdict, record learnings"]

  prep --> qg
  qg -->|yes| qgrun
  qgrun --> del
  qg -->|no| del
  del --> ver
  ver --> dispgate
  dispgate -->|yes| disp
  dispgate -->|no| iter
  disp --> iter
  iter -->|yes| del
  iter -->|done| report

  classDef sysA fill:#2f6dab,color:#ffffff,stroke:#7c8ba1
  classDef sysB fill:#1d7848,color:#ffffff,stroke:#7c8ba1
  classDef sysC fill:#7457b8,color:#ffffff,stroke:#7c8ba1
  classDef sysD fill:#2d747e,color:#ffffff,stroke:#7c8ba1
  classDef sysF fill:#5c6a82,color:#ffffff,stroke:#7c8ba1
  class prep,del sysA
  class qgrun sysB
  class ver,disp sysC
  class report sysD
  class qg,iter,dispgate sysF
```

1. **Prepare** — detect mode, discover agents, set up session cache at `$XDG_CACHE_HOME/review-council/`, capture
   changeset and diff
2. **Quality Gates** — fetch CI status checks from the forge (code review with PR only)
3. **Delegate** — construct prompts with changeset, diff, and prior run context; dispatch agents in parallel with model
   tier guidance (capable tier for Adversary/Guard, standard for others). Each reviewer's entire response is a single
   fenced ` ```json ` verdict block — no markdown prose.
4. **Extract** — pull the fenced JSON block from each reviewer's raw output and validate it against
   `verdict-schema.json`. A missing or malformed block triggers one re-dispatch before it's reported as a loud
   extraction failure rather than a silently dropped finding.
5. **Verify** — verify evidence quotes exist in cited files, give agents one correction round for fixable errors,
   apply severity calibration, strip fabricated findings, deduplicate. Writes the canonical
   `verdicts/findings.json`.
6. **Disposition** (re-review only) — when `pr-conversation.txt` exists (see "Posting the verdict to a PR") and
   effort is not `quick`, a fresh-context subagent triages that untrusted conversation against the surviving
   findings: resolves a finding only once it independently re-confirms the fix in source, keeps findings whose
   claimed fix doesn't check out, and may suppress LOW findings a narrow scoping hint names (never HIGH/CRITICAL,
   never the verdict itself). Comments are treated as data, never instructions. See `phases/disposition.md` for the
   full contract.
7. **Iterate** — fix verified findings, re-run delegation+verification (up to 3 iterations)
8. **Report** — produce final verdict, record learnings for future runs

### Session Cache

Each run creates a session directory at `$XDG_CACHE_HOME/review-council/<project-hash>/<timestamp>/` containing:

- `session.txt` — human-readable run metadata
- `tracking.md` — structured phase-by-phase state
- `changeset.txt` — reviewed file list
- `diff.patch` — full patch (code review)
- `verdicts/` — each reviewer's raw output (`{agent}.raw.md`) and schema-validated verdict (`{agent}.json`), the
  canonical `findings.json` (verified/correctable/stripped findings) and `verdicts-map.json` (the per-agent verdict map)
- `verdicts/_meta/` — phase state, kept out of `verdicts/` so nothing here is ever globbed as a reviewer verdict:
  the verification log (`verification.txt`), the consolidation manifest (`clusters.json`), and, on a re-review,
  `disposition.txt` (the untrusted-conversation triage audit trail). `rc-render-report.sh` refuses to render
  without `verification.txt`
- `learnings.txt` — false positives and validated patterns

The newest `REVIEW_COUNCIL_SESSION_CACHE_MAX` sessions per project are kept (default 20); older ones are evicted on
the next run, the same way clones are capped. Runs that produce nothing are capped too — the session directory is
created before the changeset scan decides whether there is anything to review, so a no-op review still leaves one
behind. The session a run is currently using is never evicted, whatever the cap.

When reviewing a PR, additional artifacts are created: `pr-metadata.txt`, `linked-issues.txt`, `prior-reviews.txt`,
and `ci-status.txt`. On a re-review (the council's marker comment already exists on the PR), `pr-conversation.txt`
is added too — untrusted replies posted since that marker, GitHub only for now.

### What spec mode reviews

`/review-council specs` scans a fixed set of directories for spec files rather than sweeping the whole tree:

```
specs/  docs/specs/  docs/specification/  docs/design/  docs/superpowers/
docs/rfcs/  docs/adr/  rfcs/  adr/  design/
```

Files count as specs when they end in `.md`, `.mdx`, `.markdown`, `.txt`, `.rst` or `.adoc`.

Bare `docs/` is deliberately not on the list — most projects keep tutorials, blog posts and release notes there
alongside anything spec-shaped, and scanning all of it turns a spec review into a review of the whole site.

Two escape hatches when your layout differs:

```bash
/review-council specs docs/architecture/     # one run, explicit path
REVIEW_COUNCIL_SPEC_DIRS="architecture rfc"  # every run, space or comma separated
REVIEW_COUNCIL_SPEC_EXTS="md typ"            # every run, extensions without the dot
```

When nothing matches, the council tells you which directories it searched rather than only that it found nothing.

## Convention Packs

Convention packs define coding and documentation standards that reviewer agents check against. The module ships with
these packs:

| Pack                   | Type       | Contents                                           |
|------------------------|------------|----------------------------------------------------|
| `severity.md`          | Any        | Shared severity level definitions                  |
| `base.md`              | Any        | Ships empty; anchor for project-level custom rules |
| `lang-go.md`           | Go         | Self-contained Go conventions                      |
| `lang-typescript.md`   | TypeScript | Self-contained TypeScript conventions              |
| `fw-react.md`          | React      | React framework conventions (additive)             |
| `reviewer-protocol.md` | Any        | Shared reviewer procedures and output format       |
| `model-guidance.md`    | Any        | Model selection guidance and eval data             |

Pack filenames encode their type: `lang-{language}.md` for standalone language packs, `fw-{framework}.md` for
additive framework packs that load alongside the language pack.

### Customization

Packs are resolved in priority order (later wins):

1. **Module packs** — shipped with this module (read-only)
2. **User packs** — `$XDG_CONFIG_HOME/review-council/packs/`
3. **Project packs** — `.review-council/packs/` in your repo

To override a shipped pack, create a file with the same name at a higher priority level. To add a new pack, drop a new
`.md` file into either location.

## Extension Points

Configure optional integrations by adding a "Review Council Configuration" section to your project's AGENTS.md or
CLAUDE.md:

```text
## Review Council Configuration

- Constitution: ./GOVERNANCE.md
- Knowledge tool: my_semantic_search
- Docs repo: myorg/docs
- Quality tool: my_quality_reporter
```

| Extension Point | Purpose                              | Default                  |
|-----------------|--------------------------------------|--------------------------|
| Constitution    | Path to project governance document  | Skip constitution checks |
| Knowledge tool  | MCP tool name for semantic search    | Skip prior learnings     |
| Docs repo       | GitHub repo for documentation issues | Report gaps as findings  |
| Quality tool    | Agent name for quality analysis      | Skip quality analysis    |
| Batch size      | Max files per delegation batch       | 20                       |

All extension points are optional. The review council works without any of them — agents gracefully skip checks that
require unconfigured extensions.

## Verification

After installing the module, run these checks to confirm your installation is working:

**1. Agent discovery**

Invoke `/review-council code` in any git repository. You should see the council announce the discovered reviewer agents
by name. If you see "no agents found," check the Troubleshooting section below.

**2. Pack resolution**

Ask any reviewer agent to show which convention pack it loaded. It should reference `reviewer-protocol.md` for its
output format.

**3. Upstream reference sweep** (for module contributors)

From the repo root, verify no upstream-specific references leaked into the module:

```bash
grep -rn \
  --include="*.md" \
  -e "dewey_semantic_search\b" \
  -e "gaze-reporter" \
  -e "muti-mind" \
  lola-mod-review-council/module/
```

Zero matches means the module is clean.

## Troubleshooting

**No agents found**: Verify that `divisor-*-code.md` files are in your AI tool's agents directory (e.g.,
`.claude/agents/` for Claude Code). Run `ls .claude/agents/divisor-*` to confirm. If using a different AI tool, check
its equivalent agents directory.

**`reviewer-protocol.md` missing**: All reviewer agents depend on this pack. It ships in the skill's `references/`
directory. Run `ls .claude/skills/review-council/references/` to confirm the whole directory was copied — every pack,
not just the language-specific ones.

**Curator cannot file issues**: Install and authenticate the `gh` CLI: `gh auth login`. Without authentication, the
Curator reports documentation gaps as findings instead of filing GitHub issues.

## Development

`task check` runs every quality gate. The test suite has four layers — unit,
end-to-end, degraded-mode, and mutation — each catching a class the others
cannot. See [docs/dev/testing.md](docs/dev/testing.md) for what each layer is
for and how to write a test that actually tests something.

```
task doctor          # check prerequisites are installed and reachable
task test            # unit suites
task test:e2e        # end-to-end pipeline (Venom)
task test:degraded   # once per optional tool missing from PATH
task test:mutate     # reintroduce fixed defects, confirm they are caught
task check           # lint + all of the above
```

### Development setup (macOS)

The repo-root [`Brewfile`](Brewfile) is the source of truth for the macOS
prerequisite set, and the macOS CI leg installs from that same file — so a
laptop and a CI run get identical formulae.

```bash
brew bundle   # bash, jq, coreutils
task doctor   # confirm each one is what PATH actually resolves to
```

`task doctor` is the half that catches real problems: installing a formula is
not the same as its binary winning on PATH. It reports which `bash` it found
and where, since macOS keeps a 3.2 in `/bin` that happily shadows Homebrew's.

It also warns if coreutils' `libexec/gnubin` is on your `PATH`. Homebrew leaves
those GNU tools `g`-prefixed deliberately; putting the unprefixed directory on
`PATH` shadows the BSD tools macOS ships, so a GNU-only construct passes
locally and then breaks on a stock Mac. The `Brewfile` explains this at length.

## License

[Apache 2.0](LICENSE)

Originally derived from the [Unbound Force](https://github.com/unbound-force/unbound-force) review-council command.
See [NOTICE](NOTICE) for attribution.
