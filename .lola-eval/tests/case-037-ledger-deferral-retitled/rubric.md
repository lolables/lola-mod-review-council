---
rubric_version: "1"
pass_threshold: 0.75
weights:
  deferral_applied: 0.45
  attribution_exact: 0.2
  nothing_revoked: 0.15
  check_passed: 0.1
  no_flapping: 0.1
---

# Rubric: case-037-ledger-deferral-retitled

The agent was asked to run the review-council Disposition phase against a
session with one verified finding, a LOW at `README.md:1` saying the README's
usage section does not describe the new `--strict` docs build. The prior
settlement `s1` is a LOW deferral by `pr-author77` (At
`2026-11-10T09:00:00Z`) on `README.md`, summarised "README never mentions the
strict mkdocs flag." The wording differs; the defect is the same.

`phases/disposition.md` says a settlement applies when it is about the
finding's own defect, whatever the title or wording now is, and that a
deferred settlement suppresses a LOW finding with that defect. Expected: `F1`
is `suppressed-low` with `source: "ledger"`, `ledger_id: "s1"`, `by:
"pr-author77"`, `at: "2026-11-10T09:00:00Z"`, and moved to `stripped`;
nothing is revoked; `rc-check-disposition.sh` returns `ok`.

Score five components, each in [0.0, 1.0]:

## deferral_applied (weight 0.45)

- 1.0 — F1 is `suppressed-low` from `s1` (`DISPOSITIONS` shows it with source
  ledger).
- 0.0 — F1 was left verified, or `SETTLEMENT_MATCH` is "none".

## attribution_exact (weight 0.2)

- 1.0 — `ledger_id`, `by` and `at` on the disposition match `s1` exactly.
- 0.0 — any of the three differs, is missing, or no disposition was written.

## nothing_revoked (weight 0.15)

- 1.0 — `REVOKED` is "none" and no `ledger-revoked.json` was written.
- 0.0 — any settlement was revoked.

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
    "deferral_applied": <float>,
    "attribution_exact": <float>,
    "nothing_revoked": <float>,
    "check_passed": <float>,
    "no_flapping": <float>
  },
  "explanation": "<one-paragraph rationale citing the disposition entry written for F1 and whether anything was revoked>"
}
```
