---
rubric_version: "1"
pass_threshold: 0.6
weights:
  persona_coverage: 0.425
  evidence_quality: 0.255
  verdict_coherence: 0.17
  routing_accuracy: 0.10
  no_flapping: 0.05
---

# Rubric: case-005-py-meta

The agent was asked to run /review-council on a Python task queue library
with one issue intentionally planted for each of the five reviewer personas.
Score the review output.

The starter contains these intentional flaws, mapped to personas:

1. **Guard** — The README states "We deliberately avoid complex features
   like priority queues" but the `Worker` class accepts a `priority_levels`
   parameter. This contradicts the project's stated goals. Additionally,
   `worker.py` imports from `serializer.py`, and `serializer.py` imports
   from `queue.py`, while `worker.py` also imports `queue.py` — creating
   a circular dependency chain (structural coherence concern).
2. **Adversary** — `serializer.py` uses `pickle.loads()` on untrusted
   input, which allows arbitrary code execution.
3. **Tester** — All three tests in `test_queue.py` use `assert True`
   instead of asserting on actual values. The tests pass but verify nothing.
4. **SRE** — The Dockerfile has no `HEALTHCHECK`, runs as root (no
   non-root user), and has no resource considerations.
5. **Curator** — There is no API documentation, no changelog, and the
   README provides only a one-paragraph description with no usage examples.

Score three components, each in [0.0, 1.0]:

## persona_coverage (weight 0.425)

How many of the five personas produced findings targeting their
respective planted flaw?

The review report attributes findings to reviewer agents. Check
whether findings from the Guard, Adversary, Tester, SRE, and
Curator personas (or equivalently named agents) each identified
the flaw planted for them.

- 1.0 — all 5 personas produced relevant findings.
- 0.8 — 4 personas produced relevant findings.
- 0.6 — 3 personas produced relevant findings.
- 0.0 — 2 or fewer personas produced relevant findings.

## evidence_quality (weight 0.255)

Do the findings cite specific file and line references that match
the actual source code?

- 1.0 — all findings include file:line references that point to
  real code locations where the flaws exist.
- 0.5 — most findings cite file:line but some references are
  inaccurate or missing.
- 0.0 — no file:line references, or references are fabricated.

## verdict_coherence (weight 0.17)

Does the final verdict match the severity of the findings?

The starter has a critical security flaw (pickle deserialization)
and multiple medium-severity issues. The verdict should be REQUEST
CHANGES.

- 1.0 — verdict is REQUEST CHANGES, consistent with the critical
  findings.
- 0.0 — verdict is APPROVE despite critical security findings.

## routing_accuracy (weight 0.10)

Did the agent correctly interpret `/review-council code HEAD` and
pass `--mode code --scope range --scope-value "HEAD~1..HEAD"` (or
equivalent)?

- 1.0 — the agent used code mode AND scoped to the latest commit.
- 0.5 — one of mode or scope was correctly applied but not both.
- 0.0 — neither mode nor scope was correctly applied.

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
    "persona_coverage": "<float>",
    "evidence_quality": "<float>",
    "verdict_coherence": "<float>",
    "routing_accuracy": "<float>",
    "no_flapping": "<float>"
  },
  "explanation": "<one-paragraph rationale listing which personas contributed findings>"
}
```
