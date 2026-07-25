# Phase: Verification — LLM Judgment Reference

Guides orchestrator interpretation of evidence-check results, correction rounds, severity calibration, and validation gate execution.

**THIS PHASE IS MANDATORY.** Do not skip any step. Verification phase producing no tool calls is rubber stamp, not verification.

> **Step mapping to SKILL.md**: These steps (1-6) are executed within SKILL.md Step 4 (VERIFICATION).

---

## Interpreting Evidence Check Results

Mechanical evidence checking performed by `rc-verify-evidence.sh`. Script
reads each agent's `verdicts/{agent}.json` (written by `rc-extract-verdict.sh`
— see "Step 0 — Format Gate" below) and writes the canonical
`${session_dir}/verdicts/findings.json` containing:

```json
{
  "verified": [
    {
      "severity": "HIGH",
      "file": "auth/token.go",
      "line": 42,
      "evidence": "if exp < now",
      "description": "...",
      "recommendation": "...",
      "agent": "divisor-adversary-code",
      "verdict": "REQUEST CHANGES",
      "status": "verified",
      "provenance": {}
    }
  ],
  "correctable": [
    {
      "severity": "MEDIUM",
      "file": "internal/config.go",
      "line": 10,
      "evidence": "os.Getenv(\"SECRET\")",
      "description": "...",
      "recommendation": "...",
      "agent": "divisor-guard-code",
      "verdict": "REQUEST CHANGES",
      "status": "correctable",
      "reason": "EVIDENCE_NOT_FOUND",
      "provenance": {}
    }
  ],
  "stripped": [
    {
      "severity": "LOW",
      "file": "does/not/exist.go",
      "line": null,
      "evidence": "...",
      "description": "...",
      "recommendation": "...",
      "agent": "divisor-testing-code",
      "verdict": "APPROVE",
      "status": "stripped",
      "reason": "FILE_NOT_FOUND",
      "provenance": {}
    }
  ],
  "total_findings": 3,
  "duplicates_consolidated": 0,
  "verdicts": {
    "divisor-adversary-code": "REQUEST CHANGES",
    "divisor-guard-code": "REQUEST CHANGES",
    "divisor-testing-code": "APPROVE"
  }
}
```

**Fields**:
- `verified`: passed all mechanical checks (file exists, evidence found in
  file, line number accurate within ±5)
- `correctable`: file exists but evidence quote not found, or line number
  outside ±5 — candidate for correction round. `reason` is
  `EVIDENCE_NOT_FOUND` or `LINE_MISMATCH`.
- `stripped`: file does not exist — permanently removed. `reason` is
  `FILE_NOT_FOUND`.
