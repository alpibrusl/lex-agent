# lex-agent — task store (in-memory actor OR durable SQLite)
#
# Backs `tasks/get` and `tasks/cancel`. Two interchangeable backends
# sit behind one `Store` ADT, so the server is backend-agnostic:
#
#   - `InMemory` — a `std.conc` actor carrying `Map[Str, tk.Task]`.
#     Survives across requests within a process; lost at process exit.
#   - `Sqlite`   — a `std.sql` `Db` whose `a2a_tasks` table survives
#     process restarts. `tasks/get` for a task submitted in a previous
#     session resolves; the trust model's "task history is inspectable"
#     requirement (issue #10) holds across restarts.
#
# Backend selection is declarative via `StoreConfig`, resolved into a
# live `Store` by `open_store`:
#
#   let store := match store.open_store(SqliteStore("/var/lib/agent.db")) {
#     Ok(s)  => s,
#     Err(e) => ...,
#   }
#   let agent := srv.with_store(srv.make_agent_def(card, skills), store)
#
# `spawn_store()` is retained as the zero-config in-memory constructor
# (it now returns `Store::InMemory(..)`), so existing
# `srv.with_store(agent, store.spawn_store())` call sites are unchanged.
#
# Wire / API contract:
#
#   - `open_store(cfg)` boots the selected backend. `[sql, fs_write,
#     concurrent]` — the union of both backends' open paths.
#   - `spawn_store()` / `open_sqlite(path)` open a single backend each.
#   - `put(store, task)` is fire-and-forget — server writes after
#     every successful dispatch.
#   - `get(store, id)` is total over input (unknown id → None).
#   - `cancel(store, id)` returns the updated Task on success, or an
#     error string when the task is missing or already terminal.
#
# Effects:
#   - put / get / cancel declare `[sql, concurrent]` — the SQLite arm
#     uses `[sql]`, the in-memory arm uses `[concurrent]`; the row is
#     the union. Both are already in the server's dispatch row.

import "std.map"  as map
import "std.conc" as conc
import "std.list" as list
import "std.sql"  as sql

import "lex-schema/json_value" as jv

import "./task" as tk

# ---- Backend selection -------------------------------------------
#
# `StoreConfig` is the declarative knob an agent author flips at boot;
# `open_store` turns it into a live `Store`. Defaults to in-memory
# (call `spawn_store` / `open_store(InMemoryStore)`) for backward
# compatibility with the v0.2 actor-only store.

type StoreConfig =
    InMemoryStore
  | SqliteStore(Str)        # path to the SQLite database file

type Store =
    InMemory(Actor[Map[Str, tk.Task]])
  | Sqlite(Db)

# ---- In-memory actor protocol ------------------------------------
#
# `StoreMsg` is what gets sent to the actor. `StoreReply` is the
# response shape `conc.ask` returns. The reply discriminator mirrors
# the request so callers can `match` on it confidently.

type StoreMsg =
    MsgPut(tk.Task)
  | MsgGet(Str)
  | MsgCancel(Str)

type StoreReply =
    RepPut
  | RepGet(Option[tk.Task])
  | RepCancel(Result[tk.Task, Str])

# Pure fold: `(state, msg) -> (state', reply)`. The actor framework
# calls this on every inbound message; state threads through.
fn store_handler(
  state :: Map[Str, tk.Task],
  msg :: StoreMsg
) -> (Map[Str, tk.Task], StoreReply) {
  match msg {
    MsgPut(t) => (map.set(state, t.id, t), RepPut),
    MsgGet(id) => (state, RepGet(map.get(state, id))),
    MsgCancel(id) => match map.get(state, id) {
      None => (state, RepCancel(Err("task not found"))),
      Some(t) => match tk.advance(t, TSCanceled, None) {
        Ok(t2) => (map.set(state, id, t2), RepCancel(Ok(t2))),
        Err(e) => (state, RepCancel(Err(tk.task_error_message(e)))),
      },
    },
  }
}

# ---- Opening / spawning ------------------------------------------

# Resolve a `StoreConfig` into a live `Store`.
fn open_store(cfg :: StoreConfig) -> [sql, fs_write, concurrent] Result[Store, Str] {
  match cfg {
    InMemoryStore  => Ok(spawn_store()),
    SqliteStore(p) => open_sqlite(p),
  }
}

# Zero-config in-memory store. Returns `Store::InMemory(actor)`.
fn spawn_store() -> [concurrent] Store {
  InMemory(conc.spawn(map.new(), store_handler))
}

