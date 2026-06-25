# lex-agent — durable (SQLite) task store demo
#
# Same `echo` agent as `05_persistent_store.lex`, but the task store
# is backed by SQLite instead of an in-memory actor. This is the
# difference that issue #10 asks for: a task submitted in one process
# is still resolvable by `tasks/get` after the process restarts.
#
# We simulate a restart in-process by opening a *second* agent whose
# store points at the same db file. The first agent's `tasks/send`
# persists the task; the second agent — which never saw that send —
# resolves it via `tasks/get`.
#
#   lex run --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent \
#       examples/06_sqlite_store.lex demo

import "std.str" as str

import "std.list" as list

import "lex-schema/schema" as sch

import "lex-spec/capability" as cap

import "../src/agent_card" as card

import "../src/server" as srv

import "../src/message" as msg

import "../src/task" as tk

import "../src/store" as store

# ---- Capability + handler (mirrors 05_persistent_store) ----------
fn echo_capability() -> cap.Capability {
  cap.inbound("echo", "Reply with the input text.", { title: "EchoArgs", description: "", fields: [sch.required_str("text", [StrNonEmpty])] })
}

fn first_text(parts :: List[msg.Part]) -> Str {
  match list.head(parts) {
    Some(TextPart(s)) => s,
    _ => "",
  }
}

# The handler is assigned to `Skill.handle`, whose effect row is fixed
# (and invariant in Lex 0.9.x), so the signature declares that row
# verbatim even though this body is pure.
fn echo_handler(m :: msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] srv.HandlerOutcome {
  { next_state: TSCompleted, reply: Some(msg.agent_text(str.concat("pong: ", first_text(m.parts)))), artifacts: [] }
}

# Build an agent whose store is the SQLite database at `db_path`.
# Two calls with the same path share the same durable table.
fn make_agent(db_path :: Str) -> [sql, fs_write, concurrent] Result[srv.AgentDef, Str] {
  match store.open_store(SqliteStore(db_path)) {
    Err(e) => Err(e),
    Ok(s) => {
      let base := srv.make_agent_def(card.make("ping-pong-sqlite", "demo", "0.3.0", "http://localhost:4040", [echo_capability()]), [{ capability: echo_capability(), handle: echo_handler }])
      Ok(srv.with_store(base, s))
    },
  }
}

# ---- Envelope builders ------------------------------------------
fn send_envelope() -> Str {
  str.concat("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tasks/send\",\"params\":{", str.concat("\"id\":\"t_demo\",\"contextId\":\"ctx_demo\",", "\"message\":{\"kind\":\"message\",\"messageId\":\"msg_in\",\"role\":\"user\",\"parts\":[{\"type\":\"text\",\"text\":\"hello\"}]}}}"))
}

fn get_envelope(id :: Str) -> Str {
  str.concat("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tasks/get\",\"params\":{", str.concat("\"id\":\"", str.concat(id, "\"}}")))
}

# ---- The demo ---------------------------------------------------
#
#   1. agent A (store @ db) handles tasks/send  → persists t_demo
#   2. agent B (fresh handle, same db) tasks/get → resolves t_demo,
#      proving the task survived the (simulated) restart
#   3. agent B tasks/get of an unknown id        → -32001 task-not-found
fn demo() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Str {
  let db_path := "/tmp/lex_agent_demo_store.db"
  match make_agent(db_path) {
    Err(e) => str.concat("failed to open store: ", e),
    Ok(agent_a) => {
      let sent := srv.dispatch_request(agent_a, send_envelope())
      match make_agent(db_path) {
        Err(e) => str.concat("failed to reopen store: ", e),
        Ok(agent_b) => {
          let got := srv.dispatch_request(agent_b, get_envelope("t_demo"))
          let got_ghost := srv.dispatch_request(agent_b, get_envelope("ghost"))
          str.concat("--- agent A: tasks/send ---\n", str.concat(sent, str.concat("\n\n--- agent B (after restart): tasks/get t_demo ---\n", str.concat(got, str.concat("\n\n--- agent B: tasks/get (unknown) ---\n", got_ghost)))))
        },
      }
    },
  }
}

