# Tests for `src/task.lex` — Task lifecycle transitions.

import "std.list" as list

import "std.str" as str

import "lex-schema/json_value" as jv

import "../src/message" as msg

import "../src/task" as tk

fn fresh() -> tk.Task {
  tk.submitted("t_1", "s_1", msg.user_text("go"))
}

fn submitted_to_working() -> Result[Unit, Str] {
  match tk.advance(fresh(), TSWorking, None) {
    Ok(t) => match t.state {
      TSWorking => Ok(()),
      _ => Err("wrong state"),
    },
    Err(e) => Err(tk.task_error_message(e)),
  }
}

fn working_to_completed_carries_message() -> Result[Unit, Str] {
  let working := match tk.advance(fresh(), TSWorking, None) {
    Ok(t) => t,
    Err(_) => fresh(),
  }
  let final := tk.advance(working, TSCompleted, Some(msg.agent_text("done")))
  match final {
    Ok(t) => match t.message {
      Some(_) => Ok(()),
      None => Err("message not carried"),
    },
    Err(e) => Err(tk.task_error_message(e)),
  }
}

fn terminal_rejects_advance() -> Result[Unit, Str] {
  let working := match tk.advance(fresh(), TSWorking, None) {
    Ok(t) => t,
    Err(_) => fresh(),
  }
  let done := match tk.advance(working, TSCompleted, None) {
    Ok(t) => t,
    Err(_) => working,
  }
  match tk.advance(done, TSWorking, None) {
    Err(_) => Ok(()),
    Ok(_) => Err("should have rejected"),
  }
}

fn input_required_round_trip() -> Result[Unit, Str] {
  let working := match tk.advance(fresh(), TSWorking, None) {
    Ok(t) => t,
    Err(_) => fresh(),
  }
  let waiting := match tk.advance(working, TSInputRequired, None) {
    Ok(t) => t,
    Err(_) => working,
  }
  match tk.advance(waiting, TSWorking, None) {
    Ok(_) => Ok(()),
    Err(e) => Err(tk.task_error_message(e)),
  }
}

fn invalid_initial_skip() -> Result[Unit, Str] {
  match tk.advance(fresh(), TSInputRequired, None) {
    Err(_) => Ok(()),
    Ok(_) => Err("should have rejected"),
  }
}

fn add_artifact_after_terminal() -> Result[Unit, Str] {
  let working := match tk.advance(fresh(), TSWorking, None) {
    Ok(t) => t,
    Err(_) => fresh(),
  }
  let done := match tk.advance(working, TSCompleted, None) {
    Ok(t) => t,
    Err(_) => working,
  }
  match tk.add_artifact(done, { name: "x", index: 0, parts: [] }) {
    Err(_) => Ok(()),
    Ok(_) => Err("should have rejected artifact-add on terminal"),
  }
}

# Wire shape: A2A v0.3+ uses `contextId` (not `sessionId`) and emits
# `kind: "task"` as the discriminator.
fn task_emits_v03_wire_fields() -> Result[Unit, Str] {
  let s := jv.stringify(tk.task_to_json(fresh()))
  if str.contains(s, "\"kind\":\"task\"") and str.contains(s, "\"contextId\":\"s_1\"") and not str.contains(s, "\"sessionId\":") {
    Ok(())
  } else {
    Err(str.concat("wrong wire shape: ", s))
  }
}

fn state_label_roundtrip() -> Result[Unit, Str] {
  let names := ["submitted", "working", "input-required", "completed", "canceled", "failed"]
  let result := list.fold(names, "ok", fn (acc :: Str, n :: Str) -> Str {
    match tk.state_of(n) {
      None => str.concat("unknown: ", n),
      Some(s) => if tk.state_label(s) == n {
        acc
      } else {
        str.concat("mismatch: ", n)
      },
    }
  })
  if result == "ok" {
    Ok(())
  } else {
    Err(result)
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [submitted_to_working(), working_to_completed_carries_message(), terminal_rejects_advance(), input_required_round_trip(), invalid_initial_skip(), add_artifact_after_terminal(), task_emits_v03_wire_fields(), state_label_roundtrip()]
}

fn run_all_count() -> Int {
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
fn run_all() -> Unit {
  if run_all_count() == 0 {
    ()
  } else {
    let __boom := 1 / 0
    ()
  }
}