- Every finding carries `severity`/`file`/`line`/`evidence`/`description`/
  `recommendation` from the reviewer's original JSON, plus `agent` and
  `verdict` (that agent's overall verdict, copied verbatim) added during
  merge, and a `provenance` object — empty at this stage, filled in by
  correction/calibration/deduplication/validation (Steps 1-4 below).
- `total_findings`: count before mechanical verification (verified +
  correctable + stripped).
- `duplicates_consolidated`: count of duplicate findings merged away —
  exact duplicates removed by `rc-verify-evidence.sh` (same file, evidence,
  and line within ±5) plus semantic cross-agent duplicates merged by Step 3c.
- `consolidation_records`: one record per semantic cluster
  (`{primary, merged}`), added by Step 3c for the report renderer. Absent
  when no semantic consolidation occurred.
- `verdicts`: the per-agent verdict map, copied verbatim from each agent's
  JSON — never re-derived from finding counts. Source of truth for the
  report's per-agent verdict table (see Step 6 — Verdict Upgrade Logic).

---

## Step 0 — Format Gate (fail-loud parsing)

Before evidence verification runs, `scripts/rc-extract-verdict.sh` extracts and
schema-validates each agent's fenced ```json block into `verdicts/{agent}.json`.
It short-circuits with:

```json
{ "status": "extract_error", "valid": 3,
  "invalid": [ { "agent": "...", "reason": "NO_JSON_BLOCK" | "SCHEMA_INVALID",
  "detail": "...", "path": "verdicts/auth/divisor-adversary-code.raw.md" } ], "remediation": "..." }
```

`path` is the raw file's location relative to the session directory. In deep
mode it disambiguates which subsystem's instance of an agent failed, since
the same `agent` name can appear more than once in `invalid[]`.

An entry in `invalid` is a **silent drop** — a real finding that would vanish
from the review. Do NOT proceed to Step 1 while any agent's `verdicts/{agent}.json`
is missing because of an unresolved `extract_error`.

The one-round re-dispatch (remediation text plus, when present, that agent's
`invalid[].detail` — set for `SCHEMA_INVALID`, absent for `NO_JSON_BLOCK` —
then re-run the extractor) happens in the Delegation phase — see
`phases/delegate.md` — "Verdict Collection". By the time this phase starts,
that round has already run. Your job here is to interpret its outcome:

- Every agent now shows `status: "ok"` (a clean reviewer with no findings is
  still `ok` with an empty `findings` array): proceed to Step 1 using the
  validated `verdicts/{agent}.json` files.
- An agent still fails after the one re-dispatch attempt: proceed with whatever
  now validates, but **log each still-invalid agent loudly** in `verification.txt`
  and surface it in the report — never let a dropped finding pass silently as a
  clean zero.
- `status: "nothing_to_do"` means the whole session produced zero verdict
  blocks (e.g., no `.raw.md` files exist at all) — a delegation failure, NOT
  a per-agent "no findings" signal. Treat it as the "all agents fail" case in
  `phases/delegate.md` — "Verdict Collection": stop and report a
  configuration issue.

---

## Step 1 — Correction Round

**Effort gate:** If effort is `quick`, skip this step entirely.

For **correctable** findings (file exists but evidence quote wrong), give originating agent ONE chance to fix.

Send agent focused correction prompt:

> Your finding "{finding title}" cited file `{file path}` but the evidence quote was not found in that file. Please re-read the file and either:
>
> 1. Provide the correct evidence quote that supports this finding, OR
> 2. Withdraw the finding if it was based on incorrect assumptions about the file's contents.

**Correction round rules**:

- ONE correction attempt per finding. No further rounds.
- Agent provides corrected evidence found in file: upgraded to **verified**.
- Agent withdraws finding: removed (not stripped — withdrawn by agent).
- Agent provides evidence still not matching: **stripped**.
- Agent does not respond or times out: **stripped**.

**Efficiency**: batch all correctable findings for same agent into single correction prompt. Do not dispatch separate rounds per finding.

**When to skip**: zero correctable findings, or ALL of agent's findings correctable (systemic failure — strip all, do not waste correction round).

---

## Step 2 — Severity Calibration

**Effort gate:** If effort is `quick`, skip this step entirely.

For each **verified** finding (verified mechanically or upgraded during correction round), compare assigned severity against severity pack boundary definitions:

a. Read severity pack definition for assigned level. Compare finding description against stated boundary.

b. Apply calibration rules:

- **CRITICAL assigned, but harm is theoretical** (requires unlikely conditions, compromised upstream, or hypothetical attack vector): downgrade to **HIGH**.
- **HIGH assigned, but risk requires unlikely conditions** (compromised upstream, specific attacker capability, or misconfiguration not present in current code): downgrade to **MEDIUM**.
- **CRITICAL/HIGH assigned to style, documentation, or convention issue**: downgrade to level matching severity pack examples for that persona and issue type.
- **CRITICAL/HIGH assigned to standard language semantics** (e.g., Go nil-pointer panics, Python AttributeError on None, JS TypeError on undefined): downgrade to MEDIUM or strip. Expected runtime behaviors, not defects.
- **HIGH assigned to test coverage preferences** (table-driven tests, additional edge cases, assertion depth) when comprehensive test suite already exists: downgrade to MEDIUM or LOW.

c. Apply each downgrade by editing `findings.json`: set the finding's `severity` to
   the new level and append `{from, to, reason}` to its `provenance.calibrated_from`.
   Never write calibration notes into a finding's prose fields or as HTML comments —
   provenance is structured data only.

d. Log each downgrade in `verification.txt` (Step 5 — SEVERITY CALIBRATION):
   > "Finding `{title}` severity downgraded {from} → {to} — {reason}"

e. Downgrades do NOT strip findings. Finding remains verified at lower severity. Downgrade may change agent verdict if remaining findings no longer meet REQUEST CHANGES threshold.

---

## Step 3 — Strip Unverified Findings

After correction round, remove all findings remaining unverified:

- Log each stripped finding:
  > "Finding `{title}` from `{agent}` stripped — {reason: file does not exist | evidence not found in file | correction failed}"

- If stripping leaves agent with zero remaining findings but REQUEST CHANGES verdict, upgrade to APPROVE and note:
  > "Agent `{name}` verdict changed to APPROVE — all findings were unverified."

---

## Step 3b — Merge-Base Advisories

When a finding is stripped because it describes divergence
between branch and *current* base branch — not a defect the
branch introduced — convert to **merge-base advisory**
instead of discarding.

Merge-base advisories:
- Appear in report under separate "Merge Advisories" heading
- Do NOT count toward finding total
- Do NOT affect agent verdicts or council verdict
- Informational guidance for maintainer

**Detection**: qualifies when ALL true:

1. Stripped because content was never on the branch (added
   to base branch after merge-base)
2. Merging branch into current base would remove or conflict
   with that content
3. Removal has operational consequences (lost changelog
   entries, overwritten docs, reverted config)

**Do not convert** when:
- Stripped for fabricated evidence
- Stripped because file doesn't exist
- Divergence has no operational consequence

Log each conversion:
> "Finding `{title}` converted to merge-base advisory
> — {reason}"

---

## Step 3c — Cross-Agent Consolidation

Different personas often flag the **same underlying defect** from different
angles (e.g. a bare `except` as a security swallow, an untested failure path,
and an observability gap). Exact dedup in `rc-verify-evidence.sh` does not
catch these — the descriptions differ. Consolidate them so one defect counts
once while every angle is preserved.

**Token guard — skip this step entirely (no model reasoning, do not write a
manifest) when EITHER holds:**
- fewer than 2 findings in `verified`, or
- no two `verified` findings share the same `file`.

Otherwise:

1. Read `verdicts/findings.json`. Consider only pairs of `verified` findings
   that share a `file` and whose `line` values are within ±10 of each other.
2. Among those candidates, judge which describe the **same root defect**. Two
   findings that touch the same line but describe genuinely different problems
   (e.g. a nil-deref and a naming issue) are NOT the same defect — do not
   cluster them.
3. Write `verdicts/clusters.json` — a members-only manifest conforming to
   `references/consolidation-schema.json`. Each cluster lists 2+ members by
   `{file, line, agent}`:

   ```json
   {"clusters":[{"members":[
     {"file":"svc/load.py","line":42,"agent":"divisor-adversary-code"},
     {"file":"svc/load.py","line":42,"agent":"divisor-testing-code"}
   ]}]}
   ```

   Do NOT designate a primary — the script picks it deterministically
   (highest severity; the strongest verdict in the cluster is preserved).
4. Run `scripts/rc-consolidate.sh ${session_dir}`. It rewrites
   `findings.json`: the primary survives with each secondary's angle and
   recommendation folded into `provenance.consolidated_from`, secondaries are
   removed, and `duplicates_consolidated` / `consolidation_records` are
   updated. It is a safe no-op if `clusters.json` is absent or empty.

Log the outcome in `verification.txt`:
> "Cross-agent consolidation: {N} duplicate finding(s) merged into {M} cluster(s)."

---

## Step 4 — Validation Gate

**Effort gate:** If effort is `quick`, skip this step entirely.

**Deep mode behavior:** If effort is `deep`, run Steps 1-3 separately
for each subsystem's verdicts (iterate subdirectories in
`${session_dir}/verdicts/`). Then run this validation gate once over
aggregated findings from all subsystems. Include subsystem map from
`${session_dir}/subsystems.json` as additional context in validator
prompt — append:

