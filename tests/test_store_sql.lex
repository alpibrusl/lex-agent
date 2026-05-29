# Tests for the SQLite-backed task store (`src/store.lex` Sqlite arm).
#
# The headline assertion is durability: a task written through one
# `Store` handle is readable through a *separate* handle opened at the
# same path — the in-process stand-in for surviving a process restart.
#
# Every test declares `[sql, fs_write, crypto, random, concurrent]`:
# `sql` + `fs_write` to open and write the db, `crypto`/`random` to
# mint a unique db path per run (so reruns don't collide), and
# `concurrent` because the unified `store.put` / `get` / `cancel` carry
# the in-memory actor effect in their row even on the SQLite arm.
#
#   lex test --allow-effects \
#     io,time,crypto,random,sql,fs_read,fs_write,net,concurrent tests/

import "std.list"   as list
import "std.str"    as str
import "std.crypto" as crypto

import "../src/message" as msg
import "../src/task"    as tk
import "../src/store"   as store

# A fresh, unique on-disk path each run.
fn fresh_db_path() -> [crypto, random] Str {
  str.concat("/tmp/lex_agent_store_", str.concat(crypto.random_str_hex(8), ".db"))
}

fn open_at(path :: Str) -> [sql, fs_write, concurrent] Result[store.Store, Str] {
  store.open_store(SqliteStore(path))
}

# Headline test: a task put through handle s1 is visible through a
# freshly-opened handle s2 at the same path. This is what an in-memory
# store cannot do — the durability guarantee issue #10 asks for.
fn task_survives_reopen() -> [sql, fs_write, crypto, random, concurrent] Result[Unit, Str] {
  let path := fresh_db_path()
  match open_at(path) {
    Err(e) => Err(str.concat("open #1 failed: ", e)),
    Ok(s1) => {
      let t := tk.submitted("t_persist", "ctx_1", msg.user_text("survive me"))
      let __ := store.put(s1, t)
      match open_at(path) {
        Err(e) => Err(str.concat("reopen failed: ", e)),
        Ok(s2) => match store.get(s2, "t_persist") {
          None        => Err("task lost across reopen"),
          Some(found) => if found.id == "t_persist" { Ok(()) } else {
            Err(str.concat("id mismatch after reopen: ", found.id))
          },
        },
      }
    },
  }
}

# A completed task with a reply message + an artifact must round-trip
# through JSON storage intact (exercises tk.task_from_json fully).
fn full_task_round_trips() -> [sql, fs_write, crypto, random, concurrent] Result[Unit, Str] {
  let path := fresh_db_path()
  match open_at(path) {
    Err(e) => Err(str.concat("open failed: ", e)),
    Ok(s) => {
      let base := tk.submitted("t_full", "ctx_full", msg.user_text("ask"))
      let working := match tk.advance(base, TSWorking, None) {
        Ok(w)  => w,
        Err(_) => base,
      }
      # Artifacts are only legal on a non-terminal task, so attach it
      # while still `working`, then advance to `completed`.
      let with_art := match tk.add_artifact(working, { name: "out", index: 0, parts: [TextPart("data")] }) {
        Ok(a)  => a,
        Err(_) => working,
      }
      let done := match tk.advance(with_art, TSCompleted, Some(msg.agent_text("answer"))) {
        Ok(d)  => d,
        Err(_) => with_art,
      }
      let __ := store.put(s, done)
      match open_at(path) {
        Err(e) => Err(str.concat("reopen failed: ", e)),
        Ok(s2) => match store.get(s2, "t_full") {
          None        => Err("full task lost"),
          Some(found) => check_full(found),
        },
      }
    },
  }
}

fn check_full(t :: tk.Task) -> Result[Unit, Str] {
  match t.state {
    TSCompleted => if list.len(t.artifacts) == 1 {
      if list.len(t.history) >= 1 { Ok(()) } else { Err("history not restored") }
    } else {
      Err(str.concat("artifact count wrong: ", tk.state_label(t.state)))
    },
    _ => Err(str.concat("state not restored, got ", tk.state_label(t.state))),
  }
}

