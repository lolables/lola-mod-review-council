---
pack_id: lang-rust
language: Rust
extensions: [rs]
contract: 1
version: 1.0.0
---

# Convention Pack: Rust

Self-contained Rust pack. Do not load base.md alongside.

## Calibration Notes

> No Rust-specific calibration notes yet. Apply the severity definitions as written.

## Reviewer hints

Patterns each persona checks for in a Rust change. They are prompts to look, not findings.

| Persona | Detection Hints |
|---------|-----------------|
| Adversary | Check for `unsafe` blocks without safety comments; unchecked `.unwrap()` on user input; raw pointer arithmetic |
| Guard | Check for unnecessary `clone()` calls; overly broad trait bounds; modules with >500 lines |

## Custom Rules

<!-- Project custom rules use the cr-XXXX identifier prefix (hex, e.g. cr-a1b2).
     Add them in `.review-council/packs/`, not here. -->
