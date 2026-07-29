---
name: review-council-debug
description: >
  NEVER AUTO-TRIGGER
  Diagnostic tool for review-council maintainers. Exercises the
  review-council scripts against the current repository and evaluates
  whether their output messages are clear enough for an LLM orchestrator.
---

# review-council-debug

Diagnostic skill. Validates review-council script output quality and clarity.

**HARD-GATE exemption:** review-council SKILL.md prohibits running
local builds, tests, linters, CI during reviews. This skill
is maintainer diagnostic, not review run. Executing rc-prepare.sh,
rc-extract-verdict.sh, rc-verify-evidence.sh, rc-render-report.sh is
its entire purpose.

## Path Anchoring

References review-council scripts from parent module. Derive script directory:

```bash
SKILL_DIR="$(dirname "$(realpath "$0")")"
SCRIPTS_DIR="$SKILL_DIR/../review-council/scripts"
```

Scripts referenced:
- `${SCRIPTS_DIR}/rc-prepare.sh` -- session preparation
- `${SCRIPTS_DIR}/rc-extract-verdict.sh` -- extracts + schema-validates each
  agent's fenced JSON block from `verdicts/<agent>.raw.md`, writing
  `verdicts/<agent>.json`
- `${SCRIPTS_DIR}/rc-verify-evidence.sh` -- evidence validation, writes
  `verdicts/findings.json`
- `${SCRIPTS_DIR}/rc-render-report.sh` -- report rendering

## When to Use

- After modifying any review-council script, validate output quality
- When user reports failed or confusing review-council run
- During development of new review-council features
- Never auto-invoked; always manually triggered

## Diagnostic Procedure

### Step 1: Test rc-prepare.sh

Execute preparation script:

```bash
output=$(${SCRIPTS_DIR}/rc-prepare.sh 2>&1)
```

Validate JSON output:
- `status` present?
- `message` present and non-empty?
- `message` clearly states what to do next (continue, stop, next step)?
- Any fields null or undefined? If so, does `message` explain why?
- `jq` can parse output as valid JSON?

Capture `session_dir` from output if status is "ok" for Step 2.

### Step 2: Test rc-extract-verdict.sh

If Step 1's session already has reviewer output (real subagents
dispatched, each having written `verdicts/<agent>.raw.md`), run:

```bash
output=$(${SCRIPTS_DIR}/rc-extract-verdict.sh "${session_dir}" 2>&1)
```

If no session was created, or no reviewers ran, build a minimal mock:
a raw reviewer transcript containing exactly one fenced JSON block that
validates against `references/verdict-schema.json`, plus the target
file its evidence quotes verbatim (rc-verify-evidence.sh in Step 3
greps for that exact string, so the mock must contain it).

```bash
mock_session="/tmp/rc-debug-mock-$$"
mkdir -p "${mock_session}/verdicts"
target="${mock_session}/target.py"
cat >"${target}" <<'PYEOF'
def get_user(user_id):
    return db.query(f"SELECT * FROM users WHERE id = {user_id}")
PYEOF

verdict_json=$(jq -n --arg file "$target" '{
  agent: "test-agent",
  files_read: [$file],
  verdict: "REQUEST CHANGES",
  findings: [{
    severity: "HIGH",
    file: $file,
    line: 2,
    evidence: "db.query(f\"SELECT * FROM users WHERE id = {user_id}\")",
    constraint: "no-raw-sql-interpolation",
    description: "user_id is interpolated directly into the SQL string, allowing injection.",
    recommendation: "Use a parameterized query instead of an f-string."
  }]
}')
{
  echo '```json'
  echo "$verdict_json"
  echo '```'
} >"${mock_session}/verdicts/test-agent.raw.md"

