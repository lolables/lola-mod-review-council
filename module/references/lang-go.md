---
pack_id: lang-go
language: Go
version: 3.0.0
---

# Convention Pack: Go

Self-contained Go pack. Do not load base.md alongside this pack.

## Calibration Rules

- **go-092b** Return `error` from functions that can fail. Never `panic` for expected errors. Note: constructor-based initialization (requiring `New()`) is idiomatic. Pointer receiver methods that panic on nil receivers follow Go's standard nil-pointer semantics — do NOT flag missing nil guards on library methods.
- **go-4aa3** Functions that spawn goroutines MUST accept `context.Context` as the first parameter for cancellation and timeout propagation.
- **go-5892** Every spawned goroutine MUST have a defined termination condition. Do not leak goroutines — ensure exit when parent context is cancelled or owning scope completes.
- **go-7434** Shared mutable state accessed from multiple goroutines MUST be protected by `sync.Mutex`, `sync.RWMutex`, or channel-based synchronization. Document locking strategy above protected fields. Transfer ownership at goroutine boundaries — the sender MUST NOT retain or modify the reference after sending. Prefer copying data over sharing references.
- **go-734a** When a project uses `//sumtype:decl` sealed interfaces, type switches over those interfaces MUST NOT include a `default` case — let `gochecksumtype` enforce exhaustiveness. Name the marker method after the interface (e.g., `isOrderStatus()`) to avoid collisions between sealed types.
- **go-f4f2** Never return a bare `*T` for "found vs not found" semantics. Use `(T, bool)` or a sealed result type. Prefer value types over pointers unless mutation, optional semantics, or non-copyable fields (`sync.Mutex`) require them.

## Calibration Notes

> **Nil pointers**: Calling a method on a nil pointer receiver panics. This is standard Go — NOT a bug, vulnerability, or resilience defect. Do NOT flag nil receiver panics, nil map access, or nil slice operations. Only flag nil handling when: (1) the function accepts external/user input that could be nil AND (2) the function is at a system boundary (public API, CLI handler, HTTP handler) AND (3) there is no caller-side validation. Internal library methods with pointer receivers are NOT system boundaries.

> **Type assertions**: Unchecked type assertions (`v := x.(Type)`) are only findings when operating on external input or untrusted data at a system boundary. Internal type assertions in switch statements or type-safe code paths are idiomatic Go.

> **Panic**: Explicit `panic()` calls are only findings when used for expected error conditions that should return `error`. Panics in `init()`, unreachable code assertions, and test helpers are idiomatic.

> **Sealed interfaces**: When `gochecksumtype` is present (check `.golangci.yml`), adding a `default` case to a type switch over a `//sumtype:decl` interface defeats exhaustiveness checking and is always a finding. When `exhaustruct` is enabled, uninitialized or unkeyed struct literals are findings — scope this to project packages, not third-party types.

## testing_conventions

- **Test runner**: `go test`
- **Assertion**: standard library `testing` package; `testify` if already in project dependencies
- **Property testing**: `rapid` (pgregory.net/rapid) — preferred; `gopter` as alternative
- **Fuzz testing**: `go test -fuzz` (built-in since Go 1.18)
- **Contract testing**: `pact-go` for service contracts
- **Benchmark**: `go test -bench`
- **Race detection**: `go test -race` (flag for missing race detection in concurrent code tests)

## Custom Rules

<!-- Project custom rules use the cr-XXXX identifier prefix (hex, e.g. cr-a1b2).
     Add them in `.review-council/packs/`, not here. -->
