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

# ── store_kv / recall_scoped (lex-agent#26) ─────────────────────────────────────
# Raw row count regardless of `superseded` — the only way to prove `store_kv`
# actually PRESERVES the old row (marks it dead) rather than deleting it, since
# every public recall function deliberately hides superseded rows.
fn raw_row_count(db :: conn.ConnDb, agent_id :: Str) -> [sql, fs_read] Int {
  let rows :: Result[List[{ n :: Int }], SqlError] := sql.query(db.handle, "SELECT COUNT(*) AS n FROM agent_memory WHERE agent_id=?", [PStr(agent_id)])
  match rows {
    Err(_) => -1,
    Ok(rs) => match list.head(rs) {
      None => -1,
      Some(r) => r.n,
    },
  }
}

fn store_kv_upsert_supersedes_not_deletes() -> [crypto, random, sql, fs_read, fs_write, time] Result[Unit, Str] {
  match open_fresh() {
    Err(e) => Err(e),
    Ok(db) => {
      let __1 := mem.store_kv(db, "agent1", "constraint", "budget", "100", "semantic", "medium", "global", "")
      let __2 := mem.store_kv(db, "agent1", "constraint", "budget", "200", "semantic", "medium", "global", "")
      let live := mem.recall_scoped(db, "agent1", "global", 10)
      if list.len(live) == 1 {
        match list.head(live) {
          None => Err("live entry vanished"),
          Some(e) => if e.content == "200" {
            if raw_row_count(db, "agent1") == 2 {
              Ok(())
            } else {
              Err(str.concat("expected the superseded row to survive (count=2), got ", int.to_str(raw_row_count(db, "agent1"))))
            }
          } else {
            Err(str.concat("expected the live value to be the newest, got ", e.content))
          },
        }
      } else {
        Err(str.concat("expected exactly 1 live entry, got ", int.to_str(list.len(live))))
      }
    },
  }
}

fn store_kv_unchanged_value_is_noop() -> [crypto, random, sql, fs_read, fs_write, time] Result[Unit, Str] {
  match open_fresh() {
    Err(e) => Err(e),
    Ok(db) => {
      let __1 := mem.store_kv(db, "agent1", "constraint", "budget", "100", "semantic", "medium", "global", "")
      let __2 := mem.store_kv(db, "agent1", "constraint", "budget", "100", "semantic", "medium", "global", "")
      if raw_row_count(db, "agent1") == 1 {
        Ok(())
      } else {
        Err(str.concat("re-storing the same value must not write a new row, got count ", int.to_str(raw_row_count(db, "agent1"))))
      }
    },
  }
}

fn store_kv_empty_key_dedupes_identical_appends() -> [crypto, random, sql, fs_read, fs_write, time] Result[Unit, Str] {
  match open_fresh() {
    Err(e) => Err(e),
    Ok(db) => {
      let __1 := mem.store_kv(db, "agent1", "lesson", "", "always test in prod", "episodic", "high", "global", "")
      let __2 := mem.store_kv(db, "agent1", "lesson", "", "always test in prod", "episodic", "high", "global", "")
      let __3 := mem.store_kv(db, "agent1", "lesson", "", "a genuinely different lesson", "episodic", "high", "global", "")
      if raw_row_count(db, "agent1") == 2 {
        Ok(())
      } else {
        Err(str.concat("expected 2 rows (1 deduped pair + 1 distinct), got ", int.to_str(raw_row_count(db, "agent1"))))
      }
    },
  }
}

fn recall_scoped_filters_by_scope() -> [crypto, random, sql, fs_read, fs_write, time] Result[Unit, Str] {
  match open_fresh() {
    Err(e) => Err(e),
    Ok(db) => {
      let __1 := mem.store_kv(db, "agent1", "constraint", "k1", "tenant-a value", "semantic", "medium", "tenant-a", "")
      let __2 := mem.store_kv(db, "agent1", "constraint", "k2", "tenant-b value", "semantic", "medium", "tenant-b", "")
      let a := mem.recall_scoped(db, "agent1", "tenant-a", 10)
      if list.len(a) == 1 {
        match list.head(a) {
          Some(e) => if e.content == "tenant-a value" {
            Ok(())
          } else {
            Err(str.concat("wrong scope leaked in: ", e.content))
          },
          None => Err("entry vanished"),
        }
      } else {
        Err(str.concat("expected exactly 1 entry scoped to tenant-a, got ", int.to_str(list.len(a))))
      }
    },
  }
}

fn recall_scoped_excludes_superseded() -> [crypto, random, sql, fs_read, fs_write, time] Result[Unit, Str] {
  match open_fresh() {
    Err(e) => Err(e),
    Ok(db) => {
      let __1 := mem.store_kv(db, "agent1", "constraint", "budget", "100", "semantic", "medium", "global", "")
      let __2 := mem.store_kv(db, "agent1", "constraint", "budget", "200", "semantic", "medium", "global", "")
      let live := mem.recall_scoped(db, "agent1", "global", 10)
      let has_stale := list.fold(live, false, fn (acc :: Bool, e :: mem.MemoryEntry) -> Bool {
        acc or e.content == "100"
      })
      if has_stale {
        Err("recall_scoped must not surface a superseded row")
      } else {
        Ok(())
      }
    },
  }
}

