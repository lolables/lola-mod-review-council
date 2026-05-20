---
rubric_version: "1"
pass_threshold: 0.6
weights:
  convention_detection: 0.5
  pack_attribution: 0.3
  baseline_lift: 0.2
---

# Rubric: case-006-ts-pack

The agent was asked to run /review-council on a TypeScript Express API
with five convention violations from the TypeScript convention pack.
Score the review output.

The starter contains these intentional convention violations:

1. **Non-standard naming (CS-006)** — Type alias `userRole` uses
   camelCase instead of PascalCase. Functions `CreateUser`, `ProcessOrder`,
   `GetAllUsers`, `AddUser`, `FindUser` use PascalCase instead of
   camelCase. Interface `IUser` uses the `I` prefix.
2. **Missing strict mode (CS-004)** — `tsconfig.json` does not have
   `strict: true` or `strictNullChecks: true` enabled.
3. **any type usage (CS-003)** — `any` is used as a parameter type in
   `CreateUser`, `ProcessOrder`, `GetAllUsers`, `AddUser`, and as a
   return type in `GetAllUsers` and `ProcessOrder`.
4. **Barrel export anti-pattern** — `models/index.ts` uses `export *`
   wildcard re-exports that prevent tree-shaking.
5. **Missing readonly (AP-004)** — `IUser` interface properties like
   `id` and `createdAt` should be `readonly` since they are set once
   at creation and never mutated.

Score three components, each in [0.0, 1.0]:

## convention_detection (weight 0.5)

How many of the five convention violations were identified?

- 1.0 — all 5 violations identified.
- 0.7 — 3 or 4 violations identified.
- 0.4 — 2 violations identified.
- 0.0 — 0 or 1 violation identified.

## pack_attribution (weight 0.3)

Do findings reference specific TypeScript conventions or pack rules?

- 1.0 — findings cite specific convention rule IDs (CS-003, CS-004,
  CS-006, AP-004) or describe the convention they violate in terms
  that match the TypeScript pack's language.
- 0.5 — findings identify the issues correctly but use generic
  language without referencing the convention pack.
- 0.0 — findings are entirely generic, with no connection to the
  TypeScript conventions.

## baseline_lift (weight 0.2)

Does the review show evidence that the convention pack improved
detection compared to a generic review?

- 1.0 — the review identifies convention-specific issues (like the
  `I` prefix on interfaces, `readonly` for immutable properties, or
  barrel export concerns) that a generic review would likely miss.
  These are TypeScript-pack-specific insights beyond universal code
  quality.
- 0.5 — the review finds obvious issues (like `any` usage) that any
  review would catch, but misses the convention-specific subtleties.
- 0.0 — the review shows no sign of convention pack influence.

## output

Return strict JSON:

```
{
  "components": {
    "convention_detection": <float>,
    "pack_attribution": <float>,
    "baseline_lift": <float>
  },
  "explanation": "<one-paragraph rationale>"
}
```
