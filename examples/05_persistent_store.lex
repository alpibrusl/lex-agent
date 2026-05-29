# lex-agent — persistent task store demo
#
# Same `echo` agent as `02_dispatch_offline.lex`, but mounted on a
# `std.conc` actor-backed task store (`src/store.lex`). Demonstrates:
#
#   - `tasks/send`   stores the final Task on success
#   - `tasks/get`    reads it back by id
#   - `tasks/cancel` flips the state and the next `tasks/get` sees
#                    the updated record
#   - `tasks/get` of an unknown id returns `-32001 task-not-found`
#
# In-process (no HTTP) so it runs fast under `lex test`. Run:
#   lex run --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent \
#       examples/05_persistent_store.lex demo

import "std.str" as str

import "std.list" as list

import "lex-schema/schema" as sch

import "lex-spec/spec" as sp

import "lex-spec/capability" as cap

import "../src/agent_card" as card

import "../src/server" as srv

import "../src/message" as msg

import "../src/task" as tk

import "../src/store" as store

# ---- Capability + handler (mirrors 01_ping_pong) ----------------
fn echo_capability() -> cap.Capability {
  cap.inbound("echo", "Reply with the input text.", { title: "EchoArgs", description: "", fields: [sch.required_str("text", [StrNonEmpty])] })
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

# Boot the agent with a freshly-spawned task store attached.
fn make_agent() -> [concurrent] srv.AgentDef {
  let base := srv.make_agent_def(card.make("ping-pong-persistent", "demo", "0.2.0", "http://localhost:4040", [echo_capability()]), [{ capability: echo_capability(), handle: echo_handler }])
  srv.with_store(base, store.spawn_store())
}

# ---- Envelope builders ------------------------------------------
fn send_envelope() -> Str {
  str.concat("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tasks/send\",\"params\":{", str.concat("\"id\":\"t_demo\",\"contextId\":\"ctx_demo\",", "\"message\":{\"kind\":\"message\",\"messageId\":\"msg_in\",\"role\":\"user\",\"parts\":[{\"type\":\"text\",\"text\":\"hello\"}]}}}"))
}

fn get_envelope(id :: Str) -> Str {
  str.concat("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tasks/get\",\"params\":{", str.concat("\"id\":\"", str.concat(id, "\"}}")))
}

fn cancel_envelope(id :: Str) -> Str {
  str.concat("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tasks/cancel\",\"params\":{", str.concat("\"id\":\"", str.concat(id, "\"}}")))
}

# ---- The demo ---------------------------------------------------
#
# Four round-trips through `dispatch_request` against the same
# AgentDef (so the store actor lives across the calls):
#
#   1. tasks/send   "hello"           → completed task
#   2. tasks/get    t_demo            → that same task
#   3. tasks/get    unknown           → -32001 task-not-found
#   4. tasks/cancel t_demo            → InvalidTransition
#      (already terminal — completed → canceled isn't legal)
fn demo() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Str {
  let agent := make_agent()
  let sent := srv.dispatch_request(agent, send_envelope())
  let got := srv.dispatch_request(agent, get_envelope("t_demo"))
  let got_ghost := srv.dispatch_request(agent, get_envelope("ghost"))
  let cancel_bad := srv.dispatch_request(agent, cancel_envelope("t_demo"))
  str.concat("--- tasks/send ---\n", str.concat(sent, str.concat("\n\n--- tasks/get (existing) ---\n", str.concat(got, str.concat("\n\n--- tasks/get (unknown) ---\n", str.concat(got_ghost, str.concat("\n\n--- tasks/cancel (already terminal) ---\n", cancel_bad)))))))
}

