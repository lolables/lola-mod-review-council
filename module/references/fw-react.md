---
pack_id: fw-react
framework: React
version: 1.0.0
description: "React-specific conventions. Additive — load alongside lang-typescript.md."
---

# Convention Pack: React

Additive framework pack for React projects. Load alongside `lang-typescript.md`.

## Calibration Rules

- **react-01a4** Components exceeding 200 lines or using more than 5 `useState`/`useReducer` hooks are god components. Extract state management into custom hooks and child components into separate files. Mixing state declarations, event handlers, data fetching, and JSX rendering in a single component is the signal — line count and hook count are proxies.
- **react-02b7** Props passed through 3 or more component levels without being used by intermediate components indicate missing React Context or state management. The intermediate components are coupled to data they do not use.
- **react-03c9** Every component tree must have at least one error boundary. An unhandled render error in any child crashes the entire React tree above the nearest boundary — or the whole application if none exists. Error boundaries at the application root and around independently-failing feature sections are the minimum.
- **react-04d1** Direct DOM manipulation via `useRef` combined with imperative style changes (`element.style.*`, `classList.*`, `setAttribute`) bypasses React's reconciliation. Use CSS classes, inline style objects, CSS-in-JS, or CSS Modules. Exception: measuring layout (`getBoundingClientRect`, `scrollHeight`) and managing focus are valid `useRef` uses.
- **react-05e3** Memoization (`useMemo`, `useCallback`, `React.memo`) must have a demonstrated performance reason. Premature memoization adds complexity without measurable benefit. Do not flag missing memoization as a defect unless the component re-renders expensively on every parent render with unchanged props.

## Severity Calibration

| Pattern                                                          | Severity | Rationale                                                   |
|------------------------------------------------------------------|----------|-------------------------------------------------------------|
| Missing error boundary (no boundary in component tree)           | HIGH     | Crash propagation — single child error unmounts entire app  |
| God component (>200 lines or >5 state hooks with mixed concerns) | HIGH     | Architectural debt that compounds as features are added     |
| Prop drilling (3+ levels, unused by intermediaries)              | MEDIUM   | Maintainability concern; refactor with Context when stable  |
| Direct DOM manipulation for styling via useRef                   | MEDIUM   | Correctness risk for SSR/hydration; bypasses reconciliation |
| Missing memoization on expensive render path                     | LOW      | Performance suggestion, not a defect                        |
| Inline function props without performance impact                 | LOW      | Style preference unless proven re-render bottleneck         |

## Calibration Notes

> **God component detection**: The thresholds (200 lines, 5 state hooks) are triggers for inspection, not automatic findings. A 250-line component that does one thing well (e.g., a complex form with validation) may be acceptable. A 150-line component mixing authentication state, data fetching, routing logic, and presentation is a god component regardless of size. Look for mixed concerns, not just counts.

> **Prop drilling vs. composition**: Not all multi-level prop passing is prop drilling. If each intermediate component uses the prop (e.g., a `theme` prop used for styling at every level), it is composition, not drilling. Drilling is specifically when intermediaries pass props through without using them.

> **Error boundaries and third-party components**: Error boundaries only catch errors in the React render cycle (render, lifecycle methods, constructors). They do not catch errors in event handlers, async code, or server-side rendering. Do not flag missing error boundaries for event handler failures — that is standard try/catch territory.

## Custom Rules

<!-- Project custom rules use the cr-XXXX identifier prefix (hex, e.g. cr-a1b2).
     Add them in `.review-council/packs/`, not here. -->
