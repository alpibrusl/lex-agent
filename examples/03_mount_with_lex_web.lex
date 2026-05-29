# lex-agent — mounted on a lex-web Router
#
# Same `ping-pong` agent as `01_ping_pong.lex`, but wired through
# `mount.mount(router, agent)` instead of a hand-rolled
# `std.net.serve_fn` switch. Mounting adds:
#
#   - request-id correlation (`x-request-id` header on every reply)
#   - structured access logs (`<ts> METHOD path -> status`)
#   - body-size limit (rejects payloads > 1 MiB with 413)
#   - gzip negotiation for responses ≥ 1 KiB
#   - composability: other routes (health, metrics, ...) attach to
#     the same router and inherit the middleware stack
#
# This is the integration #481's module table calls out — the
# A2A server "on top of lex-web" with `mount(agent_def)`.
#
# Run:
#   lex run --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent \
#       examples/03_mount_with_lex_web.lex main &
#
# Then:
#   curl -i http://localhost:4040/.well-known/agent.json
#   curl -i http://localhost:4040/healthz
#   curl -i -X POST http://localhost:4040/ \
#     -H 'content-type: application/json' \
#     -d '{"jsonrpc":"2.0","id":1,"method":"tasks/send","params":{
#       "id":"t_1","contextId":"ctx_1",
#       "message":{"kind":"message","messageId":"m1","role":"user",
#                   "parts":[{"type":"text","text":"hello"}]}}}'

import "std.net" as net

import "std.str" as str

import "std.list" as list

import "lex-schema/schema" as sch

import "lex-spec/spec" as sp

import "lex-spec/capability" as cap

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "lex-web/router" as router

import "lex-web/middleware" as mw

import "../src/agent_card" as card

import "../src/server" as srv

import "../src/mount" as mount

import "../src/message" as msg

import "../src/task" as tk

# ---- Capability + handler (mirrors 01_ping_pong) -----------------
fn nonempty_text_spec() -> sp.Spec {
  { name: "input_nonempty", quantifiers: [QRecord({ name: "args", fields: [{ name: "text", ty: TStr }] })], predicate: EBinop({ op: "!=", lhs: EField({ binding: "args", field: "text" }), rhs: EConst(VStr("")) }) }
}

fn echo_capability() -> cap.Capability {
  let base := cap.inbound("echo", "Reply with the input text.", { title: "EchoArgs", description: "", fields: [sch.required_str("text", [StrNonEmpty])] })
  cap.with_precondition(base, nonempty_text_spec())
}

fn first_text(parts :: List[msg.Part]) -> Str {
  match list.head(parts) {
    Some(TextPart(s)) => s,
    _ => "",
  }
}

fn echo_handler(m :: msg.Message) -> srv.HandlerOutcome {
  { next_state: TSCompleted, reply: Some(msg.agent_text(str.concat("pong: ", first_text(m.parts)))), artifacts: [] }
}

fn make_agent() -> srv.AgentDef {
  srv.make_agent_def(card.make("ping-pong", "demo A2A agent on top of lex-web", "0.1.0", "http://localhost:4040", [echo_capability()]), [{ capability: echo_capability(), handle: echo_handler }])
}

# ---- Side route — `/healthz` for readiness checks ----------------
# Demonstrates that the A2A mount composes with other routes on the
# same router; nothing about mounting locks you out of the rest of
# the lex-web surface.
fn healthz(_c :: ctx.Ctx) -> resp.Response {
  resp.json("{\"ok\":true}")
}

# ---- App assembly ------------------------------------------------
fn app() -> router.Router {
  let base := router.new()
  let with_mw := router.use_mw(router.use_mw(router.use_mw(router.use_mw(base, mw.body_limit(1048576)), mw.request_id()), mw.gzip(1024)), mw.logger())
  let with_health := router.route(with_mw, "GET", "/healthz", healthz)
  mount.mount(with_health, make_agent())
}

# ---- Net binding -------------------------------------------------
#
# `net.serve_fn` (lex-lang 0.9.5+) hands the handler a `Request`
# value and expects a `Response` back. lex-web's router speaks
# `ctx.RawRequest` -> `resp.Response` (with `body :: Str`). The
# boundary adapter rebuilds the request as a `RawRequest` literal
# and re-wraps the response body via `BodyStr(...)` on the way out.
fn handle(req :: Request) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Response {
  let raw := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
  let r := router.dispatch(app(), raw)
  { status: r.status, body: BodyStr(r.body), headers: r.headers }
}

fn main() -> [net, io, time, crypto, random, sql, fs_read, fs_write, concurrent] Nil {
  net.serve_fn(4040, handle)
}

