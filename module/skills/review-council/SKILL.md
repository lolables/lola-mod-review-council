---
name: review-council
description: >
  NEVER AUTO-TRIGGER
  Multi-persona code and specification review system. Dispatches
  specialized reviewer agents in parallel, verifies findings against
  source evidence, and produces a council verdict.
---

# Review Council

<HARD-GATE>
Review Council is READ-ONLY by default. After producing a verdict, STOP
and present findings to the user. Do NOT fix, edit, or modify any
reviewed code or spec unless the user explicitly instructs you to do so
in the current session. This applies to ALL iterations, ALL severity
levels, and both code and spec review modes. The only write operations
permitted without user consent are session bookkeeping (tracking files,
verdict files, learnings) inside the session directory.

Do NOT run local builds, tests, linters, or CI commands. Review Council
analyzes source code statically — it never executes project code. Reading
upstream CI status from the forge (Step 2.2) is permitted; launching
local processes is not.
</HARD-GATE>

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
| `quick`                          | `--effort quick`                                                                                   |
| `deep`                           | `--effort deep`                                                                                    |
| `quick code HEAD`                | `--effort quick --mode code --scope range --scope-value "HEAD~1..HEAD"`                            |
| `deep main..feat`                | `--effort deep --scope range --scope-value "main..feat"`                                           |
| `quick 42`                       | `--effort quick --scope pr --scope-value 42`                                                       |

**Rules:**

1. **Scope** (what to review) vs **instructions** (how to review): separate them. Anything that describes *what files/commits* is scope. Anything that describes *what to look for* is instructions.
2. **Git refs** resolve to range: `REF` → `--scope range --scope-value "REF~1..REF"`. Ref ranges pass through: `X..Y` → `--scope range --scope-value "X..Y"`.
3. **Directory paths** become a secondary filter: `--scope changed --scope paths --scope-value "dir/"`.
4. **Defaults**: if scope is unclear, omit `--scope` (code defaults to `changed`, specs to `all`). If mode is unclear, omit `--mode` (auto-detect).
5. **Fallback**: if the input doesn't clearly specify scope or mode, pass what you can and let defaults apply. Unrecognized text becomes `--review-instructions`.
6. **Effort** words: `quick` → `--effort quick`, `deep` → `--effort deep`. If neither appears, omit `--effort` (defaults to `standard`). Effort words can appear in any position alongside scope and mode tokens.
7. **No preemptive optimization**: The first rc-prepare.sh call MUST use exactly the flags from this table. Do not anticipate that a scope will be empty and skip ahead to a broader scope. The recovery table in Step 1 handles empty results — let it work.

### Step 1: PREPARE (scripted)

