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
- `verified`: passed all mechanical checks (file exists and resolves inside the
  review root, evidence occurs in the file as one contiguous block, and at
  least one occurrence starts within ±5 of the cited line)
- `correctable`: file exists but the evidence could not be confirmed at the
  cited location — candidate for correction round. `reason` is one of:
  - `EVIDENCE_NOT_FOUND` — the quoted block does not occur in the file.
    Evidence is matched as a contiguous byte sequence, so a multi-line quote
    must appear as written; a quote whose individual lines each appear
    somewhere in the file does not qualify.
  - `LINE_MISMATCH` — the block occurs, but no occurrence starts within ±5 of
    the cited line. A block that legitimately repeats verifies against a
    citation of any of its occurrences.
  - `EVIDENCE_EMPTY` — the finding carries no evidence quote, so there is
    nothing to verify against.
  - `EVIDENCE_SCAN_ERROR` — the file could not be scanned (unreadable, or the
    matcher itself failed). Reported rather than folded into
    `EVIDENCE_NOT_FOUND`, so a tooling fault never reads as a clean miss.
- `stripped`: permanently removed. `reason` is one of:
  - `FILE_NOT_FOUND` — the cited file does not exist.
  - `PATH_OUTSIDE_ROOT` — the cited path resolves outside the review root.
    The `file` field is reviewer-authored; a finding that escapes the
    changeset is discarded rather than corrected.
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
- `missing_verdicts`: agents that `session-manifest.json` records as dispatched
  but which produced no verdict file. Empty when the council is complete, and
  empty when the session carries no manifest — absence of the manifest claims
  nothing rather than accusing every agent at once.

**When `missing_verdicts` is non-empty, disclose it.** Record one line per
agent in `${session_dir}/verdicts/_meta/verification.txt` naming the agent and
stating that it returned no verdict, and carry the same statement into the
report narrative. A reviewer that was dispatched and returned nothing is a hole
in the council's coverage, and it is indistinguishable in the finished report
from a reviewer that simply found nothing — the per-agent verdict table is
built from the verdicts that arrived, so a silent agent has no row rather than
a visibly empty one. Never treat this as a reason to discard the verdicts that
did arrive, and never re-dispatch on its account: the dispatch budget belongs
to the format gate and the correction round.

**When `rc-verify-evidence.sh` returns `status: "nothing_to_do"`**, it never
reached the verification loop: the session directory is missing, `verdicts/`
is missing, no `divisor-*.json` verdict file was found, or the review root
does not resolve. All four sites return before `findings.json` is written, so
there is no findings file — and Steps 1-4 and Step 6 below do not run, because
there is nothing to correct, calibrate, consolidate, validate, or upgrade.

**Step 5 still runs, abbreviated.** `rc-render-report.sh` refuses to render
without `${session_dir}/verdicts/_meta/verification.txt` — the check is in the
script, not only in `phases/report.md`'s Pre-condition Gate, so it holds whether
or not the orchestrator consults that gate. It refuses unconditionally — there is no exemption for this status, because such
an exemption would rest on the orchestrator's own account of a status only it
observed. Write the file. It is also the only record of *why* the review
reported zero findings, and a zero-findings report is a claim a maintainer
acts on.

The abbreviated record carries the script's verbatim `message` and zeros:

```
=== EVIDENCE VERIFICATION ===
rc-verify-evidence.sh returned status "nothing_to_do": {verbatim message}
No verdict file reached the verification loop; no finding was checked.

=== SUMMARY ===
Total findings: 0
Verified: 0
Corrected (evidence): 0
Corrected (validator): 0
Severity downgrades: 0
Stripped: 0
Retracted (validator): 0
Duplicates consolidated: 0

Per agent:
  (none — no agent verdict JSON was verified)
```

