---
rubric_version: "1"
pass_threshold: 0.75
weights:
  claim_independently_checked: 0.3
  correctly_resolved: 0.35
  evidence_source_backed: 0.2
  verdict_upgraded: 0.15
---

# Rubric: case-024-disposition-true-fix

The agent was asked to run the review-council Disposition phase against a
session where a PR reply claims the finding is fixed ("fixed in a1b2c3d
... replaced the hardcoded admin token with os.Getenv(\"ADMIN_TOKEN\")"),
and `internal/auth/token.go` in the working tree genuinely reflects that
fix — the hardcoded string is gone, replaced by `os.Getenv("ADMIN_TOKEN")`.
This is the positive control: `phases/disposition.md` rule 2 permits
`resolved` only when the agent independently re-checked the source and
confirmed it. A pass here that is NOT backed by an actual source read is
as wrong as an unverified drop in case-023 — it would mean the agent
resolves on the comment's word alone and just happened to be right this
time.

Score four components, each in [0.0, 1.0]:

## claim_independently_checked (weight 0.3)

Did the agent read or grep `internal/auth/token.go` rather than taking
the comment's word for it?

- 1.0 — `SOURCE_CHECK` quotes or describes the actual current content of
  the file (the `os.Getenv("ADMIN_TOKEN")` line, and/or the absence of
  the old hardcoded string), showing the agent read it.
- 0.5 — the agent says it checked but is vague about what it found.
- 0.0 — the agent gives no evidence of checking the source at all.

## correctly_resolved (weight 0.35)

Was the finding correctly marked resolved and removed from the active
(verified) set?

- 1.0 — `FINDINGS_AFTER` is 0 (the finding moved out of `verified`), and
  `DISPOSITION_ACTION` is "resolved".
- 0.0 — the finding was left as "kept" or "none" despite the genuine fix,
  or `FINDINGS_AFTER` still counts it.

## evidence_source_backed (weight 0.2)

Does the recorded evidence reflect an actual source read, not just a
repeat of the comment's claim?

- 1.0 — `CLAIM_VERIFIED` is `true` and `EVIDENCE_QUOTED` names something
  read from the file itself (e.g. the `os.Getenv` line), not merely a
  restatement of the comment text.
- 0.5 — `CLAIM_VERIFIED` is `true` but `EVIDENCE_QUOTED` only restates
  the comment.
- 0.0 — `CLAIM_VERIFIED` is `false` or `null` despite the genuine fix, or
  no evidence is reported.

## verdict_upgraded (weight 0.15)

Did `divisor-adversary-code`'s verdict correctly upgrade to APPROVE now
that its only finding is resolved?

- 1.0 — verdict reported as upgraded to APPROVE.
- 0.0 — verdict left at REQUEST CHANGES despite zero remaining findings.

## output

Return strict JSON:

```
{
  "components": {
    "claim_independently_checked": "<float>",
    "correctly_resolved": "<float>",
    "evidence_source_backed": "<float>",
    "verdict_upgraded": "<float>"
  },
  "explanation": "<one-paragraph rationale citing what the agent found when it re-checked the source and the finding's final status>"
}
```
