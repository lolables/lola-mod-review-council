# Review Council

Multi-persona code and specification review system. NEVER auto-trigger — only invoke via explicit `/review-council` command or as part of a user-requested workflow.

## Tool Agnosticism

This module MUST remain target-tool agnostic. It must work identically
whether the hosting tool is Claude Code, OpenCode, Cursor, Windsurf,
Gemini CLI, or any future AI coding assistant.

Rules:

1. **No tool-specific frontmatter.** Agent file frontmatter uses only
   keys every host understands (`description`). Operational constraints
   (tool access, temperature) are expressed as natural language in the
   agent body or in orchestrator guidance (`delegate.md`).
2. **No tool-specific dispatch syntax.** Orchestrator docs describe
   dispatch intent ("use agent filename as identifier") with fallback
   instructions for hosts that lack named-agent dispatch.
3. **No tool names in operational text.** References to specific tools
   (Claude Code, OpenCode, etc.) are permitted only in eval/benchmark
   context — never in instructions, prompts, or agent definitions that
   affect runtime behavior.
4. **Graceful degradation over hard requirements.** Features that
   depend on host capabilities (model selection, temperature control,
   named subagent dispatch) must degrade gracefully when the host lacks
   them, not fail.

## Output Principle: Built for Humans, Actionable by LLMs

Every artifact this module emits for a human audience — reports, PR
comments — leads with a human summary and stays scannable, while the
underlying data remains machine-parseable.

Rules:

1. **Human summary first.** Lead with a one-line verdict and a plain-language
   TL;DR before any table or detail dump. A reader must grasp the outcome
   without expanding anything.
2. **Scannable structure over walls of text.** Use tables for counts and
   verdicts; tuck long finding lists behind collapsible `<details>` blocks.
3. **Machine-parseable substrate.** Keep structured data (`evidence-check.json`),
   stable section anchors, and hidden marker tags intact so a later LLM pass
   can parse the same artifact it presents to a human.
4. **Deterministic rendering.** Forge-specific formatting is produced by
   scripts from structured data — never hand-formatted by the model per forge.
   The model contributes prose (a narrative, a one-line summary); scripts own
   structure.
