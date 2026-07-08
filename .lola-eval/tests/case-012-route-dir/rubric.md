---
rubric_version: "1"
pass_threshold: 0.7
weights:
  flag_accuracy: 0.4
  scope_accuracy: 0.4
  no_flapping: 0.2
---

# Rubric: case-012-route-dir

The agent was asked to run `/review-council module/` on a Go repo with
files in both `module/` and `cmd/`. Only `module/` should be in scope.

## flag_accuracy (weight 0.4)

Did the LLM translate `module/` into the correct flags?

The correct translation is: `--scope changed --scope paths --scope-value "module/"`

- 1.0 — the agent passed both `--scope changed` (or equivalent base
  scope) and `--scope paths --scope-value "module/"`.
- 0.5 — the agent used `--scope paths` or `--scope-value "module/"`
  but missed the base scope or used an unexpected combination that
  still achieves directory filtering.
- 0.0 — no directory filtering attempted.

## scope_accuracy (weight 0.4)

Did the review scope to only module/ files?

- 1.0 — all findings reference files under `module/` (e.g.,
  `module/handler.go`, `module/admin.go`). No findings about
  `cmd/main.go` or `cmd/debug.go`.
- 0.5 — most findings are about `module/` but some findings
  reference `cmd/` files.
- 0.0 — findings include `cmd/` files equally, or focus on `cmd/`.

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
