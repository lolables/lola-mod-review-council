---
rubric_version: "1"
pass_threshold: 0.6
weights:
  coverage: 0.4
  structure: 0.3
  cross_agent_dedup: 0.3
---

# Rubric: case-003-py-mixed

The agent was asked to run /review-council on a Python data processing
library with seven intentional flaws. Score the review output.

The starter contains these intentional flaws:

1. **Arbitrary code execution** — `run_user_transform` in `pipeline.py`
   calls `eval()` on user-supplied code.
2. **Off-by-one error** — `process_batch` in `pipeline.py` uses
   `range(0, len(records) - 1)` which skips the last record.
3. **No tests** — there is no `tests/` directory or any test files.
4. **Mutable default argument** — `_apply_defaults` in `pipeline.py` uses
   a mutable dict `{"status": "pending", "tags": []}` as a default
   parameter.
5. **Broad exception swallow** — `safe_load` in `pipeline.py` catches all
   exceptions with bare `except:` and silently returns `None`.
6. **No type hints** — no public function in either module has type
   annotations.
7. **Missing `__init__.py` exports** — `__init__.py` is effectively empty
   with no `__all__` or re-exports of the public API.

Score three components, each in [0.0, 1.0]:

## coverage (weight 0.4)

How many of the seven flaws were identified in the review?

- 1.0 — 6 or more flaws identified.
- 0.7 — 4 or 5 flaws identified.
- 0.4 — 2 or 3 flaws identified.
- 0.0 — 0 or 1 flaw identified.

## structure (weight 0.3)

Is the review consistently structured?

- 1.0 — every finding has a consistent format (summary, severity,
  file/line reference, and suggested fix or recommendation).
- 0.6 — most findings follow a consistent format but some are
  incomplete or inconsistent.
- 0.0 — the review is unstructured prose, or findings use wildly
  different formats.

## cross_agent_dedup (weight 0.3)

Did the verification phase successfully deduplicate overlapping findings
from different agents? Multiple agents (adversary, architect, testing)
may independently flag the same issue (e.g., both adversary and testing
agents might flag the missing tests, or both adversary and architect
might flag the eval() usage).

- 1.0 — no duplicate findings. Each issue appears exactly once in the
  final report even if multiple agents would have flagged it.
- 0.5 — 1 or 2 issues appear in the report from multiple agents
  (clearly the same underlying problem described twice).
- 0.0 — 3 or more clearly duplicated findings in the final report.

## output

Return strict JSON:

```
{
  "components": {
    "coverage": <float>,
    "structure": <float>,
    "cross_agent_dedup": <float>
  },
  "explanation": "<one-paragraph rationale>"
}
```
