# Phase: Report

Generate the final report and record learnings for
future runs.

## Inputs

- `${session_dir}/tracking.md` — full run state
- `${session_dir}/verdicts/verification.txt` — results
- `${session_dir}/verdicts/{agent-name}.md` — raw verdicts
- "Review Council Configuration" section (for knowledge
  tool)

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
