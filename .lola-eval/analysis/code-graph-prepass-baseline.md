# Code-graph pre-pass — baseline arm, three runs

**Date:** 2026-08-23
**Branch:** `test/codegraph-prepass-eval`
**Decision record:** `code-graph-prepass-decision.md` (same directory)
**Run:** `task lola-eval:test-graph` ×3, claude-code / claude-sonnet-4-6

## Result: reject — the gap this design targets is not there

The baseline arm — no graph, Review Council as shipped — passes all three cases
in all three runs. Cases 030 and 031 were written expecting a *low* baseline.

| Case | Run 1 | Run 2 | Run 3 | Median | Threshold |
|------|-------|-------|-------|--------|-----------|
| `case-030-graph-caller-breakage` | 1.00 | 1.00 | 1.00 | **1.00** | 0.60 |
| `case-031-graph-untested-change` | 0.91 | 0.90 | 0.83 | **0.90** | 0.60 |
| `case-032-graph-noise-canary` | 0.88 | 1.00 | 1.00 | **1.00** | 0.70 |

Spread is 0.00 / 0.08 / 0.12, all inside the `tolerance: 0.15` noise floor
`config.yaml` documents. Nine cells, ~$40, ~2.7 hours.

## Per-component, across all three runs

```
case-030   caller_identification   1.00  1.00  1.00
           unit_regression         1.00  1.00  1.00
           evidence_grounding      1.00  1.00  1.00
           false_positives         1.00  1.00  1.00

case-031   burst_inconsistency     1.00  1.00  1.00
           missing_test_identified 1.00  1.00  1.00
           orphan_function_ident.  0.50  0.50  0.00   <-- never once reached
           evidence_grounding      0.80  1.00  0.80
           false_positives         1.00  1.00  1.00

case-032   correct_verdict         1.00  1.00  1.00
           false_positive_rate     1.00  1.00  1.00
           caller_false_alarm      0.50  1.00  1.00
```

Two components tell the whole story, and they point opposite ways.

### The premise does not hold: `caller_identification` 1.00 ×3

The council already reaches outside the diff. On case-030 it named three of the
four affected files, caught the minor-to-major unit inversion *with* its
consequence, and found two defects the case never planted (README contract
drift, a `parseAmount` round-trip break). On case-031 it reported "no
`quota_test.go` exists" — the finding the case was built assuming it would
miss — in all three runs.

It gets there by reading the files: 118 tool calls on case-030, 42 of them
`Read`, 23.5 minutes, $5.25. Expensive, but it works, and it works every time.

### The one apparent gap was a defect in this rubric — corrected

`orphan_function_identified` scored 0.50, 0.50, 0.00, and the first draft of
this analysis read that as the single finding class a graph would add. That was
wrong, and the transcripts say so.

The reviewers **did** search for the symbol — 7, 13 and 18 caller searches
across the three runs, including `grep -rn 'NewQuotaWithBurst' *_test.go`. They
found the absence. They declined to call it a defect, and instead reported:

```
run 1  HIGH      Consume ignores q.burst, contradicting NewQuotaWithBurst's contract
       HIGH      NewQuotaWithBurst and the burst branch have zero test coverage
run 2  HIGH      Consume() gates on q.limit alone while Remaining() reports limit+burst
       HIGH      no quota_test.go exists, zero grep hits for NewQuotaWithBurst in any test
run 3  CRITICAL  Consume() checks only q.limit; burst permanently inaccessible
       HIGH      NewQuotaWithBurst doc comment promises drawdown Consume never implements
```

**That judgement is correct and the rubric's was not.** `NewQuotaWithBurst` is
an exported constructor in a library package. Exported API routinely has no
internal caller; `limiter.go` continuing to call `NewQuota` is a design choice,
not dead code. Reporting "this function has no callers" as a defect would have
been a false positive, and `reviewer-protocol.md` "Proportionality" tells
reviewers not to manufacture one.

