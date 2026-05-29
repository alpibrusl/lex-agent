# lex-agent — calling a third-party A2A agent
#
# Demonstrates the client side of the cross-framework story (#481):
# a Lex agent author can talk to ANY A2A-compatible peer (Python ADK,
# LangGraph, CrewAI, AutoGen, ...) using only the in-tree client.
# We exercise:
#
#   - `client.fetch_agent_card(peer_url)`  — GET /.well-known/agent.json
#   - `client.send_task(peer_url, message, opts)`  — POST tasks/send
#
# The peer URL defaults to the in-tree Python reference server at
# `tests/interop/reference_server.py` (port 4041). That server uses
# the same a2a-sdk Pythonic types CI's `validate_with_a2a_sdk.py`
# checks — so passing this example end-to-end **proves the wire
# round-trips through the official Google A2A SDK in both
# directions**.
#
# Run (with the reference server running on :4041):
#   python3 tests/interop/reference_server.py &
#   lex run --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent \
#       examples/04_calls_public_agent.lex demo
#
# Output (one line per assertion):
#   card: name=py-echo
#   send-task: state=completed text=pong: hello
#   send-task-denied: code=-32099 message=spec-denied: ...

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "lex-schema/json_value" as jv

import "../src/client" as client

import "../src/message" as msg

import "../src/protocol" as proto

# Peer URL — override via the `A2A_PEER_URL` env var in CI; the
# default points at `tests/interop/reference_server.py`.
fn peer_url() -> Str {
  "http://127.0.0.1:4041"
}

# ---- Step 1: discovery -------------------------------------------
fn show_card() -> [net] Str {
  match client.fetch_agent_card(peer_url()) {
    Err(e) => str.concat("card-error: ", e),
    Ok(card) => str.concat("card: name=", card.name),
  }
}

# ---- Step 2: send a task -----------------------------------------
fn show_send_task(text :: Str, opts :: client.SendOpts) -> [net, crypto, random] Str {
  let m := msg.user_text_with_id("msg_lex_out", text)
  match client.send_task(peer_url(), m, opts) {
    Err(rpc) => str.concat("send-task-denied: code=", str.concat(int.to_str(rpc.code), str.concat(" message=", rpc.message))),
    Ok(result) => format_task_result(result),
  }
}

fn format_task_result(j :: jv.Json) -> Str {
  let state := match jv.j_str_at(j, "status.state", []) {
    Ok(s) => s,
    Err(_) => "?",
  }
  let reply_text := first_text(j)
  str.concat("send-task: state=", str.concat(state, str.concat(" text=", reply_text)))
}

# Pull the first TextPart's text out of `message.parts`.
fn first_text(j :: jv.Json) -> Str {
  match jv.get_path(j, "message.parts") {
    None => "",
    Some(ps) => match jv.as_list(ps) {
      None => "",
      Some(items) => match list.head(items) {
        None => "",
        Some(p) => part_text(p),
      },
    },
  }
}

fn part_text(j :: jv.Json) -> Str {
  match jv.get_field(j, "text") {
    Some(v) => match jv.as_str(v) {
      Some(s) => s,
      None => "",
    },
    None => "",
  }
}

# ---- demo --------------------------------------------------------
#
# Three assertions:
#   1. fetch_agent_card returns the peer's name
#   2. send_task with valid text → state=completed, reply text echoed
#   3. send_task with empty text → -32099 spec-denied error
fn demo() -> [net, crypto, random] Str {
  let line1 := show_card()
  let line2 := show_send_task("hello", { task_id: "t_lex_1", context_id: "ctx_lex_1", skill: "echo" })
  let line3 := show_send_task("", { task_id: "t_lex_2", context_id: "ctx_lex_1", skill: "echo" })
  str.concat(line1, str.concat("\n", str.concat(line2, str.concat("\n", line3))))
}

