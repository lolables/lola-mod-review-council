---
rubric_version: "1"
pass_threshold: 0.75
weights:
  not_suppressed: 0.4
  revoked: 0.3
  finding_untouched: 0.1
  check_passed: 0.1
  no_flapping: 0.1
---

# Rubric: case-039-ledger-deferral-raised

The agent was asked to run the review-council Disposition phase against a
session with one verified finding, a MEDIUM at `prune.sh:6`: `find ... |
xargs rm -f` without `-print0` deletes the wrong path for names with spaces
or newlines, and now runs from cron as root. The prior settlement `s1` is a
LOW deferral on `prune.sh` of the same defect ("xargs rm -f splits artefact
names on spaces.").

`phases/disposition.md` says a deferred settlement suppresses only a LOW
finding, and that when the matched finding is now MEDIUM or above the
settlement is revoked and the finding left without a disposition. Expected:
`verdicts/_meta/ledger-revoked.json` is `["s1"]`, `F1` has no disposition
and stays verified, `rc-check-disposition.sh` returns `ok`.

Score five components, each in [0.0, 1.0]:

## not_suppressed (weight 0.4)

- 1.0 — F1 was not suppressed or stripped.
- 0.0 — F1 is `suppressed-low` or in `stripped`.

## revoked (weight 0.3)

- 1.0 — `REVOKED` is exactly `s1` (`ledger-revoked.json` is `["s1"]`).
- 0.5 — `s1` was not revoked but F1 is untouched.
- 0.0 — anything else.

## finding_untouched (weight 0.1)

- 1.0 — `FINDINGS_AFTER` equals `FINDINGS_BEFORE` (1) and F1 carries no
  disposition.
- 0.0 — the finding left `verified` or carries a disposition.

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
    "not_suppressed": <float>,
    "revoked": <float>,
    "finding_untouched": <float>,
    "check_passed": <float>,
    "no_flapping": <float>
  },
  "explanation": "<one-paragraph rationale citing what was written to ledger-revoked.json and F1's final state>"
}
```