fn put_then_get_round_trips() -> [sql, fs_write, crypto, random, concurrent] Result[Unit, Str] {
  let path := fresh_db_path()
  match open_at(path) {
    Err(e) => Err(str.concat("open failed: ", e)),
    Ok(s) => {
      let t := tk.submitted("t_rt", "ctx_1", msg.user_text("hi"))
      let __ := store.put(s, t)
      match store.get(s, "t_rt") {
        None        => Err("get returned None after put"),
        Some(found) => if found.id == "t_rt" { Ok(()) } else {
          Err(str.concat("id mismatch: ", found.id))
        },
      }
    },
  }
}

fn get_unknown_is_none() -> [sql, fs_write, crypto, random, concurrent] Result[Unit, Str] {
  let path := fresh_db_path()
  match open_at(path) {
    Err(e) => Err(str.concat("open failed: ", e)),
    Ok(s)  => match store.get(s, "nope") {
      None    => Ok(()),
      Some(_) => Err("unknown id should return None"),
    },
  }
}

fn cancel_transitions_and_persists() -> [sql, fs_write, crypto, random, concurrent] Result[Unit, Str] {
  let path := fresh_db_path()
  match open_at(path) {
    Err(e) => Err(str.concat("open failed: ", e)),
    Ok(s) => {
      let t := tk.submitted("t_can", "ctx_1", msg.user_text("go"))
      let __ := store.put(s, t)
      match store.cancel(s, "t_can") {
        Err(reason) => Err(str.concat("cancel failed: ", reason)),
        Ok(updated) => match updated.state {
          TSCanceled => match store.get(s, "t_can") {
            None        => Err("disappeared after cancel"),
            Some(after) => match after.state {
              TSCanceled => Ok(()),
              _          => Err("get didn't see canceled state"),
            },
          },
          _ => Err("cancel returned wrong state"),
        },
      }
    },
  }
}

fn cancel_unknown_returns_not_found() -> [sql, fs_write, crypto, random, concurrent] Result[Unit, Str] {
  let path := fresh_db_path()
  match open_at(path) {
    Err(e) => Err(str.concat("open failed: ", e)),
    Ok(s)  => match store.cancel(s, "ghost") {
      Err(reason) => if str.contains(reason, "not found") { Ok(()) } else {
        Err(str.concat("wrong error: ", reason))
      },
      Ok(_) => Err("cancel of unknown id should error"),
    },
  }
}

fn cancel_terminal_rejected() -> [sql, fs_write, crypto, random, concurrent] Result[Unit, Str] {
  let path := fresh_db_path()
  match open_at(path) {
    Err(e) => Err(str.concat("open failed: ", e)),
    Ok(s) => {
      let t := tk.submitted("t_term", "ctx_1", msg.user_text("go"))
      let __1 := store.put(s, t)
      let _ok := store.cancel(s, "t_term")
      match store.cancel(s, "t_term") {
        Err(_) => Ok(()),
        Ok(_)  => Err("double-cancel should error"),
      }
    },
  }
}

fn suite() -> [sql, fs_write, crypto, random, concurrent] List[Result[Unit, Str]] {
  [
    task_survives_reopen(),
    full_task_round_trips(),
    put_then_get_round_trips(),
    get_unknown_is_none(),
    cancel_transitions_and_persists(),
    cancel_unknown_returns_not_found(),
    cancel_terminal_rejected(),
  ]
}

fn run_all() -> [sql, fs_write, crypto, random, concurrent] Int {
  list.fold(suite(), 0, fn (acc :: Int, v :: Result[Unit, Str]) -> Int {
    match v {
      Ok(_)  => acc,
      Err(_) => acc + 1,
    }
  })
}
