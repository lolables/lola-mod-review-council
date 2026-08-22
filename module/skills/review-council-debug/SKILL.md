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

References review-council scripts from parent module. `SCRIPTS_DIR` must
be set by substitution, not derived at runtime: this file is never
executed, so inside a bash tool call `$0` and `${BASH_SOURCE[0]}` name
the shell, not this SKILL.md, and every path derived from them is wrong.

Substitute the absolute directory of the SKILL.md you are reading (the
host resolved that path to load this file) for `<this-skill-dir>`:

```bash
SCRIPTS_DIR="<this-skill-dir>/../review-council/scripts"
```

In a checkout of this module, that resolves to the following, which you
may use directly instead:

```bash
SCRIPTS_DIR="$(git rev-parse --show-toplevel)/module/skills/review-council/scripts"
```

Confirm the assignment before running anything else — every later step
expands `${SCRIPTS_DIR}`, and an unset or wrong value makes each
invocation a "command not found" rather than a diagnostic result:

```bash
[[ -x "${SCRIPTS_DIR}/rc-prepare.sh" ]] \
  && echo "SCRIPTS_DIR ok: ${SCRIPTS_DIR}" \
  || echo "SCRIPTS_DIR wrong: ${SCRIPTS_DIR}"
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
echo "$output"
session_dir=$(printf '%s' "$output" | jq -r 'select(.status == "ok") | .session_dir // empty')
echo "session_dir=${session_dir}"
```

`rc-prepare.sh` emits its `session_dir` as a top-level string field of
the success payload, which is what the `jq -r` above reads. Two results
are both informative: an empty `session_dir=` line means `status` was
not `ok` (Steps 2-4 then run against the Step 2 mock instead), and a
`jq: error` means the script did not emit parseable JSON at all — that
is a Step 1 finding, not a setup problem to work around.

Validate JSON output:
- `status` present?
- `message` present and non-empty?
- `message` clearly states what to do next (continue, stop, next step)?
- Any fields null or undefined? If so, does `message` explain why?
- `jq` can parse output as valid JSON?

### Step 2: Test rc-extract-verdict.sh

If Step 1's session already has reviewer output (real subagents
dispatched, each having written `verdicts/<agent>.raw.md`), run:

```bash
output=$(${SCRIPTS_DIR}/rc-extract-verdict.sh "${session_dir}" 2>&1)
echo "$output"
```

If no session was created, or no reviewers ran, build a minimal mock:
a raw reviewer transcript containing exactly one fenced JSON block that
validates against review-council's `verdict-schema.json` -- this skill
has no `references/` directory of its own; the schema lives beside the
scripts you are testing, at `${SCRIPTS_DIR}/../references/verdict-schema.json`
(which is exactly how `rc-extract-verdict.sh` resolves it) -- plus the target
file its evidence quotes verbatim (rc-verify-evidence.sh in Step 3
greps for that exact string, so the mock must contain it).

Three details below are load-bearing for Step 3, and getting any of
them wrong still leaves both scripts exiting 0 -- a green diagnostic
over a pipeline that never ran:

- The agent is named `divisor-test-code`, not `test-agent`. `divisor-`
  is review-council's reviewer-agent prefix: its personas ship as
  `divisor-*-{code,spec}.md`, so a real reviewer's verdict file is
  always `divisor-*.json`. rc-verify-evidence.sh discovers verdicts by
  that glob, so any other name is invisible to it and Step 3 reports
  `nothing_to_do` without writing `findings.json` at all.
- The finding's `file` is relative to the mock session root, not
  absolute. rc-verify-evidence.sh joins the review root onto `file`
  whenever that root is not `.`, so with the root set as Step 3 sets it
  an absolute path becomes `<root>//tmp/...` and is stripped
  `FILE_NOT_FOUND`.
- The mock session is the review root, and Step 3 must say so. The
  review root is the directory each finding's `file` is resolved
  against; it defaults to `.`. Step 3's "Point the review root at the
  mock" sub-step sets it.

Two rules govern the mock's lifetime, and both exist because a
diagnostic that destroys its own evidence fails the same way a broken
pipeline does — silently, at exit 0.

**Every block echoes what its own checklist reads; nothing is left in a
variable for a later block to find.** Every block from Step 1 to Step 4
assigns `output=$(...)`, and each one echoes it before the next
assignment lands. Run two of them in one shell without echoing and the
later assignment overwrites the earlier, the combined run emits nothing
on stdout, and neither step's "Validate JSON output" bullets can be
answered. Step 3 prints `verdicts/findings.json` in full for the same
reason: its bullets quote fields out of that file, so the file's
contents have to reach you as output rather than as a path you are
trusted to still be able to open.

