---
rubric_version: "1"
pass_threshold: 0.7
weights:
  correct_verdict: 0.40
  double_false_alarm: 0.25
  false_positive_rate: 0.20
  routing_accuracy: 0.10
  no_flapping: 0.05
---

# Rubric: case-041-test-double-fidelity

The agent was asked to run `/review-council code main..feat` on a small
Go account package. The branch adds `Registrar` (`service.go`), an
in-memory `fakeStore` (`fake_store_test.go`), and a contract suite
(`contract_test.go`) that runs against both `fakeStore` and the
production `FileStore`.

The test double is faithful to production:

- Cancelled context: `fakeStore.Create` and `Get` return `ctx.Err()`
  before touching state, as `FileStore` does.
- Uniqueness: both key on `normalizeEmail`, so `" ADA@example.com "`
  collides with `ada@example.com` in both.
- Errors: both return the same `ErrDuplicate` and `ErrNotFound`
  sentinels; neither swallows or rewrites them.
- The contract suite proves the above against both implementations.
- `go vet` and `go test ./...` are green.

The correct outcome is **APPROVE**. This case exists to catch a review
that over-reaches on test doubles: seeing a fake is not evidence that it
diverges from production.

Score each component in [0.0, 1.0]:

## correct_verdict (weight 0.40)

- 1.0 — the review verdict is APPROVE or APPROVE WITH ADVISORIES (or
  equivalent: "no issues found", "no changes requested"). Both are
  non-blocking; the council reserves REQUEST CHANGES for verified CRITICAL or
  HIGH findings, and this change has none.
- 0.0 — the review verdict is REQUEST CHANGES.

## double_false_alarm (weight 0.25)

Did the review claim that `fakeStore` diverges from `FileStore` or that
the tests give false confidence because of the double? Examples of a false
alarm: the fake does not reject a cancelled context, does not enforce
uniqueness, returns a different error than production, or the service
tests "only test the mock".

- 1.0 — no such claim. Noting factually that the fake mirrors production
  and is contract-tested is correct and scores 1.0.
- 0.5 — the review recommends verifying the fake against production
  without asserting a divergence (the contract suite already does this).
- 0.0 — the review asserts that the fake diverges from production, or
  that a test double hides a defect, with no such divergence present.

## false_positive_rate (weight 0.20)

Findings claiming a defect not present in the code.

Some things that are **not** defects here, and count as false positives
if flagged as blocking issues:

- `FileStore` rewriting the whole JSON file on every `Create`. This is
  pre-existing, outside the diff, and unchanged by this commit.
- `fakeStore` being defined in a `_test.go` file rather than exported.
- The absence of a benchmark, fuzz test, or concurrency stress test.

Minor optional suggestions do not count. Claims of bugs, security
issues, or breakage that do not exist do.

- 1.0 — zero false positives.
- 0.7 — one.
- 0.3 — two or three.
- 0.0 — four or more.

## routing_accuracy (weight 0.10)

Did the agent translate `/review-council code main..feat` into
`--scope range --scope-value "main..feat"` with `--mode code`?

- 1.0 — correct scope and mode.
- 0.5 — correct mode, wrong or defaulted scope.
- 0.0 — wrong mode, or the flags were not passed to rc-prepare.sh.

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
    "double_false_alarm": "<float>",
    "false_positive_rate": "<float>",
    "routing_accuracy": "<float>",
    "no_flapping": "<float>"
  },
  "explanation": "<one paragraph: the verdict, how the review treated fakeStore, and any false positives>"
}
```
