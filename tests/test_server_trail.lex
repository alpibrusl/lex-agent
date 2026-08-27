# Tests for lex-agent server trail emission
#
# Each test opens a :memory: trail log, attaches it via
# `srv.with_trail`, runs a dispatch_request, then asserts that the
# log contains the expected a2a.* event kinds.

import "std.list" as list

import "std.str" as str

import "lex-schema/schema" as sch

import "lex-spec/capability" as cap

import "lex-trail/event" as ev

import "lex-trail/log" as trail

import "../src/agent_card" as card

import "../src/server" as srv

import "../src/message" as msg

import "../src/task" as tk

# ---- Test agent -------------------------------------------------
fn echo_cap() -> cap.Capability {
  cap.inbound("echo", "test echo skill", { title: "Args", description: "", fields: [] })
}

fn echo_handler(m :: msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] srv.HandlerOutcome {
  { next_state: TSCompleted, reply: Some(msg.agent_text("pong")), artifacts: [] }
}

fn test_agent(log :: trail.Log) -> srv.AgentDef {
  let base := srv.make_agent_def(card.make("test", "test agent", "0.0.1", "http://localhost", [echo_cap()]), [{ capability: echo_cap(), handle: echo_handler }])
  srv.with_trail(base, log)
}

fn good_envelope() -> Str {
  "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tasks/send\",\"params\":{\"id\":\"t1\",\"contextId\":\"ctx1\",\"message\":{\"kind\":\"message\",\"messageId\":\"m1\",\"role\":\"user\",\"parts\":[{\"type\":\"text\",\"text\":\"hello\"}]},\"skill\":\"echo\"}}"
}

# ---- Helpers ----------------------------------------------------
fn has_kind(log :: trail.Log, kind :: Str) -> [sql] Bool {
  match trail.range(log, 0, 9999999999999) {
    Err(_) => false,
    Ok(events) => list.fold(events, false, fn (acc :: Bool, e :: ev.Event) -> Bool {
      acc or e.kind == kind
    }),
  }
}

# ---- Tests ------------------------------------------------------
fn test_dispatch_emits_task_received() -> [sql, fs_write, time, io, crypto, random, fs_read, net, concurrent, llm, proc, approval] Result[Unit, Str] {
  match trail.open_memory() {
    Err(e) => Err(str.concat("open_memory: ", e)),
    Ok(log) => {
      let agent := test_agent(log)
      let _resp := srv.dispatch_request(agent, good_envelope())
      if has_kind(log, "a2a.task.received") {
        Ok(())
      } else {
        Err("missing a2a.task.received event")
      }
    },
  }
}

fn test_dispatch_emits_state_change() -> [sql, fs_write, time, io, crypto, random, fs_read, net, concurrent, llm, proc, approval] Result[Unit, Str] {
  match trail.open_memory() {
    Err(e) => Err(str.concat("open_memory: ", e)),
    Ok(log) => {
      let agent := test_agent(log)
      let _resp := srv.dispatch_request(agent, good_envelope())
      if has_kind(log, "a2a.task.state_change") {
        Ok(())
      } else {
        Err("missing a2a.task.state_change event")
      }
    },
  }
}

fn test_dispatch_emits_message_sent() -> [sql, fs_write, time, io, crypto, random, fs_read, net, concurrent, llm, proc, approval] Result[Unit, Str] {
  match trail.open_memory() {
    Err(e) => Err(str.concat("open_memory: ", e)),
    Ok(log) => {
      let agent := test_agent(log)
      let _resp := srv.dispatch_request(agent, good_envelope())
      if has_kind(log, "a2a.message.sent") {
        Ok(())
      } else {
        Err("missing a2a.message.sent event")
      }
    },
  }
}

fn test_dispatch_no_trail_is_fine() -> [sql, fs_write, time, io, crypto, random, fs_read, net, concurrent, llm, proc, approval] Result[Unit, Str] {
  let base := srv.make_agent_def(card.make("test", "test agent", "0.0.1", "http://localhost", [echo_cap()]), [{ capability: echo_cap(), handle: echo_handler }])
  let _resp := srv.dispatch_request(base, good_envelope())
  Ok(())
}

# A negative control for has_kind, and the reason it is here: the three tests
# above ask only whether a kind is PRESENT. If has_kind ever stopped
# discriminating — comparing with != rather than ==, say — it would return true
# whenever the trail held any other kind, and all three would still pass while
# checking nothing. Pinning that an absent kind reads as absent is what makes
# the other three mean what they say.
fn test_has_kind_discriminates() -> [sql, fs_write, time, io, crypto, random, fs_read, net, concurrent, llm, proc, approval] Result[Unit, Str] {
  match trail.open_memory() {
    Err(e) => Err(str.concat("open_memory: ", e)),
    Ok(log) => {
      let agent := test_agent(log)
      let _resp := srv.dispatch_request(agent, good_envelope())
      if has_kind(log, "a2a.task.received") and not has_kind(log, "a2a.task.never.emitted") {
        Ok(())
      } else {
        Err("has_kind must tell an emitted kind from one that was never written")
      }
    },
  }
}

fn suite() -> [sql, fs_write, time, io, crypto, random, fs_read, net, concurrent, llm, proc, approval] List[Result[Unit, Str]] {
  [test_dispatch_emits_task_received(), test_dispatch_emits_state_change(), test_dispatch_emits_message_sent(), test_dispatch_no_trail_is_fine(), test_has_kind_discriminates()]
}

fn run_all_count() -> [sql, fs_write, time, io, crypto, random, fs_read, net, concurrent, llm, proc, approval] Int {
  list.fold(suite(), 0, fn (acc :: Int, v :: Result[Unit, Str]) -> Int {
    match v {
      Ok(_) => acc,
      Err(_) => acc + 1,
    }
  })
}

# `lex test` calls `run_all` and DISCARDS what it returns (lex-lang#757), so a
# returned failure count reports `ok` however many assertions failed. Only a
# raise fails a file — the same idiom lex-ems, lex-web and lex-guard use.
# Run `run_all_count` directly to see which assertions failed.
fn run_all() -> [sql, fs_write, time, io, crypto, random, fs_read, net, concurrent, llm, proc, approval] Unit {
  if run_all_count() == 0 {
    ()
  } else {
    let __boom := 1 / 0
    ()
  }
}

