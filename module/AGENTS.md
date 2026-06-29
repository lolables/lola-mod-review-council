# Review Council

**Version**: 1.2.0

A multi-persona code and specification review system.
Run `/review-council` to invoke the full council.

Tested on Claude Code and OpenCode. Patches welcome for other clients.

## Usage

```
/review-council              # auto-detect from current branch
/review-council code         # force code review mode
/review-council specs        # force spec review mode
/review-council 42           # review PR #42
/review-council main..feat   # review a ref range
/review-council https://github.com/org/repo/pull/42  # review by URL
/review-council HEAD         # review only the latest commit
/review-council module/      # review changes under a directory
/review-council everything   # explicit full-changeset review
/review-council code HEAD -> focus on security  # mode + target + review instructions
```

**Input forms:**

- **Empty**: auto-detect mode from current branch, diff
  against base branch
- **PR number**: fetch PR metadata, diff, linked issues,
  and prior reviews from the forge
- **Ref range**: diff between two refs in the local repo
- **URL**: review a PR from any GitHub/GitLab repo
  (requires `gh` or `glab` CLI with authentication)
- **Alias** (`everything`, `all`): explicit full-changeset
  review, equivalent to empty input
- **Directory path**: review only changes under that directory
- **Git ref** (`HEAD`, tag, SHA, branch name): resolve to
  a ref range automatically
- **Review instructions**: freeform text after `->` or
  trailing natural language is carried to reviewers as
  additional guidance, not passed to the script

All forms support an optional mode prefix (`code` or
`specs`) as the first argument.

## What It Does

Review Council dynamically discovers reviewer agents
by matching `divisor-*-code.md` or `divisor-*-spec.md`
in `${AGENTS_DIR}` (based on the review mode) and
delegates review to each persona in parallel. It
verifies findings against actual file content, strips
fabricated evidence, and produces a council verdict
(APPROVE or REQUEST CHANGES).

The `/review-council` command orchestrates five phases:

| Phase         | Implementation             | Purpose                                  |
|---------------|----------------------------|------------------------------------------|
| Preparation   | `rc-prepare.sh`            | Mode detection, discovery, session setup |
| Quality Gates | inline in `SKILL.md`       | CI checks (Code Review only)             |
| Delegation    | `phases/delegate.md`       | Prompt construction, dispatch            |
| Verification  | `rc-verify-evidence.sh`    | Attestation, evidence, correction, dedup |
| Report        | `rc-render-report.sh`      | Final report, learnings feedback         |

Scripts live in `${SKILL_DIR}/scripts/`. Phase references
live in `${SKILL_DIR}/phases/`. Run state is tracked in
`${session_dir}/tracking.md` at `$XDG_CACHE_HOME/review-council/`.

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

Content agents are invoked directly for writing tasks:

| Agent              | Persona       | Focus                                     |
|--------------------|---------------|-------------------------------------------|
| `divisor-scribe`   | The Scribe    | Technical docs, READMEs, API docs         |
| `divisor-herald`   | The Herald    | Blog posts, release notes, announcements  |
| `divisor-envoy`    | The Envoy     | PR/comms, social media, community updates |

## Convention Packs

Convention packs define project-specific coding
standards that reviewer agents check against.

Packs are resolved in priority order (later wins):

1. **Module references** — at `${REFERENCES_DIR}` (shipped with the module)
2. **User packs** — `$XDG_CONFIG_HOME/review-council/packs/`
3. **Project packs** — `.review-council/packs/` in your repo

The `${REFERENCES_DIR}` variable resolves to
`skills/review-council/../../references/` relative to the
loaded `SKILL.md` file, typically
`.lola/modules/review-council/module/references/`.

Shipped references: `severity.md` (shared severity levels),
`base.md` (language-agnostic fallback), `go.md`
(self-contained), `typescript.md` (self-contained),
`content.md` (content agents only),
`reviewer-protocol.md` (shared reviewer procedures),
`model-guidance.md` (model selection and eval data).

### Pack Update Policy

Packs follow semantic versioning. Rule removals are major
version changes. Rule additions and clarifications are
minor or patch changes. Project-level custom rules using
the CR-NNN identifier prefix are stable across minor and
patch versions of shipped packs.

To check for module updates: `lola mod update review-council`.

## Requirements

- **Git** — all modes require a git repository
- **Bash 4+** — scripts use associative arrays and other Bash 4+ features. macOS ships Bash 3; install a modern version with `brew install bash`
- **jq** — JSON processing in preparation and verification scripts
- **`gh` CLI** (optional) — required for PR review, linked issues, and prior review fetching on GitHub
- **`glab` CLI** (optional) — required for MR review on GitLab

If `jq` or a modern Bash is missing, scripts exit gracefully with install instructions.

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
