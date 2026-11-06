---
rubric_version: "1"
pass_threshold: 0.6
weights:
  detection: 0.35
  evidence: 0.20
  calibration: 0.15
  false_positives: 0.15
  routing_accuracy: 0.10
  no_flapping: 0.05
---

# Rubric: case-034-shadow-constants

The agent was asked to run /review-council on the `main..feat` range of a
small Go CI helper. The feature branch contains three intentional findings,
each a second source of truth for a value owned elsewhere.

**F1, code, HIGH.** `ci/setup.go` declares `fixtureSHA`, a copy of
`fixture-sha` in `pins/fixtures.lock` (unchanged, outside the diff).
`VerifyFixture` compares a checkout's head against the copy, so the integrity
gate no longer follows the owner.

**F2, code, MEDIUM.** `ci/setup.go` declares `lintkitVersion = "1.64.0"`, a
copy of `lintkit` in `pins/tools.lock`, which the same diff bumps. `LintkitURL`
builds the download URL from the copy.

**F3, docs, HIGH.** `README.md`, outside the diff, still says
`Requires lintkit 1.62.2` and `go install ...@v1.62.2`. The owner now says
1.64.0, so the install steps a user would copy are stale.

**Decoys.** The new `docs/changelog.md` line (`bump lintkit from 1.62.2 to
1.64.0`) records history on purpose. The `v9.9.9` in `TestParseVersion` is a
made-up input, not a copy of anything. `pins/tools.lock` and
`pins/fixtures.lock` are the owners. Flagging any of these as a shadow copy
is a false positive.

Legitimate secondary findings are not false positives: no test asserts the
constants agree with the lock files, `pinbox` never reads `fixtures.lock`, or
`ParseVersion` accepts any string.

Score each component in [0.0, 1.0]:

## detection (weight 0.35)

- 1.0 — F1 and F3 are each reported at HIGH or above, F2 is reported, and the
  verdict is REQUEST CHANGES.
- 0.6 — F1 and F3 are both reported at MEDIUM or above, F2 missing, or any
  severity short of the 1.0 case.
- 0.3 — exactly one of F1 or F3 reported at MEDIUM or above.
- 0.0 — neither F1 nor F3 reported, or reported only at LOW. A finding that
  only says "hard-coded constant" or "magic string" without naming the owning
  lock file (F1, F2) or the stale README line (F3) does not count.

## evidence (weight 0.20)

- 1.0 — F1 and F3 each cite both halves with quotes: F1 `ci/setup.go` and
  `pins/fixtures.lock`; F3 `README.md` and `pins/tools.lock`.
- 0.5 — one of F1 or F3 cites both halves, or both cite one half.
- 0.0 — no file:line citations, or citations that do not match the source.

## calibration (weight 0.15)

- 1.0 — F1 and F3 are HIGH (not CRITICAL), and F2 is MEDIUM or LOW.
- 0.5 — one severity off by one level.
- 0.0 — F1 or F3 rated LOW, or any of F1-F3 rated CRITICAL.

## false_positives (weight 0.15)

Count decoys flagged plus fabricated findings that do not exist in the code.

- 1.0 — none.
- 0.5 — one.
- 0.0 — two or more.

## routing_accuracy (weight 0.10)

Did the agent translate `/review-council code main..feat` into
`--scope range --scope-value "main..feat"` with `--mode code`?

- 1.0 — correct scope and mode.
- 0.5 — correct mode, wrong or defaulted scope.
- 0.0 — wrong mode, or the flags were not passed to rc-prepare.sh.

## no_flapping (weight 0.05)

Did the agent find its instruction files (SKILL.md, phase files, agent
definitions) cleanly on the first attempt?

- 1.0 — clean load, no searching or retrying.
- 0.5 — minor searching behavior.
- 0.0 — extensive searching, multiple retries, or errors.

## output

Return strict JSON:

```
{
  "components": {
    "detection": "<float>",
    "evidence": "<float>",
    "calibration": "<float>",
    "false_positives": "<float>",
    "routing_accuracy": "<float>",
    "no_flapping": "<float>"
  },
  "explanation": "<one-paragraph rationale>"
}
```
