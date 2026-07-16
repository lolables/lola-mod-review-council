---
pack_id: fw-react
framework: React
version: 1.0.0
description: "React-specific conventions. Additive — load alongside lang-typescript.md."
---

# Convention Pack: React

Additive framework pack for React. Load alongside `lang-typescript.md`.

## Calibration Rules

- **react-01a4** Components over 200 lines or with 5+ `useState`/`useReducer` hooks are god components. Extract state into custom hooks, children into separate files. Mixed state declarations, event handlers, data fetching, and JSX in one component is signal. Line/hook counts are proxies.
- **react-02b7** Props passed through 3+ component levels without intermediate use means missing React Context or state management. Intermediaries coupled to data they never use.
- **react-03c9** Every component tree needs at least one error boundary. Unhandled render error in any child crashes entire React tree above nearest boundary, or whole app if none exists. Boundaries at app root and around independently-failing feature sections are minimum.
- **react-04d1** Direct DOM manipulation via `useRef` with imperative style changes (`element.style.*`, `classList.*`, `setAttribute`) bypasses React reconciliation. Use CSS classes, inline style objects, CSS-in-JS, or CSS Modules. Exception: layout measurement (`getBoundingClientRect`, `scrollHeight`) and focus management are valid `useRef` uses.
- **react-05e3** Memoization (`useMemo`, `useCallback`, `React.memo`) needs demonstrated performance reason. Premature memoization adds complexity without measurable benefit. Only flag missing memoization when component re-renders expensively on every parent render with unchanged props.

## Severity Calibration

| Pattern                                                          | Severity | Rationale                                                |
|------------------------------------------------------------------|----------|----------------------------------------------------------|
| Missing error boundary (none in component tree)                  | HIGH     | Crash propagation; one child error unmounts entire app   |
| God component (>200 lines or >5 state hooks, mixed concerns)     | HIGH     | Architectural debt compounds as features added           |
| Prop drilling (3+ levels, unused by intermediaries)              | MEDIUM   | Maintainability; refactor with Context when stable       |
| Direct DOM manipulation for styling via useRef                   | MEDIUM   | Correctness risk for SSR/hydration; bypasses reconciler  |
| Missing memoization on expensive render path                     | LOW      | Performance suggestion, not defect                       |
| Inline function props without performance impact                 | LOW      | Style preference unless proven re-render bottleneck      |

## Calibration Notes

> **God component detection**: Thresholds (200 lines, 5 state hooks) trigger inspection, not automatic findings. 250-line component doing one thing well (e.g., complex form with validation) may be fine. 150-line component mixing auth state, data fetching, routing, and presentation is god component regardless of size. Look for mixed concerns, not just counts.

> **Prop drilling vs. composition**: Not all multi-level prop passing is drilling. If each intermediate component uses prop (e.g., `theme` prop for styling at every level), that is composition. Drilling is when intermediaries pass props through without using them.

> **Error boundaries and third-party components**: Error boundaries only catch errors in React render cycle (render, lifecycle methods, constructors). They miss event handlers, async code, SSR. Do not flag missing error boundaries for event handler failures; use standard try/catch there.

## Custom Rules

<!-- Project custom rules use cr-XXXX identifier prefix (hex, e.g. cr-a1b2).
     Add in `.review-council/packs/`, not here. -->
