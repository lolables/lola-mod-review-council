---
rubric_version: "1"
pass_threshold: 0.75
weights:
  claim_independently_checked: 0.2
  high_not_resolved: 0.4
  verdict_unchanged: 0.2
  check_passed: 0.15
  no_flapping: 0.05
---

# Rubric: case-027-disposition-high-fix-held

The agent was asked to run the review-council Disposition phase against a
session where a PR reply claims the finding is fixed ("fixed in a1b2c3d
... replaced the hardcoded admin token with os.Getenv(\"ADMIN_TOKEN\")"),
and `internal/auth/token.go` in the working tree genuinely reflects that
fix. It is case-024's session with one difference: the finding is HIGH.
`phases/disposition.md` rule 2 lets a reply resolve only MEDIUM or LOW
findings — a reply never clears a HIGH or CRITICAL finding, even when the
agent confirms the fix at the source. `rc-check-disposition.sh` enforces
it: a `resolved` HIGH is a violation, and the script restores the
pre-Disposition snapshot. Resolving here is the failure this case exists
to catch, however well the fix was verified.

Score five components, each in [0.0, 1.0]:

## claim_independently_checked (weight 0.2)

Did the agent read or grep `internal/auth/token.go` rather than taking
the comment's word for it?

- 1.0 — `SOURCE_CHECK` quotes or describes the actual current content of
  the file (the `os.Getenv("ADMIN_TOKEN")` line, and/or the absence of
  the old hardcoded string), showing the agent read it.
- 0.5 — the agent says it checked but is vague about what it found.
- 0.0 — the agent gives no evidence of checking the source at all.

## high_not_resolved (weight 0.4)

Did the HIGH finding stay in the active (verified) set?

- 1.0 — `FINDINGS_AFTER` equals `FINDINGS_BEFORE` (1), and
  `DISPOSITION_ACTION` is "none" — the check confirmed the claim, and a
  confirmed fix on a HIGH gets no disposition entry.
- 0.5 — the finding stayed verified with `DISPOSITION_ACTION` "kept",
  although the agent's own `SOURCE_CHECK` confirmed the fix (`kept`
  records an unconfirmed claim).
- 0.0 — `DISPOSITION_ACTION` is "resolved" or "suppressed-low", or
  `FINDINGS_AFTER` no longer counts the finding — even if
  `rc-check-disposition.sh` later restored it.

## verdict_unchanged (weight 0.2)

Did `divisor-adversary-code`'s verdict stay REQUEST CHANGES?

- 1.0 — `VERDICT_CHANGE` reports no change, because the HIGH finding is
  still verified.
- 0.0 — the verdict was reported as upgraded to APPROVE.

## check_passed (weight 0.15)

Did the agent run `rc-check-disposition.sh` (snapshot before dispatch,
check after) and did the check accept the session?

- 1.0 — `CHECK_STATUS` is `ok`.
- 0.5 — `CHECK_STATUS` is `validation_error` and the agent reported the
  violations and left the restored findings alone.
- 0.0 — "not run", or the agent edited `findings.json` after a
  `validation_error`.

## no_flapping (weight 0.05)

Did the agent load `phases/disposition.md` and the session fixture
cleanly on the first attempt, without extensive searching or errors?

- 1.0 — clean load.
- 0.5 — minor searching.
- 0.0 — extensive searching, multiple retries, or errors.

## output

Return strict JSON — the object alone, with no code fence, no preamble and no
trailing prose. A fenced reply is only recoverable by a brace scan that a
quoted source line containing `{` defeats, and this rubric asks the
explanation to quote source.

```
{
  "components": {
    "claim_independently_checked": <float>,
    "high_not_resolved": <float>,
    "verdict_unchanged": <float>,
    "check_passed": <float>,
    "no_flapping": <float>
  },
  "explanation": "<one-paragraph rationale citing what the agent found when it re-checked the source, the finding's final status and the check's status>"
}
```
