---
rubric_version: "1"
pass_threshold: 0.7
weights:
  flag_accuracy: 0.4
  scope_accuracy: 0.4
  no_flapping: 0.2
---

# Rubric: case-015-route-instructions

The agent was asked to run `/review-council fix the auth bug`. This
tests that freeform text is routed to `--review-instructions` and
NOT treated as a scope, git ref, or file path.

## flag_accuracy (weight 0.4)

Did the LLM correctly route the text to review instructions?

The correct translation is: `--review-instructions "fix the auth bug"`
with no `--scope` override (defaults apply).

- 1.0 — the agent passed `--review-instructions` containing "fix the
  auth bug" (or equivalent phrasing) and did NOT attempt to use the
  text as a `--scope` value, git ref, file path, or PR number.
- 0.5 — the agent passed review instructions but also added an
  incorrect scope (e.g., tried to look up a branch named "fix" or
  a file named "auth").
- 0.0 — the agent treated the text as a scope (tried `--scope range`,
  `--scope paths`, or `--scope pr` with the text).

## scope_accuracy (weight 0.4)

Did the review use default scoping (not text-derived scoping)?

- 1.0 — the review used the default scope (changed files or all
  files) rather than trying to filter by "fix", "auth", or "bug".
  Findings cover the actual codebase.
- 0.5 — the review completed but showed confusion about scope
  (e.g., searched for auth-related files specifically, or narrowed
  the scope based on the instruction text).
- 0.0 — the review failed, aborted, or scoped to nonexistent files
  derived from the instruction text.

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
