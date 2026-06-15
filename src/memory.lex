# memory.lex — Structured per-agent memory store.
#
# Provides three capabilities on any caller-supplied ConnDb handle:
#
#   KV memory   — upsert-on-key named facts (constraint, preference, lesson)
#   Append log  — ordered observations appended without a key (kind="obs", etc.)
#   State blob  — opaque JSON per agent, backward-compatible with state_store
#
# Schema (init_schema is idempotent — call once per Db, usually at startup):
#
#   agent_memory  — id, agent_id, kind, key, content, ts
#   agent_state   — agent_id (PK), state_json, updated_at
#
# to_context(entries) formats recalled entries as a bullet list for direct
# concatenation into a system prompt. Returns "" for empty list.
#
# ConnDb (from lex-orm/src/connection) carries dialect info so queries work
# on both SQLite (? placeholders) and Postgres ($1, $2, ... placeholders).

import "std.sql" as sql

import "std.time" as time

import "std.str" as str

import "std.list" as list

import "std.crypto" as crypto

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

# ── Types ─────────────────────────────────────────────────────────────────────
type MemoryEntry = { id :: Str, agent_id :: Str, kind :: Str, key :: Str, content :: Str, ts :: Str }

# ── Schema ────────────────────────────────────────────────────────────────────
fn init_schema(db :: conn.ConnDb) -> [sql, fs_write] Result[Unit, Str] {
  match sql.exec(db.handle, "CREATE TABLE IF NOT EXISTS agent_memory (id TEXT NOT NULL PRIMARY KEY, agent_id TEXT NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL DEFAULT '', content TEXT NOT NULL, ts TEXT NOT NULL)", []) {
    Err(e) => Err(e.message),
    Ok(_) => match sql.exec(db.handle, "CREATE INDEX IF NOT EXISTS idx_mem_agent ON agent_memory(agent_id, kind)", []) {
      Err(e) => Err(e.message),
      Ok(_) => match sql.exec(db.handle, "CREATE TABLE IF NOT EXISTS agent_state (agent_id TEXT NOT NULL PRIMARY KEY, state_json TEXT NOT NULL DEFAULT '{}', updated_at TEXT NOT NULL)", []) {
        Err(e) => Err(e.message),
        Ok(_) => Ok(()),
      },
    },
  }
}

