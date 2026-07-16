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
