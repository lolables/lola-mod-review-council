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

Three details below are load-bearing for Step 3, and getting any of
them wrong still leaves both scripts exiting 0 -- a green diagnostic
over a pipeline that never ran:

- The agent is named `divisor-test-code`, not `test-agent`.
  rc-verify-evidence.sh discovers verdicts by the `divisor-*.json`
  glob, so any other name is invisible to it and Step 3 reports
  `nothing_to_do` without writing `findings.json` at all.
- The finding's `file` is relative to the mock session root, not
  absolute. rc-verify-evidence.sh joins `REVIEW_ROOT` onto `file`
  unconditionally, so an absolute path becomes
  `<root>//tmp/...` and is stripped `FILE_NOT_FOUND`.
- The mock session is the review root, and Step 3 must say so. See
  the `REVIEW_ROOT` note there.

Two rules govern the mock's lifetime, and both exist because a
diagnostic that destroys its own evidence fails the same way a broken
pipeline does — silently, at exit 0.

**Every block echoes what its own checklist reads; nothing is left in a
variable for a later block to find.** Both this block and Step 3's
assign `output=$(...)`. Run them in one shell without echoing and Step
3's assignment overwrites Step 2's, the combined run emits nothing on
stdout, and neither step's "Validate JSON output" bullets can be
answered. Step 3 prints `verdicts/findings.json` in full for the same
reason: its bullets quote fields out of that file, so the file's
contents have to reach you as output rather than as a path you are
trusted to still be able to open.

**Nothing removes the mock until Step 3's block does, and Step 3's
block always does.** Do not wrap this `mktemp -d` in an `EXIT` trap: the
trap fires when *this* block's shell exits, which is before Step 3 reads
the directory. Step 3 expands `${mock_session}`, so either run it in the
same shell as this block or substitute the path this block prints — left
unset, both the `REVIEW_ROOT` and the session argument come out empty
and `rc-verify-evidence.sh` answers with `nothing_to_do` at exit 0,
indistinguishable from a clean run. Because Step 3's block deletes the
mock on its way out, re-running Step 3 means re-running this block
first; against the deleted directory it reports that same
`nothing_to_do`.

```bash
mock_session=$(mktemp -d)
mkdir -p "${mock_session}/verdicts"
target_rel="target.py"
cat >"${mock_session}/${target_rel}" <<'PYEOF'
def get_user(user_id):
    return db.query(f"SELECT * FROM users WHERE id = {user_id}")
PYEOF

verdict_json=$(jq -n --arg file "$target_rel" '{
  agent: "divisor-test-code",
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
} >"${mock_session}/verdicts/divisor-test-code.raw.md"

output=$(${SCRIPTS_DIR}/rc-extract-verdict.sh "${mock_session}" 2>&1)
echo "$output"
echo "mock_session=${mock_session}"
```

Validate JSON output:
- `status` present (`ok`, `extract_error`, `nothing_to_do`, or `skip`)?
- On `ok`, did `verdicts/<agent>.json` get written for every agent?
- On `extract_error`, does the per-agent `reason` (`NO_JSON_BLOCK` /
  `SCHEMA_INVALID` / `VERDICT_INCOHERENT`) and `remediation` text give an
  LLM orchestrator enough to re-dispatch that one agent? A
  `VERDICT_INCOHERENT` block is schema-valid — it declares APPROVE over a
  CRITICAL or HIGH finding — so do not expect `jsonschema validate` to
  reject it.
- `jq` can parse output as valid JSON?

### Step 3: Test rc-verify-evidence.sh

If Step 1 produced a session directory, run:

```bash
output=$(${SCRIPTS_DIR}/rc-verify-evidence.sh "${session_dir}" 2>&1)
```

Otherwise, continue from the mock built in Step 2 -- it consumes
`verdicts/divisor-test-code.json` that `rc-extract-verdict.sh` just
wrote. `REVIEW_ROOT` must name the mock session: it defaults to `.`,
which resolves the finding's `file` against the current working
directory instead of the mock, and the finding is stripped
(`FILE_NOT_FOUND`, or `PATH_OUTSIDE_ROOT` when it does resolve but
lands outside the root) before the evidence matcher -- the one
component this step exists to exercise -- ever runs. The script still
exits 0 with `status: "ok"`, so nothing in the output says the match
never happened:

```bash
output=$(REVIEW_ROOT="${mock_session}" \
  ${SCRIPTS_DIR}/rc-verify-evidence.sh "${mock_session}" 2>&1)
echo "$output"
echo "--- verdicts/findings.json ---"
cat "${mock_session}/verdicts/findings.json"
echo "--- matcher assertion ---"
jq -e '(.verified | length) == 1 and (.stripped | length) == 0' \
  "${mock_session}/verdicts/findings.json" >/dev/null \
  && echo "matcher: PASS -- the mock finding is verified, nothing stripped" \
  || echo "matcher: FAIL -- read .stripped[].reason above"
rm -rf "${mock_session}"
```

Same validation as Step 1:
- Valid JSON output?
- `status` and `message` present?
- `message` clearly tells LLM what to do next?
- Proper handling of edge cases (no findings, all stripped)?
- `verdicts/findings.json` written with the finding's `constraint`
  field carried through untouched? Read it out of the
  `--- verdicts/findings.json ---` dump the mock block prints, not off
  disk: that block removes the mock as it exits.
- Did the mock finding actually reach the matcher? The mock block
  answers this with a `matcher:` line, requiring `verified` to hold the
  finding and `stripped` to be empty --
  `jq -e '(.verified | length) == 1 and (.stripped | length) == 0'`.
  A green `status: "ok"` does not answer it: a finding stripped
  `PATH_OUTSIDE_ROOT` or `FILE_NOT_FOUND` reports `ok` too, and
  `findings.json` is written either way. Treat `matcher: FAIL` as a
  failed Step 3, and read the `reason` on the stripped entry in the
  dump -- it names which of the three Step 2 details is wrong, not a
  defect in the script.

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
- **Incoherent verdict**: a schema-valid block declaring
  `"verdict": "APPROVE"` alongside a `CRITICAL` or `HIGH` finding. Expect
  `reason: "VERDICT_INCOHERENT"` with a `detail` naming the remedies. The
  distinct reason matters here: the block passes `jsonschema validate`, so
  `SCHEMA_INVALID` would send you chasing a schema break that does not exist.
- **Missing tracking.md**: Session exists but tracking.md not created
- **Large changeset**: Test with 1000+ files, check performance
- **Special characters**: Files and messages with quotes, newlines, unicode
