---
rubric_version: "1"
pass_threshold: 0.7
weights:
  correct_verdict: 0.51
  false_positive_rate: 0.34
  routing_accuracy: 0.10
  no_flapping: 0.05
---

# Rubric: case-004-go-clean

The agent was asked to run /review-council on a well-written Go
library. The code is idiomatic, well-tested, and well-documented.
There are no security issues, no architectural problems, and no
significant code quality concerns.

The review should produce an APPROVE verdict with zero or very
few findings.

Score two components, each in [0.0, 1.0]:

## correct_verdict (weight 0.51)

Did the review produce the correct verdict?

- 1.0 — the review verdict is APPROVE (or equivalent: "no issues
  found", "code looks good", "no changes requested").
- 0.0 — the review verdict is REQUEST CHANGES.

## false_positive_rate (weight 0.34)

How many spurious findings were reported?

A "spurious finding" is a reported issue that does not reflect a
real problem in the code. Minor style suggestions or optional
improvements (e.g., "consider adding benchmarks") are acceptable
and do not count as false positives. Findings that claim bugs,
security issues, or architectural problems that do not exist are
false positives.

- 1.0 — zero false positives.
- 0.7 — one minor false positive (e.g., claiming a nonexistent
  concurrency bug or a security issue that is not present).
- 0.3 — two or three false positives.
- 0.0 — four or more false positives.

## routing_accuracy (weight 0.10)

Did the agent correctly interpret `/review-council code` and pass
`--mode code` to rc-prepare.sh?

- 1.0 — the agent used code mode.
- 0.0 — the agent used specs mode or failed to set the mode.

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
    "false_positive_rate": "<float>",
    "routing_accuracy": "<float>",
    "no_flapping": "<float>"
  },
  "explanation": "<one-paragraph rationale listing any false positives found>"
}
```
