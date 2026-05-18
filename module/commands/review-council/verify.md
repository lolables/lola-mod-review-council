# Phase: Verification

Check attestation, verify evidence, correct fixable
errors, calibrate severity, deduplicate, then
validate findings independently.

## Inputs

- `${session_dir}/verdicts/{agent-name}.md` — raw verdicts
- `${session_dir}/changeset.txt` — authoritative file list

## Outputs

Write to `${session_dir}`:
- `verdicts/verification.txt` — full verification log

Update `${session_dir}/tracking.md` Phase: Verification
with: findings total, verified, corrected, stripped,
severity downgrades, duplicates consolidated,
validator confirmed/corrected/retracted, final verdict.

---

## Step 1 — Attestation Check

Each agent's output must begin with a `Files read:`
line listing every file it opened (see
reviewer-protocol.md Output Format). Cross-check
this list against the changeset:

- If an agent's attestation omits changeset files,
  note which files were skipped — findings about
  those files carry no weight.
- If an agent lists files NOT in the changeset, flag
  as a warning (supporting context files are
  acceptable, but findings about out-of-scope files
  are not).
- If an agent provides no attestation at all, flag
  the entire response as low-confidence.

---

## Step 2 — Evidence Verification

For each finding from each agent:

a. **Check file existence**: Does the `**File**:`
   reference point to a file that exists in the
   working tree?

b. **Check evidence quote**: Does the `**Evidence**:`
   text appear in the cited file? Allow minor
   whitespace differences — the quote should be
   recognizable in the file content.

c. **Classify verification failures**:

   | File exists? | Evidence matches? | Classification |
   |-------------|-------------------|----------------|
   | Yes | Yes | **Verified** — finding is grounded |
   | Yes | No | **Correctable** — file exists but quote is wrong |
   | No | N/A | **Fabricated** — permanently strip |

d. **Line-number accuracy**: If the finding's
   `**File**:` field includes a line number
   (e.g., `path/to/file:42`), check that the
   evidence quote appears within ±5 lines of the
   cited line in the actual file.

   - If the quote is found in the file but NOT
     within ±5 lines of the cited line, classify
     as **correctable** (evidence is real but
     location is wrong).
   - If the quote is found within ±5 lines,
     the line reference is **verified**.
   - Findings without a line number in the File
     field skip this check.
   - The ±5 window is bounded by the file: for
     line N, check lines max(1, N-5) to
     min(file_length, N+5).

e. **Absence-claim verification**: If the finding
   claims something is missing, absent, or not
   referenced (e.g., "not linked from any doc,"
   "no test for X," "missing input validation"),
   run `grep -rn` for the claimed-missing term
   across the repository.

   - If grep finds the term: classify the finding
     as **fabricated** — the thing the agent
     claimed was absent actually exists.
   - If grep confirms absence: classify as
     **verified** — the absence claim is
     grounded.
   - Use the most specific search term possible.
     For file references, search for the filename.
     For identifiers, search for the exact name.
   - **Evaluating grep matches**: If grep finds the
     term, read the matching lines to determine if
     they represent actual implementation or just
     references. A comment saying "TODO: add X" is
     not an implementation of X. A filename
     containing the term is not necessarily the
     thing the agent claimed was missing. If all
     matches are non-substantive (comments, TODOs,
     docs, string literals in unrelated context),
     classify the absence claim as **verified** —
     the substantive thing is truly absent.

---

## Step 3 — Correction Round

For findings classified as **correctable** (file
exists but evidence quote is wrong), give the
originating agent ONE chance to fix it.

Send the agent a focused correction prompt:

> Your finding "{finding title}" cited file
> `{file path}` but the evidence quote was not found
> in that file. Please re-read the file and either:
>
> 1. Provide the correct evidence quote that supports
>    this finding, OR
> 2. Withdraw the finding if it was based on incorrect
>    assumptions about the file's contents.

**Rules for the correction round**:

- Only ONE correction attempt per finding. No further
  rounds.
- If the agent provides corrected evidence that IS
  found in the file, the finding is upgraded to
  **verified**.
- If the agent withdraws the finding, it is removed
  (not stripped — withdrawn by the agent).
- If the agent provides evidence that still does not
  match, the finding is **stripped**.
