# CLAUDE.md — lex-agent

> Copy this file into the root of any Lex project repository as
> `CLAUDE.md` (read by Claude Code), `AGENTS.md` (read by Cursor /
> Aider / Codex CLI / Copilot CLI), or both.

This repository is a **Lex** project. Read `lex agent-guidelines` in
full before writing code. The four highest-leverage discipline rules:

1. **Narrow effects, always.** `fn foo() -> [fs_write("/tmp/x")] T`,
   not `[fs_write]`. If the type checker rejects, narrow the body.
2. **Repair, don't regenerate.** `lex check --output json` → `lex repair --apply`.
3. **`examples {}` blocks on every pure fn.** They fold into the
   SigId; free regression tests with no `tests/` boilerplate.
4. **Use the stdlib.** `std.crypto` not hand-rolled crypto; `std.regex`
   not manual scanners.

## The loop

```sh
lex check --strict src/        # type-check with extra lints
lex fmt --check src/ tests/    # formatting (must be canonical)
lex test                       # all tests/test_*.lex files
```

## Project-specific overrides — lex-agent

- **The A2A protocol surface is load-bearing.** Field names on the
  wire (`jsonrpc`, `tasks/send`, `inputSchema`, `Message.parts`, etc.)
  match the Google A2A spec verbatim. Don't rename them for "clarity"
  — third-party agents won't find them.
- **`dispatch_request` is transport-agnostic.** It takes a Str
  request body and returns a Str response body. Don't reach for
  `std.net` inside the dispatcher; HTTP wiring lives in the example
  layer (or in lex-web).
- **Capability preconditions evaluate server-side.** Every `tasks/send`
  runs `cap.gate(skill.capability, bindings)` before the handler
  fires. `Inconclusive` is a deny — never silently allow.
- **Error code -32099 means `spec-denied`.** Reserve it for
  precondition failures; don't reuse for unrelated validation
  errors (the JSON-RPC `invalid params` -32602 is the right home).
- **Task lifecycle is exhaustive.** `tk.advance(from, to, msg?)`
  rejects illegal moves with `InvalidTransition`. Don't bypass it by
  hand-building a new `Task` record with a different `state` — every
  transition needs evidence.
- **`Part` ADT is closed.** v0.1 ships `TextPart` / `DataPart` /
  `FilePart`. Adding a new part variant requires a coordinated bump
  with the A2A spec; don't extend it ad-hoc.
