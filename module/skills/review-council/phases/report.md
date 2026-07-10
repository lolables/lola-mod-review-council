# Phase: Report — LLM Judgment Reference

This file guides the orchestrator's narrative synthesis, learnings extraction, and final verdict determination.

---

## Pre-condition Gate

**Before generating any report content**, verify that the Verification phase actually executed:

1. Read `${session_dir}/verdicts/verification.txt`.

2. **If the file does not exist or is empty**: STOP. Do not generate a report. Return to the Verification phase and execute it. Display:
   > "verification.txt is missing — the Verification phase was not executed. Returning to Phase 4."

3. **If the file exists but has no `=== SUMMARY ===` section**: STOP. The verification was incomplete. Return to the Verification phase to finish it.

4. **If the SUMMARY section contains only placeholder values** (e.g., `{N}` instead of actual numbers): STOP. The verification was templated, not executed. Return to the Verification phase.

5. **If verification.txt shows zero tool calls were made** (no file reads, no greps, no evidence checks recorded in the EVIDENCE VERIFICATION section): the verification was performed mentally, not mechanically. Return to the Verification phase and re-execute with actual tool calls.

Only proceed to generate the report once verification.txt passes all five checks above.

---

## Narrative Synthesis

The template rendering is performed by `rc-render-report.sh`, which produces a report file with a `<!-- NARRATIVE -->` marker. Your job is to fill this marker with a narrative summary of the review story.

The narrative should cover:
- What the review discovered (high-level patterns, themes)
- What was verified vs. what was stripped
- Key findings that remain (by severity and persona)
- Deduplication and validation outcomes
- Overall quality assessment

Keep the narrative concise (2-4 paragraphs). Do not repeat the detailed findings table — that is already in the rendered template.

---

## Learnings Extraction

If a knowledge layer tool is configured (see "Review Council Configuration" → "Knowledge tool"):

a. **False positive patterns** — record stripped findings (from Step 4) and validator retractions (from Step 5.5). Include the agent name, the fabricated claim, why it was stripped or retracted, and the validator's reasoning where applicable. For findings that were corrected in Step 3 but retracted in Step 5.5, also record as a **correction failure** (the agent doubled down).

b. **Positive patterns** — record validated findings that led to accepted fixes. Include the file, the issue, and the fix applied.

c. **Evidence quality patterns** — record correction round outcomes (findings where the agent's evidence was wrong but the finding was real) and validator corrections (findings with inaccurate line numbers, wrong identifiers, or miscalibrated severity).

Store all learnings via the configured knowledge tool so future Prior Learnings queries surface them.

If no knowledge layer is configured, write the learnings to `${session_dir}/learnings.txt` as a human-readable record. They will be available to future runs via Prior Run Awareness.

---

## Acceptance Criteria Coverage

**When to include:** Only when `${session_dir}/linked-issues.txt` exists AND at least one linked issue has acceptance criteria. If no linked issues have acceptance criteria, omit this section entirely (no empty heading).

For each linked issue that has acceptance criteria, produce a coverage assessment:

1. For each criterion, scan the diff (`${session_dir}/diff.patch`) and verified findings for evidence of implementation:

   - **COVERED**: diff contains code that clearly implements the criterion (matching function names, route paths, test names, or variable names corresponding to the criterion)
   - **PARTIALLY COVERED**: some aspects are addressed but gaps remain (annotate what is missing)
   - **NOT COVERED**: no evidence of implementation in the diff

2. Present as a checklist grouped by issue:

   ```
   ## Acceptance Criteria Coverage

   ### From Issue #38: "Add user authentication"

   - [x] COVERED: Users can log in with email/password
   - [~] PARTIALLY COVERED: Session timeout is configurable
     (default set in config, no UI for changing it)
   - [ ] NOT COVERED: Password reset flow

   ### From Issue #41: "Fix logout redirect"

   (No acceptance criteria found in issue)
   ```

3. Issues with no acceptance criteria are listed with "(No acceptance criteria found in issue)" — do not omit them, as the listing confirms they were checked.

If the report includes linked issues with acceptance criteria, add the coverage checklist after the acceptance criteria section. If no criteria exist, note that none were found.

---

## Final Verdict Determination

End the report with the council verdict:

- **APPROVE** — all discovered reviewers returned APPROVE (after verification).
- **REQUEST CHANGES** — one or more reviewers returned REQUEST CHANGES with verified findings.
- **APPROVE WITH ADVISORIES** (Spec Review Mode only) — all LOW/MEDIUM findings were auto-fixed but HIGH/CRITICAL findings remain that require human judgment.

The discovery summary is included regardless of the verdict. Absent reviewers (known roles not found during discovery) do not affect the verdict.

---

## Forge CI Status Section

**When forge CI status is available** (`${session_dir}/ci-status.txt` exists), add a forge CI section to the report:

```
## Forge CI Status

| Check | Status |
|-------|--------|
| build | pass   |
| test  | fail   |
| lint  | fail   |

Failing checks:
- test: FAILURE (see forge CI tab for details)
- lint: FAILURE (see forge CI tab for details)
```

Include the full results table from `ci-status.txt`. Add this section after the Session Information in the report.

---

## Update Tracking

Update `${session_dir}/tracking.md` Phase: Report with: council verdict, learnings recorded.
