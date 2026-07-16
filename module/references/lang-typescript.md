---
pack_id: lang-typescript
language: TypeScript
version: 3.0.0
---

# Convention Pack: TypeScript

Self-contained pack. Do not load base.md alongside.

## Calibration Rules

- **ts-76b7** `any` MUST NOT be used. Use `unknown` for unknown types, narrow with type guards. Existing `any` SHOULD be eliminated incrementally; new `any` always rejected.
- **ts-84d2** All Promises MUST be handled. No fire-and-forget `async` calls. `await` for sequential, `Promise.all()` or `Promise.allSettled()` for concurrent. `@typescript-eslint/no-floating-promises` MUST be enabled.
- **ts-8abb** Async tests MUST await all async operations. Use `async`/`await` in test functions. Test framework must detect unhandled Promise rejections. Never return Promise without awaiting in test body.
- **ts-a3f1** Strict null checks MUST be enabled (`strict: true` or `strictNullChecks: true` in `tsconfig.json`). Code MUST handle `null` and `undefined` explicitly — no loose truthiness checks for nullable values.
- **ts-b72e** Naming MUST follow TypeScript conventions: `camelCase` for variables, functions, methods; `PascalCase` for classes, interfaces, type aliases, enums; `UPPER_SNAKE_CASE` for constants. Interface names MUST NOT use `I` prefix (use `UserService` not `IUserService`).
- **ts-c914** MUST use `readonly` on properties set once at construction (IDs, timestamps, foreign keys). Use `ReadonlyArray<T>` and `Readonly<T>` for immutable collections. MUST NOT mutate function arguments.
- **ts-d5a8** Circular module dependencies MUST be avoided — use dependency inversion or extract shared types into common module. Barrel exports (`export *` in `index.ts`) MUST NOT use wildcard re-exports; name each export explicitly for tree-shaking, prevent transitive dependency chains.

## Calibration Notes

> **Strict mode**: `tsconfig.json` with `strict: false` or missing `strict` — flag it. When `strict: true` set, do not separately flag individual strict-family options (`strictNullChecks`, `noImplicitAny`, etc.) — implied.

> **Naming**: `I` prefix on interfaces (`IUser`, `IService`) is C#/Java convention TypeScript discourages. Flag as naming violation, not style preference. PascalCase functions (`CreateUser` instead of `createUser`) are Go/C# convention — flag in TypeScript codebases.

## testing_conventions

- **Test runner**: project-configured (vitest, jest, mocha — check package.json)
- **Property testing**: `fast-check`
- **Contract testing**: `pact-js` for service contracts
- **Benchmark**: `vitest bench` or `tinybench`

## Custom Rules

<!-- Project custom rules use the cr-XXXX identifier prefix (hex, e.g. cr-a1b2).
     Add them in `.review-council/packs/`, not here. -->
