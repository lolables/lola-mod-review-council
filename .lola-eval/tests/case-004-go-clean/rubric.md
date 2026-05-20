---
rubric_version: "1"
pass_threshold: 0.7
weights:
  correct_verdict: 0.6
  false_positive_rate: 0.4
---

# Rubric: case-004-go-clean

The agent was asked to run /review-council on a well-written Go
library. The code is idiomatic, well-tested, and well-documented.
There are no security issues, no architectural problems, and no
significant code quality concerns.

The review should produce an APPROVE verdict with zero or very
few findings.

Score two components, each in [0.0, 1.0]:

## correct_verdict (weight 0.6)

Did the review produce the correct verdict?

- 1.0 — the review verdict is APPROVE (or equivalent: "no issues
  found", "code looks good", "no changes requested").
- 0.0 — the review verdict is REQUEST CHANGES.

## false_positive_rate (weight 0.4)

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

## output

Return strict JSON:

```
{
  "components": {
    "correct_verdict": <float>,
    "false_positive_rate": <float>
  },
  "explanation": "<one-paragraph rationale listing any false positives found>"
}
```
