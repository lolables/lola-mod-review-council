---
rubric_version: "1"
pass_threshold: 0.7
weights:
  flag_accuracy: 0.5
  scope_accuracy: 0.3
  no_flapping: 0.2
---

# Rubric: case-018-route-deep

The agent was asked to run `/review-council deep main..feat` on a Go repo.
This tests whether the agent correctly extracts `deep` as the effort
level and combines it with a ref range scope.

## flag_accuracy (weight 0.5)

Did the LLM translate `deep main..feat` into the correct flags?

The correct translation is: `--effort deep --scope range --scope-value "main..feat"`

- 1.0 — the agent passed `--effort deep` along with
  `--scope range --scope-value "main..feat"`.
- 0.5 — the agent passed `--effort deep` but got scope partially
  wrong, or passed the correct scope but missed `--effort deep`.
- 0.0 — the agent did not pass `--effort deep`, or treated "deep"
  as review instructions or a branch name.

## scope_accuracy (weight 0.3)

Did the review scope cover exactly main..feat?

- 1.0 — review was scoped to the main..feat range and reviewed
  only the files changed in that range.
- 0.5 — scope was approximately correct but included extra files
  or missed some.
- 0.0 — scope was completely wrong (full codebase, wrong range).

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
