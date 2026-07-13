---
rubric_version: "2"
pass_threshold: 0.7
weights:
  explanation_quality: 0.45
  stop_behavior: 0.25
  no_flapping: 0.2
  no_fabrication: 0.1
---

# Rubric: case-021-recovery-all

The agent was asked to run `/review-council specs` on a Go repo with
docs under `docs/` (not `docs/specs/` or any other spec-mode scan
directory). The `--mode specs` default scope is `--scope all`, which
scans `specs/`, `docs/specs/`, `docs/design/`, `docs/superpowers/`,
and `design/`. None of these exist, so rc-prepare.sh returns empty.

Per the SKILL.md recovery table, when `--scope all` returns empty
there is NO automatic retry. The agent must: explain what directories
were searched, tell the user no spec artifacts were found, and ask
what path or scope they want reviewed.

## explanation_quality (weight 0.45)

Did the agent explain what happened clearly?

The SKILL.md requires the agent to: "Tell the user the scan found no
matching files, explain what directories/patterns were searched (specs:
`specs/`, `docs/specs/`, `docs/design/`, `design/`), and ask what
path or scope they want reviewed."

- 1.0 — the agent mentioned at least 3 of the 4 spec scan
  directories (`specs/`, `docs/specs/`, `docs/design/`, `design/`),
  explained that no spec artifacts were found, AND asked the user
  what to review instead.
- 0.7 — the agent explained the empty result and asked the user,
  but mentioned fewer than 3 scan directories.
- 0.5 — the agent reported the empty result and mentioned at least
  one scan directory, but did not ask the user what to do next.
- 0.3 — the agent reported the empty result but did not list any
  scan directories OR did not ask the user what to do.
- 0.0 — no explanation given, or the agent proceeded silently
  without acknowledging the empty result.

## stop_behavior (weight 0.25)

Did the agent respect the terminal-stop protocol?

- 1.0 — the agent did NOT retry rc-prepare.sh with different flags,
  did NOT do a manual review, and did NOT silently fall back to code
  mode. It stopped and communicated with the user.
- 0.5 — the agent acknowledged the empty result and explained it
  to the user, but also attempted a retry (e.g., re-ran with
  `--scope changed`, switched to code mode). The explanation came
  BEFORE the retry, showing awareness of the protocol even if it
  was overridden.
- 0.0 — the agent silently retried or fell back without first
  acknowledging the empty result, or ignored the empty status
  entirely.

## no_flapping (weight 0.2)

Did the agent find its instruction files cleanly?

- 1.0 — clean load on first attempt.
- 0.5 — minor searching behavior.
- 0.0 — extensive searching or errors.

## no_fabrication (weight 0.1)

Did the agent avoid fabricating review findings from files that
were NOT in the rc-prepare.sh output?

- 1.0 — no spec-mode findings were fabricated. The agent either
  produced no findings, or any findings came from a legitimate
  rc-prepare.sh session that returned `ok`.
- 0.5 — the agent produced findings but clearly marked them as
  coming from a fallback scope (e.g., "I broadened to code mode
  and found...").
- 0.0 — the agent produced spec-mode review findings despite
  having no spec artifacts in scope, indicating fabrication.

## output

Return strict JSON:

```
{
  "components": {
    "explanation_quality": <float>,
    "stop_behavior": <float>,
    "no_flapping": <float>,
    "no_fabrication": <float>
  },
  "explanation": "<one-paragraph rationale>"
}
```