That satisfies the gate's five checks honestly: the file exists and is
non-empty, it carries `=== SUMMARY ===`, its counts are real zeros rather than
`{N}` placeholders, and the EVIDENCE VERIFICATION section records a script that
actually ran. Do not pad it with the sections whose steps did not run — an
`=== VALIDATION GATE ===` heading over an empty body asserts a gate that never
opened, which is the fabrication the Pre-condition Gate exists to catch.

SKILL.md Step 4 renames any leftover `findings.json` to
`findings.json.stale` and then goes straight to the report, which renders zero
findings. The rename is what makes that true: `rc-render-report.sh` reads
`verdicts/findings.json` directly for both the findings list and the per-agent
verdict table, so a copy left behind by an earlier iteration would be rendered
as this run's result.

This is **not** the `nothing_to_do` in Step 0 below. That one comes from
`rc-extract-verdict.sh` and means the delegation produced no verdict blocks at
all. Same token, different script, different stage: check which script emitted
it before deciding what to do.

---

## Step 0 — Format Gate (fail-loud parsing)

Before evidence verification runs, `scripts/rc-extract-verdict.sh` extracts and
schema-validates each agent's fenced ```json block into `verdicts/{agent}.json`.
It short-circuits with:

```json
{ "status": "extract_error", "valid": 3,
  "invalid": [ { "agent": "...",
  "reason": "NO_JSON_BLOCK" | "SCHEMA_INVALID" | "VERDICT_INCOHERENT",
  "detail": "...", "path": "verdicts/auth/divisor-adversary-code.raw.md" } ], "remediation": "..." }
```

`path` is the raw file's location relative to the session directory. In deep
mode it disambiguates which subsystem's instance of an agent failed, since
the same `agent` name can appear more than once in `invalid[]`.

An entry in `invalid` is a **silent drop** — a real finding that would vanish
from the review. Do NOT proceed to Step 1 while any agent's `verdicts/{agent}.json`
is missing because of an unresolved `extract_error`.

`reason` classifies the failure. `SCHEMA_INVALID` means the block breaks
`verdict-schema.json`. `VERDICT_INCOHERENT` means it satisfies the schema but
declares `APPROVE` over a CRITICAL or HIGH finding — the schema constrains
`verdict` and `severity` independently, so `rc-extract-verdict.sh` enforces that
coupling itself. Do not conflate the two: validating a `VERDICT_INCOHERENT`
block against the schema by hand will show it passing.

The one-round re-dispatch (remediation text plus, when present, that agent's
`invalid[].detail` — set for `SCHEMA_INVALID` and `VERDICT_INCOHERENT`, absent
for `NO_JSON_BLOCK` — then re-run the extractor) happens in the Delegation
phase — see
`phases/delegate.md` — "Verdict Collection". By the time this phase starts,
that round has already run. Your job here is to interpret its outcome:

- Every agent now shows `status: "ok"` (a clean reviewer with no findings is
  still `ok` with an empty `findings` array): proceed to Step 1 using the
  validated `verdicts/{agent}.json` files.
- An agent still fails after the one re-dispatch attempt: proceed with whatever
  now validates, but **log each still-invalid agent loudly** in `verification.txt`
  and surface it in the report — never let a dropped finding pass silently as a
  clean zero.
