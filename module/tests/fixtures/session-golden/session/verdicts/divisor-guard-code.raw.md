Intent-drift review of the changeset.

```json
{
  "agent": "divisor-guard-code",
  "files_read": ["internal/mcp/tools.go", "cmd/root.go"],
  "verdict": "REQUEST CHANGES",
  "findings": [
    {
      "severity": "MEDIUM",
      "file": "internal/mcp/tools.go",
      "line": 23,
      "evidence": "json.Unmarshal(b, &req)",
      "description": "Decode step is duplicated verbatim across all three handlers rather than shared.",
      "recommendation": "Extract a decode helper once the third handler lands."
    },
    {
      "severity": "LOW",
      "file": "cmd/root.go",
      "line": 4,
      "evidence": "\treturn rootCmd.Execute()",
      "description": "Execute discards the command context, so cancellation does not propagate.",
      "recommendation": "Use ExecuteContext and thread the signal context through."
    }
  ]
}
```
