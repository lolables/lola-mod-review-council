---
rubric_version: "1"
pass_threshold: 0.7
weights:
  flag_accuracy: 0.4
  scope_accuracy: 0.4
  no_flapping: 0.2
---

# Rubric: case-016-route-pr-number

The agent was asked to run `/review-council 42`. This tests that a
bare number is routed to `--scope pr --scope-value 42`. The PR fetch
will fail (no GitHub remote configured), but the routing is what we
are testing.

## flag_accuracy (weight 0.4)

Did the LLM translate `42` into the correct flags?

The correct translation is: `--scope pr --scope-value 42`

- 1.0 — the agent passed `--scope pr --scope-value 42` (or
  `--scope-value "42"`).
- 0.5 — the agent recognized 42 as a PR reference but used
  incorrect flags (e.g., `--scope range --scope-value 42`).
- 0.0 — the agent treated 42 as something other than a PR number
  (e.g., review instructions, a git ref, or ignored it).

## scope_accuracy (weight 0.4)

Did the agent handle the PR lookup failure gracefully?

Since there is no GitHub remote, `rc-prepare.sh` will return an
error or skip status for the PR scope. The agent should:
- Report that the PR lookup failed
- NOT fall back to reviewing the entire codebase silently
- NOT fabricate PR content

- 1.0 — the agent reported the PR lookup failure clearly and did
  not silently fall back to a full codebase review or fabricate
  PR content.
- 0.5 — the agent reported the failure but also performed a
  fallback review of the codebase.
- 0.0 — the agent silently reviewed the entire codebase as if no
  PR scope was requested, or fabricated PR content.

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
