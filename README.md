# lex-agent

**Pure-Lex implementation of the [Google Agent2Agent (A2A) protocol](https://github.com/google/A2A).**
Write your agent in Lex, expose `Inbound` capabilities via standard A2A
JSON-RPC over HTTPS, talk to ADK / LangGraph / CrewAI / AutoGen agents
over the same wire. No bespoke envelope to learn — the leading interop
standard with launch-partner SDK coverage.

Supersedes lex-soft's bespoke `{from, topic, payload_json}` shape. The
"publish your agent, talk to anyone" pitch survives the moment a
third-party agent only has to read your AgentCard to know how to call
you.

## Install

```toml
# lex.toml
[dependencies]
"lex-agent"  = { git = "https://github.com/alpibrusl/lex-agent" }
"lex-schema" = { git = "https://github.com/alpibrusl/lex-schema" }
"lex-spec"   = { git = "https://github.com/alpibrusl/lex-spec" }
"lex-web"    = { git = "https://github.com/alpibrusl/lex-web" }   # only if you use `src/mount.lex`
```

`lex-web` is only required when you mount the agent onto a lex-web
router (see Transport below). The standalone `std.net.serve_fn` path
needs only `lex-schema` + `lex-spec`.

## At a glance

```lex
import "lex-schema/schema"      as sch
import "lex-schema/constraints" as c
import "lex-spec/capability"    as cap

import "lex-agent/server"     as srv
import "lex-agent/agent_card" as card
import "lex-agent/message"    as msg
import "lex-agent/task"       as tk

# 1. Declare a Capability — A2A `skill` + lex-schema params + an
#    optional Spec precondition.
fn echo() -> cap.Capability {
  cap.inbound("echo", "Reply with the input text.",
    { title: "EchoArgs", description: "",
      fields: [sch.required_str("text", [StrNonEmpty])] })
}

# 2. Write the handler. The server's `Skill.handle` row matches
#    lex-web's `route_effectful` row, so handlers can declare any
#    subset of [io, time, crypto, random, sql, fs_read, fs_write,
#    net, concurrent]. Pure bodies (like this one) fit structurally
#    and need no declaration at all.
fn echo_handler(m :: msg.Message) -> srv.HandlerOutcome {
  { next_state: TSCompleted,
    reply: Some(msg.agent_text("pong")),
    artifacts: [] }
}

# 3. Assemble the AgentDef and dispatch through any HTTP transport.
fn agent() -> srv.AgentDef {
  srv.make_agent_def(
    card.make("ping-pong", "demo", "0.1.0",
      "http://localhost:4040", [echo()]),
    [{ capability: echo(), handle: echo_handler }])
}
```

End-to-end:

```bash
$ lex run --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent \
    examples/01_ping_pong.lex main &

$ curl http://localhost:4040/.well-known/agent.json
{ "name": "ping-pong", "skills": [...], ... }

$ curl -X POST http://localhost:4040/ \
    -H 'content-type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"tasks/send","params":{
      "id":"t_1","sessionId":"s_1",
      "message":{"role":"user","parts":[{"type":"text","text":"hello"}]}}}'
{ "jsonrpc": "2.0", "id": 1,
  "result": { "id": "t_1", "status": { "state": "completed" }, ... } }
```

## Surface

| Module | Purpose |
|---|---|
| `src/agent_card.lex` | AgentCard ADT, `/.well-known/agent.json` rendering, JSON Schema 2020-12 export per skill |
| `src/protocol.lex`   | JSON-RPC 2.0 envelope (`Request`, `Response`, `RpcError`) + method dispatch table |
| `src/task.lex`       | Task lifecycle (`submitted` / `working` / `input-required` / `completed` / `canceled` / `failed`) with legal-transition gating |
| `src/message.lex`    | `Message` / `Artifact` / `Part` ADTs (`TextPart` / `DataPart` / `FilePart`) + parse/render |
| `src/server.lex`     | `dispatch_request(agent_def, body)` — transport-agnostic A2A request handler |
| `src/client.lex`     | `send_task(peer_url, msg, opts)` + `fetch_agent_card(peer_url)` + `subscribe(...)` over SSE |
| `src/stream.lex`     | SSE encoder (`data: <json>\n\n`) + decoder over `Iter[Str]` |
| `src/mount.lex`      | `mount(router, agent_def)` — register the two A2A routes onto a `lex-web/router.Router` |

Every `src/*` module is pure Lex. The server's `dispatch_request`
declares the wide row `[io, time, crypto, random, sql, fs_read,
fs_write, net, concurrent]` — the same row lex-web's
`route_effectful` accepts, which is what lets `mount` register the
JSON-RPC route without an effect-row impedance. Handlers freely use
the subset they need; the type checker keeps the per-fn signature
honest.

## A2A method coverage (v0.1)

| JSON-RPC method | Status |
|---|---|
| `tasks/send`           | Full |
| `tasks/get`            | Skeleton (returns `task-not-found`; real persistence is an actor-backed wrapper — see roadmap) |
| `tasks/cancel`         | Skeleton (returns `not-cancelable`) |
| `tasks/sendSubscribe`  | Single-frame fallback today; live SSE write-half follows `lex-lang#487` upstream |

Persistent task storage / cancellation is a deliberate v0.1 deferral:
the surface that matters for interop testing (AgentCard + `tasks/send`)
is what shipped first. A `std.conc`-actor wrapper that backs
`tasks/get` and `tasks/cancel` is on the roadmap.

## Capability preconditions

The `Capability` ADT from `lex-spec/capability` carries an optional
`Spec` precondition. **The server evaluates it before invoking the
handler.** Empty input on the `echo` capability above gets:

```json
{ "jsonrpc": "2.0", "id": 2,
  "error": { "code": -32099,
             "message": "spec-denied: predicate false: (args.text != \"\")" } }
```

Code `-32099` is the `spec-denied` extension to A2A's standard error
codes. Pair with `lex-llm`'s outbound-capability filter and you get
**evaluate-at-both-ends** by construction — the receiver doesn't trust
the sender's gate.

## What's NOT in v0.1

- **OAuth / DID identity.** A2A's auth story is layered; v0.1 ships
  unauthenticated for local-dev.
- **Persistent task store.** `tasks/get` returns `task-not-found` today;
  the actor-backed wrapper lands as a follow-up.
- **True streaming SSE write half.** `tasks/sendSubscribe` falls back
  to a single-frame response when the upstream `std.net` streaming
  write surface isn't available; one-frame interop with Python A2A
  clients works.
- **Agent registry.** Platform-layer; out of scope for the
  protocol-layer package.

These mirror the "out of scope" list in issue #481; v0.2 revisits each.

## Tests

```bash
lex test
```

Suites cover:

- Message / Part / Artifact parse + round-trip
- Task transition table (legal moves and rejected moves)
- JSON-RPC envelope parse + render (id polymorphism, error codes)
- SSE encode/decode (incl. `[DONE]` marker handling, comment skipping)
- AgentCard JSON shape (constraints flow into `inputSchema`)

## Examples

```bash
# In-process dispatch demo — no HTTP transport, runs in `lex test`.
lex run --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent \
    examples/02_dispatch_offline.lex demo

# Full HTTP server on localhost:4040 (standalone std.net.serve_fn).
lex run --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent \
    examples/01_ping_pong.lex main

# Same agent, mounted onto a lex-web router (adds request-id, gzip,
# structured access logs, side-route composition).
lex run --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent \
    examples/03_mount_with_lex_web.lex main
```

## Transport

The server in `src/server.lex` is transport-agnostic: it gives you
`dispatch_request(agent_def, raw_body) -> Str`. Wire it through any of:

- `std.net.serve_fn(port, handler)` — the in-tree stdlib transport
  (the path `examples/01_ping_pong.lex` demonstrates).
- `mount.mount(router, agent_def)` — registers the two A2A endpoints
  on a [lex-web](https://github.com/alpibrusl/lex-web) `Router` so
  the agent inherits the framework's request-id correlation,
  structured access logs, body-size limit, gzip negotiation, and
  composes with side routes (`/healthz`, `/metrics`, …) on the same
  port. See `examples/03_mount_with_lex_web.lex`.
- Anything that can hand the body to `dispatch_request` and stream the
  response — a custom hyper wrapper, an in-process test harness, etc.

```lex
import "lex-web/router"   as router
import "lex-agent/mount"  as mount

fn app() -> router.Router {
  mount.mount(router.new(), my_agent())
}
```

## License

EUPL-1.2 — matches the parent `lex-lang` project.
