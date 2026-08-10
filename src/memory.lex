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
#   agent_memory  — id, agent_id, kind, key, content, ts, mtype, importance,
#                   scope, superseded, expires_at
#   agent_state   — agent_id (PK), state_json, updated_at
#
# `mtype`/`importance`/`scope`/`superseded`/`expires_at` (lex-agent#26) are an
# ADDITIVE second dimension alongside the original `kind`/`key`: `kind` stays
# a free-form category tag a caller invents ("constraint", "lesson",
# "tech_stack", ...); `mtype` is a fixed cognitive-memory-type enum
# (semantic/episodic/procedural) independent of it. Every existing function
# (`store`/`recall_all`/`recall_by_key`/`recall_kind`/`to_context`) keeps its
# exact signature and behavior — new rows just carry the new columns at their
# defaults ('semantic'/'medium'/'global'/0/''), which is a no-op for callers
# that never set them.
#
# `store_kv`/`recall_scoped` are the richer pair: `store_kv` marks a
# superseded row `superseded=1` instead of deleting it (keeps "what was true
# when" history, unlike `store`'s delete-then-insert), and `recall_scoped`
# reads back only the live view (`superseded=0`, unexpired), ordered by
# importance then recency.
#
# to_context(entries) formats recalled entries as a bullet list for direct
# concatenation into a system prompt. Returns "" for empty list.
# to_context_labeled(entries, header) is the same, with a caller-chosen
# header line instead of the hardcoded "Memory:" — for a host whose prompt
# wording predates this module and must not change (e.g. lex-soft's
# "Durable memory (facts you have remembered, honor them):").
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
type MemoryEntry = { id :: Str, agent_id :: Str, kind :: Str, key :: Str, content :: Str, ts :: Str, mtype :: Str, importance :: Str, scope :: Str, superseded :: Int, expires_at :: Str }

# ── Schema ────────────────────────────────────────────────────────────────────
# ADD COLUMN statements are tolerant (errors swallowed) so this stays
# idempotent both for a fresh table (which already has every column, via the
# CREATE below) and an existing deployment's table created before lex-agent#26
# (which needs the five new columns backfilled at their defaults).
fn add_column_tolerant(db :: conn.ConnDb, stmt :: Str) -> [sql, fs_write] Unit {
  let __i := sql.exec(db.handle, stmt, [])
  ()
}

fn upgrade_columns(db :: conn.ConnDb) -> [sql, fs_write] Unit {
  let __c1 := add_column_tolerant(db, "ALTER TABLE agent_memory ADD COLUMN mtype TEXT NOT NULL DEFAULT 'semantic'")
  let __c2 := add_column_tolerant(db, "ALTER TABLE agent_memory ADD COLUMN importance TEXT NOT NULL DEFAULT 'medium'")
  let __c3 := add_column_tolerant(db, "ALTER TABLE agent_memory ADD COLUMN scope TEXT NOT NULL DEFAULT 'global'")
  let __c4 := add_column_tolerant(db, "ALTER TABLE agent_memory ADD COLUMN superseded BIGINT NOT NULL DEFAULT 0")
  let __c5 := add_column_tolerant(db, "ALTER TABLE agent_memory ADD COLUMN expires_at TEXT NOT NULL DEFAULT ''")
  ()
}

