# Global Agent Instructions

These rules apply to every session. Project-level `AGENTS.md` files in the
workspace override or supplement these.

## Think before coding

State assumptions explicitly. If uncertain, ask. If multiple interpretations
exist, present them — do not pick silently. If a simpler approach exists, say
so. Push back when warranted. If something is unclear, stop and ask.

**Simplicity first.** Minimum code that solves the problem. No features beyond
what was asked. No abstractions for single-use code. No speculative
flexibility or configurability. No error handling for impossible scenarios. If
200 lines could be 50, rewrite.

**Surgical changes.** Touch only what you must. Do not improve adjacent code,
comments, or formatting. Do not refactor things that are not broken. Match
existing style even if you would do it differently. If you notice unrelated
dead code, mention it — do not delete it. Remove only imports/variables/functions
that your changes made unused. Every changed line should trace directly to the
request.

**Goal-driven execution.** Transform tasks into verifiable goals. Write tests
that reproduce bugs, then fix them. Ensure tests pass before and after
refactors. For multi-step tasks, state a brief plan with verification checks per
step. These guidelines bias toward caution over speed — use judgment for trivial
tasks.