The component has been inverted to `exported_api_calibration`, which now scores
whether the review *avoids* that over-flag. Rescoring the same three runs
against the corrected rubric — no re-run needed, the finding lists are on
record and agent behaviour is unchanged:

| Run | Old | Corrected |
|-----|-----|-----------|
| 1 | 0.91 | **0.980** |
| 2 | 0.90 | **0.975** |
| 3 | 0.83 | **0.980** |

Median 0.90 → **0.98**, spread 0.08 → 0.005.

### What the probes actually showed

The graph does return the facts, quickly:

```
$ codegraph init .          # 13 files, 66 nodes, 139 edges in 172ms
$ codegraph callers NewQuotaWithBurst --json
{ "symbol": "NewQuotaWithBurst", "callers": [] }

$ codegraph callers formatAmount --json | jq -r '[.callers[].filePath]|unique'
["src/checkout.ts", "src/currency.test.ts", "src/invoice.ts", "src/report.ts"]
```

4 of 4 caller files on case-030, where the council named 3, from a 143ms index
occupying 252 KB.

But `callers → []` is a **true fact that should not have become a finding
here**. The graph supplies structure with no judgement about whether it
matters, and the single place the council "failed" this rubric is precisely
where its judgement beat the rubric's. That is the strongest argument against
the pre-pass in this document: what it adds is raw structural facts into a
pipeline whose measured weakness — `caller_false_alarm` 0.50 in one run of
case-032 — is already over-reaching from structural facts.

## The call: do not build `rc-graph.sh`

Against the rule fixed before the run — *adopt only on net-new verified findings
in the cross-file classes* — the rule is **not met at all**. Every cross-file
component scores 1.00 across three runs once the rubric defect is corrected.
There is no finding class left for a treatment arm to win.

And the cost is unchanged:

- A HARD-GATE carve-out to execute a third-party indexer over attacker-authored
  checkouts, plus a write into the checkout (`codegraph index` has no
  out-of-tree index location).
- A dependency with telemetry on by default, pointed at arbitrary third-party
  pull requests.
- `rc-graph.sh`, an artifact schema, an extension point, and `delegate.md`
  changes to maintain.
- A false-positive risk pointing the wrong way: `caller_false_alarm` hit 0.50 in
  run 1 because the council recommended re-testing callers rather than noting
  them unaffected. Handing reviewers a caller list makes caller-directed
  recommendations *more* likely, not less.

### The "tighten the grep rule" alternative was also investigated, and dropped

The first draft of this analysis proposed narrowing
`references/reviewer-protocol.md:40` ("functions added but never called within
changeset") to name exported symbols and point at a `grep -rn` for callers.

That proposal rested on the assumption that reviewers were not searching. They
were: 7, 13 and 18 caller searches across the three runs, including a targeted
`grep -rn 'NewQuotaWithBurst' *_test.go`. Two rules already cover this ground —
`reviewer-protocol.md:40` and `divisor-guard-code.md`'s Zero-Waste Mandate
("Orphaned functions, types, or constants nothing references?") — and both
behaved correctly by not firing.

**No change to `reviewer-protocol.md` is warranted.** Tightening either rule
would push reviewers toward reporting zero-caller exported API as dead code,
which is the false positive `exported_api_calibration` now guards against.
Nothing to do here.

## Caveats

1. **The treatment arm was never run.** This measures the size of the gap and
   confirms codegraph can supply the missing facts; it does not measure a
   pre-pass end to end.
2. **The judge saw 29-57% of each transcript.** Mitigated by reading the finding
   lists directly out of the transcripts, which corroborate the composites.
3. **Cost and latency were not the metric.** The council spends $3.64-5.25 and
   12-23 minutes per review, much of it on file reads a graph could short-cut.
   The pre-registered rule rejects a cost-only win, so this cannot rescue
   adoption — but it is a real question that this eval did not answer, and it is
   the one angle on which the decision could reasonably be revisited.
4. **Small fixtures.** 12-13 files. Index cost on a large repository is
   unmeasured.
