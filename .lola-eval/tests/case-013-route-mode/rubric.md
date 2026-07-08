---
rubric_version: "1"
pass_threshold: 0.7
weights:
  flag_accuracy: 0.4
  scope_accuracy: 0.4
  no_flapping: 0.2
---

# Rubric: case-013-route-mode

The agent was asked to run `/review-council specs` on a Go repo with
documentation. The review should use specs mode, which dispatches
spec-variant reviewer agents and reviews all files.

## flag_accuracy (weight 0.4)

Did the LLM translate `specs` into the correct flags?

The correct translation is: `--mode specs`

- 1.0 — the agent passed `--mode specs` to rc-prepare.sh.
- 0.5 — the agent attempted specs mode but used incorrect flag
  syntax or combined it with unnecessary scope flags.
- 0.0 — the agent used `--mode code` or omitted the mode flag,
  resulting in code review instead of specs review.

## scope_accuracy (weight 0.4)

Did the review operate in specs mode?

Evidence of specs mode:
- Reviewer agents used are the `-spec.md` variants (e.g.,
  `divisor-guard-spec`, `divisor-adversary-spec`)
- Review focuses on documentation quality, specification
  completeness, and consistency rather than code bugs
- Findings reference docs, README, or API documentation

- 1.0 — clear evidence of specs mode (spec agents used, findings
  focus on documentation/specification concerns).
- 0.5 — mixed signals (some spec-oriented findings but also code
  review findings, or unclear which agent variants were used).
- 0.0 — the review is clearly a code review (code bugs, security
  issues in Go code).

## no_flapping (weight 0.2)

Did the agent find its instruction files cleanly?

- 1.0 — clean load on first attempt.
- 0.5 — minor searching behavior.
- 0.0 — extensive searching or errors.

## output

Return strict JSON:

```
{
  "components": {
    "flag_accuracy": <float>,
    "scope_accuracy": <float>,
    "no_flapping": <float>
  },
  "explanation": "<one-paragraph rationale>"
}
```
