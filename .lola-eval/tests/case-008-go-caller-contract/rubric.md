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

# Rubric: case-008-go-caller-contract

The agent was asked to run /review-council on the `main..feat` range of
a small Go per-tenant quota service. The feature branch contains one
intentional flaw: a **broken caller contract in unchanged lines of a
changed file**.

**The flaw.** On `main`, `Lookup` in `quota.go` returns `&defaultQuota`
for a tenant with no quota configured. The `feat` commit changes it to
return `nil` instead, deletes `defaultQuota`, and updates
`TestLookupUnknown` to expect `nil`, so the change looks complete and
`go test` passes. `Allow`, further down the same file and unchanged,
still does `q := Lookup(tenant)` followed by `return used < q.Limit`.
For any tenant not in `quotas`, `Allow` now dereferences a nil pointer
and panics, so any request carrying an unconfigured tenant crashes the
caller. No hunk of the diff, context lines included, shows `Allow`:
the reviewer finds it only by reading the rest of `quota.go`.

**The decoy.** `Lookup` returns `&q`, where `q` is the value copied out
of the map. In Go that is safe: `q` escapes to the heap, and callers get
a private copy, so they can neither read freed memory nor mutate the
shared `quotas` map through it. Claiming `&q` is a dangling pointer, a
pointer to a loop or stack variable that goes stale, or an alias that
lets callers modify `quotas` is a calibration failure.

Legitimate secondary findings are not false positives: no test covers
`Allow` with an unconfigured tenant, the README does not say what
`Lookup` returns for an unknown tenant, quotas are hard-coded, `used`
is caller-reported and unchecked, or `Summary` and `formatLimit` have
thin coverage.

Score each component in [0.0, 1.0]:

## detection (weight 0.35)

Did the review identify that `Allow` dereferences `Lookup`'s now-nil
result for an unconfigured tenant?

- 1.0 — a finding names `Allow` (or its nil dereference of `Lookup`'s
  result) in `quota.go`, rated HIGH or CRITICAL, and the verdict is
  REQUEST CHANGES.
- 0.6 — the same finding rated MEDIUM, or rated HIGH or CRITICAL with a
  verdict other than REQUEST CHANGES.
- 0.0 — not identified, or identified only at LOW. A finding that only
  says the `Lookup` change is wrong or risky, or that "callers may not
  handle nil", without naming `Allow`, does not count.

## evidence (weight 0.20)

Does the finding show the dereference?

- 1.0 — cites `quota.go` with a quote from `Allow`'s body (the
  `Lookup(tenant)` call or `q.Limit`) AND the `return nil` in `Lookup`.
- 0.5 — cites `Allow`'s body accurately but not the `return nil`, or
  cites the `return nil` and names `Allow` without quoting its body.
- 0.0 — no file:line citation, or citations that do not match the
  source.

## calibration (weight 0.15)

Did the review avoid reporting `return &q` in `Lookup` as unsafe?

- 1.0 — no finding claims `&q` dangles, goes stale, or lets callers
  mutate `quotas`.
- 0.0 — a finding makes that claim.

## false_positives (weight 0.15)

Did the review avoid fabricating other findings that do not exist in
the code? Do not count the decoy here — it is scored under
calibration.

- 1.0 — zero fabricated findings.
- 0.5 — one fabricated finding.
- 0.0 — two or more fabricated findings.

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
