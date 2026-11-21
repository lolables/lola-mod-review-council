---
pack_id: lang-java
language: Java
extensions: [java]
contract: 1
version: 1.0.0
---

# Convention Pack: Java

Self-contained Java pack. Do not load base.md alongside.

## Calibration Notes

> No Java-specific calibration notes yet. Apply the severity definitions as written.

## Reviewer hints

Patterns each persona checks for in a Java change. They are prompts to look, not findings.

| Persona | Detection Hints |
|---------|-----------------|
| Adversary | Check for SQL injection via string concatenation in JDBC; deserialization of untrusted data; hardcoded credentials |
| Guard | Check for god classes (>500 lines); deep inheritance hierarchies (>3 levels); package-level circular dependencies |

## Custom Rules

<!-- Project custom rules use the cr-XXXX identifier prefix (hex, e.g. cr-a1b2).
     Add them in `.review-council/packs/`, not here. -->
