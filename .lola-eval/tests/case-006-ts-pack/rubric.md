---
rubric_version: "1"
pass_threshold: 0.6
weights:
  convention_detection: 0.425
  pack_attribution: 0.255
  baseline_lift: 0.17
  routing_accuracy: 0.10
  no_flapping: 0.05
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

## convention_detection (weight 0.425)

How many of the five convention violations were identified?

- 1.0 — all 5 violations identified.
- 0.7 — 3 or 4 violations identified.
- 0.4 — 2 violations identified.
- 0.0 — 0 or 1 violation identified.

## pack_attribution (weight 0.255)

Do findings reference specific TypeScript conventions or pack rules?

- 1.0 — findings cite specific convention rule IDs (CS-003, CS-004,
  CS-006, AP-004) or describe the convention they violate in terms
  that match the TypeScript pack's language.
- 0.5 — findings identify the issues correctly but use generic
  language without referencing the convention pack.
- 0.0 — findings are entirely generic, with no connection to the
  TypeScript conventions.

## baseline_lift (weight 0.17)

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

## routing_accuracy (weight 0.10)

Did the agent correctly interpret `/review-council code` and pass
`--mode code` to rc-prepare.sh?

- 1.0 — the agent used code mode.
- 0.0 — the agent used specs mode or failed to set the mode.

## no_flapping (weight 0.05)

Did the agent find its instruction files cleanly on the first attempt?

- 1.0 — clean load, no searching or retrying.
- 0.5 — minor searching behavior.
- 0.0 — extensive searching, multiple retries, or errors.

## output

Return strict JSON:

```
{
  "components": {
    "convention_detection": "<float>",
    "pack_attribution": "<float>",
    "baseline_lift": "<float>",
    "routing_accuracy": "<float>",
    "no_flapping": "<float>"
  },
  "explanation": "<one-paragraph rationale>"
}
```