# ── Internal helpers ──────────────────────────────────────────────────────────
fn db_exec(db :: conn.ConnDb, sql_str :: Str, params :: List[SqlParam]) -> [sql, fs_write] Result[Unit, Str] {
  let sq := ormq.for_dialect({ sql: sql_str, params: params }, db.dialect)
  match sql.exec(db.handle, sq.sql, sq.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

type MemRow = { id :: Str, agent_id :: Str, kind :: Str, key :: Str, content :: Str, ts :: Str }

fn row_to_entry(r :: MemRow) -> MemoryEntry {
  { id: r.id, agent_id: r.agent_id, kind: r.kind, key: r.key, content: r.content, ts: r.ts }
}

fn db_query_mem(db :: conn.ConnDb, sql_str :: Str, params :: List[SqlParam]) -> [sql, fs_read] List[MemoryEntry] {
  let sq := ormq.for_dialect({ sql: sql_str, params: params }, db.dialect)
  let rows :: Result[List[MemRow], SqlError] := sql.query(db.handle, sq.sql, sq.params)
  match rows {
    Err(_) => [],
    Ok(rs) => list.map(rs, row_to_entry),
  }
}

# ── KV / append store ─────────────────────────────────────────────────────────
# Non-empty key → upsert: removes any existing row with the same
#   (agent_id, kind, key) then inserts the new value.
# Empty key → append: always inserts a fresh row (useful for lessons, obs).
fn store(db :: conn.ConnDb, agent_id :: Str, kind :: Str, key :: Str, content :: Str) -> [sql, fs_write, time, crypto, random] Unit {
  let now := time.now_str()
  let id := crypto.random_str_hex(8)
  if str.is_empty(key) {
    let __r := db_exec(db, "INSERT INTO agent_memory (id, agent_id, kind, key, content, ts) VALUES (?, ?, ?, '', ?, ?)", [PStr(id), PStr(agent_id), PStr(kind), PStr(content), PStr(now)])
    ()
  } else {
    let __d := db_exec(db, "DELETE FROM agent_memory WHERE agent_id=? AND kind=? AND key=?", [PStr(agent_id), PStr(kind), PStr(key)])
    let __i := db_exec(db, "INSERT INTO agent_memory (id, agent_id, kind, key, content, ts) VALUES (?, ?, ?, ?, ?, ?)", [PStr(id), PStr(agent_id), PStr(kind), PStr(key), PStr(content), PStr(now)])
    ()
  }
}

# All entries for an agent, newest first.
fn recall_all(db :: conn.ConnDb, agent_id :: Str) -> [sql, fs_read] List[MemoryEntry] {
  db_query_mem(db, "SELECT id, agent_id, kind, key, content, ts FROM agent_memory WHERE agent_id=? ORDER BY ts DESC", [PStr(agent_id)])
}

# Recall a single entry by (agent_id, kind, key). None if absent.
fn recall_by_key(db :: conn.ConnDb, agent_id :: Str, kind :: Str, key :: Str) -> [sql, fs_read] Option[MemoryEntry] {
  let sq := ormq.for_dialect({ sql: "SELECT id, agent_id, kind, key, content, ts FROM agent_memory WHERE agent_id=? AND kind=? AND key=? ORDER BY ts DESC LIMIT 1", params: [PStr(agent_id), PStr(kind), PStr(key)] }, db.dialect)
  let rows :: Result[List[MemRow], SqlError] := sql.query(db.handle, sq.sql, sq.params)
  match rows {
    Err(_) => None,
    Ok(rs) => match list.head(rs) {
      None => None,
      Some(r) => Some(row_to_entry(r)),
    },
  }
}

# Recall all entries for a given kind, newest first.
fn recall_kind(db :: conn.ConnDb, agent_id :: Str, kind :: Str) -> [sql, fs_read] List[MemoryEntry] {
  db_query_mem(db, "SELECT id, agent_id, kind, key, content, ts FROM agent_memory WHERE agent_id=? AND kind=? ORDER BY ts DESC", [PStr(agent_id), PStr(kind)])
}

# ── State blob ────────────────────────────────────────────────────────────────
fn load_state(db :: conn.ConnDb, agent_id :: Str) -> [sql, fs_read] Str {
  let sq := ormq.for_dialect({ sql: "SELECT state_json FROM agent_state WHERE agent_id=?", params: [PStr(agent_id)] }, db.dialect)
  let rows :: Result[List[{ state_json :: Str }], SqlError] := sql.query(db.handle, sq.sql, sq.params)
  match rows {
    Err(_) => "{}",
    Ok(rs) => match list.head(rs) {
      None => "{}",
      Some(r) => r.state_json,
    },
  }
}

fn save_state(db :: conn.ConnDb, agent_id :: Str, state_json :: Str) -> [sql, fs_write, time] Unit {
  let now := time.now_str()
  let __r := db_exec(db, "INSERT INTO agent_state (agent_id, state_json, updated_at) VALUES (?, ?, ?) ON CONFLICT(agent_id) DO UPDATE SET state_json=excluded.state_json, updated_at=excluded.updated_at", [PStr(agent_id), PStr(state_json), PStr(now)])
  ()
}

# ── Context injection ──────────────────────────────────────────────────────────
# Returns "" for empty list — safe to unconditionally str.concat into a system prompt.
# Non-empty result begins with "\n\nMemory:\n" so callers need no separator logic.
fn to_context(entries :: List[MemoryEntry]) -> Str {
  if list.len(entries) == 0 {
    ""
  } else {
    let lines := list.map(entries, fn (e :: MemoryEntry) -> Str {
      let label := if str.is_empty(e.key) {
        str.join(["[", e.kind, "] "], "")
      } else {
        str.join(["[", e.kind, "/", e.key, "] "], "")
      }
      str.concat("- ", str.concat(label, e.content))
    })
    str.concat("\n\nMemory:\n", str.join(lines, "\n"))
  }
}

