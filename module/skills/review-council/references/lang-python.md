---
pack_id: lang-python
language: Python
extensions: [py]
contract: 1
version: 1.0.0
---

# Convention Pack: Python

Self-contained Python pack. Do not load base.md alongside.

## Calibration Notes

> No Python-specific calibration notes yet. Apply the severity definitions as written.

## Reviewer hints

Patterns each persona checks for in a Python change. They are prompts to look, not findings.

| Persona | Detection Hints |
|---------|-----------------|
| Adversary | Check for `eval()`/`exec()` with user input; `pickle.loads()` on untrusted data; `subprocess.call(shell=True)` with string formatting; hardcoded secrets |
| Guard | Check for circular imports; mutable default arguments; missing `__init__.py` exports; god modules (>500 lines) |
| Tester | Check for `assert True` tautologies; broad `except: pass` in test setup; missing edge-case tests for off-by-one errors |

## Custom Rules

<!-- Project custom rules use the cr-XXXX identifier prefix (hex, e.g. cr-a1b2).
     Add them in `.review-council/packs/`, not here. -->