- A `VERDICT_INCOHERENT` entry gets logged **even when the re-dispatch
  succeeds**, which no other reason requires. The agent picks its own remedy —
  raise the verdict to `REQUEST CHANGES`, or drop the finding / lower it to
  MEDIUM or LOW — and the re-dispatch overwrites `{agent}.raw.md`, so the second
  branch destroys the only record that a CRITICAL or HIGH was ever claimed. An
  unlogged gate firing is therefore a silent drop wearing a green verdict.
  Record one line per entry in `verification.txt`, next to the still-invalid
  agents above:
  > "Verdict gate: `{agent}` filed APPROVE over {severity} `{file}` —
  > after re-dispatch: {verdict raised to REQUEST CHANGES | severity lowered to
  > {level} | finding withdrawn}."
  Read the corrected block to fill the outcome; do not assume the agent took the
  branch you would have. A withdrawal that the agent does not justify is the
  silent drop this gate exists to expose — surface it in the report the same way
  a still-invalid agent is surfaced. You are not the only record of this:
  `rc-extract-verdict.sh` appends every firing to
  `${session_dir}/gate-firings.jsonl`, which Step 6 — Gate-Firing Disclosure
  reads back, so a firing you never saw — a resumed session, a compacted
  context — still reaches the report.
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
>
> The quote is matched as one contiguous block, byte for byte. Copy it straight
> out of the file: no `...` elisions joining two passages, no `path:12-18 —`
> location prefix, no reflowed whitespace — those two annotation habits are the
> most common cause of this failure, and a finding can be entirely correct and
> still land here. If the finding is that something is *missing*, quote the
> present code whose counterpart is absent and describe the search you ran in
> the description field; a search transcript in the evidence field can never
> match.

**Correction round rules**:

- ONE correction attempt per finding. No further rounds.
- Agent provides corrected evidence found in file: upgraded to **verified**.
- Agent withdraws finding: removed (not stripped — withdrawn by agent).
- Agent provides evidence still not matching: **stripped**.
- Agent does not respond or times out: **stripped**.

**Efficiency**: batch all correctable findings for same agent into single correction prompt. Do not dispatch separate rounds per finding.

**When to skip**: skip only when there are zero correctable findings. Do NOT
skip — and do NOT strip — merely because ALL of an agent's findings are
correctable. That pattern usually reflects one consistent citation *style* or
an evidence-matcher artifact (e.g. a quote the matcher could not locate for a
mechanical reason), not fabrication, and stripping wholesale silently deletes
an entire agent's review. Corrections are already batched into a single prompt
per agent (above), so the all-correctable case costs one message: run it and
let the correction-round rules decide each finding's fate.

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

**Effort gate:** If effort is `quick`, skip this step entirely.

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
3. Write `verdicts/_meta/clusters.json` — a members-only manifest conforming to
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

Write combined verification, correction, and validation results to `${session_dir}/verdicts/_meta/verification.txt`.

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

The upgrade above only ever moves a verdict toward APPROVE. The reverse
direction is mechanical too: **any agent still holding a verified HIGH or
CRITICAL finding after calibration, consolidation and validation is set to
REQUEST CHANGES**, whatever it declared. `rc-extract-verdict.sh` rejects an
APPROVE filed over a HIGH or CRITICAL finding at intake, but a validator
severity adjustment (Step 4 — CORRECTED) or a consolidation that folds a
cluster into a higher-severity primary (Step 3c) can raise a severity after
that gate, so intake alone does not settle it. Log each such change in
`verification.txt` (Step 5 — SEVERITY CALIBRATION) alongside the finding that
forced it.

If all verified verdicts **APPROVE** after stripping and deduplication, verification phase returns APPROVE. Include stripped findings and deduplication notes as warnings in output.

If any verified verdict remains **REQUEST CHANGES**, return REQUEST CHANGES with verified findings.

### Gate-Firing Disclosure

Read `${session_dir}/gate-firings.jsonl`. `rc-extract-verdict.sh` appends one
JSON object to it each time the coherence gate rejects a block:

```json
{"ts":"2026-08-03T09:14:02Z","agent":"divisor-guard-code",
 "path":"verdicts/divisor-guard-code.raw.md","verdict":"APPROVE",
 "findings":[{"severity":"CRITICAL","file":"auth/token.go","line":42,
              "description":"Expired tokens are accepted at the boundary."}]}
```

`findings` holds only the CRITICAL and HIGH entries that forced the rejection.
The file is appended to and never rewritten, and it sits outside `verdicts/`,
so the re-dispatch that overwrites `{agent}.raw.md` and `{agent}.json` cannot
reach it. That is the point: it is the only place an agent's original claim
survives a re-dispatch it answered by deleting that claim.

