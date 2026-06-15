# Tests for src/memory.lex — KV store, append log, state blob, context injection.
#
# Each test opens a fresh SQLite file under /tmp so tests are fully isolated
# and reruns never collide.
#
#   lex test --allow-effects crypto,random,sql,fs_read,fs_write,time tests/

import "std.list" as list

import "std.str" as str

import "std.int" as int

import "std.crypto" as crypto

import "lex-orm/src/connection" as conn

import "../src/memory" as mem

fn fresh_path() -> [crypto, random] Str {
  str.concat("/tmp/lex_mem_test_", str.concat(crypto.random_str_hex(8), ".db"))
}

fn open_fresh() -> [crypto, random, sql, fs_write] Result[conn.ConnDb, Str] {
  let path := fresh_path()
  match conn.connect_sqlite(path) {
    Err(_) => Err("connect_sqlite failed"),
    Ok(db) => match mem.init_schema(db) {
      Err(e) => Err(e),
      Ok(_) => Ok(db),
    },
  }
}

# ── KV upsert ─────────────────────────────────────────────────────────────────
fn store_and_recall_by_key() -> [crypto, random, sql, fs_read, fs_write, time] Result[Unit, Str] {
  match open_fresh() {
    Err(e) => Err(e),
    Ok(db) => {
      let __s := mem.store(db, "agent1", "constraint", "max_tokens", "4096")
      match mem.recall_by_key(db, "agent1", "constraint", "max_tokens") {
        None => Err("expected entry not found"),
        Some(e) => if e.content == "4096" {
          Ok(())
        } else {
          Err(str.concat("wrong content: ", e.content))
        },
      }
    },
  }
}

fn upsert_replaces_existing() -> [crypto, random, sql, fs_read, fs_write, time] Result[Unit, Str] {
  match open_fresh() {
    Err(e) => Err(e),
    Ok(db) => {
      let __1 := mem.store(db, "agent1", "preference", "tone", "formal")
      let __2 := mem.store(db, "agent1", "preference", "tone", "casual")
      let all := mem.recall_kind(db, "agent1", "preference")
      if list.len(all) == 1 {
        match list.head(all) {
          None => Err("list empty after upsert"),
          Some(e) => if e.content == "casual" {
            Ok(())
          } else {
            Err(str.concat("stale value after upsert: ", e.content))
          },
        }
      } else {
        Err(str.concat("expected 1 entry, got ", int.to_str(list.len(all))))
      }
    },
  }
}

fn different_agents_isolated() -> [crypto, random, sql, fs_read, fs_write, time] Result[Unit, Str] {
  match open_fresh() {
    Err(e) => Err(e),
    Ok(db) => {
      let __1 := mem.store(db, "agentA", "constraint", "lang", "lex")
      let __2 := mem.store(db, "agentB", "constraint", "lang", "rust")
      match mem.recall_by_key(db, "agentA", "constraint", "lang") {
        None => Err("agentA entry missing"),
        Some(a) => match mem.recall_by_key(db, "agentB", "constraint", "lang") {
          None => Err("agentB entry missing"),
          Some(b) => if a.content == "lex" and b.content == "rust" {
            Ok(())
          } else {
            Err(str.join(["isolation broken: a=", a.content, " b=", b.content], ""))
          },
        },
      }
    },
  }
}

fn recall_by_key_missing_returns_none() -> [crypto, random, sql, fs_read, fs_write, time] Result[Unit, Str] {
  match open_fresh() {
    Err(e) => Err(e),
    Ok(db) => match mem.recall_by_key(db, "agent1", "constraint", "nonexistent") {
      None => Ok(()),
      Some(_) => Err("expected None for missing key"),
    },
  }
}

# ── Append log ────────────────────────────────────────────────────────────────
fn empty_key_appends() -> [crypto, random, sql, fs_read, fs_write, time] Result[Unit, Str] {
  match open_fresh() {
    Err(e) => Err(e),
    Ok(db) => {
      let __1 := mem.store(db, "agent1", "lesson", "", "first lesson")
      let __2 := mem.store(db, "agent1", "lesson", "", "second lesson")
      let entries := mem.recall_kind(db, "agent1", "lesson")
      if list.len(entries) == 2 {
        Ok(())
      } else {
        Err(str.concat("expected 2 appended entries, got ", int.to_str(list.len(entries))))
      }
    },
  }
}

# ── recall_all ────────────────────────────────────────────────────────────────
fn recall_all_returns_all_kinds() -> [crypto, random, sql, fs_read, fs_write, time] Result[Unit, Str] {
  match open_fresh() {
    Err(e) => Err(e),
    Ok(db) => {
      let __1 := mem.store(db, "agentX", "constraint", "k1", "v1")
      let __2 := mem.store(db, "agentX", "lesson", "", "obs1")
      let __3 := mem.store(db, "agentX", "tech_stack", "lang", "lex")
      let all := mem.recall_all(db, "agentX")
      if list.len(all) == 3 {
        Ok(())
      } else {
        Err(str.concat("expected 3 entries, got ", int.to_str(list.len(all))))
      }
    },
  }
}

