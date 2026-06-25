# Model Guidance for Review Council

Empirical data from the eval suite (6 test cases covering
Go security, TypeScript/React architecture, Python
multi-concern, false-positive resistance, per-persona
coverage, and convention pack detection).

## Summary

Sonnet-class models deliver the best quality-to-cost
ratio for Review Council. They match or exceed
opus-class on detection quality while costing 2-4x less
per review. Haiku-class models pass most cases but
struggle with false-positive suppression and convention
pack attribution.

## Scores by Model Class

Scores are composites (0.0-1.0) across weighted rubric
dimensions. Pass thresholds vary by case (0.60-0.70).

| Case | Opus | Sonnet | Haiku |
|------|------|--------|-------|
| Go security (4 flaws) | 1.00 | 1.00 | 0.85 |
| TS/React architecture (5 flaws) | 0.73 | 0.87 | 0.73 |
| Python multi-concern (7 flaws) | 0.88 | 1.00 | 1.00 |
| Go clean code (0 flaws) | 1.00 | 1.00 | 0.40 |
| Python per-persona (6 flaws) | 0.95 | 0.84 | 0.90 |
| TS convention pack (5 violations) | 0.77 | 0.82 | 0.45 |
| **Average** | **0.89** | **0.92** | **0.72** |

Scores are averages across CLI hosts (Claude Code and
OpenCode) tested with the same model.

## Cost Per Review

Approximate cost per single review invocation:

| Model Class | Cost Range |
|-------------|------------|
| Opus | $1.30-$8.80 |
| Sonnet | $1.00-$2.80 |
| Haiku | $0.07-$0.72 |

Cost varies with codebase size and number of findings.

## Recommendations

**Coordinator model**: Use the model the user has
configured. The coordinator's job is orchestration, not
deep analysis — any capable model works.

**Reviewer subagents**: Sonnet-class is the sweet spot.
If the host supports per-subagent model selection, the
delegate.md tier table applies:

- **Capable tier** (Adversary, Architect, Guard):
  Sonnet-class or above. These personas require
  judgment about intent, security implications, and
  architectural fitness.
- **Standard tier** (Tester, Operator, Curator):
  Sonnet-class. These personas are more
  checklist-driven but still need enough capability
  to read code accurately and avoid false positives.

Haiku-class is not recommended for reviewer subagents.
It produces acceptable results on straightforward
security detection but generates false positives on
clean codebases and misses convention pack rules.

**When cost matters more than precision**: Haiku-class
can be used for the Standard tier personas (Tester,
Operator, Curator) as a budget option, but expect
lower scores on false-positive control and convention
detection. Never use haiku-class for the Capable tier.

## Limitations

- Data is from a controlled eval suite with small,
  focused codebases (50-300 lines). Real-world
  codebases may show different patterns.
- Only Claude model variants have been tested. Other
  model families may perform differently.
- Scores reflect the full review-council pipeline
  including verification, not raw model capability.
