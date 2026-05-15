# Phase: Report

Generate the final report and record learnings for
future runs.

## Inputs

- `${session_dir}/tracking.md` — full run state
- `${session_dir}/verdicts/verification.txt` — results
- `${session_dir}/verdicts/{agent-name}.md` — raw verdicts
- "Review Council Configuration" section (for knowledge
  tool)
- `${session_dir}/ci-causality.txt` — CI results with
  causality tags (when available)
- `${session_dir}/linked-issues.txt` — linked issue
  details and acceptance criteria (when available)
- `${session_dir}/diff.patch` — full patch (for
  acceptance criteria coverage scan)

## Outputs

- Final report to the user (displayed)
- `${session_dir}/learnings.txt` — recorded learnings
- Knowledge layer entries (if configured)

Update `${session_dir}/tracking.md` Phase: Report
with: council verdict, learnings recorded.

---

## Final Report — Code Review Mode

Provide a final report to the user containing:

- **Session directory**: `{session_dir}` (repeat the
  path for easy access to cached artifacts)
- **Discovery summary**: how many reviewer agents were
  discovered, which were invoked, and which known
  reviewer roles were absent
- **Verification summary**: how many findings were
  verified, corrected, and stripped, per agent
- **Deduplication summary**: how many duplicate
  findings were consolidated
- What was found in each iteration
- What was fixed
- If stopped early, the current set of outstanding
  **REQUEST CHANGES**
- If there were persistent circular **REQUEST CHANGES**
  (fixes for one reviewer cause failures in another),
  report those with additional detail

**When CI causality data is available**
(`${session_dir}/ci-causality.txt` exists), add two CI
failure sections to the report:

**CI Failures (PR-caused):** For each failure with
`causality: pr-caused` or `causality: unknown`, include
the check name, exit code, likely cause (inferred from
the output), and truncated output:

```
## CI Failures (PR-caused)

### test
Exit code: 1
Likely cause: TestAuth/login_timeout assertion failure
Output:
  FAIL TestAuth/login_timeout (0.3s)
  Expected 200, got 504
```

**CI Failures (Pre-existing):** For each failure with
`causality: pre-existing`, include the check name and
output, prefixed with the base branch note:

```
## CI Failures (Pre-existing)

### lint
Note: This failure also occurs on the base branch
({base}). It is not caused by the changes under review.
Output:
  src/legacy.py:12: E501 line too long (120 > 79)
```

Include the CI results summary table (Check, Status,
Source, Causality) from `ci-causality.txt`.

---

## Final Report — Spec Review Mode

Same structure as Code Review Mode, plus:

- What was auto-fixed (LOW/MEDIUM severity)
- Outstanding HIGH/CRITICAL findings that require human
  decision, with full context and recommendations
- The Architect's Alignment Score for spec quality
  (if provided)
- Suggested next steps for resolving outstanding
  findings

**When CI causality data is available**
(`${session_dir}/ci-causality.txt` exists): include the
same CI failure sections as Code Review Mode. These are
unlikely to be present in Spec Review Mode (quality
gates are skipped), but if they exist from a prior run,
include them.

---

## Prior Learnings Feedback

If a knowledge layer tool is configured (see "Review
Council Configuration" → "Knowledge tool"):

a. Record stripped findings as **false positive
   patterns** — include the agent name, the fabricated
   claim, and why it was stripped. These become negative
   learnings for future runs.
b. Record validated findings that led to accepted fixes
   as **positive patterns** — include the file, the
   issue, and the fix applied.
c. Record correction round outcomes — findings that
   were corrected successfully are informational
   (agent made an evidence error but the finding was
   real).
d. Store these learnings via the configured knowledge
   tool so future Prior Learnings queries surface them.

If no knowledge layer is configured, write the
learnings to `${session_dir}/learnings.txt` as a
human-readable record. They will be available to
future runs via Prior Run Awareness.

---

## Verdict Summary

End the report with the council verdict:

- **APPROVE** — all discovered reviewers returned
  APPROVE (after verification).
- **REQUEST CHANGES** — one or more reviewers returned
  REQUEST CHANGES with verified findings.
- **APPROVE WITH ADVISORIES** (Spec Review Mode only)
  — all LOW/MEDIUM findings were auto-fixed but
  HIGH/CRITICAL findings remain that require human
  judgment.

The discovery summary is included regardless of the
verdict. Absent reviewers (known roles not found during
discovery) do not affect the verdict.

---

## Acceptance Criteria Coverage (Appendix)

**When to include:** Only when
`${session_dir}/linked-issues.txt` exists AND at least
one linked issue has acceptance criteria. If no linked
issues have acceptance criteria, omit this section
entirely (no empty heading).

For each linked issue that has acceptance criteria,
produce a coverage assessment:

1. For each criterion, scan the diff
   (`${session_dir}/diff.patch`) and verified findings
   for evidence of implementation:

   - **COVERED**: diff contains code that clearly
     implements the criterion (matching function names,
     route paths, test names, or variable names
     corresponding to the criterion)
   - **PARTIALLY COVERED**: some aspects are addressed
     but gaps remain (annotate what is missing)
   - **NOT COVERED**: no evidence of implementation in
     the diff

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

3. Issues with no acceptance criteria are listed with
   "(No acceptance criteria found in issue)" — do not
   omit them, as the listing confirms they were checked.
