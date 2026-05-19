---
description: >
    NEVER AUTO-TRIGGER
    Run the reviewer governance council to audit codebase or spec compliance.
---
# Command: /review-council

## Path Anchoring

Set `COMMAND_DIR` to the directory containing this
command file. All phase file references below are
relative to `${COMMAND_DIR}`. When reading a phase
file, construct the full path — do not search by
filename.

```
COMMAND_DIR=$(dirname "<path-to-this-file>")
```

## User Input

```text
$ARGUMENTS
```

## Description

Review the current codebase **or** specification
artifacts for compliance with project standards using
the review council. The council dynamically discovers
which reviewer agents are available rather than
assuming a fixed set.

## Phase Procedures

Each phase of the review is documented in its own file
under `review-council/`. Read each phase file when you
reach that phase — not before. This keeps your context
focused on the current work.

| Phase | File | Responsibility |
|-------|------|---------------|
| Preparation | `${COMMAND_DIR}/review-council/prepare.md` | Mode detection, agent discovery, session setup, changeset capture |
| Quality Gates | `${COMMAND_DIR}/review-council/quality-gates.md` | CI checks, quality tool (Code Review only) |
| Delegation | `${COMMAND_DIR}/review-council/delegate.md` | Prompt construction, batching, agent dispatch, verdict collection |
| Verification | `${COMMAND_DIR}/review-council/verify.md` | Attestation, evidence checking, correction round, deduplication |
| Report | `${COMMAND_DIR}/review-council/report.md` | Final report, prior learnings feedback |

---

## Tracking File

Maintain `${session_dir}/tracking.md` throughout the
run. Update it after each phase completes. This file
is the single source of truth for run state.

```markdown
# Review Council Run

## Configuration
- Mode: {Code Review | Spec Review}
- Branch: {branch name}
- Base: {main | master}
- Session: {session_dir path}

## Phase: Preparation
- Status: {pending | complete | failed}
- Started: {ISO 8601}
- Finished: {ISO 8601}
- Agents discovered: {count} ({comma-separated names})
- Agents absent: {comma-separated names or "none"}
- Changeset: {count} files
- Prior run: {none | prior run_id}
- Input type: {auto | pr_number | ref_range | url}
- Forge: {github | gitlab | local}
- Tooling: {gh | glab | api | none}
- PR: #{number} or "none"
- Linked issues: {count}
- Prior reviews: {count}

## Phase: Quality Gates
- Status: {pending | complete | failed | skipped}
- Started: {ISO 8601}
- Finished: {ISO 8601}
- CI checks run: {count}
- CI checks passed: {count}
- CI checks failed: {count} ({N} pr-caused, {N} pre-existing, {N} unknown)
- CI source: {local | forge | both}
- Quality tool: {available | skipped | failed}

## Phase: Delegation (iteration {N})
- Status: {pending | complete | failed}
- Started: {ISO 8601}
- Finished: {ISO 8601}
- Batches: {count}
- Agents dispatched: {count}
- Verdicts received: {count}
- Agent failures: {list or "none"}

## Phase: Verification (iteration {N})
- Status: {pending | complete | failed}
- Started: {ISO 8601}
- Finished: {ISO 8601}
- Findings total: {count}
- Findings verified: {count}
- Findings corrected: {count}
- Findings stripped: {count}
- Duplicates consolidated: {count}
- Verdict: {APPROVE | REQUEST CHANGES}

## Phase: Report
- Status: {pending | complete}
- Council verdict: {APPROVE | REQUEST CHANGES | APPROVE WITH ADVISORIES}
- Learnings recorded: {count}
```

---

## Execution Flow

### Code Review Mode

```
1. Read and follow `${COMMAND_DIR}/review-council/prepare.md`
   → Update tracking: Preparation
   → If changeset empty: stop

2. Read and follow `${COMMAND_DIR}/review-council/quality-gates.md`
   → Update tracking: Quality Gates
   → CI failures are recorded with causality tags
     (pr-caused, pre-existing, unknown). Review
     continues regardless — failures are reported
     in the final report, not used as a gate.

3. Read and follow `${COMMAND_DIR}/review-council/delegate.md` (Code Review section)
   → Update tracking: Delegation (iteration 1)

4. Read and follow `${COMMAND_DIR}/review-council/verify.md`
   → Update tracking: Verification (iteration 1)
   → If all APPROVE: go to step 7

5. Fix verified REQUEST CHANGES findings.
   Re-run steps 3-4 (increment iteration counter).
   Repeat until all APPROVE or 3 iterations exceeded.

6. If 3 iterations exceeded, ask the user whether
   to continue or stop.

7. Read and follow `${COMMAND_DIR}/review-council/report.md` (Code Review section)
   → Update tracking: Report
```

### Spec Review Mode

```
1. Read and follow `${COMMAND_DIR}/review-council/prepare.md`
   → Update tracking: Preparation

2. Skip quality gates (Spec Review does not run CI).
   → Update tracking: Quality Gates — Status: skipped

3. Read and follow `${COMMAND_DIR}/review-council/delegate.md` (Spec Review section)
   → Update tracking: Delegation (iteration 1)

4. Read and follow `${COMMAND_DIR}/review-council/verify.md`
   → Update tracking: Verification (iteration 1)
   → If all APPROVE: go to step 7

5. Apply hybrid fix policy:
   - Auto-fix LOW and MEDIUM findings (formatting,
     status fields, terminology, stale metadata)
   - Report only HIGH and CRITICAL findings
   Re-run steps 3-4 (increment iteration counter).
   Repeat until all APPROVE or 3 iterations exceeded.

6. If 3 iterations exceeded, ask the user whether
   to continue or stop.

7. Read and follow `${COMMAND_DIR}/review-council/report.md` (Spec Review section)
   → Update tracking: Report
```

### Spec Review — Hybrid Fix Policy

When fixing LOW/MEDIUM spec findings (step 5):

**Auto-fix**:
- Formatting and template compliance issues
- Status field updates (e.g., "Draft" on completed)
- Terminology inconsistencies
- Missing or stale cross-references
- Coverage gaps with obvious fixes
- Stale or incorrect metadata

**Report only** (HIGH and CRITICAL):
- Missing user stories or acceptance criteria
- Scope creep or under-specification
- Design-level security gaps
- Inter-feature conflicts or architectural misalignment
- Constitution violations
- Ambiguous requirements requiring human judgment