fn init_schema(db :: conn.ConnDb) -> [sql, fs_write] Result[Unit, Str] {
  match sql.exec(db.handle, "CREATE TABLE IF NOT EXISTS agent_memory (id TEXT NOT NULL PRIMARY KEY, agent_id TEXT NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL DEFAULT '', content TEXT NOT NULL, ts TEXT NOT NULL, mtype TEXT NOT NULL DEFAULT 'semantic', importance TEXT NOT NULL DEFAULT 'medium', scope TEXT NOT NULL DEFAULT 'global', superseded BIGINT NOT NULL DEFAULT 0, expires_at TEXT NOT NULL DEFAULT '')", []) {
    Err(e) => Err(e.message),
    Ok(_) => {
      let __up := upgrade_columns(db)
      match sql.exec(db.handle, "CREATE INDEX IF NOT EXISTS idx_mem_agent ON agent_memory(agent_id, kind)", []) {
        Err(e) => Err(e.message),
        Ok(_) => match sql.exec(db.handle, "CREATE INDEX IF NOT EXISTS idx_mem_scope ON agent_memory(agent_id, scope, superseded)", []) {
          Err(e) => Err(e.message),
          Ok(_) => match sql.exec(db.handle, "CREATE TABLE IF NOT EXISTS agent_state (agent_id TEXT NOT NULL PRIMARY KEY, state_json TEXT NOT NULL DEFAULT '{}', updated_at TEXT NOT NULL)", []) {
            Err(e) => Err(e.message),
            Ok(_) => Ok(()),
          },
        },
      }
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

type MemRow = { id :: Str, agent_id :: Str, kind :: Str, key :: Str, content :: Str, ts :: Str, mtype :: Str, importance :: Str, scope :: Str, superseded :: Int, expires_at :: Str }

fn row_to_entry(r :: MemRow) -> MemoryEntry {
  { id: r.id, agent_id: r.agent_id, kind: r.kind, key: r.key, content: r.content, ts: r.ts, mtype: r.mtype, importance: r.importance, scope: r.scope, superseded: r.superseded, expires_at: r.expires_at }
}

fn mem_cols() -> Str {
  "id, agent_id, kind, key, content, ts, mtype, importance, scope, superseded, expires_at"
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

# All entries for an agent, newest first. Filters superseded=0 (a no-op for
# every row `store` ever wrote — that column is always 0 there — and the
# correct "current view" once a caller starts using `store_kv`).
fn recall_all(db :: conn.ConnDb, agent_id :: Str) -> [sql, fs_read] List[MemoryEntry] {
  db_query_mem(db, str.join(["SELECT ", mem_cols(), " FROM agent_memory WHERE agent_id=? AND superseded=0 ORDER BY ts DESC"], ""), [PStr(agent_id)])
}

# Recall a single entry by (agent_id, kind, key). None if absent.
fn recall_by_key(db :: conn.ConnDb, agent_id :: Str, kind :: Str, key :: Str) -> [sql, fs_read] Option[MemoryEntry] {
  let sq := ormq.for_dialect({ sql: str.join(["SELECT ", mem_cols(), " FROM agent_memory WHERE agent_id=? AND kind=? AND key=? AND superseded=0 ORDER BY ts DESC LIMIT 1"], ""), params: [PStr(agent_id), PStr(kind), PStr(key)] }, db.dialect)
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
  db_query_mem(db, str.join(["SELECT ", mem_cols(), " FROM agent_memory WHERE agent_id=? AND kind=? AND superseded=0 ORDER BY ts DESC"], ""), [PStr(agent_id), PStr(kind)])
}

# ── KV store with supersession + scope/importance/expiry ────────────────────────
fn norm_mtype(t :: Str) -> Str {
  if t == "episodic" or t == "procedural" or t == "semantic" {
    t
  } else {
    "semantic"
  }
}

fn norm_importance(i :: Str) -> Str {
  if i == "high" or i == "low" or i == "medium" {
    i
  } else {
    "medium"
  }
}

fn norm_scope(s :: Str) -> Str {
  if str.is_empty(s) {
    "global"
  } else {
    s
  }
}

fn current_kv_content(db :: conn.ConnDb, agent_id :: Str, kind :: Str, scope :: Str, key :: Str) -> [sql, fs_read] Option[Str] {
  let sq := ormq.for_dialect({ sql: "SELECT content FROM agent_memory WHERE agent_id=? AND kind=? AND scope=? AND key=? AND superseded=0", params: [PStr(agent_id), PStr(kind), PStr(scope), PStr(key)] }, db.dialect)
  let rows :: Result[List[{ content :: Str }], SqlError] := sql.query(db.handle, sq.sql, sq.params)
  match rows {
    Err(_) => None,
    Ok(rs) => match list.head(rs) {
      None => None,
      Some(r) => Some(r.content),
    },
  }
}

# Richer sibling of `store`: same upsert-by-`(agent_id, kind, key)` contract
# for a non-empty key, but marks the row it replaces `superseded=1` instead
# of deleting it — the write-side half of "what was true when." An
# unchanged value (same content already current) is a no-op, same
# idempotence guarantee `store` gives implicitly through its delete+insert.
# An empty key appends, deduped against an identical not-yet-superseded
# fact for the same `(agent_id, kind)` so re-observing the same thing twice
# doesn't grow the log.
fn store_kv(db :: conn.ConnDb, agent_id :: Str, kind :: Str, key :: Str, content :: Str, mtype :: Str, importance :: Str, scope0 :: Str, expires_at :: Str) -> [sql, fs_read, fs_write, time, crypto, random] Unit {
  let scope := norm_scope(scope0)
  let mt := norm_mtype(mtype)
  let imp := norm_importance(importance)
  let now := time.now_str()
  let id := crypto.random_str_hex(8)
  if str.is_empty(key) {
    let __r := db_exec(db, "INSERT INTO agent_memory (id, agent_id, kind, key, content, ts, mtype, importance, scope, superseded, expires_at) SELECT ?, ?, ?, '', ?, ?, ?, ?, ?, 0, ? WHERE NOT EXISTS (SELECT 1 FROM agent_memory WHERE agent_id=? AND kind=? AND content=? AND superseded=0)", [PStr(id), PStr(agent_id), PStr(kind), PStr(content), PStr(now), PStr(mt), PStr(imp), PStr(scope), PStr(expires_at), PStr(agent_id), PStr(kind), PStr(content)])
    ()
  } else {
    match current_kv_content(db, agent_id, kind, scope, key) {
      Some(cur) => if cur == content {
        ()
      } else {
        let __s := db_exec(db, "UPDATE agent_memory SET superseded=1 WHERE agent_id=? AND kind=? AND scope=? AND key=? AND superseded=0", [PStr(agent_id), PStr(kind), PStr(scope), PStr(key)])
        let __i := db_exec(db, "INSERT INTO agent_memory (id, agent_id, kind, key, content, ts, mtype, importance, scope, superseded, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)", [PStr(id), PStr(agent_id), PStr(kind), PStr(key), PStr(content), PStr(now), PStr(mt), PStr(imp), PStr(scope), PStr(expires_at)])
        ()
      },
      None => {
        let __i := db_exec(db, "INSERT INTO agent_memory (id, agent_id, kind, key, content, ts, mtype, importance, scope, superseded, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)", [PStr(id), PStr(agent_id), PStr(kind), PStr(key), PStr(content), PStr(now), PStr(mt), PStr(imp), PStr(scope), PStr(expires_at)])
        ()
      },
    }
  }
}

# The live view for one agent within a scope: not superseded, not expired,
# highest importance first then most recent — the ordering a prompt wants
# ("tell me the few things that matter most"), not just "everything."
fn recall_scoped(db :: conn.ConnDb, agent_id :: Str, scope :: Str, lim :: Int) -> [sql, fs_read, time] List[MemoryEntry] {
  let now := time.now_str()
  let sq := ormq.for_dialect({ sql: str.join(["SELECT ", mem_cols(), " FROM agent_memory WHERE agent_id=? AND scope=? AND superseded=0 AND (expires_at='' OR expires_at>?) ORDER BY CASE importance WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END, ts DESC LIMIT ?"], ""), params: [PStr(agent_id), PStr(scope), PStr(now), PInt(lim)] }, db.dialect)
  let rows :: Result[List[MemRow], SqlError] := sql.query(db.handle, sq.sql, sq.params)
  match rows {
    Err(_) => [],
    Ok(rs) => list.map(rs, row_to_entry),
  }
}

# Same live-view ordering as `recall_scoped` (importance, then recency;
# `superseded=0`; unexpired), but across EVERY scope for the agent rather
# than one — the shape a host wants when it doesn't partition memory by
# scope at all (a single global view is just every entry sharing the
# default 'global' scope, which this already covers; a host that DOES use
# multiple scopes gets all of them ranked together here, or one scope at a
# time via `recall_scoped`).
fn recall_ranked(db :: conn.ConnDb, agent_id :: Str, lim :: Int) -> [sql, fs_read, time] List[MemoryEntry] {
  let now := time.now_str()
  let sq := ormq.for_dialect({ sql: str.join(["SELECT ", mem_cols(), " FROM agent_memory WHERE agent_id=? AND superseded=0 AND (expires_at='' OR expires_at>?) ORDER BY CASE importance WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END, ts DESC LIMIT ?"], ""), params: [PStr(agent_id), PStr(now), PInt(lim)] }, db.dialect)
  let rows :: Result[List[MemRow], SqlError] := sql.query(db.handle, sq.sql, sq.params)
  match rows {
    Err(_) => [],
    Ok(rs) => list.map(rs, row_to_entry),
  }
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
fn entry_line(e :: MemoryEntry) -> Str {
  let label := if str.is_empty(e.key) {
    str.join(["[", e.kind, "] "], "")
  } else {
    str.join(["[", e.kind, "/", e.key, "] "], "")
  }
  str.concat("- ", str.concat(label, e.content))
}

# Returns "" for empty list — safe to unconditionally str.concat into a system prompt.
# Non-empty result begins with "\n\n<header>\n" so callers need no separator logic.
fn to_context_labeled(entries :: List[MemoryEntry], header :: Str) -> Str {
  if list.len(entries) == 0 {
    ""
  } else {
    let lines := list.map(entries, entry_line)
    str.join(["\n\n", header, "\n", str.join(lines, "\n")], "")
  }
}

# The original, fixed-header formatter — unchanged wording ("Memory:") and
# behavior for every existing caller. `to_context_labeled` is the same
# formatting with a caller-chosen header, for a host (e.g. lex-soft) whose
# prompt wording predates this module and must not move out from under it.
fn to_context(entries :: List[MemoryEntry]) -> Str {
  to_context_labeled(entries, "Memory:")
}

