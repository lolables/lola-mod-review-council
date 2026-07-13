---
rubric_version: "1"
pass_threshold: 0.7
weights:
  recovery_behavior: 0.5
  transparency: 0.3
  no_flapping: 0.2
---

# Rubric: case-019-recovery-changed

The agent was asked to run `/review-council code` on a Go repo where
all code lives on main with no feature branch. The default `--scope
changed` produces an empty diff (`main...HEAD` is empty because HEAD
is main). The SKILL.md recovery table says: when `--scope changed`
returns empty, re-run with `--scope all`.

## recovery_behavior (weight 0.5)

Did the agent follow the recovery table correctly?

The expected sequence is:
1. First call: `--mode code` (scope defaults to changed) → gets `empty` status
2. Recovery call: `--mode code --scope all` → gets `ok` status
3. Proceeds with the review using the `--scope all` results

- 1.0 — the agent called rc-prepare.sh twice: first with default/changed
  scope (got empty), then with `--scope all` (got ok), and completed
  the review with findings from the full codebase.
- 0.5 — the agent recovered but used incorrect recovery flags (e.g.,
  broadened to `--scope all` without keeping `--mode code`), or
  recovered but did not complete the full review pipeline.
- 0.0 — the agent did not attempt recovery: it either stopped after
  the empty result, or silently skipped rc-prepare.sh and did a
  manual review, or never got an empty result (wrong initial flags).

## transparency (weight 0.3)

Did the agent explain the scope change to the user?

The SKILL.md requires: "Before re-running with recovery flags, tell
the user what happened and what you are trying instead."

- 1.0 — the agent explicitly told the user that the initial scope
  was empty and that it was retrying with a broader scope. The
  message was clear about what changed and why.
- 0.5 — the agent mentioned the empty result or the scope change
  but not both, or the explanation was unclear.
- 0.0 — the agent silently retried without any explanation, or
  did not retry at all.

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
    "recovery_behavior": <float>,
    "transparency": <float>,
    "no_flapping": <float>
  },
  "explanation": "<one-paragraph rationale>"
}
```
