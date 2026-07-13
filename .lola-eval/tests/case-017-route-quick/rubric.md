---
rubric_version: "1"
pass_threshold: 0.7
weights:
  flag_accuracy: 0.5
  scope_accuracy: 0.3
  no_flapping: 0.2
---

# Rubric: case-017-route-quick

The agent was asked to run `/review-council quick code HEAD` on a Go repo.
This tests whether the agent correctly extracts `quick` as the effort
level and combines it with mode and scope flags.

## flag_accuracy (weight 0.5)

Did the LLM translate `quick code HEAD` into the correct flags?

The correct translation is: `--effort quick --mode code --scope range --scope-value "HEAD~1..HEAD"`

- 1.0 — the agent passed `--effort quick` along with `--mode code`
  and `--scope range --scope-value "HEAD~1..HEAD"` (or equivalent).
- 0.5 — the agent passed `--effort quick` but got mode or scope
  partially wrong (e.g., omitted `--mode code`).
- 0.0 — the agent did not pass `--effort quick`, or treated "quick"
  as review instructions instead of an effort level.

## scope_accuracy (weight 0.3)

Did the review scope match the HEAD commit?

- 1.0 — review was scoped to the HEAD commit diff.
- 0.5 — scope was approximately correct but slightly broader.
- 0.0 — scope was completely wrong (full codebase, wrong commits).

## no_flapping (weight 0.2)

Did the agent find its instruction files cleanly?

- 1.0 — clean load, no searching or retrying.
- 0.5 — minor searching before finding the right files.
- 0.0 — extensive searching, multiple path candidates tried.

## output

Return strict JSON:

```json
{
  "components": {
    "flag_accuracy": <float>,
    "scope_accuracy": <float>,
    "no_flapping": <float>
  },
  "explanation": "<one-paragraph rationale>"
}
```