If the file is absent or empty, the gate never fired — do nothing further.

This does not duplicate Step 0's logging rule; it is what makes that rule hold
when the orchestrator did not watch the gate fire. A session resumed mid-run
(SKILL.md Step 2) has no record of the first extractor call, and neither does
a context that has since been compacted. Where both this step and Step 0
produce a line for the same firing, they are the same line — write it once.

**Collapse repeats first.** Records identical apart from `ts` describe one
claim, not several. Re-running the extractor re-evaluates every raw block —
including the ones no re-dispatch touched — so an iterated session accumulates
copies of a firing nothing new happened to. Group those into a single
disclosure line and carry the count: append `(filed {n} times)` when `n` is
greater than one.

Do not rewrite the log to achieve this. The append is deliberate: a second
firing can be a genuine second refusal, the first record is the only one that
carries what was originally claimed, and collapsing at the writer would lose
both. Collapse at the reader, where the timestamps are still there to tell the
two cases apart.

For each record, establish what became of the finding it names. Match on
`agent` plus `file` plus `description` across `findings.json`'s `verified`,
`correctable` and `stripped` arrays, and log one line per collapsed record in
`verification.txt` (Step 5 — SEVERITY CALIBRATION):

> "Verdict gate: `{agent}` filed APPROVE over {severity} `{file}` —
> after re-dispatch: {kept at {severity} | severity lowered to {level} |
> finding withdrawn}. Original claim: {description}."

**A firing is not by itself grounds to change a verdict.** The gate's own
remediation text invites the agent to drop a finding or lower it to MEDIUM/LOW
and keep APPROVE, so a later APPROVE can be an honest correction. Forcing
REQUEST CHANGES on every firing would reject those corrections and leave the
agent no remedy the gate accepts, which teaches the next orchestrator to route
around this step. The verdict is already settled by the REQUEST CHANGES
backstop above, which keys on the severity a finding actually holds after
calibration, consolidation and validation rather than on what it was once
claimed at. Disclosure is the entire job of this section.

Disclose every collapsed record, and disclose the withdrawal branch loudest.
Every distinct claim gets a line; repeats of one claim were already folded into
that line, with their count, by the collapse rule above. When no
finding in `findings.json` matches the record, the agent resolved the gate by
deleting its own CRITICAL or HIGH, and the review carries no other trace of it
— a maintainer reading a clean APPROVE has no way to know a reviewer once
claimed otherwise. Say so in the report, quoting the record's `description`
and stating that the agent withdrew it. A withdrawal the agent did not justify
in prose is the silent drop this gate exists to expose; surface it the way a
still-invalid agent is surfaced (Step 0).

The report seam is the Council Synthesis narrative. `phases/report.md` — "How
Sections Reach the Report" — permits filling only the markers
`rc-render-report.sh` anchors, and `<!-- NARRATIVE -->` is the one that carries
verification-phase prose to the reader. Append the disclosure lines to
`${session_dir}/narrative.md` before splicing it, per `phases/report.md` —
"Narrative Synthesis". Do not add a section the renderer does not anchor, and
do not write the disclosure into a finding's prose fields.

In `quick` mode narrative synthesis does not run, so there is no seam and the
disclosure reaches `verification.txt` only. Write it there regardless.

### Verdict Coherence Rule

If all agent verdicts APPROVE after verification and no remaining finding exceeds MEDIUM severity, final council verdict MUST be APPROVE. Coordinator cannot override unanimous agent consensus without citing specific HIGH or CRITICAL finding that survived verification pipeline. This rule is mechanical — not subject to coordinator judgment.

This rule and the REQUEST CHANGES backstop above partition one decision rather
than competing over it: the backstop has already run by the time this rule is
read, so an agent holding a surviving HIGH or CRITICAL is no longer APPROVE and
the case the second sentence contemplates — unanimous APPROVE alongside a
surviving HIGH or CRITICAL — cannot arise. The coordinator never weighs one
against the other.
