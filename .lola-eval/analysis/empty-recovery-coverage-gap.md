# Empty-Status Recovery: Coverage Gap Analysis

> Date: 2026-07-14
> Branch: `fix/ask-before-fix`
> Trigger: eval run showed 37/60 passing (61.7%), with cases 012, 013,
>   017 failing due to agents abandoning tool on `empty` status

## Root Cause

SKILL.md lines 155-156 had exactly one instruction for `empty` status:

> "If status is `skip` or `empty`: Read the message field, report to
> the user, and stop."

No recovery guidance. No retry logic. Both CLIs (claude-code and
opencode) translated user input to correct flags, called rc-prepare.sh,
got `empty`, and stopped. The routing was right — the recovery was
missing.

## Fixes Applied

### SKILL.md recovery table (commit 028f7a3, refined in a521293)

Added a recovery table at lines 158-178 with one-retry semantics:

| Original scope | Recovery action |
|----------------|-----------------|
| `--scope changed` (±paths) | Re-run with `--scope all` |
| `--scope range` | Re-run with `--scope changed` |
| `--scope all` | Tell user what was searched, ask what to review |
| Any other | Re-run with `--scope all` |

The agent must be transparent about the scope change before retrying.
After a failed retry, the agent asks the user instead of stopping.

### Test scaffold fixes

- **case-012**: scaffold.sh now creates a feature branch so
  `base...HEAD` diff is non-empty for `--scope changed`
- **case-013**: moved `docs/api.md` → `docs/specs/api.md` so the
  specs-mode scan finds it
- **case-017**: added scaffold.sh creating a second commit so
  `HEAD~1..HEAD` has a diff

## Coverage Gap Audit

After the fixes, a full audit of all 18 eval cases revealed that
**no test case explicitly exercises the recovery table**. The table
was written, the broken cases were fixed so they no longer *need*
recovery, but whether an agent *correctly follows* the recovery
logic when it *does* encounter empty was untested.

### Full coverage matrix

| Case | Scope Type | Could Hit Empty? | Recovery Tested? |
|------|-----------|-----------------|-----------------|
| case-001-go-security | changed (default) | Maybe (single-commit main) | No |
| case-002-ts-architecture | range (HEAD) | No (scaffold adds commit) | No |
| case-003-py-mixed | default | Maybe (single-commit main) | No |
| case-004-go-clean | changed (default) | Maybe (single-commit main) | No |
| case-005-py-meta | range (HEAD) | No (scaffold adds commit) | No |
| case-006-ts-pack | changed (default) | Maybe (single-commit main) | No |
| case-010-route-head | range (HEAD) | Yes (scores honest handling) | Partial |
| case-011-route-range | range (main..feat) | No (scaffold creates branch) | No |
| case-012-route-dir | changed + paths | No (scaffold creates branch) | No |
| case-013-route-mode | all (specs default) | No (docs/specs/ exists) | No |
| case-014-route-mixed | range (HEAD) | Yes (scores honest handling) | Partial |
| case-015-route-instructions | default + instructions | Maybe (single-commit main) | No |
| case-016-route-pr-number | pr | Yes (always fails, no forge) | No (skip path, not empty) |
| case-017-route-quick | range + effort | No (scaffold adds commit) | No |
| case-018-route-deep | range + effort | No (scaffold creates branch) | No |

### Untested scope types

- `--scope url` — zero cases
- `--scope all` (explicit) — only via specs-mode auto-default
- `--base <branch>` override — zero cases
- `--scope pr` success path — case-016 always fails (no forge)

### Untested recovery paths

All four rows of the recovery table had zero dedicated test cases:

1. `--scope changed` → retry `--scope all`
2. `--scope range` → retry `--scope changed`
3. `--scope all` → explain + ask user
4. Any other → retry `--scope all`

## New Test Cases

Three recovery-specific eval cases were added:

### case-019-recovery-changed

**Scenario**: `/review-council code` on a main-only repo (all code
committed to main, no feature branch). `--scope changed` computes
`main...HEAD` which is empty.

**Expected behavior**: Agent calls rc-prepare.sh with default scope
(changed) → gets `empty` → tells user → retries with `--scope all`
→ gets `ok` → completes review.

**Rubric dimensions**: recovery_behavior (0.5), transparency (0.3),
no_flapping (0.2)

**Scaffold**: None needed. Single commit on main guarantees empty
for `--scope changed`.

### case-020-recovery-range

**Scenario**: `/review-council HEAD` on a feature branch where HEAD
is an empty commit (no file changes). The code changes are in an
earlier commit on the same branch.

**Expected behavior**: Agent translates HEAD → `--scope range
--scope-value "HEAD~1..HEAD"` → gets `empty` → tells user → retries
with `--scope changed` → gets `ok` (finds code in branch diff) →
completes review.

**Rubric dimensions**: flag_accuracy (0.2), recovery_behavior (0.4),
transparency (0.2), no_flapping (0.2)

**Scaffold**: Creates feature branch, adds flawed Go code, then adds
an empty commit (`--allow-empty`) so HEAD has zero changed files.

### case-021-recovery-all

**Scenario**: `/review-council specs` on a repo with documentation
under `docs/` but NOT in any spec-mode scan directory (`specs/`,
`docs/specs/`, `docs/design/`, `design/`). Specs mode defaults to
`--scope all`, which finds no spec artifacts.

**Expected behavior**: Agent calls rc-prepare.sh with `--mode specs`
→ gets `empty` → does NOT retry (recovery table says no auto-retry
for `--scope all`) → explains what directories were searched →
asks user what to review instead.

**Rubric dimensions**: correct_stop (0.3), explanation_quality (0.4),
no_flapping (0.2), no_fabrication (0.1)

**Scaffold**: None needed. Docs exist under `docs/` (not in scan
dirs) by design.

## Verification

All three scenarios were validated against rc-prepare.sh:

```
case-019: --mode code              → {"status": "empty"}
          --mode code --scope all  → {"status": "ok"}

case-020: --scope range HEAD~1..HEAD → {"status": "empty"}
          --scope changed            → {"status": "ok"}

case-021: --mode specs             → {"status": "empty"}
          (no recovery available)
```

All 59 existing unit tests pass. Provision.sh discovers and provisions
all 18 cases. Task runner updated: `task lola-eval:test-routing` now
includes cases 017-018, new `task lola-eval:test-recovery` runs
cases 019-021.

## Remaining Gaps

Lower-priority items not addressed in this round:

1. **Single-commit-repo nondeterminism** (cases 001, 003, 004, 006,
   015): These may or may not hit empty depending on eval harness
   behavior. Should get scaffolds to make behavior deterministic.
2. **`--scope url`**: Zero test cases.
3. **`--scope pr` success path**: case-016 always fails (no forge).
4. **`--base` override**: Zero test cases.
5. **`--scope all` explicit (code mode)**: Only tested via specs-mode
   auto-default, never via the SKILL.md "everything" keyword.
