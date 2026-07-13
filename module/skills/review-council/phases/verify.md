# Phase: Verification — LLM Judgment Reference

This file guides the orchestrator's interpretation of evidence-check results, correction rounds, severity calibration, and validation gate execution.

**THIS PHASE IS MANDATORY.** Do not skip any step. A verification phase that produces no tool calls is not a verification phase; it is a rubber stamp.

> **Step mapping to SKILL.md**: These steps (1-6) are executed within SKILL.md Step 4 (VERIFICATION).

---

## Interpreting Evidence Check Results

The mechanical evidence checking is performed by `rc-verify-evidence.sh`. The script produces `${session_dir}/evidence-check.json` containing:

```json
{
  "verified": [
    {
      "agent": "divisor-adversary-code",
      "title": "...",
      "file": "...",
      "evidence": "...",
      "result": "verified"
    }
  ],
  "correctable": [
    {
      "agent": "divisor-guard-code",
      "title": "...",
      "file": "...",
      "evidence": "...",
      "result": "EVIDENCE_NOT_FOUND",
      "reason": "Evidence quote not found in file"
    }
  ],
  "stripped": [
    {
      "agent": "divisor-testing-code",
      "title": "...",
      "file": "...",
      "evidence": "...",
      "result": "file_not_found",
      "reason": "File does not exist"
    }
  ],
  "duplicates_consolidated": [
    {
      "kept_finding": "...",
      "kept_agent": "...",
      "merged_from": ["divisor-adversary-code", "divisor-sre-code"]
    }
  ]
}
```

**Fields**:
- `verified`: findings that passed all mechanical checks (file exists, evidence found in file, line number accurate within ±5)
- `correctable`: findings where the file exists but the evidence quote was not found — candidate for correction round
- `stripped`: findings where the file does not exist or absence claims were disproven by grep — permanently removed
- `duplicates_consolidated`: findings merged from multiple agents (same file ±5 lines, same issue)

---

## Step 1 — Correction Round

**Effort gate:** If effort is `quick`, skip this step entirely.

For findings classified as **correctable** (file exists but evidence quote is wrong), give the originating agent ONE chance to fix it.

Send the agent a focused correction prompt:

> Your finding "{finding title}" cited file `{file path}` but the evidence quote was not found in that file. Please re-read the file and either:
>
> 1. Provide the correct evidence quote that supports this finding, OR
> 2. Withdraw the finding if it was based on incorrect assumptions about the file's contents.

**Rules for the correction round**:

- Only ONE correction attempt per finding. No further rounds.
- If the agent provides corrected evidence that IS found in the file, the finding is upgraded to **verified**.
- If the agent withdraws the finding, it is removed (not stripped — withdrawn by the agent).
- If the agent provides evidence that still does not match, the finding is **stripped**.
- If the agent does not respond or times out, the finding is **stripped**.

**Efficiency**: batch all correctable findings for the same agent into a single correction prompt. Do not dispatch separate correction rounds per finding.

**When to skip the correction round**: If the number of correctable findings is zero, or if ALL of an agent's findings are correctable (suggests systemic failure — strip all, do not waste a correction round).

---

## Step 2 — Severity Calibration

**Effort gate:** If effort is `quick`, skip this step entirely.

For each finding that is now classified as **verified** (either verified in the mechanical check or upgraded to verified during the correction round), compare the assigned severity against the severity pack boundary definitions:

a. Read the severity pack definition for the finding's assigned level. Compare the finding's description against the stated boundary.

b. Apply these calibration rules:

- **CRITICAL assigned, but harm is theoretical** (requires unlikely conditions, compromised upstream, or hypothetical attack vector): downgrade to **HIGH**.
- **HIGH assigned, but risk requires unlikely conditions** (compromised upstream, specific attacker capability, or misconfiguration not present in the current code): downgrade to **MEDIUM**.
- **CRITICAL/HIGH assigned to a style, documentation, or convention issue**: downgrade to the level matching the severity pack's examples for that persona and issue type.
- **CRITICAL/HIGH assigned to standard language semantics** (e.g., Go nil-pointer panics, Python AttributeError on None, JS TypeError on undefined): downgrade to MEDIUM or strip. These are expected runtime behaviors, not defects.
- **HIGH assigned to test coverage preferences** (table-driven tests, additional edge cases, assertion depth) when a comprehensive test suite already exists: downgrade to MEDIUM or LOW.

c. Log each downgrade:
   > "Finding `{title}` severity downgraded {from} → {to} — {reason}"

d. Downgrades do NOT strip findings. The finding remains verified at the lower severity. A downgrade may change an agent's verdict if the remaining findings no longer meet the REQUEST CHANGES threshold.

---

## Step 3 — Strip Unverified Findings

After the correction round, remove all findings that remain unverified:

- Log each stripped finding:
  > "Finding `{title}` from `{agent}` stripped — {reason: file does not exist | evidence not found in file | correction failed}"

- If stripping leaves an agent with zero remaining findings but a REQUEST CHANGES verdict, upgrade to APPROVE and note:
  > "Agent `{name}` verdict changed to APPROVE — all findings were unverified."

---

## Step 4 — Validation Gate

**Effort gate:** If effort is `quick`, skip this step entirely.

**Deep mode behavior:** If effort is `deep`, run Steps 1-3 separately
for each subsystem's verdicts (iterate subdirectories in
`${session_dir}/verdicts/`). Then run this validation gate once over
the aggregated findings from all subsystems. Include the subsystem
map from `${session_dir}/subsystems.json` as additional context in
the validator prompt — append:

