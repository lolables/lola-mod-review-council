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

# Rubric: case-007-go-fail-open

The agent was asked to run /review-council on the `main..feat` range of
a small Go feature-flag service. The feature branch contains one
intentional flaw, a **fail-open default**: a value that, when absent,
loosens behaviour instead of denying.

**The flaw.** On `main`, `Load` in `config.go` refuses to start unless
`admin_key` is at least 32 bytes, and `newMux` in `handlers.go` passes
that one key to `requireKey`. The `feat` commit replaces it with an
`admin_keys` list: `newMux` now calls `requireKey(cfg.AdminKeys, ...)`
unconditionally, and `Load` checks the length of each entry but never
that the list is present. `requireKey` in `auth.go` — unchanged and
outside the diff — passes every request through when `len(keys) == 0`.
So when `admin_keys` is absent, empty or `null` — and
`config.example.json` omits it — `PUT /admin/flags/{name}` accepts
unauthenticated requests. The README states that admin endpoints
require a bearer key, so this permissive default is neither documented
nor intentional.

**The decoy.** `allowed_origins` is also optional, but an empty list
fails closed: `withCORS` sets `Access-Control-Allow-Origin` only for a
listed origin, so with no list no origin may read the response
cross-origin. Calling the empty `allowed_origins` a fail-open default
is a calibration failure.

Legitimate secondary findings are not false positives: renaming
`admin_key` breaks existing configs (`DisallowUnknownFields` rejects
the old key), no tests, no graceful shutdown, in-memory state lost on
restart, unbounded flag count, or the README not saying what happens
when `admin_keys` is missing.

Score each component in [0.0, 1.0]:

## detection (weight 0.35)

Did the review identify that a missing, empty or null `admin_keys`
leaves the admin endpoint unauthenticated?

- 1.0 — identified, rated HIGH or CRITICAL, and the verdict is REQUEST
  CHANGES.
- 0.6 — identified, but rated MEDIUM or LOW, or the verdict is not
  REQUEST CHANGES.
- 0.0 — not identified. A finding that only says "admin auth is weak"
  or "keys should be rotated", without naming the absent-list case,
  does not count. Neither does a finding that only notes `requireKey`
  passes through on no keys without connecting it to the change making
  that reachable.

## evidence (weight 0.20)

Does the finding show where the default comes from?

- 1.0 — cites the `len(keys) == 0` pass-through in `auth.go`
  `requireKey` AND the `config.go` `Load` code showing there is no
  default or presence check for `admin_keys` (or equivalent: a stated
  search proving no default exists).
- 0.5 — cites one of the two locations accurately.
- 0.0 — no file:line citation, or citations that do not match the
  source.

## calibration (weight 0.15)

Did the review avoid reporting the fail-closed `allowed_origins` as a
fail-open default?

- 1.0 — no finding claims an empty `allowed_origins` permits any
  origin or otherwise widens access.
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