**Nothing removes the mock until Step 4's block does.** Do not wrap this
`mktemp -d` in an `EXIT` trap: the trap fires when *this* block's shell
exits, which is before Step 3 reads the directory.

Steps 3 and 4 both expand `${mock_session}`, so either run them in the
same shell as this block or substitute the path this block prints — left
unset, both the review root and the session argument come out empty and
`rc-verify-evidence.sh` answers with `nothing_to_do` at exit 0,
indistinguishable from a clean run.

Step 3 leaves the mock in place, on either of its branches, precisely so
Step 4 can render against it; Step 4's block deletes it on its way out,
so re-running either step after that means re-running this block first.
Against the deleted directory both report `nothing_to_do`.

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

Take branch A if Step 1 printed a non-empty `session_dir`; take branch B
otherwise. Neither branch deletes anything: Step 4 needs whichever
session directory this step ran against.

#### Branch A: real session from Step 1

1. Run against Step 1's session directory:

   ```bash
   output=$(${SCRIPTS_DIR}/rc-verify-evidence.sh "${session_dir}" 2>&1)
   echo "$output"
   ```

2. Answer the "Validate JSON output" bullets below from that output.
   The `matcher:` bullet does not apply on this branch -- it asserts the
   shape of the Step 2 mock, not of a real changeset.

#### Branch B: mock session from Step 2

The mock consumes `verdicts/divisor-test-code.json` that
`rc-extract-verdict.sh` just wrote.

1. **Point the review root at the mock.** The root defaults to `.`:

   - That resolves the finding's `file` against the current working
     directory instead of the mock, and the finding is stripped
     (`FILE_NOT_FOUND`, or `PATH_OUTSIDE_ROOT` when it does resolve but
     lands outside the root) before the evidence matcher -- the one
     component this step exists to exercise -- ever runs.
   - The script still exits 0 with `status: "ok"`, so nothing in the
     output says the match never happened.
   - Two inputs set the root, and the script reads them as
     `review_root="${2:-${REVIEW_ROOT:-.}}"`: positional argument 2
     outranks the `REVIEW_ROOT` environment variable.
   - The block below uses the environment variable and passes only the
     session argument, so there is no argument 2 to override it.

2. **Run the script, dump what the checklist reads, and assert the
   matcher ran.**

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
     || echo "matcher: FAIL -- read .stripped[].reason and .correctable[].reason above"
   ```

3. Answer every bullet below, including the `matcher:` one.

Validate JSON output:
- Valid JSON output?
- `status` and `message` present?
- `message` clearly tells LLM what to do next?
- Proper handling of edge cases (no findings, all stripped)?
- `verdicts/findings.json` written with the finding's `constraint`
  field carried through untouched? Read it out of the
  `--- verdicts/findings.json ---` dump the mock block prints, not off
  disk: Step 4 removes the mock as it exits.
- Did the mock finding actually reach the matcher? The mock block
  answers this with a `matcher:` line.
  - The assertion is
    `jq -e '(.verified | length) == 1 and (.stripped | length) == 0'` --
    `verified` holds the finding, `stripped` is empty.
  - A green `status: "ok"` does not answer it. A finding stripped
    `PATH_OUTSIDE_ROOT` or `FILE_NOT_FOUND` reports `ok` too, and
    `findings.json` is written either way.
  - Treat `matcher: FAIL` as a failed Step 3.
  - On failure, read the `reason` in the dump. Path faults
    (`FILE_NOT_FOUND`, `PATH_OUTSIDE_ROOT`) land in `.stripped[]`;
    evidence faults (`EVIDENCE_NOT_FOUND`, `EVIDENCE_EMPTY`,
    `LINE_MISMATCH`, `EVIDENCE_SCAN_ERROR`) land in `.correctable[]`,
    which leaves `.stripped[]` empty -- check both arrays.
  - The `reason` names which of the three Step 2 details is wrong, not
    a defect in the script.

### Step 4: Test rc-render-report.sh

A session directory is not sufficient input. The renderer checks three
preconditions in order and stops at the first unmet one, printing
markdown and exiting 0 each time:

1. `<session>` exists -- otherwise `Session data not available.`
2. `<session>/tracking.md` exists -- otherwise
   `Session tracking data not found.`
3. `<session>/verdicts/_meta/verification.txt` exists, is non-empty,
   contains a `=== SUMMARY ===` line, and holds no `{placeholder}`
   tokens -- otherwise `**Not rendered.**` plus the reason.

The third is the one that catches maintainers out. Step 1 only prepares
a session; nothing in Steps 1-3 writes `verdicts/_meta/verification.txt`,
which the Verification phase writes during a real run. So a Step-1
session and the Step 2 mock both hit the refusal, and no report section
is reachable until the file is placed. The two sub-steps below exercise
both outcomes against the mock Step 3 left in place. If Step 3 took
branch A, substitute `${session_dir}` for `${mock_session}` throughout,
skip the `tracking.md` write (rc-prepare.sh already wrote one), and skip
the closing `rm -rf` — that directory is a real session, not a
throwaway.

**4a. Refusal.** The mock has no `tracking.md`, and precondition 2 would
stop the run before the check this sub-step is about, so write one
first. Every `tracking.md` key the renderer reads has a default, so a
short file is enough:

```bash
cat >"${mock_session}/tracking.md" <<'TRACKEOF'
# Review Council Session
- Mode: code
- Branch: mock
- Base: main
- Agents discovered: 1
- Changeset size: 1 files
TRACKEOF

