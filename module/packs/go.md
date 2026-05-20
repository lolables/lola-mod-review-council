---
pack_id: go
language: Go
version: 1.0.0
---

<!-- Self-contained Go convention pack. Includes all base
     rules — do not load base.md alongside this pack. -->

# Convention Pack: Go

## Coding Style

- **CS-001** [MUST] Format all Go source files with `gofmt`. No manual formatting overrides.
- **CS-002** [MUST] Organize imports with `goimports` in three groups separated by blank lines: standard library, third-party packages, internal packages.
- **CS-003** [MUST] Use PascalCase for exported identifiers and camelCase for unexported identifiers.
- **CS-004** [MUST] Add GoDoc-style comments on all exported functions, methods, and types. The comment MUST start with the identifier name.
- **CS-005** [MUST] Return `error` values from functions that can fail. Never use `panic` for expected error conditions. Note: constructor-based initialization (requiring callers to use `New()`) is idiomatic Go. Pointer receiver methods that panic on nil receivers are NOT violations of this rule — they follow Go's standard nil-pointer semantics. Do NOT flag missing nil guards on library methods as defects.
- **CS-006** [MUST] Wrap errors with `fmt.Errorf("context: %w", err)` to preserve the error chain. The context MUST describe what operation failed.
- **CS-007** [MUST] Avoid mutable package-level variables. No global mutable state. Prefer functional style and dependency injection.
- **CS-008** [SHOULD] Keep functions focused on a single responsibility. Extract helper functions when a function exceeds ~50 lines.
- **CS-009** [SHOULD] Prefer named return values only when they improve GoDoc clarity, not as a general practice.
- **CS-010** [SHOULD] Use constants or typed enums instead of raw string/int literals for domain values.
- **CS-011** [MUST] Follow standard Go naming idioms: receivers are short (1-2 letters), acronyms are all-caps (`ID`, `HTTP`, `URL`), interfaces ending in `-er` for single-method interfaces.

## Architectural Patterns

- **AP-001** [MUST] Business logic MUST NOT import from CLI or presentation layers. Core packages MUST NOT depend on edge packages.

- **AP-002** [SHOULD] Dependencies SHOULD be injected
  rather than hard-instantiated. Functions and
  constructors SHOULD accept interfaces or abstractions
  rather than concrete implementations, enabling testing
  and substitution.

- **AP-003** [MUST] Separation of concerns MUST be
  maintained across architectural layers. Presentation
  logic MUST NOT contain business rules. Data access
  logic MUST NOT contain rendering or CLI output.

- **AP-004** [SHOULD] Interfaces SHOULD be narrow and
  client-specific rather than broad and general-purpose
  (Interface Segregation Principle). Consumers SHOULD
  NOT be forced to depend on methods they do not use.

- **AP-005** [MUST] Circular dependencies between
  packages, modules, or layers MUST NOT exist. If
  module A imports module B, module B MUST NOT import
  module A (directly or transitively).

## Security Checks

- **SC-001** [MUST] Never hardcode secrets, API keys, tokens, or credentials in source code or embedded assets.
- **SC-002** [MUST] Never commit `.env` files, credential JSON files, or private keys to the repository.
- **SC-003** [MUST] Use `filepath.Join` for all filesystem path construction. Never concatenate paths with string operations.
- **SC-004** [MUST] Validate target directories before writing files. Ensure the path is within the expected root and does not escape via `..` traversal.
- **SC-005** [MUST] Set safe file permissions when creating files: `0o644` for regular files, `0o755` for executable scripts and directories.
- **SC-006** [SHOULD] Audit embedded assets for accidental inclusion of sensitive files. Embed directive patterns MUST be as narrow as possible.

## Testing Conventions

- **TC-001** [MUST] Use the standard library `testing` package only. Do not import testify, gomega, or any external assertion library.
- **TC-002** [MUST] Use `t.Errorf` or `t.Fatalf` for assertions directly. No third-party assertion helper functions.
- **TC-003** [SHOULD] Name tests following the `TestXxx_Description` pattern (e.g., `TestRun_CreatesFiles`, `TestIsToolOwned_ToolFiles`). The Go language requires only `TestXxx`; the underscore-description suffix is a readability convention, not a language requirement.
- **TC-004** [MUST] Use `t.TempDir()` for all tests that touch the filesystem. No shared mutable state between test cases.
- **TC-005** [MUST] Run tests with `-race -count=1`. All tests MUST pass under the race detector.
- **TC-006** [SHOULD] Use table-driven tests when exercising multiple input/output combinations for the same function.
- **TC-007** [MUST] Verify specific expected values in assertions — not just `err == nil` or length checks. Assert return values, struct fields, and slice contents.
- **TC-008** [MUST] Ensure tests do not depend on execution order. Each test case MUST be independently runnable.
- **TC-009** [SHOULD] Guard slow tests (subprocess execution, full-module analysis) with `testing.Short()` checks.
- **TC-010** [SHOULD] Place test files alongside their source in the same package directory. Both internal (`_test.go` in same package) and external (`_test` package) test styles are acceptable.

## Documentation Requirements

- **DR-001** [MUST] Write GoDoc comments on every exported function, method, type, and package. Comments MUST be complete sentences starting with the identifier name.

- **DR-002** [SHOULD] Configuration options, environment
  variables, and feature flags SHOULD be documented in
  the project README or a dedicated configuration
  reference, including defaults, valid ranges, and
  examples.

- **DR-003** [SHOULD] User-visible changes (new features,
  breaking changes, deprecations, bug fixes) SHOULD be
  recorded in a changelog or release notes, following
  the project's established format.

- **DR-004** [MUST] Commit messages MUST be meaningful
  and describe the intent of the change, not just what
  files were modified. If the project uses Conventional
  Commits, the message MUST conform to the format
  (e.g., `feat:`, `fix:`, `docs:`).

## Custom Rules

<!-- This section is intentionally empty in the canonical pack. Project-specific custom rules can be added in a separate file in your project's `.review-council/packs/` directory. -->
