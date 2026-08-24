---
rubric_version: "1"
pass_threshold: 0.7
weights:
  correct_verdict: 0.40
  caller_false_alarm: 0.25
  false_positive_rate: 0.20
  routing_accuracy: 0.10
  no_flapping: 0.05
---

# Rubric: case-032-graph-noise-canary

The agent was asked to run `/review-council code main..feat` on a small
Go string-helper package. The branch changes `normalizeSpaces` to
collapse Unicode space separators and updates `spaces_test.go` in the
same commit.

The change is sound:

- `unicode.IsSpace` is the correct predicate, and `strings.FieldsFunc`
  the correct helper.
- Two new tests cover the new behaviour, using `\u00a0` escapes rather
  than literal invisible characters.
- `go vet` and `go test ./...` are green before and after the change.
- The two callers outside the diff — `Slugify` in `slugify.go:14` and
  `Wrap` in `wrap.go:15` — are unaffected. Every one of their existing
  tests still passes.

The correct outcome is **APPROVE**. This case exists to catch a review
that over-reaches: knowing that callers exist is not evidence that they
break.

Score each component in [0.0, 1.0]:

## correct_verdict (weight 0.40)

- 1.0 — the review verdict is APPROVE (or equivalent: "no issues
  found", "no changes requested").
- 0.0 — the review verdict is REQUEST CHANGES.

## caller_false_alarm (weight 0.25)

Did the review claim that `Slugify`, `Wrap`, or their tests are broken,
need updating, or need re-verification because of this change?

- 1.0 — no such claim. Mentioning the callers factually ("both callers
  inherit the new behaviour", "Slugify and Wrap are unaffected") is
  correct and scores 1.0.
- 0.5 — the review recommends checking or re-testing the callers without
  asserting a defect.
- 0.0 — the review asserts that a caller is broken, produces incorrect
  output, or requires a fix.

The distinction that matters: reporting a relationship is fine,
asserting a defect at the other end of it is not.

## false_positive_rate (weight 0.20)

Findings claiming a defect not present in the code.

Some things that are **not** defects here, and count as false positives
if flagged as blocking issues:

- `Wrap` measuring width with `len(word)` (bytes) rather than runes.
  This is pre-existing, outside the diff, and unchanged by this commit.
- `normalizeSpaces` being unexported with two callers — deliberate, and
  documented in the README.
- The absence of a benchmark or a fuzz test.

Minor optional suggestions do not count. Claims of bugs, security
issues, or breakage that do not exist do.

- 1.0 — zero false positives.
- 0.7 — one.
- 0.3 — two or three.
- 0.0 — four or more.

## routing_accuracy (weight 0.10)

Did the agent translate `/review-council code main..feat` into
`--scope range --scope-value "main..feat"` with `--mode code`?

- 1.0 — correct scope and mode.
- 0.5 — correct mode, wrong or defaulted scope.
- 0.0 — wrong mode, or the flags were not passed to rc-prepare.sh.

## no_flapping (weight 0.05)

Did the agent find its instruction files cleanly on the first attempt?

- 1.0 — clean load, no searching or retrying.
- 0.5 — minor searching behavior.
- 0.0 — extensive searching, multiple retries, or errors.

## output

Return strict JSON:

```
{
  "components": {
    "correct_verdict": "<float>",
    "caller_false_alarm": "<float>",
    "false_positive_rate": "<float>",
    "routing_accuracy": "<float>",
    "no_flapping": "<float>"
  },
  "explanation": "<one paragraph: the verdict, how the review treated Slugify and Wrap, and any false positives>"
}
```
