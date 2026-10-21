---
pack_id: severity
version: 2.0.0
description: "Shared severity level definitions for all Divisor Council personas."
---

# Severity Convention Pack

## Severity Levels

### CRITICAL

Change introduces data loss, security breach, build failure, or constitutional violation. MUST NOT merge.

**Boundary**: Immediate, concrete harm — not theoretical risk.

### HIGH

Significant risk or tech debt causing problems if not fixed before merge. Blocks review.

**Boundary**: Likely near-term problems. Style preferences, optional test expansion, idiomatic patterns do NOT meet this bar — use MEDIUM or LOW. A HIGH names a concrete consequence — who is affected and the mechanism that hurts them — recorded in the finding's `impact`.

### MEDIUM

Quality issue worth fixing but does not block merge.

**Boundary**: Improvement opportunity — code/spec works but could be better.

### LOW

Minor style or docs improvement. Non-blocking.

**Boundary**: Cosmetic or informational. No functional impact.

## Per-Persona Examples

| Severity | Adversary                                                             | Tester                                                                                                   | Guard                                                                                                                                                     | Operator                                                                             |
|----------|-----------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------|
| CRITICAL | Hardcoded secret, SQL injection, `panic()` for expected errors        | Coverage strategy missing (constitution violation), test masks real failure                              | Constitution violated without justification, implementation contradicts spec                                                                              | Release pipeline broken, destructive op without guard, critical CVE                  |
| HIGH     | Credentials at INFO, unpinned CI action, unchecked type assertion     | Vague acceptance criteria, missing regression test                                                       | Scope creep that adds trust surface, commits a public contract, or is undisclosed; acceptance criterion with no task; undocumented constitution trade-off | Missing upgrade path, hardcoded env values, no error recovery for I/O                |
| MEDIUM   | Broad file permissions, missing error context, redundant read         | Missing fixture spec, shallow assertions (err == nil only), test isolation concern, convention deviation | Scope creep with maintenance cost only (gold plating), stale cross-reference, metadata inconsistency                                                      | Missing operational docs, incomplete platform support, unquantified perf requirement |
| LOW      | Comment suggesting future security review, minor naming inconsistency | Minor test naming issue, optional observability enhancement                                              | Minor wording improvement, optional cross-reference                                                                                                       | Style improvement in errors, optional health check, minor doc gap                    |

**Guard scope creep: MEDIUM unless one criterion holds.** HIGH only when extra
scope (a) adds trust or attack surface — network calls, permissions,
untrusted-input parsing, new dependencies; (b) commits a contract users or
downstream code will build on — API fields, config keys, file/wire formats,
flags whose output others parse (an unrequested `--verbose` is MEDIUM under
(b); a new machine-readable `--json` output is HIGH); or (c) is undisclosed —
change claims X, ships X+Y. Change description = the PR/MR description, supplied
as the PR Description section. With no change description supplied, (c) does not
apply. Spec review: (c) is undisclosed — spec's stated problem and scope do not
cover it and nothing in the spec acknowledges it. With no stated problem or scope
in the spec, (c) does not apply.

## Fix Policy

All findings reported to user. Nothing fixed automatically, regardless of severity. User decides which findings to address.

| Severity | Action      | Rationale                            |
|----------|-------------|--------------------------------------|
| LOW      | Report only | User decides if cosmetic fix wanted  |
| MEDIUM   | Report only | User decides on quality improvements |
| HIGH     | Report only | Needs human judgment on intent/scope |
| CRITICAL | Report only | May indicate design issue            |