Run `${SCRIPTS_DIR}/rc-prepare.sh` with **exactly** the flags from Step 0's
decision table. Do not add `--scope` if the table omits it — the script has
its own defaults. Do not substitute a broader scope because you expect the
default will be empty.

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
  "scope_dir": "",
  "effort": "standard"
}
```

**If status is `skip`:** Read the message field, report to the user,
and stop. Do not proceed to delegation.

**If status is `empty`:** The scope resolved to zero files. Before
giving up, try exactly ONE recovery attempt using the table below.
If you already retried once, report the empty result to the user and
ask what they would like to review instead.

| Original scope                                      | Recovery action                                                                                                                                                                                       |
|-----------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `--scope changed` (with or without `--scope paths`) | Re-run with `--scope all` (keep `--scope paths` and `--scope-value` if present, keep `--mode`)                                                                                                        |
| `--scope range --scope-value "X..Y"`                | Re-run with `--scope changed` (keep `--mode`)                                                                                                                                                         |
| `--scope all`                                       | **Terminal — no retry permitted.** Output the message below verbatim (filling in the blanks), then end the task. Do not call rc-prepare.sh again. Do not read project files. Do not produce findings. |
| Any other                                           | Re-run with `--scope all` (keep `--mode`)                                                                                                                                                             |

When `--scope all` returns `empty`, output exactly this and stop:

> **Review Council: no files in scope.**
> Mode: {code or specs}
> Searched: {list directories the mode scans — code: all tracked files; specs: specs/, docs/specs/, docs/design/, design/}
> Result: no matching files found.
>
> To continue, tell me which path or scope you'd like reviewed — for example:
> - `/review-council code` to review code instead of specs
> - `/review-council specs module/docs/` to review a specific directory

**Be explicit when changing scope.** Before re-running with recovery
flags, tell the user what happened and what you are trying instead.
Example: "The diff for HEAD~1..HEAD contained no files. Falling back
to reviewing uncommitted and staged changes (--scope changed)."

Do NOT invent flags and do NOT fall back to a manual review. Run
rc-prepare.sh exactly once more with the recovery flags. If the second
attempt also returns `empty`, report both results to the user and ask
what they would like to review.

**If status is `ok`:** Capture session_dir, mode, and effort, proceed to Step 2.

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

### Step 2.1: DECOMPOSITION (deep mode only)

**Skip this step unless effort is `deep`.**

Read `${PHASES_DIR}/decompose.md` for decomposition instructions.

Analyze the changeset from `${session_dir}/changeset.txt` and the diff
from `${session_dir}/diff.patch`. Produce a subsystem map and write it
to `${session_dir}/subsystems.json`.

If decomposition produces a single subsystem (changeset is already
cohesive), fall back to standard-mode delegation — do not create
`subsystems.json`.

**Update tracking:** Record subsystem count and names.

Proceed to Step 2.5 (Quality Gates).

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

**Effort-conditional behavior:**
- **quick / standard**: Delegate once over the whole changeset as
  described above.
- **deep**: If `${session_dir}/subsystems.json` exists, run one
  delegation round per subsystem. For each subsystem, scope the
  changeset and diff to that subsystem's files. Write verdicts to
  `${session_dir}/verdicts/{subsystem-name}/{agent-name}.md`.
  Dispatch all agents for a given subsystem in parallel, then proceed
  to the next subsystem.

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

**Effort-conditional behavior:**
- **quick**: Skip the correction round, severity calibration, and
  validation gate. Run only `rc-verify-evidence.sh` (mechanical
  evidence check). Proceed directly to Step 5 with surviving findings.
- **standard**: Full verification as described above.
- **deep**: Run Steps 1-3 of verify.md per-subsystem (iterate over
  subdirectories in `${session_dir}/verdicts/`). Then run the
  validation gate once over aggregated findings from all subsystems,
  providing the subsystem map from `${session_dir}/subsystems.json`
  as context.

**Update tracking:** Set Verification (iteration N) status to `complete`,
record findings total/verified/corrected/stripped, duplicates
consolidated, and iteration verdict.

Proceed to Step 5.

### Step 5: ITERATION CHECK

- **If all agents APPROVE:** Proceed to Step 6 (Report).
- **If any REQUEST CHANGES:**
  - Present the verified findings to the user
  - Ask: "Would you like me to fix these issues and re-review?"
  - **If user says yes:** Fix the findings, increment iteration counter,
    return to Step 3 (Delegation)
  - **If user says no (or stop):** Proceed to Step 6 with
    REQUEST CHANGES verdict
  - **Iteration limits by effort level:**
    - **quick**: Max 1 iteration. After delegation and verification,
      proceed directly to Step 6 regardless of verdict.
    - **standard**: Max 3 iterations. If iteration >= 3 and user
      says yes, warn that this is iteration N and ask the user to
      confirm before continuing.
    - **deep**: Max 5 iterations. If iteration >= 3, warn as above.

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

**Effort-conditional behavior:**
- **quick**: Produce a compact report: findings list (sorted by
  severity) and verdict only. Skip learnings extraction and narrative
  synthesis.
- **standard**: Full report as described above.
- **deep**: Full report plus a **Subsystem Analysis** section before
  the findings list. Read `${session_dir}/subsystems.json` and render
  a tree with finding counts per subsystem. Include learnings.

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
- Effort: {quick | standard | deep}
- Branch: {branch name}
- Base: {main | master}
- Language: {language}
- Framework: {framework | none}
- Agents discovered: {count}
- Agents absent: none
- Changeset size: {count} files

## Phase: Decomposition (deep mode only)

- Subsystems: {count}
- Names: {comma-separated}
- Cross-cutting files: {count}
- Fallback to standard: {yes|no}

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
