---
rubric_version: "1"
pass_threshold: 0.7
weights:
  flag_accuracy: 0.2
  recovery_behavior: 0.4
  transparency: 0.2
  no_flapping: 0.2
---

# Rubric: case-020-recovery-range

The agent was asked to run `/review-council HEAD` on a Go repo. The
scaffold puts the agent on a feature branch where HEAD is a
.gitignore-only commit. The code changes are in an earlier commit
on the same branch. The agent should translate HEAD to `--scope range
--scope-value "HEAD~1..HEAD"`, get an empty result (no code files in
that commit), then recover by retrying with `--scope changed` per the
SKILL.md recovery table.

## flag_accuracy (weight 0.2)

Did the LLM translate `HEAD` into the correct initial flags?

- 1.0 — the agent passed `--scope range --scope-value "HEAD~1..HEAD"`
  (or equivalent).
- 0.5 — the agent passed a range scope with a slightly different
  value but still targeting HEAD.
- 0.0 — the agent did not use `--scope range`, or passed completely
  wrong initial flags.

## recovery_behavior (weight 0.4)

Did the agent follow the recovery table correctly?

The expected sequence is:
1. First call: `--scope range --scope-value "HEAD~1..HEAD"` → `empty`
2. Recovery call: `--scope changed` (keep `--mode`) → `ok`
3. Proceeds with the review using the `--scope changed` results

- 1.0 — the agent called rc-prepare.sh twice: first with range scope
  (got empty), then with `--scope changed` (got ok), and completed
  the review with findings from the changed files.
- 0.5 — the agent recovered but used a different recovery path than
  prescribed (e.g., jumped straight to `--scope all` instead of
  `--scope changed`), or recovered but did not complete the review.
- 0.0 — the agent did not attempt recovery: stopped after empty,
  did a manual review, or never got an empty result.

## transparency (weight 0.2)

Did the agent explain the scope change to the user?

- 1.0 — the agent explicitly told the user that HEAD contained no
  code changes and that it was falling back to --scope changed.
- 0.5 — partial explanation (mentioned empty or mentioned fallback
  but not both).
- 0.0 — silent retry or no retry.

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
    "recovery_behavior": <float>,
    "transparency": <float>,
    "no_flapping": <float>
  },
  "explanation": "<one-paragraph rationale>"
}
```
