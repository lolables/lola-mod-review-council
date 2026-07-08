---
rubric_version: "1"
pass_threshold: 0.7
weights:
  flag_accuracy: 0.5
  scope_accuracy: 0.3
  no_flapping: 0.2
---

# Rubric: case-014-route-mixed

The agent was asked to run `/review-council code HEAD -> focus on error handling`.
This tests three routing dimensions simultaneously: mode, scope, and
review instructions. The eval harness creates bookkeeping commits after
the scaffold, so HEAD may contain only config changes (not application
code). This test evaluates whether the agent correctly parses the
compound input into separate flag groups — not whether the scoped
content is useful.

## flag_accuracy (weight 0.5)

Did the LLM translate the mixed input into the correct flags?

The correct translation is:
- `--mode code`
- `--scope range --scope-value "HEAD~1..HEAD"`
- `--review-instructions "focus on error handling"`

- 1.0 — all three flag groups are correct: mode is code, scope is
  a HEAD range, and review instructions include "error handling".
- 0.7 — two of the three flag groups are correct.
- 0.3 — one of the three flag groups is correct.
- 0.0 — none correct, or the `->` separator was not parsed correctly.

## scope_accuracy (weight 0.3)

When the scoped changeset is empty or contains only non-code files,
did the agent handle it honestly?

- 1.0 — the agent reported the empty/minimal scope honestly: stated
  that HEAD contained no reviewable code changes, or produced a
  review limited to the actual HEAD diff. Did NOT silently broaden
  to the full codebase.
- 0.5 — the agent broadened scope but acknowledged doing so (e.g.,
  "HEAD was empty so I reviewed the full codebase instead").
- 0.0 — the agent silently fell back to reviewing the full codebase
  without noting that HEAD had no code changes, or fabricated
  findings about files not in the HEAD diff.

## no_flapping (weight 0.2)

Did the agent find its instruction files cleanly?

- 1.0 — the agent loaded SKILL.md, phase files, and agent definitions
  on the first attempt via known paths. No searching, retrying, or
  error recovery visible in the transcript.
- 0.5 — the agent found the right files but showed some searching
  behavior (e.g., tried one wrong path before finding the right one).
- 0.0 — the agent searched extensively for instruction files, tried
  multiple path candidates, or emitted errors about missing files
  before recovering.

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
