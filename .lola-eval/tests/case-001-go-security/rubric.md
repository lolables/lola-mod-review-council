---
rubric_version: "1"
pass_threshold: 0.6
weights:
  detection: 0.425
  evidence: 0.255
  false_positives: 0.17
  routing_accuracy: 0.10
  no_flapping: 0.05
---

# Rubric: case-001-go-security

The agent was asked to run /review-council on a Go HTTP server with
four intentional security flaws. Score the review output.

The starter contains these intentional flaws:

1. **SQL injection** in `getUserHandler` — string formatting used to
   build a SQL query with user-supplied `id` parameter (`fmt.Sprintf`).
2. **Hardcoded API key** — `apiKey` constant with a production-style
   secret, leaked via `X-API-Key` response header in `healthHandler`.
3. **Missing input validation** — `runDiagHandler` accepts any command
   name from the `cmd` query parameter with no allowlist or validation.
4. **Command injection** — `exec.Command(cmdName, args)` in
   `runDiagHandler` passes unsanitized user input directly to the OS.

Note: Flaws 3 and 4 are closely related (both in `runDiagHandler`).
A review that identifies the command injection risk (flaw 4) but
does not separately call out the missing validation (flaw 3) should
still receive credit for both, since the command injection finding
subsumes the validation gap.

Score three components, each in [0.0, 1.0]:

## detection (weight 0.425)

How many of the four flaws were explicitly identified in the review?

- 1.0 — all 4 flaws identified.
- 0.7 — 3 flaws identified.
- 0.4 — 2 flaws identified.
- 0.0 — 0 or 1 flaws identified.

## evidence (weight 0.255)

Do findings cite specific file locations with real code?

- 1.0 — all findings cite file:line references that match actual source
  code in `main.go`. The cited line numbers and code snippets are accurate.
- 0.5 — most findings cite file:line but some references are approximate
  or missing.
- 0.0 — no file:line citations, or citations point to non-existent lines.

## false_positives (weight 0.17)

Did the review avoid fabricating findings that do not exist in the code?

- 1.0 — zero fabricated findings. Every reported issue corresponds to
  a real problem in the source code.
- 0.5 — one finding that describes a problem not present in the code.
- 0.0 — two or more fabricated findings.

## routing_accuracy (weight 0.10)

Did the agent correctly interpret `/review-council code` and pass
`--mode code` to rc-prepare.sh?

- 1.0 — the agent used code mode (passed `--mode code` or the
  review clearly operated in code review mode with code-variant
  agents).
- 0.0 — the agent used specs mode or failed to set the mode.

## no_flapping (weight 0.05)

Did the agent find its instruction files (SKILL.md, phase files,
agent definitions) cleanly on the first attempt?

- 1.0 — clean load, no searching or retrying.
- 0.5 — minor searching behavior.
- 0.0 — extensive searching, multiple retries, or errors.

## output

Return strict JSON:

```
{
  "components": {
    "detection": "<float>",
    "evidence": "<float>",
    "false_positives": "<float>",
    "routing_accuracy": "<float>",
    "no_flapping": "<float>"
  },
  "explanation": "<one-paragraph rationale>"
}
```
