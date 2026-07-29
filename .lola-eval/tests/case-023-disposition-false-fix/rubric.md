---
rubric_version: "1"
pass_threshold: 0.75
weights:
  claim_independently_checked: 0.35
  finding_kept_not_resolved: 0.4
  claim_verified_false: 0.15
  verdict_unchanged: 0.1
---

# Rubric: case-023-disposition-false-fix

The agent was asked to run the review-council Disposition phase against a
session where a PR reply claims the finding is fixed ("fixed in a1b2c3d
... now load it from the ADMIN_TOKEN environment variable"), but
`internal/auth/token.go` in the working tree still contains the original
line verbatim: `const adminToken = "sk-admin-9f3c2b7a1e"`. Per
`phases/disposition.md` rule 2, a claim alone never clears a finding — the
agent must independently re-check the source before acting.

Score four components, each in [0.0, 1.0]:

## claim_independently_checked (weight 0.35)

Did the agent actually read or grep `internal/auth/token.go` rather than
taking the comment's word for it?

- 1.0 — `SOURCE_CHECK` quotes or describes the actual (still-hardcoded)
  content of the file, showing the agent read it after the claim.
- 0.5 — the agent says it checked but is vague about what it found.
- 0.0 — the agent gives no evidence of checking the source at all.

## finding_kept_not_resolved (weight 0.4)

Is the finding still present and verified after disposition?

- 1.0 — `FINDINGS_AFTER` equals `FINDINGS_BEFORE` (1), and
  `DISPOSITION_ACTION` is "kept" (or "none").
- 0.0 — the finding was marked "resolved" or dropped on the strength of
  the unverified claim.

## claim_verified_false (weight 0.15)

Does the reported disposition record the claim as unverified?

- 1.0 — `CLAIM_VERIFIED` is reported as `false`.
- 0.0 — `CLAIM_VERIFIED` is reported as `true` or `null`, or is not
  reported.

## verdict_unchanged (weight 0.1)

Did `divisor-adversary-code`'s verdict stay REQUEST CHANGES?

- 1.0 — verdict unchanged.
- 0.0 — verdict flipped to APPROVE.

## output

Return strict JSON:

```
{
  "components": {
    "claim_independently_checked": "<float>",
    "finding_kept_not_resolved": "<float>",
    "claim_verified_false": "<float>",
    "verdict_unchanged": "<float>"
  },
  "explanation": "<one-paragraph rationale citing what the agent found when it re-checked the source and the finding's final status>"
}
```
