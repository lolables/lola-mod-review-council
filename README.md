# Review Council - An Unbound Force Project

Instead of one AI reviewer catching what it can, six specialized agents review your code in parallel — security,
architecture, testing, operations, governance, and documentation — then produce a unified verdict.

A multi-persona code and specification review system for AI coding tools. Installs as a
[Lola](https://github.com/LobsterTrap/lola) module and works with Claude Code, Cursor, Gemini CLI, and OpenCode.

## What It Does

Review Council runs a panel of specialized reviewer agents against your code or specifications:

| Persona           | Focus                                 | Temperature |
|-------------------|---------------------------------------|-------------|
| **The Guard**     | Intent drift, governance, zero-waste  | 0.1         |
| **The Architect** | Structure, patterns, conventions, DRY | 0.1         |
| **The Adversary** | Security, resilience, secrets, CVEs   | 0.1         |
| **The Tester**    | Test quality, coverage, isolation     | 0.1         |
| **The Operator**  | Operations, deployment, dependencies  | 0.1         |
| **The Curator**   | Documentation gaps, content triage    | 0.2         |

Each reviewer agent reviews independently and returns a verdict. The council verifies every finding against actual file
content — stripping fabricated evidence — then produces a unified result: **APPROVE** or **REQUEST CHANGES**.

The `/review-council` command invokes the six reviewer agents automatically. The module also includes three content
production agents that are invoked directly for writing tasks — they share the module's convention packs and extension
points but do not participate in the review council flow:

| Persona        | Focus                                     | Temperature |
|----------------|-------------------------------------------|-------------|
| **The Scribe** | Technical docs, READMEs, API docs         | 0.1         |
| **The Herald** | Blog posts, release notes, announcements  | 0.4         |
| **The Envoy**  | PR/comms, social media, community updates | 0.5         |

## Install

### Via Lola (recommended)

```bash
lola mod add https://github.com/unbound-force/review-council.git
lola install review-council
```

### Manual

Clone and copy the module directory into your project's AI tool configuration:

```bash
git clone https://github.com/unbound-force/review-council.git
# For Claude Code:
cp review-council/module/agents/divisor-*.md .claude/agents/
cp review-council/module/commands/review-council.md .claude/commands/
cp -r review-council/module/commands/review-council/ .claude/commands/review-council/
cp -r review-council/module/skills/review-council/ .claude/skills/review-council/
```

Convention packs are required — all reviewer agents depend on `reviewer-protocol.md`. Copy them to your user or project
pack directory:

```bash
# User-level (applies to all projects):
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/review-council/packs"
cp review-council/module/packs/*.md "${XDG_CONFIG_HOME:-$HOME/.config}/review-council/packs/"

# Or project-level (applies to this repo only):
mkdir -p .review-council/packs
cp review-council/module/packs/*.md .review-council/packs/
```

Adjust agent and command paths for your AI tool (`.cursor/`, `.gemini/`, etc.).

### Optional Dependency: `gh` CLI

The Curator agent can file GitHub issues for documentation gaps when a Docs repo is configured (see Extension Points).
This requires the [GitHub CLI](https://cli.github.com/) (`gh`) to be installed and authenticated (`gh auth login`).
Without `gh`, the Curator reports gaps as review findings instead.

## Quick Start

```
/review-council        # auto-detect mode from workspace state
/review-council code   # force code review mode
/review-council specs  # force spec review mode
```

## How It Works

The `/review-council` command is a thin coordinator that dispatches five phases, each in its own procedure file under
`commands/review-council/`:

| Phase             | File               | Purpose                                                           |
|-------------------|--------------------|-------------------------------------------------------------------|
| **Prepare**       | `prepare.md`       | Mode detection, agent discovery, session setup, changeset capture |
| **Quality Gates** | `quality-gates.md` | CI checks and quality tool (Code Review only)                     |
| **Delegate**      | `delegate.md`      | Prompt construction, batching, agent dispatch                     |
| **Verify**        | `verify.md`        | Attestation, evidence checking, correction round, dedup           |
| **Report**        | `report.md`        | Final report, prior learnings feedback                            |

Each phase loads only when reached — the orchestrating LLM never needs to hold the full pipeline in context.

### Pipeline

1. **Prepare** — detect mode, discover agents, set up session cache at `$XDG_CACHE_HOME/review-council/`, capture
   changeset and diff
2. **Quality Gates** — read CI config, run build/test/lint locally (code review only)
3. **Delegate** — construct prompts with changeset, diff, and prior run context; dispatch agents in parallel with model
   tier guidance (capable tier for Adversary/Architect/Guard, standard for others)
4. **Verify** — check self-attestation against changeset, verify evidence quotes exist in cited files, give agents one
   correction round for fixable errors, strip fabricated findings, deduplicate
5. **Iterate** — fix verified findings, re-run delegation+verification (up to 3 iterations)
6. **Report** — produce final verdict, record learnings for future runs

### Session Cache

Each run creates a session directory at `$XDG_CACHE_HOME/review-council/<project>/<timestamp>/` containing:

- `session.txt` — human-readable run metadata
- `tracking.md` — structured phase-by-phase state
- `changeset.txt` — reviewed file list
- `diff.patch` — full patch (code review)
- `verdicts/` — per-agent output and verification log
- `learnings.txt` — false positives and validated patterns

## Convention Packs

Convention packs define coding and documentation standards that reviewer agents check against. The module ships with
these packs:

| Pack                   | Language   | Contents                                        |
|------------------------|------------|-------------------------------------------------|
| `severity.md`          | Any        | Shared severity level definitions               |
| `base.md`              | Any        | Language-agnostic coding conventions (fallback) |
| `go.md`                | Go         | Self-contained Go conventions                   |
| `typescript.md`        | TypeScript | Self-contained TypeScript conventions           |
| `content.md`           | Any        | Content writing standards (content agents only) |
| `reviewer-protocol.md` | Any        | Shared reviewer procedures and output format    |

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

**3. UF reference sweep** (for module contributors)

From the repo root, verify no UF-specific references leaked into the module:

```bash
grep -rn \
  --include="*.md" \
  -e "dewey_semantic_search\b" \
  -e "gaze-reporter" \
  -e "muti-mind" \
  review-council/module/
```

Zero matches means the module is clean.

## Troubleshooting

**No agents found**: Verify that `divisor-*-code.md` files are in your AI tool's agents directory (e.g.,
`.claude/agents/` for Claude Code). Run `ls .claude/agents/divisor-*` to confirm. If using a different AI tool, check
its equivalent agents directory.

**`reviewer-protocol.md` missing**: All reviewer agents depend on this pack. Ensure you copied all files from
`module/packs/` — not just language-specific packs.

**Curator cannot file issues**: Install and authenticate the `gh` CLI: `gh auth login`. Without authentication, the
Curator reports documentation gaps as findings instead of filing GitHub issues.

## Changes from Unbound Force

Review Council was extracted from the [Unbound Force](https://github.com/unbound-force/unbound-force) monorepo and
restructured as a standalone Lola module. This section documents the differences between the two versions.

### Command structure: monolithic to modular

In Unbound Force, the entire review pipeline lives in a single file (`.opencode/commands/review-council.md`, ~283
lines). The extracted version splits this into a thin coordinator plus five phase files under
`commands/review-council/` — prepare, quality-gates, delegate, verify, and report. The orchestrating LLM loads each
phase only when reached, so no single context window needs to hold the full pipeline.

### Agent split: one file per mode

Unbound Force uses one agent file per persona (e.g., `divisor-guard.md`) containing both code review and spec review
logic. The extracted version splits each reviewer persona into `-code.md` and `-spec.md` variants, so each agent file
contains only the logic for its review mode. Content agents (Scribe, Herald, Envoy) remain unsplit because they are
invoked directly for writing tasks, not through the review pipeline.

| Unbound Force         | Extracted                                              |
|-----------------------|--------------------------------------------------------|
| `divisor-guard.md`    | `divisor-guard-code.md`, `divisor-guard-spec.md`       |
| `divisor-architect.md`| `divisor-architect-code.md`, `divisor-architect-spec.md`|
| `divisor-adversary.md`| `divisor-adversary-code.md`, `divisor-adversary-spec.md`|
| `divisor-testing.md`  | `divisor-testing-code.md`, `divisor-testing-spec.md`   |
| `divisor-sre.md`      | `divisor-sre-code.md`, `divisor-sre-spec.md`           |
| `divisor-curator.md`  | `divisor-curator-code.md`, `divisor-curator-spec.md`   |
| `divisor-scribe.md`   | `divisor-scribe.md` (unchanged)                        |
| `divisor-herald.md`   | `divisor-herald.md` (unchanged)                        |
| `divisor-envoy.md`    | `divisor-envoy.md` (unchanged)                         |

### Shared procedures extracted to `reviewer-protocol.md`

In Unbound Force, each agent file embeds its own copy of shared procedures — evidence discipline, pack loading rules,
prior learnings queries, output format, and self-attestation requirements. The extracted version moves these into a
single `reviewer-protocol.md` convention pack that all reviewer agents reference, eliminating duplication and making
the protocol easier to update.

### Convention pack changes

**Renamed**: `default.md` → `base.md`. The original name implied it was the primary pack; it is actually a
language-agnostic fallback loaded only when no language-specific pack (e.g., `go.md`) matches.

**Removed**: `-custom.md` companion files (`default-custom.md`, `go-custom.md`, `typescript-custom.md`,
`content-custom.md`). Unbound Force shipped tool-owned packs alongside user-owned `-custom.md` files in the same
directory. The extracted version uses a priority-based override system instead — drop a file with the same name into
`$XDG_CONFIG_HOME/review-council/packs/` (user) or `.review-council/packs/` (project) and it takes precedence over
the shipped pack.

**Added**: `reviewer-protocol.md` (see above).

### UF-specific tool references replaced with extension points

Unbound Force hardcodes references to its own tooling:

- **Gaze** (`gaze-reporter` agent) for quality analysis — replaced by the configurable **Quality tool** extension point
- **Dewey** (`dewey_semantic_search` MCP tool) for prior learnings — replaced by the configurable **Knowledge tool**
  extension point
- **Speckit/OpenSpec** workflow tier detection (`NNN-*` and `opsx/*` branch patterns) — removed entirely

The extracted version defines these as optional extension points in a "Review Council Configuration" section of your
project's AGENTS.md or CLAUDE.md. Unconfigured extensions are skipped gracefully — no tools are assumed.

### Mode detection generalized

Unbound Force mode detection recognizes its project-specific governance frameworks:

- `NNN-*` branches → Speckit workflow (reviews `specs/NNN-<name>/` artifacts)
- `opsx/*` branches → OpenSpec workflow (reviews `openspec/changes/<name>/` artifacts)
- Spec file scope varies by detected workflow tier

The extracted version uses a simpler heuristic: files under `specs/`, `docs/specs/`, `docs/design/`,
`docs/superpowers/`, `design/`, or named `spec.md`, `plan.md`, `tasks.md`, `design.md`, `research.md` are treated as
specification artifacts. Everything else is code. No branch-naming conventions are assumed.

### Superpowers spec directory support (new)

The extracted version adds `docs/superpowers/` as a recognized spec artifact location. This directory is where the
[superpowers](https://github.com/claude-plugins-official/superpowers) brainstorming skill writes design specs
(`docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`) and where the writing-plans skill stores implementation plans.
Unbound Force did not use this convention — the path is a net-new addition, not a migration from an existing UF path.

Files under `docs/superpowers/` are classified as spec artifacts for auto-detection purposes and included in the scan
locations for Spec Review Mode. All six reviewer agents, the shared `reviewer-protocol.md`, and the prepare phase
recognize this path.

### Directory layout

| Purpose          | Unbound Force                    | Extracted                         |
|------------------|----------------------------------|-----------------------------------|
| Agents           | `.opencode/agents/`              | `module/agents/`                  |
| Commands         | `.opencode/commands/`            | `module/commands/`                |
| Command phases   | (embedded in single command)     | `module/commands/review-council/` |
| Convention packs | `.opencode/uf/packs/`            | `module/packs/`                   |
| Skills           | `.opencode/skills/` (shared)     | `module/skills/review-council/`   |
| Module metadata  | `AGENTS.md` (project-level)      | `module/AGENTS.md` (module-level) |

## License

[Apache 2.0](LICENSE)
