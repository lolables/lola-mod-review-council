I reviewed the changeset for security and resilience defects.

```json
{
  "agent": "divisor-adversary-code",
  "files_read": ["internal/mcp/tools.go", "internal/auth/token.go"],
  "verdict": "REQUEST CHANGES",
  "findings": [
    {
      "severity": "HIGH",
      "file": "internal/mcp/tools.go",
      "line": 23,
      "evidence": "\tif err := json.Unmarshal(b, &req); err != nil {\n\t\treturn err\n\t}",
      "description": "handleDelete returns the raw unmarshal error to the caller, leaking struct field names from the decoder message.",
      "recommendation": "Wrap with a caller-safe error before returning."
    },
    {
      "severity": "CRITICAL",
      "file": "internal/mcp/tools.go",
      "line": 9,
      "evidence": "\tdb.Exec(\"DROP TABLE users\")\n\t}",
      "description": "Unparameterised destructive SQL executed on the request path.",
      "recommendation": "Remove the statement and parameterise all queries."
    },
    {
      "severity": "HIGH",
      "file": "../outside/creds.env",
      "line": 1,
      "evidence": "SECRET_TOKEN=fixture-not-a-real-credential",
      "description": "Credential committed in plaintext.",
      "recommendation": "Move to a secret manager and rotate."
    }
  ]
}
```
