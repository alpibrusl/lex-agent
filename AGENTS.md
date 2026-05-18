# lex-agent — Agent Guidelines

Pure-Lex implementation of the Google Agent2Agent (A2A) protocol.
See `README.md` for the surface; this doc carries the discipline
specific to authoring against the package.

---

## Wire-shape fidelity

The JSON envelopes on the wire match the A2A v0.3 spec — what the
Google Python SDK ([`a2a-sdk`](https://pypi.org/project/a2a-sdk/))
parses through its `a2a.compat.v0_3` Pydantic types:

```
POST /
{ "jsonrpc": "2.0", "id": <int|str|null>, "method": "tasks/send",
  "params": { "id": "task_...",
              "contextId": "ctx_...",
              "message": { "kind": "message",
                           "messageId": "msg_...",
                           "role": "user",
                           "parts": [...] } } }

GET /.well-known/agent.json
{ "name": "...", "description": "...", "version": "...",
  "url": "...",
  "skills": [ { "id": "...", "name": "...", "tags": [],
                "description": "...", "inputSchema": { ... } } ],
  "capabilities": { ... } }
```

Required v0.3 fields:
- `Task.kind = "task"`, `Task.contextId` (not `sessionId` — the
  legacy name is still accepted on parse for backwards compat,
  emitted shape is canonical).
- `Message.kind = "message"`, `Message.messageId` (non-empty).
  Server-side replies built via the pure `msg.agent_text` /
  `msg.user_text` builders get a fresh id stamped by
  `stamp_reply_id` in `server.lex`; the pure builders default the
  field to `""` so test fixtures stay deterministic.
- `AgentSkill.tags` — always emitted, defaults to `[]`.
- `AgentSkill.id` + `name` — A2A clients distinguish skills on the
  wire by `id`; we emit both from the same `Capability.name`.

Don't change field casing (`sessionId`/`session_id`, `inputSchema`/
`input_schema`). The interop tests in `tests/interop/` run every
emitted shape through the official Google A2A SDK — any drift fails
CI loudly.

---

## Effects

`Skill.handle` and the whole `dispatch_request` chain declare the
wide row

```
[io, time, crypto, random, sql, fs_read, fs_write, net, concurrent]
```

— the same row `lex-web/router.route_effectful` accepts. This is what
lets `src/mount.lex` register the `POST /` route without an effect-row
impedance (#481's "A2A server on top of lex-web — `mount()` an
AgentDef" criterion). The choice supersedes the earlier
`[net, io, llm, proc]` row, which was a defensive widening from before
the lex-web integration landed.

| effect    | why a handler might declare it                                       |
|-----------|----------------------------------------------------------------------|
| `[io]`    | filesystem read/write through `std.io`, log lines, timers            |
| `[time]`  | wall-clock reads, monotonic deltas                                   |
| `[crypto]`/`[random]` | signing requests, generating IDs                         |
| `[sql]`   | persistent task store / session state via `std.sql`                  |
| `[fs_read]`/`[fs_write]` | per-path filesystem grants                            |
| `[net]`   | outbound HTTP from the handler (calling a downstream agent)          |
| `[concurrent]` | dispatch to a `std.conc` actor (background work, llm wrappers)  |

`dispatch_request` itself never uses any of these — the row leaks
through from the handler-closure call (`skill.handle(m)` in
`run_skill`) because effect rows on record-field closures are
invariant in Lex 0.9.x. Pure handlers satisfy the row structurally
(subset rule), so the simplest handler signature is just
`(msg.Message) -> srv.HandlerOutcome` with no effects declared at all.

Handlers that previously needed `[llm]` (semantic annotation for a
model call) or `[proc]` (shelling out) re-route through wrappers:
- `[llm]`: post a request to a registered LLM-runner actor via
  `conc.tell` (carried by the `[concurrent]` effect).
- `[proc]`: factor the shell-out behind a process-runner adapter and
  invoke it via the same actor pattern, or fall back to the standalone
  `std.net.serve_fn` path where the handler can declare `[proc]` on
  its own (lex-web isn't in the call chain there).

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

## Task store

`src/store.lex` is a `std.conc` actor wrapping `Map[Str, tk.Task]`.
The server writes the final Task after every successful dispatch
and reads back on `tasks/get` / `tasks/cancel`. Wire it in once at
boot:

```lex
let agent := srv.with_store(
  srv.make_agent_def(my_card, my_skills),
  store.spawn_store())
```

Rules:

- **Server owns the put.** Handlers don't touch the store; the
  server stamps the final task into it from `run_skill`. Never
  call `store.put` from a handler — you'd race the server's own
  write and the lifecycle assertions on `tk.advance` would lose
  their authority.
- **`tasks/cancel` goes through `tk.advance`.** The store calls
  `tk.advance(t, TSCanceled, None)`; terminal tasks surface as
  `Err(InvalidTransition({...}))`. The server maps that to
  `-32002 not-cancelable`. Don't shortcut by re-writing the task
  record with a different `state` — the lifecycle is exhaustive
  for a reason.
- **In-memory only.** The store's state is the actor's, lost at
  process exit. A durable variant (sqlite-backed) is a follow-up.
- **One store per agent.** The `AgentDef.store :: Option[conc.Addr]`
  holds one address. Sharing a store across two agents is
  technically possible (just pass the same addr to both
  `with_store` calls) but the task-id namespace would need to be
  globally unique across both — A2A doesn't say anything about
  that, so it's a "your problem" pattern.

---

## Trail emission

Attach a `lex-trail` log via `with_trail(agent, log)` to record every
A2A protocol method as an auditable event.

### Server events

| Trigger                  | Event kind              | Payload fields                              |
|--------------------------|-------------------------|---------------------------------------------|
| `tasks/send` received    | `a2a.task.received`     | `task_id`, `context_id`                     |
| handler starts (→working)| `a2a.task.state_change` | `task_id`, `from_state`, `to_state`         |
| handler completes        | `a2a.task.state_change` | `task_id`, `from_state`, `to_state`         |
| reply present            | `a2a.message.sent`      | `task_id`, `message_id`                     |
| `tasks/cancel` success   | `a2a.task.state_change` | `task_id`, `to_state: "canceled"`           |

### Client events (`send_task_traced` / `subscribe_traced`)

| Function            | Event kind          | Payload fields                      |
|---------------------|---------------------|-------------------------------------|
| `send_task_traced`  | `a2a.task.sent`     | `task_id`, `to_agent`, `skill`      |
| `subscribe_traced`  | `a2a.message.sent`  | `task_id`, `to_agent`               |

Events are emitted before the network call so the trail captures
intent even when HTTP fails. Emission errors are silently discarded —
a write failure never affects A2A dispatch.

### Wiring

```lex
import "lex-trail/log" as trail
import "../src/server" as srv

# In tests:
let log   := match trail.open_memory() { Ok(l) => l, Err(_) => ... }
let agent := srv.with_trail(srv.make_agent_def(my_card, skills), log)
let _resp := srv.dispatch_request(agent, body)

# In production:
let log   := match trail.open("/var/log/agent.trail") { Ok(l) => l, Err(_) => ... }
let agent := srv.with_trail(base_agent, log)
```

Chain with `with_store` in any order — both fields are independent:

```lex
let agent :=
  srv.with_trail(
    srv.with_store(srv.make_agent_def(card, skills), store_addr),
    trail_log)
```

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
HTTP transport you prefer.

### std.net.serve_fn (standalone)

```lex
# In-tree stdlib path — see examples/01_ping_pong.lex.
fn handle(req :: Request) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Response {
  let body := srv.dispatch_request(my_agent, req.body)
  { status: 200, body: BodyStr(body), headers: ... }
}
net.serve_fn(4040, handle)
```

### lex-web mount

`src/mount.lex` registers the two A2A endpoints on a lex-web router,
so the agent inherits the framework's middleware stack (request-id,
access logs, body-size limit, gzip) and composes with side routes
(`/healthz`, `/metrics`, sub-routers) on the same port. This is the
integration #481 specifies for "A2A server on top of lex-web".

```lex
import "lex-web/router"   as router
import "lex-agent/mount"  as mount

fn app() -> router.Router {
  let r := router.use_mw(router.use_mw(router.new(),
             mw.request_id()), mw.logger())
  mount.mount(r, my_agent())
}
```

See `examples/03_mount_with_lex_web.lex` for the full wiring,
including the `net.serve_fn` boundary adapter (lex-web's `Response`
shape differs from lex-lang's built-in `Response` — the adapter
rewraps `body :: Str` as `BodyStr(...)` on the way out).

---

## Tests

```bash
lex test
```

7 suites, ~30 cases. Coverage: message round-trips, lifecycle
transitions, JSON-RPC envelopes, SSE encode/decode, AgentCard
shape, trail emission (server + client). Examples are runnable
demos (the offline dispatch demo in particular is a useful smoke
test before standing up the HTTP transport).

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
