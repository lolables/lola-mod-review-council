---
rubric_version: "1"
pass_threshold: 0.8
weights:
  planted_recall: 0.6
  triage_disclosure: 0.2
  invariants_held: 0.1
  no_flapping: 0.1
---

# Rubric: case-026-triage-recall

The agent ran `/review-council deep main..feat --triage` over a five-subsystem
changeset holding five planted defects. Each defect sits in the subsystem where
a naive triage is most likely to route its lens away.

The pass threshold is **0.8**, higher than the routing cases, and
`planted_recall` alone is weighted 0.6 — a run cannot pass on good bookkeeping
about a review that lost a defect. That is the point of the case: triage is
off by default until it demonstrates it does not cost recall.

## planted_recall (weight 0.6)

Five defects were planted, one per subsystem, one per lens. Score
`found / 5`, counting a defect as found when a finding names the right file
and describes the right problem. Severity need not match.

| # | File | Defect | Lens it belongs to |
|---|------|--------|--------------------|
| 1 | `web/templates/render.go` | `template.HTML(userSuppliedBody)` disables escaping on user input — stored XSS | Adversary |
| 2 | `deploy/ci.yml` | `go test ./... \|\| true` — a failing test can never fail the build | Tester |
| 3 | `pkg/store/store.go` | `Purge` permanently deletes records while `README.md` still states records are never removed | Curator |
| 4 | `pkg/metrics/counter.go` | `byPath` grows one entry per distinct request path, never evicted — unbounded memory from client-controlled keys | Operator |
| 5 | `pkg/legacy/oldstore.go` | duplicates `pkg/store` wholesale and is reachable from nothing | Guard |

Partial credit within a defect is not given: a finding that flags
`web/templates/render.go` for style without identifying the escaping problem
does not count as #1.

**Record which of the five were missed, and whether the triage matrix had
excluded that lens from that subsystem.** A miss on a cell triage excluded is
the failure this case exists to detect. A miss on a cell that WAS dispatched is
a reviewer limitation, not a triage regression, and belongs in the explanation
so the two are never confused.

## triage_disclosure (weight 0.2)

Did the run report what triage did, without ever presenting a narrowed review
as full coverage?

- 1.0 — `TRIAGE_APPLIED` is answered, every excluded persona/subsystem pair is
  named with its reason, and the report or comment shows the skipped reviewers
  rather than implying all five ran everywhere.
- 0.5 — triage is acknowledged but the excluded pairs are not enumerated, or
  the reasons are absent.
- 0.0 — the run reads as a full-coverage review, or claims triage did nothing
  when the session artifacts say otherwise.

## invariants_held (weight 0.1)

`rc-apply-triage.sh` must never let triage remove a lens from the review, take
a subsystem below two reviewers, or route away a reviewer holding an open
finding.

- 1.0 — every persona appears in at least one subsystem's council, and every
  subsystem has at least two reviewers, per the session manifest.
- 0.0 — either invariant is violated in the artifacts. This is a defect in the
  script, not in the agent, and should be reported as such.

## no_flapping (weight 0.1)

Did the agent find its instruction files cleanly and pass `--triage` without
retrying?

- 1.0 — clean load, `--triage` passed on the first `rc-prepare.sh` call.
- 0.5 — minor searching, or triage enabled on a second attempt.
- 0.0 — extensive searching, or triage never enabled at all (which makes
  `planted_recall` a measurement of something else — say so in the
  explanation).

## output

Return strict JSON:

```json
{
  "components": {
    "planted_recall": <float>,
    "triage_disclosure": <float>,
    "invariants_held": <float>,
    "no_flapping": <float>
  },
  "missed_defects": [
    {"id": <int>, "file": "<path>", "lens": "<persona>", "triage_excluded_this_cell": <true|false>}
  ],
  "explanation": "<one-paragraph rationale>"
}
```
