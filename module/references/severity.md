---
pack_id: severity
version: 2.0.0
description: "Shared severity level definitions for all Divisor Council personas."
---

# Severity Convention Pack

## Severity Levels

### CRITICAL

The change introduces a defect causing data loss, security breach, build failure, or constitutional violation. MUST NOT merge.

**Boundary**: Immediate, concrete harm — not theoretical risk.

### HIGH

Significant risk or technical debt that will cause problems if not addressed before merge. Blocks review.

**Boundary**: Likely to cause near-term problems. Style preferences, optional test expansion, and idiomatic patterns do NOT meet this bar — use MEDIUM or LOW.

### MEDIUM

Quality issue that should be addressed but does not block merge. Auto-fixable in Spec Review Mode.

**Boundary**: Improvement opportunity — code/spec works but could be better.

### LOW

Minor style or documentation improvement. Non-blocking. Auto-fixable in Spec Review Mode.

**Boundary**: Cosmetic or informational. No functional impact.

## Per-Persona Examples

| Severity | Adversary                                                             | Tester                                                                                   | Guard                                                                               | Operator                                                                             |
|----------|-----------------------------------------------------------------------|------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------|
| CRITICAL | Hardcoded secret, SQL injection, `panic()` for expected errors        | Coverage strategy missing (constitution violation), test masks real failure              | Constitution violated without justification, implementation contradicts spec        | Release pipeline broken, destructive op without guard, critical CVE                  |
| HIGH     | Credentials at INFO, unpinned CI action, unchecked type assertion     | Vague acceptance criteria, shallow assertions (err == nil only), missing regression test | Scope creep, acceptance criterion with no task, undocumented constitution trade-off | Missing upgrade path, hardcoded env values, no error recovery for I/O                |
| MEDIUM   | Broad file permissions, missing error context, redundant read         | Missing fixture spec, test isolation concern, convention deviation                       | Minor scope addition (gold plating), stale cross-reference, metadata inconsistency  | Missing operational docs, incomplete platform support, unquantified perf requirement |
| LOW      | Comment suggesting future security review, minor naming inconsistency | Minor test naming issue, optional observability enhancement                              | Minor wording improvement, optional cross-reference                                 | Style improvement in errors, optional health check, minor doc gap                    |

## Auto-Fix Policy (Spec Review Mode)

| Severity | Action      | Rationale                               |
|----------|-------------|-----------------------------------------|
| LOW      | Auto-fix    | Cosmetic; safe without human judgment   |
| MEDIUM   | Auto-fix    | Quality improvement; deterministic fix  |
| HIGH     | Report only | Requires human judgment on intent/scope |
| CRITICAL | Report only | May indicate design issue               |