output=$(${SCRIPTS_DIR}/rc-render-report.sh "${mock_session}" 2>&1)
echo "$output"
```

Expect a `# Review Council Report` heading, `**Not rendered.**` followed
by the reason (`verification.txt is missing or empty — the Verification
phase was not executed.`), an instruction to return to the Verification
phase, and an `Expected at:` line naming
`${mock_session}/verdicts/_meta/verification.txt`. Expect no report
sections and exit status 0.

**4b. Rendered report.** Satisfy the gate the way the Verification
phase's abbreviated record does -- a real `=== SUMMARY ===` block with
literal counts, never `{N}`-shaped placeholders, which the renderer
rejects as a templated log:

```bash
mkdir -p "${mock_session}/verdicts/_meta"
cat >"${mock_session}/verdicts/_meta/verification.txt" <<'VERIFYEOF'
=== EVIDENCE VERIFICATION ===
rc-verify-evidence.sh returned status "ok" on the review-council-debug mock.

=== SUMMARY ===
Total findings: 1
Verified: 1
Corrected (evidence): 0
Corrected (validator): 0
Severity downgrades: 0
Stripped: 0
Retracted (validator): 0
Duplicates consolidated: 0

Per agent:
  divisor-test-code: 1 finding, 1 verified
VERIFYEOF

output=$(${SCRIPTS_DIR}/rc-render-report.sh "${mock_session}" 2>&1)
echo "$output"
rm -rf "${mock_session}"
```

This block deletes the mock. Re-running Step 3 or Step 4 after it means
rebuilding the mock from Step 2.

Validate markdown output:
- Valid markdown (no unescaped characters, proper heading hierarchy)?
- 4a: does the refusal name *which* of the three verification checks
  failed, and does it give the path the file is expected at?
- 4b: expected sections present (Council Verdict, Session Information,
  Discovery Summary, Verification Summary, Per-Agent Verdicts, and
  Findings by Severity, which renders only because Step 3 left one
  verified finding in `verdicts/findings.json`)?
- Report gracefully handles missing data? The mock supplies no
  `verdict.txt` and no models file, so Council Verdict and Models used
  should render as explicit "not recorded" prose, not as blanks or raw
  variable names.
- Field values properly quoted/escaped?
- LLM reading this knows review outcome?

### Step 5: Evaluate Script Output Quality

For each script output, assess:

**JSON Validity**
- JSON parseable by `jq`?
- All strings properly quoted?
- Arrays and objects well-formed?

**Message Clarity**

Not every payload carries `message`. `rc-extract-verdict.sh` emits
`{status, valid, invalid, remediation}` on `extract_error` -- there is
no `message` field, and the guidance lives in `remediation` plus the
per-agent `reason` inside `invalid`. Judge that payload on those fields;
a missing `message` there is the script's shape, not a defect.
`rc-render-report.sh` emits markdown, not JSON, so this whole section is
scored on its prose instead.

- `message` (or `remediation`, where that is the carrier) tells LLM what
  to do next?
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
- **Empty changeset (--mode specs, terminal)**: Run `rc-prepare.sh --mode specs` on repo with no spec directories. Expect `status: "empty"`. Verify `message` names the directories and extensions that were searched, and that no scope retry can help — the orchestrator must either point the review at the real layout (`--scope paths <dir>`, `REVIEW_COUNCIL_SPEC_DIRS` / `REVIEW_COUNCIL_SPEC_EXTS`) or ask the user what to review.
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