fn recall_scoped_excludes_expired() -> [crypto, random, sql, fs_read, fs_write, time] Result[Unit, Str] {
  match open_fresh() {
    Err(e) => Err(e),
    Ok(db) => {
      let __1 := mem.store_kv(db, "agent1", "obs", "", "long expired", "episodic", "medium", "global", "2000-01-01T00:00:00Z")
      let __2 := mem.store_kv(db, "agent1", "obs", "", "still valid", "episodic", "medium", "global", "9999-01-01T00:00:00Z")
      let live := mem.recall_scoped(db, "agent1", "global", 10)
      let contents := list.map(live, fn (e :: mem.MemoryEntry) -> Str {
        e.content
      })
      if str.join(contents, ",") == "still valid" {
        Ok(())
      } else {
        Err(str.concat("expired entry leaked into recall_scoped: ", str.join(contents, ",")))
      }
    },
  }
}

fn recall_scoped_orders_by_importance_then_recency() -> [crypto, random, sql, fs_read, fs_write, time] Result[Unit, Str] {
  match open_fresh() {
    Err(e) => Err(e),
    Ok(db) => {
      let __1 := mem.store_kv(db, "agent1", "obs", "", "low prio", "episodic", "low", "global", "")
      let __2 := mem.store_kv(db, "agent1", "obs", "", "high prio", "episodic", "high", "global", "")
      let __3 := mem.store_kv(db, "agent1", "obs", "", "medium prio", "episodic", "medium", "global", "")
      let live := mem.recall_scoped(db, "agent1", "global", 10)
      let contents := list.map(live, fn (e :: mem.MemoryEntry) -> Str {
        e.content
      })
      if str.join(contents, ",") == "high prio,medium prio,low prio" {
        Ok(())
      } else {
        Err(str.concat("expected high,medium,low order, got: ", str.join(contents, ",")))
      }
    },
  }
}

fn recall_scoped_limit_is_respected() -> [crypto, random, sql, fs_read, fs_write, time] Result[Unit, Str] {
  match open_fresh() {
    Err(e) => Err(e),
    Ok(db) => {
      let __1 := mem.store_kv(db, "agent1", "obs", "", "one", "episodic", "medium", "global", "")
      let __2 := mem.store_kv(db, "agent1", "obs", "", "two", "episodic", "medium", "global", "")
      let __3 := mem.store_kv(db, "agent1", "obs", "", "three", "episodic", "medium", "global", "")
      let live := mem.recall_scoped(db, "agent1", "global", 2)
      if list.len(live) == 2 {
        Ok(())
      } else {
        Err(str.concat("expected the limit to cap at 2, got ", int.to_str(list.len(live))))
      }
    },
  }
}

# recall_all/recall_kind/recall_by_key are unmoved by lex-agent#26 for any
# caller that only ever used `store` — every row `store` writes has
# `superseded=0` by column default, so the new filter these functions gained
# is a no-op against them. This locks that down explicitly.
fn plain_store_still_fully_visible_through_recall_all() -> [crypto, random, sql, fs_read, fs_write, time] Result[Unit, Str] {
  match open_fresh() {
    Err(e) => Err(e),
    Ok(db) => {
      let __1 := mem.store(db, "agent1", "constraint", "max_tokens", "4096")
      let __2 := mem.store(db, "agent1", "lesson", "", "always test in prod")
      let all := mem.recall_all(db, "agent1")
      if list.len(all) == 2 {
        Ok(())
      } else {
        Err(str.concat("lex-agent#26's filter changed store()'s existing recall_all behavior, got ", int.to_str(list.len(all))))
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

fn to_context_labeled_uses_custom_header() -> [crypto, random, sql, fs_read, fs_write, time] Result[Unit, Str] {
  match open_fresh() {
    Err(e) => Err(e),
    Ok(db) => {
      let __s := mem.store(db, "agent1", "constraint", "speed", "fast")
      let entries := mem.recall_all(db, "agent1")
      let ctx := mem.to_context_labeled(entries, "Durable memory (facts you have remembered, honor them):")
      if str.contains(ctx, "Durable memory (facts you have remembered, honor them):") and str.contains(ctx, "Memory:") == false {
        Ok(())
      } else {
        Err(str.concat("custom header not honored (or default header leaked in): ", ctx))
      }
    },
  }
}

fn to_context_labeled_empty_returns_empty_str() -> Result[Unit, Str] {
  let ctx := mem.to_context_labeled([], "Anything:")
  if ctx == "" {
    Ok(())
  } else {
    Err(str.concat("expected empty string, got: ", ctx))
  }
}

# ── Suite ─────────────────────────────────────────────────────────────────────
fn suite() -> [crypto, random, sql, fs_read, fs_write, time] List[Result[Unit, Str]] {
  [store_and_recall_by_key(), upsert_replaces_existing(), different_agents_isolated(), recall_by_key_missing_returns_none(), empty_key_appends(), recall_all_returns_all_kinds(), recall_all_empty_agent_returns_empty(), state_defaults_to_empty_json(), save_and_load_state_round_trips(), save_state_overwrites(), state_isolated_per_agent(), store_kv_upsert_supersedes_not_deletes(), store_kv_unchanged_value_is_noop(), store_kv_empty_key_dedupes_identical_appends(), recall_scoped_filters_by_scope(), recall_scoped_excludes_superseded(), recall_scoped_excludes_expired(), recall_scoped_orders_by_importance_then_recency(), recall_scoped_limit_is_respected(), plain_store_still_fully_visible_through_recall_all(), to_context_empty_returns_empty_str(), to_context_non_empty_has_header(), to_context_includes_entry_content(), to_context_labeled_uses_custom_header(), to_context_labeled_empty_returns_empty_str()]
}

fn run_all() -> [crypto, random, sql, fs_read, fs_write, time] Int {
  list.fold(suite(), 0, fn (acc :: Int, v :: Result[Unit, Str]) -> Int {
    match v {
      Ok(_) => acc,
      Err(_) => acc + 1,
    }
  })
}

