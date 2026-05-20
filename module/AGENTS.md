# Review Council

**Version**: 1.2.0

A multi-persona code and specification review system.
Run `/review-council` to invoke the full council.

## Usage

```
/review-council              # auto-detect from current branch
/review-council code         # force code review mode
/review-council specs        # force spec review mode
/review-council 42           # review PR #42
/review-council main..feat   # review a ref range
/review-council https://github.com/org/repo/pull/42  # review by URL
```

**Input forms:**

- **Empty**: auto-detect mode from current branch, diff
  against base branch
- **PR number**: fetch PR metadata, diff, linked issues,
  and prior reviews from the forge
- **Ref range**: diff between two refs in the local repo
- **URL**: review a PR from any GitHub/GitLab repo
  (requires `gh` or `glab` CLI with authentication)

All forms support an optional mode prefix (`code` or
`specs`) as the first argument.

## What It Does

Review Council dynamically discovers reviewer agents
by matching `divisor-*-code.md` or `divisor-*-spec.md`
in the agents directory (based on the review mode) and
delegates review to each persona in parallel. It
verifies findings against actual file content, strips
fabricated evidence, and produces a council verdict
(APPROVE or REQUEST CHANGES).

The `/review-council` command is a thin coordinator
that dispatches five phases, each documented in its
own procedure file under `commands/review-council/`:

| Phase         | File               | Purpose                                  |
|---------------|--------------------|------------------------------------------|
| Preparation   | `prepare.md`       | Mode detection, discovery, session setup |
| Quality Gates | `quality-gates.md` | CI checks (Code Review only)             |
| Delegation    | `delegate.md`      | Prompt construction, dispatch            |
| Verification  | `verify.md`        | Attestation, evidence, correction, dedup |
| Report        | `report.md`        | Final report, learnings feedback         |

Run state is tracked in `${session_dir}/tracking.md`
in the session cache at `$XDG_CACHE_HOME/review-council/`.

## Personas

Reviewer agents are split by mode (`-code.md` and
`-spec.md`). Content agents are unsplit.

| Agent                           | Persona       | Focus                                 |
|---------------------------------|---------------|---------------------------------------|
| `divisor-guard-{code,spec}`     | The Guard     | Intent drift, governance, zero-waste  |
| `divisor-architect-{code,spec}` | The Architect | Structure, patterns, conventions, DRY |
| `divisor-adversary-{code,spec}` | The Adversary | Security, resilience, secrets, CVEs   |
| `divisor-testing-{code,spec}`   | The Tester    | Test quality, coverage, isolation     |
| `divisor-sre-{code,spec}`       | The Operator  | Operations, deployment, dependencies  |
| `divisor-curator-{code,spec}`   | The Curator   | Documentation gaps, content triage    |

> **Note**: The Curator operates differently in each mode. In code
> review mode (`divisor-curator-code.md`), it can file GitHub issues
> via the `gh` CLI when a Docs repo is configured. In spec review mode
> (`divisor-curator-spec.md`), it reports documentation gaps as
> findings only — no bash access, no issue filing.
| `divisor-scribe` | The Scribe | Technical docs, READMEs, API docs         |
| `divisor-herald` | The Herald | Blog posts, release notes, announcements  |
| `divisor-envoy`  | The Envoy  | PR/comms, social media, community updates |

## Convention Packs

Convention packs define project-specific coding
standards that reviewer agents check against.

Packs are resolved in priority order (later wins):

1. **Module packs** — shipped with this module
2. **User packs** — `$XDG_CONFIG_HOME/review-council/packs/`
3. **Project packs** — `.review-council/packs/` in your repo

Shipped packs: `severity.md` (shared severity levels),
`base.md` (language-agnostic fallback), `go.md`
(self-contained), `typescript.md` (self-contained),
`content.md` (content agents only),
`reviewer-protocol.md` (shared reviewer procedures).

### Pack Update Policy

Packs follow semantic versioning. Rule removals are major
version changes. Rule additions and clarifications are
minor or patch changes. Project-level custom rules using
the CR-NNN identifier prefix are stable across minor and
patch versions of shipped packs.

To check for module updates: `lola mod update review-council`.

## Review Council Configuration

Configure optional extension points by adding this section
to your project's AGENTS.md or CLAUDE.md:

```text
## Review Council Configuration

- Constitution: ./path/to/governance.md
- Knowledge tool: my_semantic_search
- Docs repo: myorg/docs
- Quality tool: my_quality_reporter
```

All extension points are optional. If omitted, the
corresponding checks are skipped gracefully.

| Extension Point | Purpose                              | Default                  |
|-----------------|--------------------------------------|--------------------------|
| Constitution    | Path to project governance document  | Auto-discover from `.specify/memory/constitution.md`; skip if not found or still a template |
| Knowledge tool  | MCP tool name for semantic search    | Skip prior learnings     |
| Docs repo       | GitHub repo for documentation issues | Report gaps as findings  |
| Quality tool    | Agent name for quality analysis      | Skip quality analysis    |
| Batch size      | Max files per delegation batch       | 20                       |
