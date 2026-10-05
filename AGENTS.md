# Review Council — Developer Guide

Source for the `review-council` Lola module. All changes go in `./module/`;
never edit an installed copy (`~/.claude/skills/review-council/`,
`~/.config/opencode/skills/review-council/`) — install overwrites it.
`module/AGENTS.md` is injected into users' AGENTS.md by lola: keep it
host-agnostic.

## Commands

- `task test` runs unit suites only; `task check` (lint + full matrix) before commit.
- Lint with `task lint`, never bare `shellcheck` — it misses what the gate rejects.
- `task lola-eval:update` before eval runs: the harness floats on upstream
  `main`, but an existing `.venv` stays on the commit it first installed.

## Files that change together

- `rc-prepare.sh` flags ↔ SKILL.md Step 0 table. `--help` is truth for valid
  flags; SKILL.md is truth for mapping intent to them. A new routing path needs
  an eval case whose followup requests `FLAGS_PASSED` and `SCOPE_USED`.
- `review-council/SKILL.md` → check `review-council-debug/SKILL.md` for new
  edge cases (status handling, flags, output fields).
- `verdict-schema.json` ↔ `reviewer-protocol.md` worked examples ↔ fixtures in
  `test-verdict-schema.sh` / `test-rc-extract-verdict.sh`. Changing what
  `rc-verify-evidence.sh` reads → recheck `phases/verify.md` "Interpreting
  Evidence Check Results".
- `pr-conversation.txt` envelope in `scripts/lib/prepare-context.sh`
  (delimiters, `Author:`/`Timestamp:`/`Body:`, column-0 anchoring) ↔ the
  "Column 0 is the entire trust boundary" paragraph in `disposition.md`'s
  Step 3 prompt ↔ `case-022`–`case-025` fixtures.

## Module markdown style

Markdown under `module/` is compressed "caveman" style: drop articles and
filler, keep fragments; preserve technical terms, code, paths and
output-template strings verbatim. Match it when editing. Do NOT compress
script-emitted report content, `CHANGELOG.md`, `README.md`, this file, or
anything in code fences/backticks.

## Personas

Five: guard, adversary, testing, sre, curator. Architect, Scribe, Herald and
Envoy were removed — update any reference to them you find.

## Eval cases (`.lola-eval/tests/`)

- Every case exercises SKILL.md Step 0 routing; no bare `/review-council`
  prompt — case-003 is the sole control. Disposition cases (022–025) seed a
  prior session instead.
- Every rubric scores `no_flapping`: the agent grepping for, re-reading, or
  path-guessing instruction files instead of loading each once.
- Cases needing history beyond the starter commit ship a `scaffold.sh` beside
  `prompt.md`/`rubric.md`/`task.yaml` (not in `starter/`). The external harness
  runs it with the workdir as `$1`, after `reset.sh` makes the "starter"
  commit. It must be idempotent, exit non-zero to abort, and commit with
  `git -c user.name="scaffold" -c user.email="scaffold@test"`.

## A/B evaluations

Before measuring whether a tool or module change makes reviews cheaper or
better, read `docs/dev/ab-evaluations.md`. Its rules are what the code-graph and
context-mode runs cost to learn.