- If the agent does not respond or times out, the
  finding is **stripped**.

**Efficiency**: batch all correctable findings for the
same agent into a single correction prompt. Do not
dispatch separate correction rounds per finding.

**When to skip the correction round**: If the number
of correctable findings is zero, or if ALL of an
agent's findings are correctable (suggests systemic
failure — strip all, do not waste a correction round).

---

## Step 3.5 — Severity Calibration

For each finding that is now classified as
**verified** (either verified in Step 2 or upgraded
to verified during the correction round), compare
the assigned severity against the severity pack
boundary definitions:

a. Read the severity pack definition for the
   finding's assigned level. Compare the finding's
   description against the stated boundary.

b. Apply these calibration rules:

   - **CRITICAL assigned, but harm is theoretical**
     (requires unlikely conditions, compromised
     upstream, or hypothetical attack vector):
     downgrade to **HIGH**.
   - **HIGH assigned, but risk requires unlikely
     conditions** (compromised upstream, specific
     attacker capability, or misconfiguration not
     present in the current code): downgrade to
     **MEDIUM**.
   - **CRITICAL/HIGH assigned to a style,
     documentation, or convention issue**: downgrade
     to the level matching the severity pack's
     examples for that persona and issue type.

c. Log each downgrade:
   > "Finding `{title}` severity downgraded
   > {from} → {to} — {reason}"

d. Downgrades do NOT strip findings. The finding
   remains verified at the lower severity. A
   downgrade may change an agent's verdict if the
   remaining findings no longer meet the REQUEST
   CHANGES threshold.

---

## Step 4 — Strip Unverified Findings

After the correction round, remove all findings that
remain unverified:

- Log each stripped finding:
  > "Finding `{title}` from `{agent}` stripped —
  > {reason: file does not exist | evidence not found
  > in file | correction failed}"

- If stripping leaves an agent with zero remaining
  findings but a REQUEST CHANGES verdict, upgrade
  to APPROVE and note:
  > "Agent `{name}` verdict changed to APPROVE —
  > all findings were unverified."

---

## Step 5 — Cross-Agent Deduplication

Scan the surviving verified findings from all agents
for duplicates:

- Two findings are duplicates if they reference the
  **same file** (within 5 lines) AND describe the
  **same issue** (same root cause, even if worded
  differently).
- Two findings are also duplicates if they describe
  the **same project-wide concern** — even if they
  reference different files or lines. Examples:
  the same dependency management pattern flagged in
  different manifests, the same documentation gap
  noted from different angles, the same configuration
  approach questioned in different files. The 5-line
  proximity rule does not apply to project-wide
  concerns.
