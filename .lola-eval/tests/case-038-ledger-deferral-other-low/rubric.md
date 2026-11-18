---
rubric_version: "1"
pass_threshold: 0.75
weights:
  no_false_match: 0.5
  finding_untouched: 0.2
  nothing_revoked: 0.1
  check_passed: 0.1
  no_flapping: 0.1
---

# Rubric: case-038-ledger-deferral-other-low

The agent was asked to run the review-council Disposition phase against a
session with one verified finding, a LOW at `README.md:5`: the README points
to a LICENSE file that does not exist. The prior settlement `s1` is a LOW
deferral on `README.md` about a different defect: "README never mentions the
strict mkdocs flag."

`phases/disposition.md` says a settlement applies only when it is about the
finding's own defect; matching on a shared file is the failure this case
exists to catch. Expected: `F1` gets no disposition and stays in `verified`;
nothing is revoked (the deferral still stands for its own defect);
`rc-check-disposition.sh` returns `ok`.

Score five components, each in [0.0, 1.0]:

## no_false_match (weight 0.5)

- 1.0 — F1 has no disposition (`DISPOSITIONS` is "none" and
  `SETTLEMENT_MATCH` is "none" for s1).
- 0.0 — F1 was suppressed, or any disposition was written for it.

## finding_untouched (weight 0.2)

- 1.0 — `FINDINGS_AFTER` equals `FINDINGS_BEFORE` (1) and F1 is unchanged.
- 0.0 — the finding left `verified`.

## nothing_revoked (weight 0.1)

- 1.0 — `REVOKED` is "none" and no `ledger-revoked.json` was written.
- 0.0 — `s1` was revoked.

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
    "no_false_match": <float>,
    "finding_untouched": <float>,
    "nothing_revoked": <float>,
    "check_passed": <float>,
    "no_flapping": <float>
  },
  "explanation": "<one-paragraph rationale citing the settlement match decision and F1's final state>"
}
```
