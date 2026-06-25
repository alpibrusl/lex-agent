# Tests for lex-agent client trail emission
#
# `send_task_traced` and `subscribe_traced` emit an a2a.* event
# BEFORE the HTTP call. Since no server is running, the HTTP call
# will fail — but the trail event is already written by the time
# the call is attempted, so we can verify emission independently
# of network success.

import "std.list" as list

import "std.str" as str

import "lex-trail/log" as trail

import "../src/client" as client

import "../src/message" as msg

# ---- Tests ------------------------------------------------------
fn test_send_task_traced_emits_task_sent() -> [sql, fs_write, time, net, crypto, random] Result[Unit, Str] {
  match trail.open_memory() {
    Err(e) => Err(str.concat("open_memory: ", e)),
    Ok(log) => {
      let m := msg.user_text("hello")
      let opts := client.default_opts()
      let _res := client.send_task_traced(log, None, "http://127.0.0.1:19999", m, opts)
      match trail.head(log) {
        None => Err("trail is empty — a2a.task.sent not written"),
        Some(e) => if e.kind == "a2a.task.sent" {
          Ok(())
        } else {
          Err(str.concat("expected a2a.task.sent, got: ", e.kind))
        },
      }
    },
  }
}

fn test_subscribe_traced_emits_message_sent() -> [sql, fs_write, time, net, crypto, random, stream] Result[Unit, Str] {
  match trail.open_memory() {
    Err(e) => Err(str.concat("open_memory: ", e)),
    Ok(log) => {
      let m := msg.user_text("hello")
      let opts := client.default_opts()
      let _res := client.subscribe_traced(log, None, "http://127.0.0.1:19999", m, opts, "")
      match trail.head(log) {
        None => Err("trail is empty — a2a.message.sent not written"),
        Some(e) => if e.kind == "a2a.message.sent" {
          Ok(())
        } else {
          Err(str.concat("expected a2a.message.sent, got: ", e.kind))
        },
      }
    },
  }
}

fn suite() -> [sql, fs_write, time, net, crypto, random, stream] List[Result[Unit, Str]] {
  [test_send_task_traced_emits_task_sent(), test_subscribe_traced_emits_message_sent()]
}

fn run_all() -> [sql, fs_write, time, net, crypto, random, stream] Int {
  list.fold(suite(), 0, fn (acc :: Int, v :: Result[Unit, Str]) -> Int {
    match v {
      Ok(_) => acc,
      Err(_) => acc + 1,
    }
  })
}

