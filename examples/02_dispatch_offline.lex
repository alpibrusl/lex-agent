# lex-agent — offline dispatch demo
#
# Exercises the same agent definition as `01_ping_pong.lex` but
# bypasses the HTTP transport — `dispatch_request` is called
# directly with a JSON-RPC envelope and the response inspected
# in-process. This is what `lex test` will run against your A2A
# agent without needing a port.
#
# Run:
#   lex run --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent \
#       examples/02_dispatch_offline.lex demo

import "std.str"  as str

import "lex-schema/schema"      as sch
import "lex-schema/constraints" as c

import "lex-spec/spec"       as sp
import "lex-spec/capability" as cap

import "../src/agent_card" as card
import "../src/server"     as srv
import "../src/message"    as msg
import "../src/task"       as tk

# ---- Capability + handler (mirrors 01_ping_pong) ----------------

fn echo_capability() -> cap.Capability {
  let base := cap.inbound("echo", "Reply with the input text.",
    {
      title: "EchoArgs",
      description: "",
      fields: [sch.required_str("text", [StrNonEmpty])],
    })
  cap.with_precondition(base, {
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
  })
}

import "std.list" as list
fn first_text(parts :: List[msg.Part]) -> Str {
  match list.head(parts) {
    Some(TextPart(s)) => s,
    _                 => "",
  }
}

fn echo_handler(m :: msg.Message) -> srv.HandlerOutcome {
  {
    next_state: TSCompleted,
    reply: Some(msg.agent_text(str.concat("pong: ", first_text(m.parts)))),
    artifacts: [],
  }
}

fn make_agent() -> srv.AgentDef {
  srv.make_agent_def(
    card.make("ping-pong", "demo", "0.1.0", "http://localhost:4040",
      [echo_capability()]),
    [{ capability: echo_capability(), handle: echo_handler }])
}

# ---- The demo ----------------------------------------------------

# A well-formed `tasks/send` request.
fn good_envelope() -> Str {
  str.concat(
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tasks/send\",\"params\":{",
    str.concat("\"id\":\"t_1\",\"sessionId\":\"s_1\",",
      "\"message\":{\"role\":\"user\",\"parts\":[{\"type\":\"text\",\"text\":\"hello\"}]}}}"))
}

# An empty-text request — should be `spec-denied` (-32099).
fn empty_envelope() -> Str {
  str.concat(
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tasks/send\",\"params\":{",
    str.concat("\"id\":\"t_2\",\"sessionId\":\"s_1\",",
      "\"message\":{\"role\":\"user\",\"parts\":[{\"type\":\"text\",\"text\":\"\"}]}}}"))
}

fn demo() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Str {
  let agent := make_agent()
  let good := srv.dispatch_request(agent, good_envelope())
  let bad  := srv.dispatch_request(agent, empty_envelope())
  str.concat("--- valid request ---\n",
    str.concat(good,
      str.concat("\n\n--- empty input (spec-denied) ---\n", bad)))
}
