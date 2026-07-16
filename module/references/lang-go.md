---
pack_id: lang-go
language: Go
version: 3.0.0
---

# Convention Pack: Go

Self-contained Go pack. Do not load base.md alongside.

## Calibration Rules

- **go-092b** Return `error` from functions that can fail. Never `panic` for expected errors. Constructor-based init (requiring `New()`) is idiomatic. Pointer receiver methods panicking on nil receivers follow standard nil-pointer semantics — do NOT flag missing nil guards on library methods.
- **go-4aa3** Functions spawning goroutines MUST accept `context.Context` as first parameter for cancellation and timeout propagation.
- **go-5892** Every spawned goroutine MUST have defined termination condition. No goroutine leaks — ensure exit when parent context cancelled or owning scope completes.
- **go-7434** Shared mutable state accessed from multiple goroutines MUST be protected by `sync.Mutex`, `sync.RWMutex`, or channel-based sync. Document locking strategy above protected fields. Transfer ownership at goroutine boundaries — sender MUST NOT retain or modify reference after sending. Prefer copying over sharing references.
- **go-734a** When project uses `//sumtype:decl` sealed interfaces, type switches over them MUST NOT include `default` case — let `gochecksumtype` enforce exhaustiveness. Name marker method after interface (e.g., `isOrderStatus()`) to avoid collisions between sealed types.
- **go-f4f2** Never return bare `*T` for "found vs not found" semantics. Use `(T, bool)` or sealed result type. Prefer value types over pointers unless mutation, optional semantics, or non-copyable fields (`sync.Mutex`) require them.

## Calibration Notes

> **Nil pointers**: Calling method on nil pointer receiver panics. Standard Go — NOT bug, vulnerability, or resilience defect. Do NOT flag nil receiver panics, nil map access, or nil slice ops. Only flag nil handling when: (1) function accepts external/user input that could be nil AND (2) function is at system boundary (public API, CLI handler, HTTP handler) AND (3) no caller-side validation. Internal library methods with pointer receivers are NOT system boundaries.

> **Type assertions**: Unchecked type assertions (`v := x.(Type)`) only findings when operating on external input or untrusted data at system boundary. Internal type assertions in switch statements or type-safe code paths are idiomatic Go.

> **Panic**: Explicit `panic()` calls only findings when used for expected error conditions that should return `error`. Panics in `init()`, unreachable code assertions, and test helpers are idiomatic.

> **Sealed interfaces**: When `gochecksumtype` present (check `.golangci.yml`), adding `default` case to type switch over `//sumtype:decl` interface defeats exhaustiveness checking and is always a finding. When `exhaustruct` enabled, uninitialized or unkeyed struct literals are findings — scope to project packages, not third-party types.

## testing_conventions

- **Test runner**: `go test`
- **Assertion**: stdlib `testing` package; `testify` if already in deps
- **Property testing**: `rapid` (pgregory.net/rapid) preferred; `gopter` as alt
- **Fuzz testing**: `go test -fuzz` (built-in since Go 1.18)
- **Contract testing**: `pact-go` for service contracts
- **Benchmark**: `go test -bench`
- **Race detection**: `go test -race` (flag missing race detection in concurrent code tests)

## Custom Rules

<!-- Project custom rules use cr-XXXX identifier prefix (hex, e.g. cr-a1b2).
     Add in `.review-council/packs/`, not here. -->
