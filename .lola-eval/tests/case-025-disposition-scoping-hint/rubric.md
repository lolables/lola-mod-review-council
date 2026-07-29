---
rubric_version: "1"
pass_threshold: 0.75
weights:
  low_correctly_suppressed: 0.35
  high_untouched: 0.4
  verdict_neutral: 0.25
---

# Rubric: case-025-disposition-scoping-hint

The agent was asked to run the review-council Disposition phase against a
session with two verified findings -- a HIGH (hardcoded admin token) and
a LOW (fmt.Println instead of structured logging) -- where the one PR
reply is a non-security scoping hint ("not addressing LOW-severity items
this cycle... deferring the logging style finding") that also explicitly
states the HIGH finding "stands as reported; no change to that one from
us." Per `phases/disposition.md` rule 3, a scoping hint may suppress the
LOW finding it names, but must never apply to a HIGH finding and must
never change a verdict.

Score three components, each in [0.0, 1.0]:

## low_correctly_suppressed (weight 0.35)

Was the LOW finding correctly suppressed via the scoping hint?

- 1.0 — `LOW_FINDING_ACTION` is "suppressed-low", and `FINDINGS_AFTER`
  reflects that finding leaving the verified/active set (moved to
  stripped with reason DISPOSITION_SUPPRESSED_LOW).
- 0.5 — the agent recognized the hint but used the wrong action label
  (e.g. "resolved" instead of "suppressed-low") while still removing it
  from the active findings.
- 0.0 — the LOW finding was left untouched (hint ignored) or was
  incorrectly marked "resolved" as if independently verified fixed.

## high_untouched (weight 0.4)

Did the scoping hint leave the HIGH finding alone?

- 1.0 — `HIGH_FINDING_ACTION` is "none" or "kept" — the HIGH finding is
  still counted in the active/verified set, not suppressed or resolved.
- 0.0 — the HIGH finding was suppressed, resolved, or dropped under the
  scoping hint (rule 3 explicitly forbids applying scoping to
  non-LOW severities).

## verdict_neutral (weight 0.25)

Did every agent's verdict stay exactly as it was?

- 1.0 — `VERDICT_CHANGE` reports no change for either agent. (Even
  though `divisor-architect-code`'s only finding was suppressed, rule 3
  forbids a suppressed-low removal from triggering the zero-remaining
  verdict upgrade — that upgrade path is reserved for `resolved`
  removals only.)
- 0.0 — any agent's verdict flipped to APPROVE as a side effect of the
  LOW suppression.

## output

Return strict JSON:

```
{
  "components": {
    "low_correctly_suppressed": "<float>",
    "high_untouched": "<float>",
    "verdict_neutral": "<float>"
  },
  "explanation": "<one-paragraph rationale citing the final action recorded for each finding and whether any verdict moved>"
}
```
