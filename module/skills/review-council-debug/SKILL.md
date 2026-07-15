---
name: review-council-debug
description: >
  NEVER AUTO-TRIGGER
  Diagnostic tool for review-council maintainers. Exercises the
  review-council scripts against the current repository and evaluates
  whether their output messages are clear enough for an LLM orchestrator.
---

# review-council-debug

Diagnostic skill for validating review-council script output quality and clarity.

**HARD-GATE exemption:** The review-council SKILL.md prohibits running
local builds, tests, linters, and CI commands during reviews. This skill
is a maintainer diagnostic, not a review run. Executing rc-prepare.sh,
rc-verify-evidence.sh, and rc-render-report.sh is its entire purpose.

## Path Anchoring

This skill references the review-council scripts from the parent module. Derive the script directory:

```bash
SKILL_DIR="$(dirname "$(realpath "$0")")"
SCRIPTS_DIR="$SKILL_DIR/../review-council/scripts"
```

The scripts referenced are:
- `${SCRIPTS_DIR}/rc-prepare.sh` — session preparation
- `${SCRIPTS_DIR}/rc-verify-evidence.sh` — evidence validation
- `${SCRIPTS_DIR}/rc-render-report.sh` — report rendering

## When to Use

Run this diagnostic skill:
- After modifying any review-council script to validate output quality
- When a user reports a failed or confusing review-council run
- During development of new review-council features
- Never auto-invoked; always manually triggered for validation

## Diagnostic Procedure

### Step 1: Test rc-prepare.sh

Execute the preparation script:

```bash
output=$(${SCRIPTS_DIR}/rc-prepare.sh 2>&1)
```

Validate the JSON output:
- Is `status` present in the output?
- Is `message` present and non-empty?
- Does `message` clearly state what to do next (continue, stop, or what the next step is)?
- Are any fields null or undefined? If so, does `message` explain why?
- Can jq parse the output as valid JSON?

Capture the `session_dir` from the output if status is "ok" for use in Step 2.

### Step 2: Test rc-verify-evidence.sh

If Step 1 produced a session directory, run:

```bash
output=$(${SCRIPTS_DIR}/rc-verify-evidence.sh "${session_dir}" 2>&1)
```

If no session was created, create a minimal mock session with a synthetic verdict file:

```bash
mock_session="/tmp/rc-debug-mock-$$"
mkdir -p "${mock_session}/verdicts"
echo "### [MEDIUM] Test Finding" > "${mock_session}/verdicts/test-agent.md"
echo "**File**: \`test.txt:10\`" >> "${mock_session}/verdicts/test-agent.md"
echo "**Evidence**: \`test evidence\`" >> "${mock_session}/verdicts/test-agent.md"
output=$(${SCRIPTS_DIR}/rc-verify-evidence.sh "${mock_session}" 2>&1)
```

Same validation as Step 1:
- Valid JSON output?
- `status` and `message` present?
- Does `message` clearly tell an LLM what to do next?
- Proper handling of edge cases (no findings, all stripped)?

### Step 3: Test rc-render-report.sh

If a session exists, render the report:

```bash
output=$(${SCRIPTS_DIR}/rc-render-report.sh "${session_dir}" 2>&1)
```

Validate the markdown output:
- Is the output valid markdown (no unescaped characters, proper heading hierarchy)?
- Are expected sections present (Session Information, Discovery Summary, Verification Summary)?
- Does the report gracefully handle missing data (tracking.md not found, no evidence-check.json)?
- Are field values properly quoted/escaped?
- Would an LLM reading this know the review outcome?

### Step 4: Evaluate Script Output Quality

For each script's output, assess:

**JSON Validity**
- Is the JSON parseable by `jq`?
- Are all strings properly quoted?
- Are arrays and objects well-formed?

**Message Clarity**
- Does the `message` field tell an LLM what to do next?
- Is the message actionable or explanatory?
- Are there unclear abbreviations or jargon without context?

**Silent Failures**
- Is there empty output instead of a JSON response?
- Are fields missing when they should be present?
- Does status "skip" or "nothing_to_do" differ semantically (can an LLM distinguish them)?

**LLM Readability**
- Would an LLM reading the message know whether to continue or stop?
- Are "not found" and "nothing to do" messages distinct and clear?
- Are error messages actionable?

### Step 5: Generate Diagnostic Report

Output a structured diagnostic report:

```
Review Council Debug Report
============================

Script: rc-prepare.sh
- JSON Valid: [YES/NO]
- Message Present: [YES/NO]
- Message Clear: [YES/NO]
- Status Values: [list detected statuses]
- Issues: [list any problems found]
- Recommendation: [improvement suggestion if needed]

Script: rc-verify-evidence.sh
- [same structure]

Script: rc-render-report.sh
- [same structure]

Overall Recommendation:
[Summary of findings and next steps]
```

## Edge Cases to Test

Test these scenarios for robustness:

- **Non-git directory**: Run scripts outside a git repo
- **Empty repository**: Init a git repo with no commits
- **No forge CLI**: Verify graceful degradation when `gh` and `glab` are unavailable
- **Empty changeset (--scope changed)**: Run `rc-prepare.sh --mode code` on a repo where HEAD is main (no feature branch). Expect `status: "empty"`. Verify `message` is clear enough for the orchestrator to know it should retry with `--scope all`.
- **Empty changeset (--scope range)**: Run `rc-prepare.sh --scope range --scope-value "HEAD~1..HEAD"` where HEAD is an empty commit. Expect `status: "empty"`. Verify `message` guides the orchestrator to retry with `--scope changed`.
- **Empty changeset (--scope all, terminal)**: Run `rc-prepare.sh --mode specs` on a repo with no spec directories. Expect `status: "empty"`. Verify `message` makes clear that no retry is available and the orchestrator should ask the user what to review.
- **No verdict files**: Session created but verdicts directory is empty
- **Malformed verdict files**: Verdicts with missing fields or invalid format
- **Missing tracking.md**: Session exists but tracking.md was not created
- **Large changeset**: Test with 1000+ files to check performance
- **Special characters**: Files and messages with quotes, newlines, unicode
