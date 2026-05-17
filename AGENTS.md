# lex-agent — Agent Guidelines

Pure-Lex implementation of the Google Agent2Agent (A2A) protocol.
See `README.md` for the surface; this doc carries the discipline
specific to authoring against the package.

---

## Wire-shape fidelity

The JSON envelopes on the wire match the
[A2A spec](https://github.com/google/A2A) exactly:

```
POST /
{ "jsonrpc": "2.0", "id": <int|str|null>, "method": "tasks/send",
  "params": { "id": "...", "sessionId": "...", "message": { ... } } }

GET /.well-known/agent.json
{ "name": "...", "description": "...", "version": "...",
  "url": "...", "skills": [...], "capabilities": { ... } }
```

Don't change field casing (it's `sessionId`, not `session_id`; the
agent card emits `inputSchema`, not `input_schema`). Cross-language
SDKs reading the wire are unforgiving.

---

## Effects

| effect | why |
|---|---|
| `[net]`  | HTTP transport |
| `[io]`   | available to handlers that touch the filesystem |
| `[llm]`  | semantic annotation when a handler dispatches to a model |
| `[proc]` | available to handlers that shell out |

`dispatch_request` declares the union `[net, io, llm, proc]` so any
handler closure assignable to the union is accepted. Pure handlers
satisfy this structurally — unused declared effects are ignored at
the call site.

---

## Spec preconditions

Every `Inbound` capability MAY carry a `Spec` precondition (via
`cap.with_precondition`). The server evaluates it before invoking
the handler:

- `Allow`         → handler runs.
- `Deny(reason)`  → response error `-32099 spec-denied: <reason>`.
- `Inconclusive(reason)` → same `-32099` response.

`Inconclusive` mapping to deny is intentional: at a trust boundary,
the receiver doesn't trust the sender's gate. Pair with
`lex-llm`'s outbound-side filter for "evaluate at both ends".

---

## Task lifecycle

```
submitted → working → input-required → working → completed
                              ↓
                          canceled | failed
```

Legal transitions are in `tk.advance`. Calling it with an illegal
move returns `Err(InvalidTransition({...}))` — never bypass with a
record-rebuild.

`is_terminal(state)` is true for `completed` / `canceled` / `failed`;
artifacts can't be added to a terminal task.

---

## AgentCard skill emission

Skills come from the `Capability` values you attached when building
the AgentDef. Each skill emits:

- `id` + `name`        — the capability's `name`
- `description`        — verbatim from the capability
- `inputSchema`        — `sch.to_json_schema(capability.params)`
- `outputSchema`       — emitted only if `capability.reply` is `Some`
- `hasPrecondition`    — `true` when `capability.precondition` is
                         `Some` (opaque to clients; they're free to
                         re-evaluate against their own state)

---

## Transport choices

`dispatch_request(agent, body) -> Str` is intentionally pure-ish
(only the handler closures bring effects in). Plug it into whichever
HTTP transport you prefer:

```lex
# std.net.serve_fn — the in-tree path (see examples/01_ping_pong.lex):
fn handle(req :: Request) -> [net, io, llm, proc] Response {
  let body := srv.dispatch_request(my_agent, req.body)
  { status: 200, body: BodyStr(body), headers: ... }
}
net.serve_fn(4040, handle)
```

When [lex-web](https://github.com/alpibrusl/lex-web) ships its
production `mount(agent_def)` surface, swap that in and keep the
rest of the agent untouched — the protocol surface is the contract.

---

## Tests

```bash
lex test
```

5 suites, ~24 cases. Coverage: message round-trips, lifecycle
transitions, JSON-RPC envelopes, SSE encode/decode, AgentCard
shape. Examples are runnable demos (the offline dispatch demo in
particular is a useful smoke test before standing up the HTTP
transport).

---

## Sharp edges

- **`Part` decoded as `DataPart` carries the raw `Json` ADT.**
  Validate the inner shape against a `lex-schema/ModelSchema` before
  trusting it — A2A says "anything goes inside data parts" by
  convention.
- **SSE `data: [DONE]` is the canonical terminator.** Some
  third-party A2A reference servers emit a custom marker; the
  decoder is conservative — it stops on `[DONE]` and drops
  unknown lines.
- **`task.id` is the JSON-RPC `id` for the request that created
  it.** Cross-call correlation goes through `sessionId`. Don't
  reuse a `task.id` across sessions; the persistent store roadmap
  uses it as a primary key.

---

## Where to read more

- [A2A protocol](https://github.com/google/A2A) — wire spec
- `README.md` — high-level pitch + capability table
- `src/` — every module is short and documented inline
- [lex-spec](https://github.com/alpibrusl/lex-spec) — the
  precondition DSL
- [lex-llm](https://github.com/alpibrusl/lex-llm) — outbound-side
  capability filtering against the same Spec values