> ## Subsystem Map
>
> This review was decomposed into subsystems. The finding you are
> validating came from the **{subsystem name}** subsystem. Consider
> whether cross-subsystem interactions affect the finding's validity.
>
> {JSON contents of subsystems.json}

After deduplication, dispatch fresh-context sub-agent for independent validation. Agent has NOT participated in any prior review phase — sees only surviving findings with access to source files.

### Agent Profile

The validation agent operates read-only with restricted shell access:
may read files and run search commands (`grep`, `find`, `wc`, `head`,
`tail`). Must not write, edit, or delete files. Must not fetch external
resources. Temperature should be set to minimum (most deterministic)
if the hosting tool supports it.

Validator does NOT receive:
- Diff or patch
- Delegation prompts
- Raw agent verdicts
- Correction round history

### Validator Prompt

Validator performs checks mechanical verification cannot: identifier grounding, logical soundness, holistic judgment. Does NOT re-check file existence or evidence quotes — already verified mechanically.

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

Validator outcomes are recorded in each finding's `provenance.validator` object
(`{result, reason}`) and any corrected fields are updated in place in
`findings.json`. Do not inject validator commentary into prose fields.

- **CONFIRMED**: finding passes to report unchanged.
- **CORRECTED**: apply validator corrections to finding. Log what changed:
  > "Finding `{title}` corrected by validator — {description of change}"
