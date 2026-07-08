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

**When invoking scripts**, export these variables as environment variables:

```bash
export AGENTS_DIR SCRIPTS_DIR PHASES_DIR REFERENCES_DIR
```

Scripts require `AGENTS_DIR` to discover reviewer agents. Pass it when
calling `rc-prepare.sh`:

```bash
AGENTS_DIR="${AGENTS_DIR}" bash "${SCRIPTS_DIR}/rc-prepare.sh" [user args]
```

## Quick Reference

### Usage

```
/review-council              # auto-detect from current branch
/review-council code         # force code review mode
/review-council specs        # force spec review mode
/review-council 42           # review PR #42
/review-council main..feat   # review a ref range
/review-council https://github.com/org/repo/pull/42  # review by URL
/review-council HEAD         # review only the latest commit
/review-council module/      # review changes under a directory
/review-council everything   # explicit full-project review
/review-council code HEAD -> focus on security  # mode + target + instructions
```

### What It Does

Review Council dynamically discovers reviewer agents matching
`divisor-*-code.md` or `divisor-*-spec.md` (based on review mode)
and delegates review to each persona in parallel. It verifies
findings against actual file content, strips fabricated evidence,
and produces a council verdict (APPROVE or REQUEST CHANGES).

Five reviewer personas run in parallel: Guard (intent drift,
governance, structural coherence), Adversary (security, resilience),
Tester (test quality, coverage), Operator (deployment, dependencies),
Curator (documentation gaps).

## Execution Flow

This skill is a re-entrant state machine. If invoked mid-run,
it reads the tracking file and resumes from the last completed phase.

### Step 0: INTERPRET INPUT (LLM judgment)

Before calling the script, interpret the user's input and resolve it
to explicit CLI flags. The script accepts only structured flags — it
does NOT parse raw user input.

**Decision table:**

| User says                        | Flags                                                                                              |
|----------------------------------|----------------------------------------------------------------------------------------------------|
| *(empty)*                        | *(no flags — defaults apply)*                                                                      |
| `code`                           | `--mode code`                                                                                      |
| `specs`                          | `--mode specs`                                                                                     |
| `42`                             | `--scope pr --scope-value 42`                                                                      |
| `main..feat`                     | `--scope range --scope-value "main..feat"`                                                         |
| `HEAD`                           | `--scope range --scope-value "HEAD~1..HEAD"`                                                       |
| `v1.2.3`                         | `--scope range --scope-value "v1.2.3~1..v1.2.3"`                                                   |
| `module/`                        | `--scope changed --scope paths --scope-value "module/"`                                            |
| `everything`                     | `--scope all`                                                                                      |
| `https://...pull/42`             | `--scope url --scope-value "https://...pull/42"`                                                   |
| `code HEAD -> focus on security` | `--mode code --scope range --scope-value "HEAD~1..HEAD" --review-instructions "focus on security"` |
| `review the auth module`         | `--scope changed --scope paths --scope-value "src/auth/"`                                          |
| `do stuff and make it good`      | `--review-instructions "make it good"`                                                             |

**Rules:**

1. **Scope** (what to review) vs **instructions** (how to review): separate them. Anything that describes *what files/commits* is scope. Anything that describes *what to look for* is instructions.
2. **Git refs** resolve to range: `REF` → `--scope range --scope-value "REF~1..REF"`. Ref ranges pass through: `X..Y` → `--scope range --scope-value "X..Y"`.
3. **Directory paths** become a secondary filter: `--scope changed --scope paths --scope-value "dir/"`.
4. **Defaults**: if scope is unclear, omit `--scope` (code defaults to `changed`, specs to `all`). If mode is unclear, omit `--mode` (auto-detect).
5. **Fallback**: if the input doesn't clearly specify scope or mode, pass what you can and let defaults apply. Unrecognized text becomes `--review-instructions`.

### Step 1: PREPARE (scripted)

Run `${SCRIPTS_DIR}/rc-prepare.sh` with the flags resolved in Step 0.

```bash
AGENTS_DIR="${AGENTS_DIR}" bash "${SCRIPTS_DIR}/rc-prepare.sh" [resolved flags from Step 0]
```

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
  "agents": ["divisor-guard-code", "divisor-adversary-code", ...],
  "language": "Go",
  "framework": "none",
  "review_instructions": "",
  "scope_type": "changed | all | range | paths | pr | url",
  "scope_value": "",
  "scope_dir": ""
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

### Step 2.5: QUALITY GATES (code review with PR only)

If `${session_dir}/ci-status.txt` exists (created by rc-prepare.sh for
PR-based code reviews with forge CI data):

1. Read `${session_dir}/ci-status.txt`
2. If there are failing CI checks:
   - Present the failures to the user
   - Ask: "CI checks are failing. Proceed with review or abort?"
   - If abort: stop and report "Review aborted due to failing CI"
3. If all checks pass or user chooses to proceed: continue to Step 3

If `${session_dir}/ci-status.txt` does not exist, skip this step.

**Update tracking:** Set Phase: Quality Gates status to `complete`.

### Step 3: DELEGATION (iteration N)

**Read `${PHASES_DIR}/delegate.md`** for prompt construction
guidance and dispatch instructions.

**Before constructing prompts**, read these session files:
- `${session_dir}/changeset.txt` — the file list (scope-filtered)
- `${session_dir}/diff.patch` — the diff (may be empty for `--scope all`)
- `${session_dir}/tracking.md` — scope, mode, language, framework metadata

For each reviewer agent in the agents array from Step 1:
- Construct a prompt using the changeset from `changeset.txt`,
  the diff from `diff.patch`, convention packs from
  `${REFERENCES_DIR}`, and project configuration
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
Update it after each phase completes. The Preparation and
Quality Gates phases are written by `rc-prepare.sh`. The
orchestrator writes subsequent phases.

```markdown
# Review Council Session Tracking

## Phase: Preparation

- Input type: {auto | pr_number | ref_range | url | dir_scope | all}
- Scope: {changed | all | range | paths | pr | url}
- Scope value: {resolved scope value or base...HEAD}
- Forge: {github | gitlab | local}
- Tooling: {gh | glab | none}
- PR: {none | PR number}
- Linked issues: {count}
- Prior reviews: {count}
- Constitution: {none | path (source)}
- Mode: {code | spec} ({reason})
- Branch: {branch name}
- Base: {main | master}
- Language: {language}
- Framework: {framework | none}
- Agents discovered: {count}
- Agents absent: none
- Changeset size: {count} files

## Phase: Quality Gates

- Forge CI: {available | unavailable}
- Forge CI failures: {count}

## Phase: Delegation (iteration {N})

- Status: {pending | complete | failed}
- Agents dispatched: {count}
- Verdicts received: {count}
- Agent failures: {list or "none"}

## Phase: Verification (iteration {N})

- Status: {pending | complete | failed}
- Findings total: {count}
- Findings verified: {count}
- Findings correctable: {count}
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
If no Constitution path is configured, constitution-specific checks are skipped.

Convention packs define project-specific coding standards. Override or
extend the shipped packs by placing files in `.review-council/packs/`
or `$XDG_CONFIG_HOME/review-council/packs/`.
