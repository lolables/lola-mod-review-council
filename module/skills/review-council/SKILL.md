---
name: review-council
description: >
  NEVER AUTO-TRIGGER
  Multi-persona code and specification review system. Dispatches
  specialized reviewer agents in parallel, verifies findings against
  source evidence, and produces a council verdict.
---

# Review Council

## Path Anchoring

Set `SKILL_DIR` to the directory containing this file.
Derive all other paths from `SKILL_DIR`:

```bash
SKILL_DIR=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
SCRIPTS_DIR="${SKILL_DIR}/scripts"
PHASES_DIR="${SKILL_DIR}/phases"
MODULE_DIR=$(dirname "$(dirname "${SKILL_DIR}")")
AGENTS_DIR="${MODULE_DIR}/agents"
REFERENCES_DIR="${MODULE_DIR}/references"
```

All script and phase references below use these paths.
Construct full paths — do not search by filename.

## Quick Reference

### Usage

```
/review-council              # auto-detect from current branch
/review-council code         # force code review mode
/review-council specs        # force spec review mode
/review-council 42           # review PR #42
/review-council main..feat   # review a ref range
/review-council https://github.com/org/repo/pull/42  # review by URL
```

### What It Does

Review Council dynamically discovers reviewer agents matching
`divisor-*-code.md` or `divisor-*-spec.md` (based on review mode)
and delegates review to each persona in parallel. It verifies
findings against actual file content, strips fabricated evidence,
and produces a council verdict (APPROVE or REQUEST CHANGES).

Six reviewer personas run in parallel: Guard (intent drift,
governance), Architect (structure, patterns, DRY), Adversary
(security, resilience), Tester (test quality, coverage), Operator
(deployment, dependencies), Curator (documentation gaps).

## Execution Flow

This skill is a re-entrant state machine. If invoked mid-run,
it reads the tracking file and resumes from the last completed phase.

### Step 1: PREPARE (scripted)

Run `${SCRIPTS_DIR}/rc-prepare.sh` with user arguments.

The script creates a session directory, captures changeset and diff,
discovers agents, detects forge/framework/language, fetches CI status,
linked issues, and prior reviews (if PR), and initializes the tracking file.

**Returns JSON to stdout:**
```json
{
  "status": "ok | skip | empty",
  "message": "human-readable status or instruction",
  "session_dir": "/absolute/path/to/session",
  "mode": "code | specs",
  "agents": ["divisor-guard-code", "divisor-architect-code", ...],
  "changeset_size": 42,
  "language": "Go",
  "framework": "none",
  "forge": "github | gitlab | local",
  "pr_number": "42 | null",
  "ci_status": {...},
  "linked_issues_count": 3
}
```

**If status is `skip` or `empty`:** Read the message field, report to
the user, and stop. Do not proceed to delegation.

**If status is `ok`:** Capture session_dir and mode, proceed to Step 2.

### Step 2: READ TRACKING (re-entry support)

Read `${session_dir}/tracking.md` (created by rc-prepare.sh).

Determine the current state from the tracking file:
- If all phases are complete and verdict is recorded, report
  the existing verdict and stop.
- If Delegation or Verification is in progress, resume from
  the next incomplete phase.
- If starting fresh, proceed to Step 3.

This enables re-entry: if the skill is invoked mid-run,
it resumes without repeating completed work.

### Step 3: DELEGATION (iteration N)

**Read `${PHASES_DIR}/delegate.md`** for prompt construction
guidance and dispatch instructions.

For each reviewer agent in the agents array from Step 1:
- Construct a prompt using the changeset context, convention
  packs from `${REFERENCES_DIR}`, and project configuration
- Dispatch the agent using `subagent_type = agent filename`
  (e.g., "divisor-guard-code")
- Collect the verdict and write to `${session_dir}/verdicts/{agent-name}.md`

Dispatch all agents in parallel for speed.

**Update tracking:** Set Delegation (iteration N) status to `complete`,
record agents dispatched, verdicts received, and any failures.

Proceed to Step 4.

### Step 4: VERIFICATION (iteration N)

**First, run `${SCRIPTS_DIR}/rc-verify-evidence.sh ${session_dir}`**

The script checks file existence, quote matching, line accuracy ±5,
absence claims via grep, and cross-agent deduplication.

**Returns JSON to stdout:**
```json
{
  "verified": [...],
  "stripped": [...],
  "duplicates": [...]
}
```

**Then, read `${PHASES_DIR}/verify.md`** for severity calibration
and validation gate procedures.

- Apply severity calibration (LLM judgment on findings severity)
- Run validation gate — dispatch a fresh-context validator agent
  to check findings against actual code
- Consolidate duplicates across agents
- Determine iteration verdict: APPROVE or REQUEST CHANGES

**Update tracking:** Set Verification (iteration N) status to `complete`,
record findings total/verified/corrected/stripped, duplicates
consolidated, and iteration verdict.

Proceed to Step 5.

### Step 5: ITERATION CHECK

- **If all agents APPROVE:** Proceed to Step 6 (Report).
- **If any REQUEST CHANGES and iteration < 3:**
  - Fix verified findings
  - Increment iteration counter
  - Return to Step 3 (Delegation)
- **If iteration >= 3:**
  - Ask the user whether to continue fixing or stop and report
  - If user says continue: increment iteration, return to Step 3
  - If user says stop: proceed to Step 6 with REQUEST CHANGES verdict

### Step 6: REPORT

**First, run `${SCRIPTS_DIR}/rc-render-report.sh ${session_dir}`**

The script renders a structured report template from tracking
and verification data.

**Then, read `${PHASES_DIR}/report.md`** for narrative synthesis
and learnings extraction guidance.

- Add narrative synthesis (executive summary, key themes)
- Extract learnings from the review (patterns, anti-patterns, gaps)
- Record learnings using the Knowledge tool (if configured) or
  write to `${session_dir}/learnings.txt`
- Output final report with council verdict

**Update tracking:** Set Report status to `complete`, record council
verdict and learnings count.

---

## Tracking File Template

Maintain `${session_dir}/tracking.md` throughout the run.
Update it after each phase completes. This file is the single
source of truth for run state.

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

## Extension Points

Configure optional integrations in your project's AGENTS.md or CLAUDE.md:

```text
## Review Council Configuration

- Constitution: ./path/to/governance.md
- Knowledge tool: my_semantic_search
- Docs repo: myorg/docs
- Quality tool: my_quality_reporter
```

All extension points are optional and degrade gracefully when omitted.
The Constitution is auto-discovered from `.specify/memory/constitution.md`
if no explicit path is configured and the file is not an unfilled template.

Convention packs define project-specific coding standards. Override or
extend the shipped packs by placing files in `.review-council/packs/`
or `$XDG_CONFIG_HOME/review-council/packs/`.