> ## Subsystem Map
>
> This review was decomposed into subsystems. The finding you are
> validating came from the **{subsystem name}** subsystem. Consider
> whether cross-subsystem interactions affect the finding's validity.
>
> {JSON contents of subsystems.json}

After deduplication, dispatch a fresh-context sub-agent to perform independent validation. This agent has NOT participated in any prior phase of the review — it sees only the surviving findings and has access to the source files.

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

The validator performs checks that the mechanical verification steps cannot: identifier grounding, logical soundness, and holistic judgment. It does NOT re-check file existence or evidence quotes — those were already verified mechanically.

> You are an independent validator. You have not participated in the review that produced these findings. Each finding has already passed mechanical checks (file exists, evidence quote found in file). Your job is to verify what mechanical checks cannot.
>
> For each finding:
>
> 1. **Identifier verification**: Are all identifiers mentioned in the description and recommendation (variable names, function names, file names, target names) real? `grep` for each one. If an identifier does not exist in the codebase, the finding may be based on a hallucinated name.
> 2. **Logical soundness**: Does the evidence actually support the conclusion in the description? Read the surrounding context in the file — does the finding still hold when you see the full picture, not just the quoted excerpt?
> 3. **Severity appropriateness**: Does the assigned severity match the definitions below? Apply the boundary test: CRITICAL = immediate concrete harm, HIGH = likely near-term problems.
>
> {Insert severity pack definitions here}
>
> **Evidence discipline**: For every claim you make, quote what you read or show the grep output that supports it. Do not assert "I checked and it's fine" without showing your work.
>
> **Common false positive patterns — retract these:**
> - Standard language behavior flagged as a security defect: Go nil-pointer panics, Python `AttributeError` on `None`, JavaScript/TypeScript `TypeError` on `undefined`, Rust `unwrap()` on `Option::None` in test code.
> - Test coverage style preferences (table-driven tests, additional assertion depth, edge case expansion) flagged as HIGH when a comprehensive test suite already exists and all methods are exercised.
> - Idiomatic language patterns treated as defects: Go's `map[K]struct{}` for sets, short receiver names, error-return conventions; Python list comprehensions, `__dunder__` methods; TypeScript discriminated unions, type guards.
> - Optional improvements (documentation examples, benchmark tests, additional docs) elevated above LOW.
> - Framework-specific patterns flagged without checking the framework version: React class components in pre-hooks codebases, Express middleware patterns, Django class-based views.
>
> For each finding, return one of:
>
> - **CONFIRMED** — finding is accurate as stated. State briefly what you verified.
> - **CORRECTED** — finding is real but details are wrong. Provide corrections: fixed identifier, adjusted severity, or clarified description. Quote the evidence that supports the correction.
> - **RETRACTED** — finding is not supported by the source code. Quote what you read or show the grep output that contradicts the finding.

### Processing Validator Output

- **CONFIRMED**: finding passes to the report unchanged.
- **CORRECTED**: apply the validator's corrections to the finding. Log what changed:
  > "Finding `{title}` corrected by validator — {description of change}"
- **RETRACTED**: strip the finding. Log the retraction with the validator's reasoning:
  > "Finding `{title}` retracted by validator — {reason}"

If the validator retracts ALL findings from an agent whose verdict was REQUEST CHANGES, upgrade that agent's verdict to APPROVE (same logic as Step 3).

Record retracted findings as false positive patterns in learnings (same as existing stripped-findings logic in the report phase).

### Cross-Checking Validator Retractions

For each RETRACTED finding, verify the validator's claim before applying it:

- The validator must have quoted evidence or shown grep output supporting the retraction. If the retraction contains no supporting evidence (just an assertion like "I checked and it's not there"), disregard the retraction and keep the finding as verified. Log as a validator error.
- If the validator retracts a finding that was upgraded to verified during the correction round (Step 1), this indicates the agent's corrected evidence was also fabricated. Log as a **correction failure pattern** in learnings — the agent doubled down on a false claim. Record both the original and corrected evidence as false positives.

### When to Skip

Skip the validation gate if:
- Zero findings survived to this point (nothing to validate).
- All surviving findings are LOW severity (cost of validation exceeds value).

---

## Step 5 — Write Verification Summary

Write the combined verification, correction, and validation results to `${session_dir}/verdicts/verification.txt`.

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

Update `${session_dir}/tracking.md` Phase: Verification with these fields: findings total, verified, corrected, stripped, severity downgrades, duplicates consolidated, validator confirmed/corrected/retracted, final verdict.

---

## Step 6 — Verdict Upgrade Logic

If stripping leaves an agent with zero findings, upgrade to APPROVE.

If all verified verdicts are **APPROVE** after stripping and deduplication, the verification phase returns APPROVE. Include stripped findings and deduplication notes as warnings in the output.

If any verified verdict remains **REQUEST CHANGES**, return REQUEST CHANGES with the verified findings.

### Verdict Coherence Rule

If all individual agent verdicts are APPROVE after verification and no remaining finding exceeds MEDIUM severity, the final council verdict MUST be APPROVE. The coordinator cannot override unanimous agent consensus without citing a specific HIGH or CRITICAL finding that survived the verification pipeline. This rule is mechanical — it is not subject to coordinator judgment.
