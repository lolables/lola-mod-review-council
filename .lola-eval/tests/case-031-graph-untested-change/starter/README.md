# ratelimit

Rate-limiting primitives used by the edge proxy.

## Types

| File         | Type      | Purpose                                   |
|--------------|-----------|-------------------------------------------|
| `bucket.go`  | `Bucket`  | Token bucket, refills at a fixed rate      |
| `window.go`  | `Window`  | Sliding-window event counter               |
| `quota.go`   | `Quota`   | Per-key allowance accounting               |
| `limiter.go` | `Limiter` | Combines the three into one `Allow` check  |

Each type is safe for concurrent use. `Bucket` and `Window` take their
clock from an injectable `now` field so tests drive time by hand rather
than sleeping.

## Commands

```bash
go test ./...
go vet ./...
```
