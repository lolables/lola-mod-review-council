# Phase: Report — LLM Judgment Reference

Guides orchestrator's narrative synthesis, learnings extraction, final verdict determination.

---

## Pre-condition Gate

**Before generating any report content**, verify Verification phase actually executed:

1. Read `${session_dir}/verdicts/verification.txt`.

2. **If file does not exist or is empty**: STOP. Do not generate report. Return to Verification phase and execute it. Display:
   > "verification.txt is missing — the Verification phase was not executed. Returning to Phase 4."

3. **If file exists but has no `=== SUMMARY ===` section**: STOP. Verification was incomplete. Return to Verification phase to finish it.

4. **If SUMMARY section contains only placeholder values** (e.g., `{N}` instead of actual numbers): STOP. Verification was templated, not executed. Return to Verification phase.

5. **If verification.txt shows zero tool calls were made** (no file reads, no greps, no evidence checks recorded in EVIDENCE VERIFICATION section): verification was performed mentally, not mechanically. Return to Verification phase and re-execute with actual tool calls.

Only proceed to generate report once verification.txt passes all five checks above.

---

## Narrative Synthesis

**Effort gate — quick mode:** If effort is `quick`, skip narrative
synthesis entirely. Compact report consists of:
1. Findings list from rendered template (sorted by severity)
2. Final verdict

Skip to Final Verdict Determination section.

Template rendering is performed by `rc-render-report.sh`, which produces report file with `<!-- NARRATIVE -->` marker. Your job: fill this marker with narrative summary of review story.

Narrative should cover:
- What review discovered (high-level patterns, themes)
- What was verified vs. what was stripped
- Key findings that remain (by severity and persona)
- Deduplication and validation outcomes
- Overall quality assessment

Keep narrative concise (2-4 paragraphs). Do not repeat detailed findings table — already in rendered template.

---

## Learnings Extraction

**Effort gate — quick mode:** If effort is `quick`, skip learnings
extraction entirely.

If knowledge layer tool is configured (see "Review Council Configuration" — "Knowledge tool"):

a. **False positive patterns** — record stripped findings (from Step 3) and validator retractions (from Step 4). Include agent name, fabricated claim, why stripped or retracted, and validator reasoning where applicable. For findings corrected in Step 1 but retracted in Step 4, also record as **correction failure** (agent doubled down).

b. **Positive patterns** — record validated findings that led to accepted fixes. Include file, issue, and fix applied.

c. **Evidence quality patterns** — record correction round outcomes (findings where agent's evidence was wrong but finding was real) and validator corrections (findings with inaccurate line numbers, wrong identifiers, or miscalibrated severity).

Store all learnings via configured knowledge tool so future Prior Learnings queries surface them.

If no knowledge layer is configured, write learnings to `${session_dir}/learnings.txt` as human-readable record. Available to future runs via Prior Run Awareness.

---

## Subsystem Analysis (Deep Mode Only)

**Skip this section unless effort is `deep` and
`${session_dir}/subsystems.json` exists.**

Read `${session_dir}/subsystems.json` and verified findings.
Render subsystem tree before findings list:

```
## Subsystem Analysis

{subsystem-name} ({severity counts})
  {file1}
  {file2}

{subsystem-name} ({severity counts})
  {file1}
  {file2}          <- also in: {other-subsystem}
```

**Rendering rules:**
- Subsystem name on header line with severity counts in parentheses
  (e.g., `auth-middleware (1 CRITICAL, 2 HIGH)`).
- Files indented with 2-space indent.
- Cross-cutting files (appearing in multiple subsystems) get
  `<- also in: {other-subsystem-names}` annotation.
- Subsystems with zero findings show `(clean)` instead of counts.
- Finding counts come from verified findings, not raw agent output.
- Sort subsystems by highest severity first: subsystems with CRITICAL
  findings first, then HIGH, etc.

---

## Acceptance Criteria Coverage

**When to include:** Only when `${session_dir}/linked-issues.txt` exists AND at least one linked issue has acceptance criteria. If no linked issues have acceptance criteria, omit this section entirely (no empty heading).

For each linked issue with acceptance criteria, produce coverage assessment:

1. For each criterion, scan diff (`${session_dir}/diff.patch`) and verified findings for evidence of implementation:

   - **COVERED**: diff contains code that clearly implements criterion (matching function names, route paths, test names, or variable names corresponding to criterion)
   - **PARTIALLY COVERED**: some aspects addressed but gaps remain (annotate what is missing)
   - **NOT COVERED**: no evidence of implementation in diff

2. Present as checklist grouped by issue:

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

3. Issues with no acceptance criteria listed with "(No acceptance criteria found in issue)" — do not omit them, listing confirms they were checked.

If report includes linked issues with acceptance criteria, add coverage checklist after acceptance criteria section. If no criteria exist, note that none were found.

---

## Final Verdict Determination

End report with council verdict:

- **APPROVE** — all discovered reviewers returned APPROVE (after verification).
- **REQUEST CHANGES** — one or more reviewers returned REQUEST CHANGES with verified findings.
- **APPROVE WITH ADVISORIES** (Spec Review Mode only) — only LOW/MEDIUM findings remain; no HIGH/CRITICAL findings present. Remaining findings are advisory and do not block merge.

Discovery summary included regardless of verdict. Absent reviewers (known roles not found during discovery) do not affect verdict.

---

## Forge CI Status Section

**When forge CI status is available** (`${session_dir}/ci-status.txt` exists), add forge CI section to report:

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

Include full results table from `ci-status.txt`. Add this section after Session Information in report.

---

## Update Tracking

Update `${session_dir}/tracking.md` Phase: Report with: council verdict, learnings recorded.
