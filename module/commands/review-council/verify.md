# Phase: Verification

Check attestation, verify evidence, give agents one
correction round for fixable errors, then deduplicate.

## Inputs

- `${session_dir}/verdicts/{agent-name}.md` — raw verdicts
- `${session_dir}/changeset.txt` — authoritative file list

## Outputs

Write to `${session_dir}`:
- `verdicts/verification.txt` — full verification log

Update `${session_dir}/tracking.md` Phase: Verification
with: findings total, verified, corrected, stripped,
duplicates consolidated, final verdict.

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
- When duplicates are found, keep the finding with
  the highest severity. Add a note listing which
  other agents also flagged it:
  > "Also flagged by: The Adversary, The Operator"
- Do NOT merge findings that address different aspects
  of the same file (e.g., a security issue and a
  performance issue on the same line).

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

=== STRIPPED FINDINGS ===
{list of stripped findings with reasons}

=== DEDUPLICATION ===
{consolidated findings}

=== SUMMARY ===
Total findings: {N}
Verified: {N}
Corrected: {N}
Stripped: {N}
Duplicates consolidated: {N}
```

## Decision

If all verified verdicts are **APPROVE** after
stripping and deduplication, the verification phase
returns APPROVE. Include stripped findings and
deduplication notes as warnings in the output.

If any verified verdict remains **REQUEST CHANGES**,
return REQUEST CHANGES with the verified findings.
