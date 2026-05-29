# Tests for `src/store.lex` — actor-backed task store.
#
# Every test declares `[concurrent]` because `store.spawn_store` /
# `put` / `get` / `cancel` go through `std.conc`. Run via:
#
#   lex test --allow-effects \
#     io,time,crypto,random,sql,fs_read,fs_write,net,concurrent tests/

import "std.list" as list

import "std.str" as str

import "../src/message" as msg

import "../src/task" as tk

import "../src/store" as store

# Each test boots a fresh actor so we don't carry state across cases.
fn put_then_get_round_trips() -> [concurrent] Result[Unit, Str] {
  let addr := store.spawn_store()
  let t := tk.submitted("t_round", "ctx_1", msg.user_text("hi"))
  let __ := store.put(addr, t)
  match store.get(addr, "t_round") {
    None => Err("get returned None after put"),
    Some(found) => if found.id == "t_round" {
      Ok(())
    } else {
      Err(str.concat("id mismatch: ", found.id))
    },
  }
}

fn get_unknown_is_none() -> [concurrent] Result[Unit, Str] {
  let addr := store.spawn_store()
  match store.get(addr, "nope") {
    None => Ok(()),
    Some(_) => Err("unknown id should return None"),
  }
}

fn put_replaces_existing() -> [concurrent] Result[Unit, Str] {
  let addr := store.spawn_store()
  let t1 := tk.submitted("t_dup", "ctx_1", msg.user_text("first"))
  let __1 := store.put(addr, t1)
  let working := match tk.advance(t1, TSWorking, None) {
    Ok(t) => t,
    Err(_) => t1,
  }
  let __2 := store.put(addr, working)
  match store.get(addr, "t_dup") {
    None => Err("get returned None"),
    Some(found) => match found.state {
      TSWorking => Ok(()),
      _ => Err(str.concat("expected working, got ", tk.state_label(found.state))),
    },
  }
}

# Cancel from submitted → canceled is a legal transition; the
# stored task should reflect the new state on subsequent gets.
fn cancel_transitions_state() -> [concurrent] Result[Unit, Str] {
  let addr := store.spawn_store()
  let t := tk.submitted("t_can", "ctx_1", msg.user_text("go"))
  let __ := store.put(addr, t)
  match store.cancel(addr, "t_can") {
    Err(reason) => Err(str.concat("cancel failed: ", reason)),
    Ok(updated) => match updated.state {
      TSCanceled => {
        match store.get(addr, "t_can") {
          None => Err("disappeared after cancel"),
          Some(after) => match after.state {
            TSCanceled => Ok(()),
            _ => Err("get didn't see canceled state"),
          },
        }
      },
      _ => Err("cancel returned wrong state"),
    },
  }
}

fn cancel_unknown_returns_not_found() -> [concurrent] Result[Unit, Str] {
  let addr := store.spawn_store()
  match store.cancel(addr, "ghost") {
    Err(reason) => if str.contains(reason, "not found") {
      Ok(())
    } else {
      Err(str.concat("wrong error: ", reason))
    },
    Ok(_) => Err("cancel of unknown id should error"),
  }
}

# Cancelling an already-terminal task surfaces the
# InvalidTransition error from `tk.advance`.
fn cancel_terminal_rejected() -> [concurrent] Result[Unit, Str] {
  let addr := store.spawn_store()
  let t := tk.submitted("t_term", "ctx_1", msg.user_text("go"))
  let __1 := store.put(addr, t)
  let _ok := store.cancel(addr, "t_term")
  match store.cancel(addr, "t_term") {
    Err(_) => Ok(()),
    Ok(_) => Err("double-cancel should error"),
  }
}

fn suite() -> [concurrent] List[Result[Unit, Str]] {
  [put_then_get_round_trips(), get_unknown_is_none(), put_replaces_existing(), cancel_transitions_state(), cancel_unknown_returns_not_found(), cancel_terminal_rejected()]
}

fn run_all() -> [concurrent] Int {
  list.fold(suite(), 0, fn (acc :: Int, v :: Result[Unit, Str]) -> Int {
    match v {
      Ok(_) => acc,
      Err(_) => acc + 1,
    }
  })
}

