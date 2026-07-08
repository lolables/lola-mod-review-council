---
rubric_version: "1"
pass_threshold: 0.6
weights:
  detection: 0.34
  recommendations: 0.255
  severity_accuracy: 0.255
  routing_accuracy: 0.10
  no_flapping: 0.05
---

# Rubric: case-002-ts-architecture

The agent was asked to run /review-council on a React/TypeScript
dashboard with five intentional architectural flaws. Score the
review output.

The starter contains these intentional flaws:

1. **God component** — `App.tsx` is a single 250+ line file containing
   the root component, all state management, all event handlers, and
   four child components. All concerns are mixed in one file.
2. **Prop drilling** — `theme` and `user` are passed from App through
   TaskList, TaskCard, and into TaskCardContent (4 levels deep) instead
   of using React Context or another state management pattern.
3. **Circular imports** — `types.ts` imports `formatDate` from `utils.ts`,
   and `utils.ts` imports `Task` and `TaskStatus` from `types.ts`.
4. **No error boundaries** — the component tree has no React error
   boundary. A runtime error in any child component crashes the entire
   application.
5. **Direct DOM manipulation** — `TaskCard` uses `useRef` and
   `useEffect` to directly set `style.backgroundColor`, `style.color`,
   and `style.border` instead of using CSS classes, inline styles via
   React's `style` prop, or a CSS-in-JS solution.

Score three components, each in [0.0, 1.0]:

## detection (weight 0.34)

How many of the five flaws were explicitly identified?

- 1.0 — all 5 flaws identified.
- 0.7 — 3 or 4 flaws identified.
- 0.4 — 2 flaws identified.
- 0.0 — 0 or 1 flaw identified.

## recommendations (weight 0.255)

Are the suggested fixes idiomatic and actionable?

- 1.0 — suggestions reference specific React/TypeScript patterns
  (Context API for prop drilling, error boundaries, CSS modules or
  styled-components for styling) and describe how to apply them to
  this codebase.
- 0.5 — suggestions are directionally correct but generic (e.g.,
  "break into smaller components" without specifics).
- 0.0 — no suggestions, or suggestions that would not address the
  identified issues.

## severity_accuracy (weight 0.255)

Are severity levels appropriate for each finding?

- 1.0 — severity levels match the actual impact. Circular imports
  and no error boundaries are correctly rated higher than cosmetic
  issues like prop drilling style.
- 0.5 — severity is mostly reasonable but some findings are
  systematically over- or under-rated.
- 0.0 — severity levels are random or all set to the same level.

## routing_accuracy (weight 0.10)

Did the agent correctly interpret `/review-council code HEAD` and
pass `--mode code --scope range --scope-value "HEAD~1..HEAD"` (or
equivalent)?

- 1.0 — the agent used code mode AND scoped to the latest commit.
  Findings primarily reference `src/GlobalState.tsx` (the latest
  commit).
- 0.5 — the agent set the mode correctly but did not scope to HEAD,
  or scoped correctly but did not set the mode.
- 0.0 — neither mode nor scope was correctly applied.

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
    "detection": "<float>",
    "recommendations": "<float>",
    "severity_accuracy": "<float>",
    "routing_accuracy": "<float>",
    "no_flapping": "<float>"
  },
  "explanation": "<one-paragraph rationale>"
}
```
