---
pack_id: lang-typescript
language: TypeScript
version: 3.0.0
---

# Convention Pack: TypeScript

Self-contained TypeScript pack. Do not load base.md alongside this pack.

## Calibration Rules

- **ts-76b7** The `any` type MUST NOT be used. Use `unknown` for truly unknown types, then narrow with type guards. Existing `any` usages SHOULD be eliminated incrementally; new `any` introductions are always rejected.
- **ts-84d2** All Promises MUST be handled. No fire-and-forget `async` calls. Use `await` for sequential async, `Promise.all()` or `Promise.allSettled()` for concurrent. The `@typescript-eslint/no-floating-promises` rule MUST be enabled.
- **ts-8abb** Async tests MUST properly await all asynchronous operations. Use `async`/`await` in test functions. Ensure the test framework detects unhandled Promise rejections. Never return a Promise without awaiting it in the test body.
- **ts-a3f1** Strict null checks MUST be enabled (`strict: true` or `strictNullChecks: true` in `tsconfig.json`). Code MUST handle `null` and `undefined` explicitly — no reliance on loose truthiness checks for nullable values.
- **ts-b72e** Naming MUST follow TypeScript conventions: `camelCase` for variables, functions, and methods; `PascalCase` for classes, interfaces, type aliases, and enums; `UPPER_SNAKE_CASE` for constants. Interface names MUST NOT use the `I` prefix (e.g., use `UserService` not `IUserService`).
- **ts-c914** Data structures MUST use `readonly` on properties set once at construction (IDs, timestamps, foreign keys). Use `ReadonlyArray<T>` and `Readonly<T>` for collections that should not be mutated after creation. MUST NOT mutate function arguments.
- **ts-d5a8** Circular module dependencies MUST be avoided — use dependency inversion or extract shared types into a common module to break cycles. Barrel exports (`export *` in `index.ts`) MUST NOT use wildcard re-exports; name each export explicitly to enable tree-shaking and prevent accidental transitive dependency chains.

## Calibration Notes

> **Strict mode**: When `tsconfig.json` has `strict: false` or omits `strict` entirely, flag it. When `strict: true` is set, do not separately flag individual strict-family options (`strictNullChecks`, `noImplicitAny`, etc.) as they are implied.

> **Naming**: The `I` prefix on interfaces (`IUser`, `IService`) is a C#/Java convention that TypeScript explicitly discourages. Flag it as a naming violation, not a style preference. PascalCase functions (e.g., `CreateUser` instead of `createUser`) are a Go/C# convention — flag them in TypeScript codebases.

## testing_conventions

- **Test runner**: project-configured (vitest, jest, mocha — check package.json)
- **Property testing**: `fast-check`
- **Contract testing**: `pact-js` for service contracts
- **Benchmark**: `vitest bench` or `tinybench`

## Custom Rules

<!-- Project custom rules use the cr-XXXX identifier prefix (hex, e.g. cr-a1b2).
     Add them in `.review-council/packs/`, not here. -->
