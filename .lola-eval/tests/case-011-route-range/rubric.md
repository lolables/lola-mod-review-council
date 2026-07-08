---
rubric_version: "1"
pass_threshold: 0.7
weights:
  flag_accuracy: 0.4
  scope_accuracy: 0.4
  no_flapping: 0.2
---

# Rubric: case-011-route-range

The agent was asked to run `/review-council main..feat` on a Go repo.
The feat branch adds `auth.go` with a hardcoded token. Main has clean
code. Score how well the agent routed the input.

## flag_accuracy (weight 0.4)

Did the LLM translate `main..feat` into the correct flags?

The correct translation is: `--scope range --scope-value "main..feat"`

- 1.0 — the agent passed `--scope range --scope-value "main..feat"`
  (or equivalent like `--scope range --scope-value main..feat`).
- 0.5 — the agent passed `--scope range` but with a different value
  that still captures the branch changes.
- 0.0 — the agent did not use `--scope range`, or passed completely
  wrong flags.

## scope_accuracy (weight 0.4)

Did the review scope to only the feat branch changes?

- 1.0 — findings reference only `auth.go` (the file on the feat
  branch). No findings about `main.go` pre-existing issues.
- 0.5 — findings primarily reference `auth.go` but include some
  findings from main's `main.go`.
- 0.0 — findings are about `main.go` only, or the review treated
  the entire codebase as in scope.

## no_flapping (weight 0.2)

Did the agent find its instruction files cleanly?

- 1.0 — clean load of all instruction files on first attempt.
- 0.5 — minor searching behavior.
- 0.0 — extensive searching or errors before recovery.

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