output=$(${SCRIPTS_DIR}/rc-extract-verdict.sh "${mock_session}" 2>&1)
```

Validate JSON output:
- `status` present (`ok`, `extract_error`, `nothing_to_do`, or `skip`)?
- On `ok`, did `verdicts/<agent>.json` get written for every agent?
- On `extract_error`, does the per-agent `reason` (`NO_JSON_BLOCK` /
  `SCHEMA_INVALID`) and `remediation` text give an LLM orchestrator
  enough to re-dispatch that one agent?
- `jq` can parse output as valid JSON?

### Step 3: Test rc-verify-evidence.sh

If Step 1 produced a session directory, run:

```bash
output=$(${SCRIPTS_DIR}/rc-verify-evidence.sh "${session_dir}" 2>&1)
```

Otherwise, continue from the mock built in Step 2 -- it consumes
`verdicts/test-agent.json` that `rc-extract-verdict.sh` just wrote:

```bash
output=$(${SCRIPTS_DIR}/rc-verify-evidence.sh "${mock_session}" 2>&1)
```

Same validation as Step 1:
- Valid JSON output?
- `status` and `message` present?
- `message` clearly tells LLM what to do next?
- Proper handling of edge cases (no findings, all stripped)?
- `verdicts/findings.json` written with the finding's `constraint`
  field carried through untouched?

### Step 4: Test rc-render-report.sh

If session exists, render report:

```bash
output=$(${SCRIPTS_DIR}/rc-render-report.sh "${session_dir}" 2>&1)
```

Validate markdown output:
- Valid markdown (no unescaped characters, proper heading hierarchy)?
- Expected sections present (Session Information, Discovery Summary, Verification Summary)?
- Report gracefully handles missing data (tracking.md not found, no verdicts/findings.json)?
- Field values properly quoted/escaped?
- LLM reading this knows review outcome?

### Step 5: Evaluate Script Output Quality

For each script output, assess:

**JSON Validity**
- JSON parseable by `jq`?
- All strings properly quoted?
- Arrays and objects well-formed?

**Message Clarity**
- `message` field tells LLM what to do next?
- Message actionable or explanatory?
- Unclear abbreviations or jargon without context?

**Silent Failures**
- Empty output instead of JSON response?
- Fields missing when they should be present?
- Status "skip" vs "nothing_to_do" semantically distinct (can LLM distinguish)?

**LLM Readability**
- LLM reading message knows whether to continue or stop?
- "not found" and "nothing to do" messages distinct and clear?
- Error messages actionable?

### Step 6: Generate Diagnostic Report

Output structured diagnostic report:

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

Script: rc-extract-verdict.sh
- [same structure]

Script: rc-verify-evidence.sh
- [same structure]

Script: rc-render-report.sh
- [same structure]

Overall Recommendation:
[Summary of findings and next steps]
```

## Edge Cases to Test

Test these scenarios for robustness:

- **Non-git directory**: Run scripts outside git repo
- **Empty repository**: Init git repo with no commits
- **No forge CLI**: Verify graceful degradation when `gh` and `glab` unavailable
- **Empty changeset (--scope changed)**: Run `rc-prepare.sh --mode code` on repo where HEAD is main (no feature branch). Expect `status: "empty"`. Verify `message` clear enough for orchestrator to know it should retry with `--scope all`.
- **Empty changeset (--scope range)**: Run `rc-prepare.sh --scope range --scope-value "HEAD~1..HEAD"` where HEAD is empty commit. Expect `status: "empty"`. Verify `message` guides orchestrator to retry with `--scope changed`.
- **Empty changeset (--scope all, terminal)**: Run `rc-prepare.sh --mode specs` on repo with no spec directories. Expect `status: "empty"`. Verify `message` makes clear no retry available and orchestrator should ask user what to review.
- **No verdict files**: Session created but verdicts directory empty
- **Malformed raw.md**: `verdicts/<agent>.raw.md` with no fenced JSON block,
  invalid JSON, or JSON that fails `verdict-schema.json`. Expect
  `rc-extract-verdict.sh` to return `status: "extract_error"` with a
  per-agent `reason` (`NO_JSON_BLOCK` / `SCHEMA_INVALID`) and
  `remediation` text -- not a silently dropped agent.
- **Missing tracking.md**: Session exists but tracking.md not created
- **Large changeset**: Test with 1000+ files, check performance
- **Special characters**: Files and messages with quotes, newlines, unicode
