---
rubric_version: "1"
pass_threshold: 0.6
weights:
  persona_coverage: 0.5
  evidence_quality: 0.3
  verdict_coherence: 0.2
---

# Rubric: case-005-py-meta

The agent was asked to run /review-council on a Python task queue library
with one issue intentionally planted for each of the six reviewer personas.
Score the review output.

The starter contains these intentional flaws, mapped to personas:

1. **Guard** — The README states "We deliberately avoid complex features
   like priority queues" but the `Worker` class accepts a `priority_levels`
   parameter. This contradicts the project's stated goals.
2. **Architect** — `worker.py` imports from `serializer.py`, and
   `serializer.py` imports from `queue.py`, while `worker.py` also
   imports `queue.py` — creating a circular dependency chain.
3. **Adversary** — `serializer.py` uses `pickle.loads()` on untrusted
   input, which allows arbitrary code execution.
4. **Tester** — All three tests in `test_queue.py` use `assert True`
   instead of asserting on actual values. The tests pass but verify nothing.
5. **SRE** — The Dockerfile has no `HEALTHCHECK`, runs as root (no
   non-root user), and has no resource considerations.
6. **Curator** — There is no API documentation, no changelog, and the
   README provides only a one-paragraph description with no usage examples.

Score three components, each in [0.0, 1.0]:

## persona_coverage (weight 0.5)

How many of the six personas produced findings targeting their
respective planted flaw?

The review report attributes findings to reviewer agents. Check
whether findings from the Guard, Architect, Adversary, Tester,
SRE, and Curator personas (or equivalently named agents) each
identified the flaw planted for them.

- 1.0 — all 6 personas produced relevant findings.
- 0.8 — 5 personas produced relevant findings.
- 0.6 — 4 personas produced relevant findings.
- 0.0 — 3 or fewer personas produced relevant findings.

## evidence_quality (weight 0.3)

Do the findings cite specific file and line references that match
the actual source code?

- 1.0 — all findings include file:line references that point to
  real code locations where the flaws exist.
- 0.5 — most findings cite file:line but some references are
  inaccurate or missing.
- 0.0 — no file:line references, or references are fabricated.

## verdict_coherence (weight 0.2)

Does the final verdict match the severity of the findings?

The starter has a critical security flaw (pickle deserialization)
and multiple medium-severity issues. The verdict should be REQUEST
CHANGES.

- 1.0 — verdict is REQUEST CHANGES, consistent with the critical
  findings.
- 0.0 — verdict is APPROVE despite critical security findings.

## output

Return strict JSON:

```
{
  "components": {
    "persona_coverage": <float>,
    "evidence_quality": <float>,
    "verdict_coherence": <float>
  },
  "explanation": "<one-paragraph rationale listing which personas contributed findings>"
}
```