- A concern is **project-wide** when it represents a
  single systemic pattern or policy violation that
  manifests in multiple locations. Two separate
  implementation gaps with the same root cause (e.g.,
  "Function A lacks error handling" and "Function B
  lacks error handling") are NOT project-wide — they
  are distinct findings that happen to share a
  pattern. When in doubt, do NOT merge. False
  deduplication hides distinct issues.
- When duplicates are found, keep the finding with
  the highest severity. Add a note listing which
  other agents also flagged it:
  > "Also flagged by: The Adversary, The Operator"
- Do NOT merge findings that address different aspects
  of the same file (e.g., a security issue and a
  performance issue on the same line).

---

## Step 5.5 — Validation Gate

After deduplication, dispatch a fresh-context
sub-agent to perform independent validation. This
agent has NOT participated in any prior phase of the
review — it sees only the surviving findings and has
access to the source files.

### Agent Profile

```yaml
mode: subagent
temperature: 0.0
tools:
  read: true
  bash: restricted   # grep, find, wc, head, tail only
  write: false
  edit: false
  webfetch: false
```

The validator does NOT receive:
- The diff or patch
- The delegation prompts
- The raw agent verdicts
- The correction round history

### Validator Prompt

The validator performs checks that the mechanical
verification steps (2-4) cannot: identifier
grounding, logical soundness, and holistic judgment.
It does NOT re-check file existence or evidence
quotes — those were already verified mechanically.

> You are an independent validator. You have not
> participated in the review that produced these
> findings. Each finding has already passed
> mechanical checks (file exists, evidence quote
> found in file). Your job is to verify what
> mechanical checks cannot.
>
> For each finding:
>
> 1. **Identifier verification**: Are all
>    identifiers mentioned in the description and
>    recommendation (variable names, function names,
>    file names, target names) real? `grep` for each
>    one. If an identifier does not exist in the
>    codebase, the finding may be based on a
>    hallucinated name.
> 2. **Logical soundness**: Does the evidence
>    actually support the conclusion in the
>    description? Read the surrounding context in
>    the file — does the finding still hold when
>    you see the full picture, not just the quoted
>    excerpt?
> 3. **Severity appropriateness**: Does the assigned
>    severity match the definitions below? Apply the
>    boundary test: CRITICAL = immediate concrete
>    harm, HIGH = likely near-term problems.
>
> {Insert severity pack definitions here}
>
> **Evidence discipline**: For every claim you make,
> quote what you read or show the grep output that
> supports it. Do not assert "I checked and it's
> fine" without showing your work.
>
> For each finding, return one of:
>
> - **CONFIRMED** — finding is accurate as stated.
>   State briefly what you verified.
> - **CORRECTED** — finding is real but details are
>   wrong. Provide corrections: fixed identifier,
>   adjusted severity, or clarified description.
>   Quote the evidence that supports the correction.
> - **RETRACTED** — finding is not supported by the
>   source code. Quote what you read or show the
>   grep output that contradicts the finding.

### Processing Validator Output

- **CONFIRMED**: finding passes to the report
  unchanged.
- **CORRECTED**: apply the validator's corrections
  to the finding. Log what changed:
  > "Finding `{title}` corrected by validator —
  > {description of change}"
- **RETRACTED**: strip the finding. Log the
  retraction with the validator's reasoning:
  > "Finding `{title}` retracted by validator —
  > {reason}"

If the validator retracts ALL findings from an
agent whose verdict was REQUEST CHANGES, upgrade
that agent's verdict to APPROVE (same logic as
Step 4).

Record retracted findings as false positive
patterns in learnings (same as existing
stripped-findings logic in the report phase).

### Cross-Checking Validator Retractions

For each RETRACTED finding, verify the validator's
claim before applying it:

- The validator must have quoted evidence or shown
  grep output supporting the retraction. If the
  retraction contains no supporting evidence
  (just an assertion like "I checked and it's not
  there"), disregard the retraction and keep the
  finding as verified. Log as a validator error.
- If the validator retracts a finding that was
  upgraded to verified during the correction round
  (Step 3), this indicates the agent's corrected
  evidence was also fabricated. Log as a
  **correction failure pattern** in learnings —
  the agent doubled down on a false claim. Record
  both the original and corrected evidence as
  false positives.

### When to Skip

Skip the validation gate if:
- Zero findings survived to this point (nothing
  to validate).
- All surviving findings are LOW severity (cost
  of validation exceeds value).

---

## Step 6 — Write Results

Write the combined verification, correction, and
deduplication results to
`${session_dir}/verdicts/verification.txt`.

Format:

```
=== ATTESTATION CHECK ===
{per-agent attestation results}

=== EVIDENCE VERIFICATION ===
{per-finding verification result}

=== CORRECTION ROUND ===
{correctable findings and their outcomes}

=== SEVERITY CALIBRATION ===
{downgraded findings with reasons}

=== STRIPPED FINDINGS ===
{list of stripped findings with reasons}

=== DEDUPLICATION ===
{consolidated findings}

=== VALIDATION GATE ===
{per-finding validator result: CONFIRMED/CORRECTED/RETRACTED}

=== SUMMARY ===
Total findings: {N}
Verified: {N}
Corrected (evidence): {N}
Corrected (validator): {N}
Severity downgrades: {N} ({original} → {adjusted}, ...)
Stripped: {N}
Retracted (validator): {N}
Duplicates consolidated: {N}

Per agent:
  {agent-name}: {verified}/{corrected}/{stripped}/{retracted}
  ...
```

## Decision

If all verified verdicts are **APPROVE** after
stripping and deduplication, the verification phase
returns APPROVE. Include stripped findings and
deduplication notes as warnings in the output.

If any verified verdict remains **REQUEST CHANGES**,
return REQUEST CHANGES with the verified findings.