fn recall_all_empty_agent_returns_empty() -> [crypto, random, sql, fs_read, fs_write, time] Result[Unit, Str] {
  match open_fresh() {
    Err(e) => Err(e),
    Ok(db) => {
      let entries := mem.recall_all(db, "nobody")
      if list.len(entries) == 0 {
        Ok(())
      } else {
        Err("expected empty list for unknown agent")
      }
    },
  }
}

# ── State blob ────────────────────────────────────────────────────────────────
fn state_defaults_to_empty_json() -> [crypto, random, sql, fs_read, fs_write, time] Result[Unit, Str] {
  match open_fresh() {
    Err(e) => Err(e),
    Ok(db) => {
      let s := mem.load_state(db, "agent1")
      if s == "{}" {
        Ok(())
      } else {
        Err(str.concat("expected '{}', got: ", s))
      }
    },
  }
}

fn save_and_load_state_round_trips() -> [crypto, random, sql, fs_read, fs_write, time] Result[Unit, Str] {
  match open_fresh() {
    Err(e) => Err(e),
    Ok(db) => {
      let payload := "{\"step\":3,\"done\":false}"
      let __s := mem.save_state(db, "agent1", payload)
      let loaded := mem.load_state(db, "agent1")
      if loaded == payload {
        Ok(())
      } else {
        Err(str.concat("state mismatch: ", loaded))
      }
    },
  }
}

fn save_state_overwrites() -> [crypto, random, sql, fs_read, fs_write, time] Result[Unit, Str] {
  match open_fresh() {
    Err(e) => Err(e),
    Ok(db) => {
      let __1 := mem.save_state(db, "agent1", "{\"v\":1}")
      let __2 := mem.save_state(db, "agent1", "{\"v\":2}")
      let loaded := mem.load_state(db, "agent1")
      if loaded == "{\"v\":2}" {
        Ok(())
      } else {
        Err(str.concat("overwrite failed, got: ", loaded))
      }
    },
  }
}

fn state_isolated_per_agent() -> [crypto, random, sql, fs_read, fs_write, time] Result[Unit, Str] {
  match open_fresh() {
    Err(e) => Err(e),
    Ok(db) => {
      let __1 := mem.save_state(db, "agentA", "{\"a\":1}")
      let __2 := mem.save_state(db, "agentB", "{\"b\":2}")
      let a := mem.load_state(db, "agentA")
      let b := mem.load_state(db, "agentB")
      if a == "{\"a\":1}" and b == "{\"b\":2}" {
        Ok(())
      } else {
        Err(str.join(["state isolation broken: a=", a, " b=", b], ""))
      }
    },
  }
}

# ── to_context ────────────────────────────────────────────────────────────────
fn to_context_empty_returns_empty_str() -> Result[Unit, Str] {
  let ctx := mem.to_context([])
  if ctx == "" {
    Ok(())
  } else {
    Err(str.concat("expected empty string, got: ", ctx))
  }
}

fn to_context_non_empty_has_header() -> [crypto, random, sql, fs_read, fs_write, time] Result[Unit, Str] {
  match open_fresh() {
    Err(e) => Err(e),
    Ok(db) => {
      let __s := mem.store(db, "agent1", "constraint", "speed", "fast")
      let entries := mem.recall_all(db, "agent1")
      let ctx := mem.to_context(entries)
      if str.contains(ctx, "Memory:") {
        Ok(())
      } else {
        Err(str.concat("header missing from context: ", ctx))
      }
    },
  }
}

fn to_context_includes_entry_content() -> [crypto, random, sql, fs_read, fs_write, time] Result[Unit, Str] {
  match open_fresh() {
    Err(e) => Err(e),
    Ok(db) => {
      let __s := mem.store(db, "agent1", "lesson", "", "always test in prod")
      let entries := mem.recall_all(db, "agent1")
      let ctx := mem.to_context(entries)
      if str.contains(ctx, "always test in prod") {
        Ok(())
      } else {
        Err(str.concat("content missing from context: ", ctx))
      }
    },
  }
}

# ── Suite ─────────────────────────────────────────────────────────────────────
fn suite() -> [crypto, random, sql, fs_read, fs_write, time] List[Result[Unit, Str]] {
  [store_and_recall_by_key(), upsert_replaces_existing(), different_agents_isolated(), recall_by_key_missing_returns_none(), empty_key_appends(), recall_all_returns_all_kinds(), recall_all_empty_agent_returns_empty(), state_defaults_to_empty_json(), save_and_load_state_round_trips(), save_state_overwrites(), state_isolated_per_agent(), to_context_empty_returns_empty_str(), to_context_non_empty_has_header(), to_context_includes_entry_content()]
}

fn run_all() -> [crypto, random, sql, fs_read, fs_write, time] Int {
  list.fold(suite(), 0, fn (acc :: Int, v :: Result[Unit, Str]) -> Int {
    match v {
      Ok(_) => acc,
      Err(_) => acc + 1,
    }
  })
}

