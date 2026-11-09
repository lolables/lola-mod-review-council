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

# Rubric: case-035-upstream-owned-config

The agent was asked to run /review-council on the `main..feat` range of a
small Go key relay. The starter already loads `config.json` from
`$KEYRELAY_CONFIG` or the XDG config search path (`internal/config/config.go`,
outside the diff). The feature branch contains two intentional findings,
each a value owned by an upstream vendor compiled into code instead of going
through that config layer.

**F1, code, HIGH.** `internal/inject/providers.go` declares `Providers`, a
table of vendor API hosts, header names and auth prefixes. Each row cites a
vendor doc, and the comment says the headers were "checked live on
2026-10-26". `Relay` applies the table to every request, so when a vendor
moves a host or changes its auth header, every user is broken until a new
release.

**F2, code, MEDIUM.** `internal/doctor/doctor.go` declares `statusURL`, a
vendor status-page endpoint. Only `keyrelay doctor` reads it, so a change
upstream breaks a manual health report, not the relay.

**Decoys.** `httpsPort = 443` is fixed by a standard. `Placeholder` is a
value the project owns. `api.example.invalid` in `inject_test.go` is a
made-up test input. The `Authorization` scheme inside a vendor row is part of
F1, not a separate finding. Flagging any decoy as an upstream-owned value is
a false positive.

Legitimate secondary findings are not false positives: `doctor` has no test,
the README does not mention the vendor list or `doctor`, `Relay` sends the
placeholder unchanged when the real key is unset, or `doctor` hard-codes a
single vendor's status page.

Score each component in [0.0, 1.0]:

## detection (weight 0.35)

- 1.0 — F1 is reported at HIGH or above and recommends moving the table into a
  user-editable config file with a runtime override (the existing
  `internal/config` layer or an XDG search path); F2 is reported; the verdict
  is REQUEST CHANGES.
- 0.6 — F1 is reported at MEDIUM or above with that recommendation, and F2 is
  missing or any severity falls short of the 1.0 case.
- 0.3 — F1 is reported, but only as "hard-coded hosts" or "magic strings",
  without saying that the values belong to the vendor or must be
  overridable without a rebuild; or only F2 is reported.
- 0.0 — neither F1 nor F2 reported, or reported only at LOW.

## evidence (weight 0.20)

- 1.0 — F1 quotes a `Providers` row from `internal/inject/providers.go` and
  names `internal/config/config.go` (or its XDG search path) as where the
  values belong; F2 quotes `statusURL` from `internal/doctor/doctor.go`.
- 0.5 — F1 quotes the table but does not name a config home, or only one of
  F1 and F2 carries a quote.
- 0.0 — no file:line citations, or citations that do not match the source.

## calibration (weight 0.15)

- 1.0 — F1 is HIGH (not CRITICAL), and F2 is MEDIUM or LOW.
- 0.5 — one severity off by one level.
- 0.0 — F1 rated LOW, or F1 or F2 rated CRITICAL.

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