# Open (creating if absent) a SQLite-backed store at `path` and ensure
# the `a2a_tasks` table exists. Idempotent — safe to call on every boot.
fn open_sqlite(path :: Str) -> [sql, fs_write] Result[Store, Str] {
  match sql.open(path) {
    Err(e) => Err(e.message),
    Ok(db) => match init_schema(db) {
      Err(e2) => Err(e2),
      Ok(_)   => Ok(Sqlite(db)),
    },
  }
}

# The durable task table. The full Task is persisted as its canonical
# wire JSON in `task_json`; `id` / `context_id` / `state` are lifted
# into columns for queryability and so `tasks/get` is a primary-key
# lookup. DDL uses the SQLite/Postgres common subset.
fn init_schema(db :: Db) -> [sql] Result[Unit, Str] {
  let ddl := "CREATE TABLE IF NOT EXISTS a2a_tasks (id TEXT PRIMARY KEY, context_id TEXT NOT NULL, state TEXT NOT NULL, task_json TEXT NOT NULL)"
  match sql.exec(db, ddl, []) {
    Err(e) => Err(e.message),
    Ok(_)  => Ok(()),
  }
}

# ---- Unified store interface -------------------------------------

fn put(s :: Store, t :: tk.Task) -> [sql, concurrent] Unit {
  match s {
    InMemory(a) => mem_put(a, t),
    Sqlite(db)  => sql_put(db, t),
  }
}

fn get(s :: Store, id :: Str) -> [sql, concurrent] Option[tk.Task] {
  match s {
    InMemory(a) => mem_get(a, id),
    Sqlite(db)  => sql_get(db, id),
  }
}

fn cancel(s :: Store, id :: Str) -> [sql, concurrent] Result[tk.Task, Str] {
  match s {
    InMemory(a) => mem_cancel(a, id),
    Sqlite(db)  => sql_cancel(db, id),
  }
}

# ---- In-memory backend -------------------------------------------

fn mem_put(actor :: Actor[Map[Str, tk.Task]], t :: tk.Task) -> [concurrent] Unit {
  let __discard := conc.tell(actor, MsgPut(t))
  ()
}

fn mem_get(actor :: Actor[Map[Str, tk.Task]], id :: Str) -> [concurrent] Option[tk.Task] {
  match conc.ask(actor, MsgGet(id)) {
    RepGet(opt) => opt,
    _           => None,
  }
}

fn mem_cancel(actor :: Actor[Map[Str, tk.Task]], id :: Str) -> [concurrent] Result[tk.Task, Str] {
  match conc.ask(actor, MsgCancel(id)) {
    RepCancel(r) => r,
    _            => Err("unexpected reply from store"),
  }
}

# ---- SQLite backend ----------------------------------------------
#
# `put` upserts the whole task (INSERT OR REPLACE on the `id` primary
# key) so re-writing an advanced task is a single statement. `get`
# reconstructs the Task from the stored JSON via `tk.task_from_json`.
# `cancel` is read-advance-write through the lifecycle gate, exactly
# like the in-memory actor — terminal tasks surface the
# `InvalidTransition` message which the server maps to `-32002`.

fn sql_put(db :: Db, t :: tk.Task) -> [sql] Unit {
  let payload := jv.stringify(tk.task_to_json(t))
  let __discard := sql.exec(db,
    "INSERT OR REPLACE INTO a2a_tasks (id, context_id, state, task_json) VALUES (?, ?, ?, ?)",
    [PStr(t.id), PStr(t.context_id), PStr(tk.state_label(t.state)), PStr(payload)])
  ()
}

fn sql_get(db :: Db, id :: Str) -> [sql] Option[tk.Task] {
  let rows :: Result[List[{ task_json :: Str }], SqlError] :=
    sql.query(db, "SELECT task_json FROM a2a_tasks WHERE id = ?", [PStr(id)])
  match rows {
    Err(_) => None,
    Ok(rs) => match list.head(rs) {
      None    => None,
      Some(r) => match jv.parse(r.task_json) {
        Err(_) => None,
        Ok(j)  => match tk.task_from_json(j) {
          Err(_) => None,
          Ok(t)  => Some(t),
        },
      },
    },
  }
}

fn sql_cancel(db :: Db, id :: Str) -> [sql] Result[tk.Task, Str] {
  match sql_get(db, id) {
    None    => Err("task not found"),
    Some(t) => match tk.advance(t, TSCanceled, None) {
      Err(e) => Err(tk.task_error_message(e)),
      Ok(t2) => {
        let __discard := sql_put(db, t2)
        Ok(t2)
      },
    },
  }
}
