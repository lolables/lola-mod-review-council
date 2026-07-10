# Review Council — Developer Guide

This repo is the source for the `review-council` Lola module.
The installable module lives entirely under `./module/`.

## Project layout

```
module/                            ← installable module (what users get)
  AGENTS.md                        ← injected into user's AGENTS.md by lola
  agents/                          ← reviewer agent definitions
  references/                      ← convention packs and protocols
  skills/review-council/
    SKILL.md                       ← orchestration skill
    scripts/                       ← bash scripts (rc-prepare.sh, etc.)
    phases/                        ← LLM phase files (delegate.md, etc.)
  tests/                           ← test suite for scripts
docs/                              ← project docs (specs, plans, etc.)
.lola-eval/                        ← eval harness and test cases
Taskfile.yml                       ← task runner (test, lint, eval)
```

## Golden rule

**All changes go in `./module/`, never in the installed location.**

The installed copy (typically `~/.config/opencode/skills/review-council/`
or `.claude/skills/review-council/`) is a deployment artifact. If you
find yourself editing files outside `./module/`, stop — you're modifying
a copy that will be overwritten on next install.

## Working on scripts

Scripts live at `module/skills/review-council/scripts/`. Tests live at
`module/tests/`. Run tests with:

```bash
task test
```

### Script ↔ SKILL.md sync

The `rc-prepare.sh` flag interface and SKILL.md Step 0's interpretation
table are two halves of one contract:

- When adding a `--scope` type to the script, add the corresponding
  interpretation rule and example to SKILL.md.
- When adding interpretation guidance to SKILL.md, verify the script
  accepts the flags it would produce.
- The script's `--help` output is the source of truth for valid flags;
  SKILL.md is the source of truth for how to map user intent to those
  flags.

## Working on agents

Agent definitions live at `module/agents/divisor-*.md`. Each has a
`-code.md` and `-spec.md` variant. Follow the existing agents as a
template when adding new ones.

## Working on convention packs

Packs live at `module/references/`. Filenames encode type:
`lang-{language}.md`, `fw-{framework}.md`, or bare names for
cross-cutting concerns (`base.md`, `severity.md`, `reviewer-protocol.md`).

## Testing

```bash
task test           # run all module tests
task lola-eval:test # run eval harness (requires lola-eval)
```

Tests use temporary git repos and validate script behavior against
known inputs. When adding new script flags or behaviors, add
corresponding test cases.

## Current persona model

Review Council uses 5 reviewer personas:

| Agent | Persona | Focus |
|-------|---------|-------|
| divisor-guard-{code,spec} | Guard | Intent drift, governance, zero-waste |
| divisor-adversary-{code,spec} | Adversary | Security, resilience, secrets, CVEs |
| divisor-testing-{code,spec} | Tester | Test quality, coverage, isolation |
| divisor-sre-{code,spec} | Operator | Operations, deployment, dependencies |
| divisor-curator-{code,spec} | Curator | Documentation gaps, content triage |

There is no Architect, Scribe, Herald, or Envoy persona. These were
removed in prior refactors. If you encounter references to them in
test descriptions or rubrics, update them.

## Eval tests and routing coverage

All eval test cases should exercise LLM-driven routing (SKILL.md
Step 0). No test should use a bare `/review-council` prompt without
explicit justification — case-003 is the designated control case for
the default routing path.

## Entrypoint update checklist

When changing SKILL.md Step 0's interpretation table or
`rc-prepare.sh`'s flag interface, check whether existing eval
test cases need corresponding updates:

1. Does the new routing path have an eval case testing it?
2. Do existing cases still exercise valid routing paths?
3. Does the followup message template request `FLAGS_PASSED` and
   `SCOPE_USED` (needed for routing rubric scoring)?

### Unit tests vs eval tests

- `module/tests/` — unit tests for scripts (`rc-prepare.sh`,
  `rc-verify-evidence.sh`, `rc-render-report.sh`). Test deterministic
  behavior. Run with `task test`.
- `.lola-eval/tests/` — end-to-end agent eval. Test LLM judgment,
  routing, and multi-agent coordination. Run with
  `task lola-eval:test`.

### Targeted routing tests

Cases `case-010` through `case-016` test specific routing paths in
isolation. Run with `task lola-eval:test-routing`.

| Case | Input | What It Tests |
|------|-------|---------------|
| case-010 | `HEAD` | HEAD → HEAD~1..HEAD range |
| case-011 | `main..feat` | Ref range scoping |
| case-012 | `module/` | Directory filter |
| case-013 | `specs` | Mode selection |
| case-014 | `code HEAD -> ...` | Mixed mode+scope+instructions |
| case-015 | `fix the auth bug` | Freeform → review-instructions |
| case-016 | `42` | Number → PR scope |

## scaffold.sh contract

Test cases that need git history beyond the initial starter commit
include a `scaffold.sh` in the case directory (alongside `prompt.md`,
`rubric.md`, `task.yaml`).

**Interface:**
- Receives workdir path as `$1`
- Runs after `reset.sh` copies starter files and creates the initial
  "starter" commit
- Creates additional commits, branches, staged/unstaged changes
- Must be idempotent
- Exit 0 on success; non-zero aborts the test
- Uses `git -c user.name="scaffold" -c user.email="scaffold@test"`
  for commits (no reliance on global git config)
- Lives in the case directory, NOT inside `starter/`

## Flapping anti-pattern

"Flapping" means the agent wastes cycles searching for instruction
files (SKILL.md, phase files, agent definitions) instead of loading
them cleanly via known paths. Signs:

- Grep/find for SKILL.md or phase files
- Re-reading the same instruction file multiple times
- Trying multiple path candidates before finding the right one
- Errors about missing files before recovering

A clean run loads each instruction file once. All eval rubrics
include a `no_flapping` dimension to detect this.
