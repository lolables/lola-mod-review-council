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

# Rubric: case-033-go-producer-contract

The agent was asked to run /review-council on the `main..feat` range of a
small Go job runner. The feature branch contains one intentional flaw: a
**producer of the newly restricted input, outside the diff**.

**The flaw.** On `main`, `Validate` in `gate.go` refuses only `$(` and
backticks. The `feat` commit makes it refuse any `$` or backtick and adds
tests for the new denials, so the change looks complete and `go test`
passes. `Spec` in `internal/newjob/spec.go`, unchanged, renders the starter spec
for every new job with the step `archive "$OUT_DIR/result.json"`. `Run`
passes each step through `Validate`, so a job created from `gate new` now
fails at its archive step. No hunk of the diff shows `internal/newjob/spec.go`, and
`newjob.Spec` never calls `Validate`: the reviewer finds it only by searching
the repo for what emits commands the new rule rejects.

**The decoy.** `strings.ContainsAny(cmd, "$`")` matches every `$`, including
the one in `\$HOME` and in `${HOME}`. Claiming that an escaped `\$` or a
braced `${...}` expansion bypasses the check is a calibration failure.

Legitimate secondary findings are not false positives: no test runs
`newjob.Spec`'s output through `Run` or `Validate`, the README does not say
which characters `Validate` refuses, `Validate` only inspects the first word
of a multi-command line, or `Run` clears steps without executing them.

Score each component in [0.0, 1.0]:

## detection (weight 0.35)

Did the review identify that `newjob.Spec`'s output is now refused by
`Validate`?

- 1.0 — a finding names `newjob.Spec` (or `internal/newjob/spec.go`, or the starter spec's
  `archive "$OUT_DIR/result.json"` step) as rejected by the new `Validate`
  rule, rated HIGH or CRITICAL, and the verdict is REQUEST CHANGES.
- 0.6 — the same finding rated MEDIUM, or rated HIGH or CRITICAL with a
  verdict other than REQUEST CHANGES.
- 0.0 — not identified, or identified only at LOW. A finding that only says
  the new rule is strict, may break existing specs, or "callers may emit
  `$`", without naming `newjob.Spec` or the starter spec's step, does not count.
  A finding that calls `$OUT_DIR` in the starter spec an injection risk without
  saying that `Validate` now refuses it does not count.

## evidence (weight 0.20)

Does the finding show both halves of the break?

- 1.0 — cites `gate.go` with a quote of the new refusal (the
  `strings.ContainsAny` line) AND cites `internal/newjob/spec.go` with a quote of the
  `archive "$OUT_DIR/result.json"` step.
- 0.5 — cites only one of the two accurately, or names `newjob.Spec` and its
  `$OUT_DIR` step in prose without quoting the file.
- 0.0 — no file:line citation, or citations that do not match the source.

## calibration (weight 0.15)

Did the review avoid reporting an escape or braced form as bypassing
`Validate`?

- 1.0 — no finding claims `\$` or `${...}` evades the check.
- 0.0 — a finding makes that claim.

## false_positives (weight 0.15)

Did the review avoid fabricating other findings that do not exist in the
code? Do not count the decoy here — it is scored under calibration.

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
