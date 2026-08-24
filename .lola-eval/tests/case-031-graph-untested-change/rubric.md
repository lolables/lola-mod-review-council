---
rubric_version: "1"
pass_threshold: 0.6
weights:
  missing_test_identified: 0.35
  burst_inconsistency: 0.20
  exported_api_calibration: 0.15
  evidence_grounding: 0.10
  routing_accuracy: 0.10
  false_positives: 0.05
  no_flapping: 0.05
---

# Rubric: case-031-graph-untested-change

The agent was asked to run `/review-council code main..feat` on a Go
rate-limiting package. The branch rewrites `quota.go` and nothing else,
adding a burst allowance.

The package's test layout matters:

| Source       | Test file          |
|--------------|--------------------|
| `bucket.go`  | `bucket_test.go`   |
| `window.go`  | `window_test.go`   |
| `limiter.go` | `limiter_test.go`  |
| `quota.go`   | **none**           |

Two defects are available — one inside the diff, one outside it — plus a
calibration check on a fact that looks like a defect and is not. Score
each component in [0.0, 1.0]:

## missing_test_identified (weight 0.35)

Did the review flag that the changed file has no covering test?

- 1.0 — the review states that `quota.go` has no test file and notes
  that its siblings do, or otherwise makes clear the gap is specific to
  this file rather than a general "add more tests" remark.
- 0.6 — the review states that the new burst behaviour is untested,
  without observing that `quota.go` has no test file at all.
- 0.3 — the review makes a generic recommendation to add tests, with no
  reference to what is or is not currently covered.
- 0.0 — test coverage is not mentioned.

A generic "consider adding tests" scores 0.3. The finding this case
measures is the specific one: this file, unlike its siblings, has none.

## burst_inconsistency (weight 0.20)

This is the control — it is visible in the diff and both arms should
find it.

`Remaining` computes `total := q.limit + q.burst` and reports against
that. `Consume` still refuses anything past `q.limit`. With a non-zero
burst, `Remaining` reports capacity that `Consume` will reject.

- 1.0 — the review identifies that the two methods disagree about
  whether burst counts, and names the consequence.
- 0.5 — the review notes that `Consume` was not updated for burst, or
  that `q.burst` is read in only one of the two methods, without
  connecting it to the over-report.
- 0.0 — not identified.

## exported_api_calibration (weight 0.15)

`NewQuotaWithBurst` is exported and has zero callers anywhere in the
repository. **That is not, on its own, a defect.** It is a public
constructor in a library package; exported API routinely has no internal
caller, and `limiter.go` continuing to call `NewQuota` is a design
choice, not dead code.

This component scores whether the review kept that distinction.

- 1.0 — the review does not present the absence of callers as a defect.
  Citing it as *supporting* evidence for a real finding is correct and
  scores 1.0: "no test exercises this constructor" and "`Consume` never
  honours the burst this constructor accepts" are both grounded uses of
  the same fact.
- 0.5 — the review raises the zero-caller fact as a standalone concern
  without asserting a defect ("consider whether this constructor is
  needed").
- 0.0 — the review reports `NewQuotaWithBurst` as dead code, unused, or
  requiring removal on the strength of having no callers.

### Why this component is inverted

It was originally written the other way round — awarding 1.0 for
reporting "this function has no callers" — and all three baseline runs
scored 0.50 or 0.00 against it. Reading the transcripts showed the
reviewers had grepped for the symbol (7, 13 and 18 caller searches
across the three runs), found the absence, and correctly declined to
call it a defect, reporting the missing test and the `Consume`
contradiction instead.

The original component asked for a false positive. It now guards
against one, which is the more useful thing for this suite to measure:
handing a reviewer a caller list makes exactly this over-flag more
likely. See `.lola-eval/analysis/code-graph-prepass-baseline.md`.

## evidence_grounding (weight 0.10)

The missing test is an **absence** claim, which
`references/reviewer-protocol.md` governs specifically: the search
performed goes in the description, and the evidence must be a verbatim
quote of the present code whose counterpart is missing.

- 1.0 — absence findings quote real present code (the untested function,
  the `NewQuota` call in `limiter.go`) and describe the search that
  established the absence.
- 0.5 — absence findings are asserted with a quote but no search, or
  with a search transcript pasted into the evidence field.
- 0.0 — absence findings cite files or symbols that do not exist, or
  quote code not present in the named file.

Score 1.0 by default when the review made no absence findings — that is
already penalised above and should not be counted twice.

## routing_accuracy (weight 0.10)

Did the agent translate `/review-council code main..feat` into
`--scope range --scope-value "main..feat"` with `--mode code`?

- 1.0 — correct scope and mode.
- 0.5 — correct mode, wrong or defaulted scope.
- 0.0 — wrong mode, or the flags were not passed to rc-prepare.sh.

## false_positives (weight 0.05)

Findings that claim a defect not present in the code.

The package is otherwise sound: the mutex discipline is correct, the
clamping in `NewQuota` is deliberate, and `Reset` deleting the map entry
rather than zeroing it is intentional. Claims of a race, a nil map
panic, or a leak in these are false positives.

- 1.0 — zero false positives.
- 0.6 — one.
- 0.3 — two or three.
- 0.0 — four or more.

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
    "missing_test_identified": "<float>",
    "burst_inconsistency": "<float>",
    "exported_api_calibration": "<float>",
    "evidence_grounding": "<float>",
    "routing_accuracy": "<float>",
    "false_positives": "<float>",
    "no_flapping": "<float>"
  },
  "explanation": "<one paragraph: which defects were found, how the absence claims were grounded, whether the zero-caller fact was used as support or misreported as a defect>"
}
```
