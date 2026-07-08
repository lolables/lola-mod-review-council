---
description: "Empirical model comparison data from the Review Council eval suite."
last_updated: 2026-06-30
---

# Model Guidance for Review Council

Empirical data from the eval suite (6 cases: Go security, TypeScript/React architecture, Python multi-concern, false-positive resistance, per-persona coverage, convention pack detection).

## Summary

Sonnet-class models deliver the best quality-to-cost ratio. They match or exceed opus-class on detection while costing 2-4x less. Haiku-class passes most cases but struggles with false-positive suppression and convention pack attribution.

## Scores by Model Class

Composites (0.0-1.0) across weighted rubric dimensions. Pass thresholds: 0.60-0.70.

| Case                              | Opus     | Sonnet   | Haiku    |
|-----------------------------------|----------|----------|----------|
| Go security (4 flaws)             | 1.00     | 1.00     | 0.85     |
| TS/React architecture (5 flaws)   | 0.73     | 0.87     | 0.73     |
| Python multi-concern (7 flaws)    | 0.88     | 1.00     | 1.00     |
| Go clean code (0 flaws)           | 1.00     | 1.00     | 0.40     |
| Python per-persona (6 flaws)      | 0.95     | 0.84     | 0.90     |
| TS convention pack (5 violations) | 0.77     | 0.82     | 0.45     |
| **Average**                       | **0.89** | **0.92** | **0.72** |

Scores averaged across CLI hosts (Claude Code, OpenCode).

> Haiku scores 0.40 on clean codebases (Go clean code), indicating a 60% false positive rate — the primary reason it is not recommended for reviewer subagents.

## Cost Per Review

| Model Class | Cost Range  |
|-------------|-------------|
| Opus        | $1.30-$8.80 |
| Sonnet      | $1.00-$2.80 |
| Haiku       | $0.07-$0.72 |

Cost varies with codebase size and finding count. Pricing as of 2026-06-30.

## Recommendations

**Coordinator**: Use user-configured model. Orchestration, not deep analysis.

**Reviewer subagents**: Sonnet-class is the sweet spot. Per-subagent tiers (if host supports model selection):

- **Capable tier** (Adversary, Guard): Sonnet or above. Requires judgment on intent, security, governance.
- **Standard tier** (Tester, Operator, Curator): Sonnet. Checklist-driven but needs accurate code reading and false-positive control.

Haiku is not recommended for reviewers. Budget option for Standard tier only — expect lower false-positive control and convention detection. Never use haiku for Capable tier.

## Limitations

- Eval suite uses small, focused codebases (50-300 lines). Real-world patterns may differ.
- Only Claude model variants tested.
- Scores reflect the full pipeline including verification, not raw model capability.
