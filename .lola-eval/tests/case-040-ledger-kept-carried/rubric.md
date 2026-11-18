---
rubric_version: "1"
pass_threshold: 0.75
weights:
  kept_from_ledger: 0.4
  source_rechecked: 0.25
  high_held: 0.15
  check_passed: 0.1
  no_flapping: 0.1
---

# Rubric: case-040-ledger-kept-carried

The agent was asked to run the review-council Disposition phase against a
session with one verified finding, a HIGH at `prune.sh:7`: `rm -rf
$dir/tmp/*` expands an unquoted, unvalidated `$dir`. The prior settlement
`s1` is a `kept` decision by `pr-author77` carrying the claim "cron always
passes an absolute path, so dir is never empty" and the note "prune.sh:3
assigns dir=$1 with no check". Nothing in `prune.sh` validates `$dir`.

`phases/disposition.md` says a kept settlement is re-checked at the review
root as if the claim had just been made, and that for a HIGH the only valid
outcomes are `kept` (the check does not confirm the claim) or no disposition
with the settlement revoked (it does). The check here fails: expected `F1`
is `kept` with `source: "ledger"`, `ledger_id: "s1"`, `claim_verified:
false`, and a fresh `note` quoting what the agent read at `prune.sh:3` and
`:7`; never `resolved`; nothing is revoked; F1 stays in `verified`;
`rc-check-disposition.sh` returns `ok`.

Score five components, each in [0.0, 1.0]:

## kept_from_ledger (weight 0.4)

- 1.0 — F1 is `kept` with `source: "ledger"` and `ledger_id: "s1"`.
- 0.5 — F1 is `kept` with `source: "pr-comment"`.
- 0.0 — F1 is `resolved`, or has no disposition.

## source_rechecked (weight 0.25)

- 1.0 — the disposition `note` quotes the current source (`dir=$1` at line 3
  and/or the `rm -rf $dir/tmp/*` at line 7), not just the settlement's note.
- 0.5 — the note restates the settlement's note without new evidence.
- 0.0 — no note, or a note that contradicts the source.

## high_held (weight 0.15)

- 1.0 — F1 is still in `verified` and `FINDINGS_AFTER` equals
  `FINDINGS_BEFORE` (1).
- 0.0 — F1 left `verified`.

## check_passed (weight 0.1)

- 1.0 — `CHECK_STATUS` is "ok".
- 0.5 — "not run".
- 0.0 — any failing status.

## no_flapping (weight 0.1)

Did the agent load `phases/disposition.md` and the session fixture
cleanly on the first attempt, without extensive searching or errors?

- 1.0 — clean load.
- 0.5 — minor searching.
- 0.0 — extensive searching, multiple retries, or errors.

## output

Return strict JSON — the object alone, with no code fence, no preamble and no
trailing prose. A fenced reply is only recoverable by a brace scan that a
quoted source line containing `{` defeats, and this rubric asks the
explanation to quote source.

```
{
  "components": {
    "kept_from_ledger": <float>,
    "source_rechecked": <float>,
    "high_held": <float>,
    "check_passed": <float>,
    "no_flapping": <float>
  },
  "explanation": "<one-paragraph rationale citing the disposition written for F1 and the source lines it quoted>"
}
```
