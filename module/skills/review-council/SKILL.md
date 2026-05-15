---
name: review-council
description: Multi-persona code and specification review system. Use when performing code review, PR review, spec review, or quality audits. Invokes a council of specialized reviewer agents (security, architecture, testing, operations, governance) that review in parallel and produce a unified verdict.
---

# Review Council

Run `/review-council` to invoke the full multi-persona
review council. The council dynamically discovers all
available `divisor-*-code.md` or `divisor-*-spec.md`
reviewer agents (based on review mode) and delegates
review to each in parallel.

## Two Review Modes

- **Code Review Mode** (default): Reviews code changes
  against project conventions. Runs CI checks first,
  then delegates to all discovered reviewer agents.
- **Spec Review Mode**: Reviews specification artifacts
  for quality, consistency, and governance alignment.

## Quick Start

```
/review-council              # auto-detect from current branch
/review-council code         # force code review mode
/review-council specs        # force spec review mode
/review-council 42           # review PR #42
/review-council main..feat   # review a ref range
/review-council https://github.com/org/repo/pull/42  # review by URL
```

## Reviewer Personas

Six specialized reviewer agents run in parallel:

| Persona | Focus |
|---------|-------|
| The Guard | Intent drift, governance, zero-waste |
| The Architect | Structure, patterns, conventions, DRY |
| The Adversary | Security, resilience, secrets, CVEs |
| The Tester | Test quality, coverage, isolation |
| The Operator | Operations, deployment, dependencies |
| The Curator | Documentation gaps, content triage |

Content agents (Scribe, Herald, Envoy) are bundled with
the module but are invoked directly for writing tasks —
they do not participate in the `/review-council` review
loop.

## Verdicts

Each agent returns one of:
- **APPROVE** — no blocking findings
- **REQUEST CHANGES** — one or more MEDIUM+ findings

The council verdict is **APPROVE** only when all agents
return APPROVE. Any REQUEST CHANGES triggers an iterative
fix loop (up to 3 iterations) before a final verdict.

## Extension Points

Configure optional integrations in your project's
AGENTS.md or CLAUDE.md:

```text
## Review Council Configuration

- Constitution: ./path/to/governance.md
- Knowledge tool: my_semantic_search
- Docs repo: myorg/docs
- Quality tool: my_quality_reporter
```

All extension points are optional and degrade gracefully
when omitted.

## Convention Packs

Reviewer agents load convention packs for project-
specific standards. Override or extend the shipped
packs by placing files in `.review-council/packs/`
or `$XDG_CONFIG_HOME/review-council/packs/`.
