# lex-agent — end-to-end ping/pong demo
#
# Wires the A2A server up to `std.net.serve_fn` directly. For the
# lex-web-mounted variant (request-id correlation, structured access
# logs, gzip negotiation, sub-router composition) see
# `03_mount_with_lex_web.lex`.
#
# Demonstrates:
#
#   - AgentCard at `/.well-known/agent.json`
#   - JSON-RPC dispatch at `/`  (POST tasks/send)
#   - One Inbound capability — `echo` — that returns its input
#   - The Capability carries a `Spec` precondition: the input text
#     must be non-empty. Empty inputs are rejected with
#     `spec-denied` (-32099) before the handler runs.
#
# Run the server:
#   lex run --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent \
#       examples/01_ping_pong.lex main
#
# In another shell:
#   curl http://localhost:4040/.well-known/agent.json
#
#   curl -X POST http://localhost:4040/ -H 'content-type: application/json' \
#     -d '{"jsonrpc":"2.0","id":1,"method":"tasks/send","params":{
#       "id":"t_1","sessionId":"s_1",
#       "message":{"role":"user","parts":[{"type":"text","text":"hello"}]}
#     }}'

import "std.net" as net
import "std.str" as str

import "lex-schema/constraints" as c
import "lex-schema/schema"      as sch

import "lex-spec/spec"       as sp
import "lex-spec/capability" as cap

import "../src/agent_card" as card
import "../src/server"     as srv
import "../src/message"    as msg
import "../src/task"       as tk

# ---- Capability + precondition -----------------------------------

# Spec: forall args :: Args. args.text != "".
fn nonempty_text_spec() -> sp.Spec {
  {
    name: "input_nonempty",
    quantifiers: [
      QRecord({
        name: "args",
        fields: [{ name: "text", ty: TStr }],
      }),
    ],
    predicate: EBinop({
      op: "!=",
      lhs: EField({ binding: "args", field: "text" }),
      rhs: EConst(VStr("")),
    }),
  }
}

fn echo_capability() -> cap.Capability {
  let base := cap.inbound("echo", "Reply with the input text.",
    {
      title:       "EchoArgs",
      description: "Input message; first TextPart is echoed back.",
      fields:      [sch.required_str("text", [StrNonEmpty])],
    })
  let with_out := cap.with_reply(base, {
    title:       "EchoReply",
    description: "",
    fields:      [sch.required_str("text", [])],
  })
  cap.with_precondition(with_out, nonempty_text_spec())
}

# Handler: extract the text, prepend "pong: ", build a reply.
# Pure body — fits structurally in `Skill.handle`'s wider effect row.
fn echo_handler(m :: msg.Message) -> srv.HandlerOutcome {
  let txt := first_text(m.parts)
  let reply := msg.agent_text(str.concat("pong: ", txt))
  {
    next_state: TSCompleted,
    reply: Some(reply),
    artifacts: [],
  }
}

import "std.list" as list

fn first_text(parts :: List[msg.Part]) -> Str {
  match list.head(parts) {
    Some(TextPart(s)) => s,
    _                 => "",
  }
}

# ---- Agent assembly ----------------------------------------------

fn make_agent() -> srv.AgentDef {
  let c := card.make(
    "ping-pong",
    "Demo A2A agent — echoes inputs with a `pong: ` prefix.",
    "0.1.0",
    "http://localhost:4040",
    [echo_capability()])
  srv.make_agent_def(c, [
    { capability: echo_capability(), handle: echo_handler },
  ])
}

# ---- HTTP dispatch -----------------------------------------------

fn handle(req :: Request) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Response {
  let agent := make_agent()
  if req.method == "GET" {
    if req.path == "/.well-known/agent.json" {
      { status: 200, body: BodyStr(srv.agent_card_response(agent)), headers: empty_headers() }
    } else {
      { status: 404, body: BodyStr("{\"error\":\"not found\"}"), headers: empty_headers() }
    }
  } else { if req.method == "POST" {
    let body_out := srv.dispatch_request(agent, req.body)
    { status: 200, body: BodyStr(body_out), headers: empty_headers() }
  } else {
    { status: 405, body: BodyStr("{\"error\":\"method not allowed\"}"), headers: empty_headers() }
  }}
}

import "std.map" as map
fn empty_headers() -> Map[Str, Str] {
  map.from_list([("content-type", "application/json")])
}

fn main() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Nil {
  net.serve_fn(4040, handle)
}
