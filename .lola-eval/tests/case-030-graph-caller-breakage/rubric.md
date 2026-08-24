---
rubric_version: "1"
pass_threshold: 0.6
weights:
  caller_identification: 0.40
  unit_regression: 0.25
  evidence_grounding: 0.15
  routing_accuracy: 0.10
  false_positives: 0.05
  no_flapping: 0.05
---

# Rubric: case-030-graph-caller-breakage

The agent was asked to run `/review-council code main..feat` on a
TypeScript billing package. The branch rewrites `src/currency.ts` and
nothing else.

`formatAmount` changed in two breaking ways at once:

1. **Units.** It used to take minor units (cents) and divide by 100
   internally. It now takes major units and hands the value straight to
   `Intl.NumberFormat`. Callers still pass cents, so every rendered
   amount is inflated 100x.
2. **Arity.** A third required parameter, `locale`, was added. Every
   existing call site passes two arguments, which under
   `"strict": true` is a compile error.

Four files break, and **none of them are in the diff**:

| File                   | Broken calls |
|------------------------|--------------|
| `src/checkout.ts`      | 3            |
| `src/invoice.ts`       | 2            |
| `src/report.ts`        | 3            |
| `src/currency.test.ts` | 6 assertions |

This case measures whether the review reaches outside the changeset. A
low score means the review stayed inside the diff — that is a valid
measurement, not a broken case.

Score each component in [0.0, 1.0]:

## caller_identification (weight 0.40)

Did the review identify the specific call sites that break, by file?

Count the distinct files among `src/checkout.ts`, `src/invoice.ts`,
`src/report.ts` and `src/currency.test.ts` that the review names in a
finding as containing a now-broken call.

- 1.0 — three or four of them named.
- 0.7 — two named.
- 0.4 — one named.
- 0.2 — the review states that unnamed callers elsewhere must be
  updated, without naming any file.
- 0.0 — no mention that anything outside `src/currency.ts` is affected.

A generic recommendation to "update all call sites" with no file named
scores 0.2, not higher. Naming a file that does not call `formatAmount`
does not count toward the tally.

## unit_regression (weight 0.25)

Did the review catch the minor-units-to-major-units semantic change?

- 1.0 — the review states that callers pass minor units while the new
  signature expects major units, and identifies the consequence
  (amounts inflated by 100x, or equivalent).
- 0.6 — the review notes the parameter was renamed `cents` to `amount`
  and flags the meaning as changed, without stating the consequence.
- 0.3 — the review flags only the arity change (the added `locale`
  parameter) and misses the unit change entirely.
- 0.0 — neither breaking change is identified.

The arity change is the easier of the two and is visible in the diff
alone. The unit change is the one that requires reading a caller.

## evidence_grounding (weight 0.15)

For findings that cite a file outside the diff, is the evidence a
verbatim quote from that file?

- 1.0 — every out-of-diff citation quotes real code from the file it
  names.
- 0.5 — at least one out-of-diff citation is paraphrased, or quotes
  code that does not appear in the named file.
- 0.0 — out-of-diff files are named with no supporting quote at all, or
  quoted code is fabricated.

Score 1.0 by default when the review made no out-of-diff citations —
the absence is already penalised under `caller_identification`, and
double-counting it here would distort the weighting.

## routing_accuracy (weight 0.10)

Did the agent translate `/review-council code main..feat` into
`--scope range --scope-value "main..feat"` with `--mode code`?

- 1.0 — correct scope and mode.
- 0.5 — correct mode, wrong or defaulted scope.
- 0.0 — wrong mode, or the flags were not passed to rc-prepare.sh.

## false_positives (weight 0.05)

Findings that claim a defect not present in the code.

Note that `SYMBOLS` becoming write-only in the new `currency.ts` (it is
consulted only through `hasOwnProperty`) is a **real** observation, not
a false positive. So is the loss of the negative-number formatting that
the old implementation handled explicitly.

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
    "caller_identification": "<float>",
    "unit_regression": "<float>",
    "evidence_grounding": "<float>",
    "routing_accuracy": "<float>",
    "false_positives": "<float>",
    "no_flapping": "<float>"
  },
  "explanation": "<one paragraph: which of the four affected files were named, whether the unit change was caught, and any false positives>"
}
```