- **RETRACTED**: strip finding. Log retraction with validator reasoning:
  > "Finding `{title}` retracted by validator — {reason}"

If validator retracts ALL findings from agent whose verdict was REQUEST CHANGES, upgrade verdict to APPROVE (same logic as Step 3).

Record retracted findings as false positive patterns in learnings (same as stripped-findings logic in report phase).

### Cross-Checking Validator Retractions

For each RETRACTED finding, verify validator claim before applying:

- Validator must have quoted evidence or shown grep output supporting retraction. If retraction contains no supporting evidence (just assertion like "I checked and it's not there"), disregard retraction and keep finding as verified. Log as validator error.
- If validator retracts finding upgraded to verified during correction round (Step 1), agent's corrected evidence was also fabricated. Log as **correction failure pattern** in learnings — agent doubled down on false claim. Record both original and corrected evidence as false positives.

### When to Skip

Skip validation gate if:
- Zero findings survived to this point (nothing to validate).
- All surviving findings LOW severity (validation cost exceeds value).

---

## Step 5 — Write Verification Summary

Write combined verification, correction, and validation results to `${session_dir}/verdicts/verification.txt`.

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

Update `${session_dir}/tracking.md` Phase: Verification with fields: findings total, verified, corrected, stripped, severity downgrades, duplicates consolidated, validator confirmed/corrected/retracted, final verdict.

---

## Step 6 — Verdict Upgrade Logic

Per-agent verdicts come from `findings.json` `.verdicts` (verbatim from each
agent's JSON — never re-derive them from finding counts). If stripping or
validator retraction leaves an agent with zero verified findings and that
agent's entry in `.verdicts` was `REQUEST CHANGES`, set that entry to
`APPROVE` and log the change.

If stripping leaves agent with zero findings, upgrade to APPROVE.

If all verified verdicts **APPROVE** after stripping and deduplication, verification phase returns APPROVE. Include stripped findings and deduplication notes as warnings in output.

If any verified verdict remains **REQUEST CHANGES**, return REQUEST CHANGES with verified findings.

### Verdict Coherence Rule

If all agent verdicts APPROVE after verification and no remaining finding exceeds MEDIUM severity, final council verdict MUST be APPROVE. Coordinator cannot override unanimous agent consensus without citing specific HIGH or CRITICAL finding that survived verification pipeline. This rule is mechanical — not subject to coordinator judgment.
