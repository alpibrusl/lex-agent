# lex-agent — persistent task store (in-memory, actor-backed)
#
# Backs `tasks/get` and `tasks/cancel` on a `std.conc` actor that
# carries the agent's task table. v0.1's deferred "actor-backed
# wrapper" called out in the README: every successful `tasks/send`
# writes the final Task into the store; `tasks/get` reads it back;
# `tasks/cancel` flips a non-terminal task to TSCanceled and writes
# the updated record.
#
# "Persistent" here means survives-across-requests, not survives-
# across-restarts. The store is in-memory only — the actor's state
# is the source of truth for the lifetime of the process. A
# durable variant (sqlite or KV-backed) is a follow-up.
#
# Wire / API contract:
#
#   - `spawn_store()` boots the actor and returns its address.
#     One actor per agent; the address goes into `AgentDef.store`.
#   - `put(addr, task)` is fire-and-forget — server writes after
#     every successful dispatch.
#   - `get(addr, task_id)` is synchronous (`conc.ask`) and total
#     over input.
#   - `cancel(addr, task_id)` is synchronous; returns the updated
#     Task on success, an error string if the task isn't found or
#     is already in a terminal state.
#
# Effects:
#   - `spawn_store` declares `[concurrent]`.
#   - `put` / `get` / `cancel` declare `[concurrent]`.
#   - The handler itself is pure — it's a fold over the Map.

import "std.map" as map

import "std.conc" as conc

import "./task" as tk

# ---- Message protocol --------------------------------------------
#
# `StoreMsg` is what gets sent to the actor. `StoreReply` is the
# response shape `conc.ask` returns. The reply discriminator mirrors
# the request so callers can `match` on it confidently.
type StoreMsg = MsgPut(tk.Task) | MsgGet(Str) | MsgCancel(Str)

type StoreReply = RepPut | RepGet(Option[tk.Task]) | RepCancel(Result[tk.Task, Str])

fn store_handler(state :: Map[Str, tk.Task], msg :: StoreMsg) -> (Map[Str, tk.Task], StoreReply) {
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

# ---- Spawn ------------------------------------------------------
fn spawn_store() -> [concurrent] Actor[Map[Str, tk.Task]] {
  conc.spawn(map.new(), store_handler)
}

# ---- Caller-side helpers ----------------------------------------
fn put(actor :: Actor[Map[Str, tk.Task]], t :: tk.Task) -> [concurrent] Unit {
  let __discard := conc.tell(actor, MsgPut(t))
  ()
}

fn get(actor :: Actor[Map[Str, tk.Task]], id :: Str) -> [concurrent] Option[tk.Task] {
  match conc.ask(actor, MsgGet(id)) {
    RepGet(opt) => opt,
    _ => None,
  }
}

fn cancel(actor :: Actor[Map[Str, tk.Task]], id :: Str) -> [concurrent] Result[tk.Task, Str] {
  match conc.ask(actor, MsgCancel(id)) {
    RepCancel(r) => r,
    _ => Err("unexpected reply from store"),
  }
}

