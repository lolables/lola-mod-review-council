# textutil

Small string helpers shared by the docs site generator.

| File          | Exported     | Notes                                    |
|---------------|--------------|------------------------------------------|
| `slugify.go`  | `Slugify`    | Title to URL-safe slug                    |
| `wrap.go`     | `Wrap`       | Break text into width-bounded lines       |
| `truncate.go` | `Truncate`   | Rune-aware shortening with an ellipsis    |
| `spaces.go`   | —            | `normalizeSpaces`, shared by the above    |

`normalizeSpaces` is unexported and deliberately shared: `Slugify` and
`Wrap` both need predictable single-space separation before they start.

## Commands

```bash
go test ./...
go vet ./...
```
