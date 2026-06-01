# lex-agent — A2A server
#
# Glues together:
#
#   - AgentCard at `/.well-known/agent.json`
#   - JSON-RPC dispatch at `/`  (POST)
#   - Spec precondition gating before any handler runs
#
# v0.2 wires `tasks/send`, `tasks/get`, and `tasks/cancel` against
# an optional `std.conc` actor-backed task store (see `src/store.lex`).
# When `AgentDef.store` is `None`, `tasks/get` returns
# `task-not-found` and `tasks/cancel` returns `not-cancelable` —
# matching the pre-store v0.1 behaviour. `tasks/sendSubscribe` now
# emits proper SSE frames via `dispatch_subscribe_str` (concatenated
# Str for lex-web callers) or `dispatch_sse_frames` (List[Str] for
# `net.serve_fn` / BodyStream callers). Both paths were unblocked
# by lex-lang#487. mount.lex routes SSE requests automatically.
#
# Effects: the dispatch chain declares the wide row
# `[io, time, crypto, random, sql, fs_read, fs_write, net, concurrent]`
# — the same row `lex-web/router.route_effectful` accepts, so an
# `AgentDef` mounts onto a lex-web `Router` without an effect-row
# impedance (see `src/mount.lex`). `dispatch_request` itself never
# uses any of these — they leak through from the handler-closure
# call (`skill.handle(m)` in `run_skill`) because effect rows on
# record-field closures are invariant in Lex 0.9.x. The previous
# `[net, io, llm, proc]` choice predated the lex-web integration
# called for by #481; `[llm]` was a semantic annotation only and
# `[proc]` wasn't used by any v0.1 example. Handlers needing those
# routes them through wrappers (lex-llm called from a `[concurrent]`
# actor; a process runner adapter).

import "std.list" as list

import "std.str" as str

import "std.conc" as conc

import "lex-schema/json_value" as jv

import "lex-spec/capability" as cap

import "lex-spec/spec" as sp

import "lex-trail/log" as trail

import "lex-trail/kinds" as kinds

import "./protocol" as proto

import "./agent_card" as card

import "./task" as tk

import "./message" as msg

import "./stream" as ssem

import "./store" as store

# ---- Handler signature -------------------------------------------
#
# A skill handler is supplied by the agent author. It takes the
# (already-validated) input message and returns the next task state
# plus optional output message / artifacts.
type HandlerOutcome = { next_state :: tk.TaskState, reply :: Option[msg.Message], artifacts :: List[msg.Artifact] }

# Pair a capability declaration with its concrete handler. The
# `Capability` value supplies the schema (for validation), the
# precondition (for the gate), and the direction (must be
# `Inbound`). Effects on `handle` declare the same wide row as
# `lex-web/router.route_effectful` — pure handlers fit structurally
# via subset, and the choice of row is what lets `src/mount.lex`
# register a single `POST /` route that calls back into
# `dispatch_request` without an effect-row impedance.
type Skill = { capability :: cap.Capability, handle :: (msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] HandlerOutcome }

# ---- AgentDef ----------------------------------------------------
#
# `store` is an optional `std.conc` actor address; when present, the
# server writes every successful dispatch into it and reads back on
# `tasks/get` / `tasks/cancel`. When `None`, those methods return
# their respective "not supported" errors (the pre-v0.2 behaviour).
#
# `trail` is an optional lex-trail Log; when present, every A2A
# protocol method emits an `a2a.*` event for end-to-end auditability.
# Attach via `with_trail(agent, log)`.
type AgentDef = { card :: card.AgentCard, skills :: List[Skill], store :: Option[Actor[Map[Str, tk.Task]]], trail :: Option[trail.Log] }

fn make_agent_def(c :: card.AgentCard, skills :: List[Skill]) -> AgentDef {
  { card: c, skills: skills, store: None, trail: None }
}

# Attach a task store. Callers spawn the actor via
# `store.spawn_store()` once at boot and pipe the address in here.
fn with_store(agent :: AgentDef, addr :: Actor[Map[Str, tk.Task]]) -> AgentDef {
  { card: agent.card, skills: agent.skills, store: Some(addr), trail: agent.trail }
}

# Attach a trail log. Every A2A protocol method will emit an
# `a2a.*` event into `log`. Open a `trail.open_memory()` log in
# tests; use `trail.open(path)` for persistent audit trails.
fn with_trail(agent :: AgentDef, log :: trail.Log) -> AgentDef {
  { card: agent.card, skills: agent.skills, store: agent.store, trail: Some(log) }
}

# ---- Trail helpers -----------------------------------------------
fn emit_trail(log :: Option[trail.Log], kind :: Str, parent :: Option[Str], payload :: Str) -> [sql, time] Unit {
  match log {
    None => (),
    Some(l) => {
      let __evt := trail.append(l, kind, parent, payload)
      ()
    },
  }
}

fn emit_msg_sent_if_reply(log :: Option[trail.Log], task_id :: Str, reply :: Option[msg.Message]) -> [sql, time] Unit {
  match reply {
    None => (),
    Some(m) => {
      let payload := str.join(["{\"task_id\":\"", task_id, "\",\"message_id\":\"", m.message_id, "\"}"], "")
      emit_trail(log, kinds.a2a_msg_sent(), None, payload)
    },
  }
}

# ---- Routing -----------------------------------------------------
#
# `dispatch_request(agent, body)` is the single entry point: takes a
# raw HTTP body, returns a JSON-RPC response string. Pure-ish: the
# only effects come from the handler closures.
fn dispatch_request(agent :: AgentDef, body :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Str {
  match proto.parse_request(body) {
    Err(rpcerr) => proto.response_to_str(ResErr(IdNull, rpcerr)),
    Ok(req) => proto.response_to_str(handle_method(agent, req)),
  }
}

fn handle_method(agent :: AgentDef, req :: proto.Request) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] proto.Response {
  if req.method == proto.method_tasks_send() {
    handle_tasks_send(agent, req)
  } else {
    if req.method == proto.method_tasks_get() {
      handle_tasks_get(agent, req)
    } else {
      if req.method == proto.method_tasks_cancel() {
        handle_tasks_cancel(agent, req)
      } else {
        if req.method == proto.method_tasks_send_subscribe() {
          handle_tasks_send(agent, req)
        } else {
          proto.fail(req.id, proto.err_method_not_found(), str.concat("method not supported: ", req.method))
        }
      }
    }
  }
}

# ---- tasks/send --------------------------------------------------
#
# Wire shape (A2A v0.3-compatible):
#
#   { "params": {
#       "id":        "task_...",
#       "contextId": "ctx_...",                  # legacy `sessionId` still accepted
#       "message":   { "kind": "message",
#                      "messageId": "msg_...",
#                      "role": "user",
#                      "parts": [...] },
#       "skill":     "<capability_name>"        # extension to vanilla A2A
#   } }
#
# A2A reference servers route to skills via prior `tasks/get` of the
# AgentCard skill list; we accept an explicit `skill` field for
# directness. If omitted, we attempt single-skill dispatch.
fn handle_tasks_send(agent :: AgentDef, req :: proto.Request) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] proto.Response {
  let params := req.params
  match required_str(params, "id") {
    Err(e) => proto.fail(req.id, proto.err_invalid_params(), e),
    Ok(task_id) => match required_context_id(params) {
      Err(e) => proto.fail(req.id, proto.err_invalid_params(), e),
      Ok(ctx_id) => match required_obj(params, "message") {
        Err(e) => proto.fail(req.id, proto.err_invalid_params(), e),
        Ok(mj) => match msg.parse_message(mj) {
          Err(e) => proto.fail(req.id, proto.err_invalid_params(), str.concat("invalid message: ", e)),
          Ok(m) => {
            let recv_payload := str.join(["{\"task_id\":\"", task_id, "\",\"context_id\":\"", ctx_id, "\"}"], "")
            let __recv := emit_trail(agent.trail, kinds.a2a_task_received(), None, recv_payload)
            let skill_name := optional_str(params, "skill")
            dispatch_skill(agent, req.id, task_id, ctx_id, m, skill_name)
          },
        },
      },
    },
  }
}

# Accept `contextId` (v0.3+ canonical) OR `sessionId` (legacy). At
# least one must be present.
fn required_context_id(params :: jv.Json) -> Result[Str, Str] {
  match jv.get_field(params, "contextId") {
    Some(v) => match jv.as_str(v) {
      Some(s) => Ok(s),
      None => Err("contextId must be string"),
    },
    None => match jv.get_field(params, "sessionId") {
      Some(v) => match jv.as_str(v) {
        Some(s) => Ok(s),
        None => Err("sessionId must be string"),
      },
      None => Err("missing param: contextId (or legacy sessionId)"),
    },
  }
}

fn dispatch_skill(agent :: AgentDef, rpc_id :: proto.RpcId, task_id :: Str, ctx_id :: Str, m :: msg.Message, skill_name :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] proto.Response {
  let resolved := if str.is_empty(skill_name) {
    match list.head(agent.skills) {
      Some(s) => Some(s),
      None => None,
    }
  } else {
    find_skill(agent.skills, skill_name)
  }
  match resolved {
    None => proto.fail(rpc_id, proto.err_unsupported_op(), str.concat("unknown skill: ", skill_name)),
    Some(skill) => run_skill(skill, agent.store, agent.trail, rpc_id, task_id, ctx_id, m),
  }
}

fn run_skill(skill :: Skill, store_ref :: Option[Actor[Map[Str, tk.Task]]], trail_log :: Option[trail.Log], rpc_id :: proto.RpcId, task_id :: Str, ctx_id :: Str, m :: msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] proto.Response {
  let bindings := [("args", bindings_from_message(m))]
  match cap.gate(skill.capability, bindings) {
    Deny(reason) => proto.fail(rpc_id, proto.err_spec_denied(), str.concat("spec-denied: ", reason)),
    Inconclusive(reason) => proto.fail(rpc_id, proto.err_spec_denied(), str.concat("spec-inconclusive: ", reason)),
    Allow => {
      let initial := tk.submitted(task_id, ctx_id, m)
      let advanced := match tk.advance(initial, TSWorking, None) {
        Ok(t) => t,
        Err(_) => initial,
      }
      let __e1 := emit_trail(trail_log, kinds.a2a_task_state_change(), None, str.join(["{\"task_id\":\"", task_id, "\",\"from_state\":\"submitted\",\"to_state\":\"working\"}"], ""))
      let outcome := skill.handle(m)
      let stamped_reply := stamp_reply_id(outcome.reply)
      let with_reply := match tk.advance(advanced, outcome.next_state, stamped_reply) {
        Ok(t) => t,
        Err(_) => advanced,
      }
      let final_task := list.fold(outcome.artifacts, with_reply, fn (acc :: tk.Task, a :: msg.Artifact) -> tk.Task {
        match tk.add_artifact(acc, a) {
          Ok(t) => t,
          Err(_) => acc,
        }
      })
      let __e2 := emit_trail(trail_log, kinds.a2a_task_state_change(), None, str.join(["{\"task_id\":\"", task_id, "\",\"from_state\":\"working\",\"to_state\":\"", tk.state_label(final_task.state), "\"}"], ""))
      let __e3 := emit_msg_sent_if_reply(trail_log, task_id, stamped_reply)
      let __discard := persist(store_ref, final_task)
      proto.ok(rpc_id, tk.task_to_json(final_task))
    },
  }
}

# Fire-and-forget write into the optional store. Pulled out as its
# own fn so the [concurrent] effect stays localised and the call
# site stays readable.
fn persist(s :: Option[Actor[Map[Str, tk.Task]]], t :: tk.Task) -> [concurrent] Unit {
  match s {
    None => (),
    Some(addr) => store.put(addr, t),
  }
}

# Stamp a fresh messageId onto a reply if the handler returned a
# blank one (pure builders default to ""). Pass-through if the
# handler supplied an explicit id.
fn stamp_reply_id(r :: Option[msg.Message]) -> [crypto, random] Option[msg.Message] {
  match r {
    None => None,
    Some(m) => Some(stamp_message(m)),
  }
}

fn stamp_message(m :: msg.Message) -> [crypto, random] msg.Message {
  if str.is_empty(m.message_id) {
    msg.with_message_id(m, msg.gen_message_id())
  } else {
    m
  }
}

# Build a SpecValue-shaped record from an inbound Message so simple
# preconditions can pattern-match on `args.role`, `args.first_text`,
# etc. v0.1 surfaces `role` and `text` (first TextPart) — extend
# this as call sites need richer fields.
fn bindings_from_message(m :: msg.Message) -> sp.SpecValue {
  let first := first_text_part(m.parts)
  VRecord({ name: "Args", fields: [("role", VStr(msg.role_label(m.role))), ("text", VStr(first))] })
}

fn first_text_part(parts :: List[msg.Part]) -> Str {
  list.fold(parts, "", fn (acc :: Str, p :: msg.Part) -> Str {
    if str.is_empty(acc) {
      match p {
        TextPart(s) => s,
        _ => acc,
      }
    } else {
      acc
    }
  })
}

# ---- tasks/get ---------------------------------------------------
#
# When a store is attached (`with_store`), looks the task up by id
# and returns it as the JSON-RPC result. Without a store, replies
# `-32001 task-not-found` — same shape as the v0.1 stub so callers
# that didn't opt in see no behaviour change.
fn handle_tasks_get(agent :: AgentDef, req :: proto.Request) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] proto.Response {
  match required_str(req.params, "id") {
    Err(e) => proto.fail(req.id, proto.err_invalid_params(), e),
    Ok(id) => match agent.store {
      None => proto.fail(req.id, proto.err_task_not_found(), str.concat("task not found: ", id)),
      Some(addr) => match store.get(addr, id) {
        None => proto.fail(req.id, proto.err_task_not_found(), str.concat("task not found: ", id)),
        Some(t) => proto.ok(req.id, tk.task_to_json(t)),
      },
    },
  }
}

# ---- tasks/cancel -----------------------------------------------
#
# Routes the cancel through the store actor, which guards the
# transition via `tk.advance(t, TSCanceled, None)` — already-terminal
# tasks (completed / failed / canceled) surface as `-32002
# not-cancelable`. Missing-id surfaces as `task-not-found`.
fn handle_tasks_cancel(agent :: AgentDef, req :: proto.Request) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] proto.Response {
  match required_str(req.params, "id") {
    Err(e) => proto.fail(req.id, proto.err_invalid_params(), e),
    Ok(id) => match agent.store {
      None => proto.fail(req.id, proto.err_not_cancelable(), str.concat("no cancel-tracking actor for: ", id)),
      Some(addr) => match store.cancel(addr, id) {
        Err(reason) => {
          if str.contains(reason, "not found") {
            proto.fail(req.id, proto.err_task_not_found(), str.concat("task not found: ", id))
          } else {
            proto.fail(req.id, proto.err_not_cancelable(), str.concat("not cancelable: ", reason))
          }
        },
        Ok(t) => {
          let __ec := emit_trail(agent.trail, kinds.a2a_task_state_change(), None, str.join(["{\"task_id\":\"", id, "\",\"to_state\":\"canceled\"}"], ""))
          proto.ok(req.id, tk.task_to_json(t))
        },
      },
    },
  }
}

# ---- Helpers ------------------------------------------------------
fn required_str(j :: jv.Json, field :: Str) -> Result[Str, Str] {
  match jv.get_field(j, field) {
    None => Err(str.concat("missing param: ", field)),
    Some(v) => match jv.as_str(v) {
      Some(s) => Ok(s),
      None => Err(str.concat("param must be string: ", field)),
    },
  }
}

fn required_obj(j :: jv.Json, field :: Str) -> Result[jv.Json, Str] {
  match jv.get_field(j, field) {
    None => Err(str.concat("missing param: ", field)),
    Some(v) => match jv.as_obj(v) {
      Some(_) => Ok(v),
      None => Err(str.concat("param must be object: ", field)),
    },
  }
}

fn optional_str(j :: jv.Json, field :: Str) -> Str {
  match jv.get_field(j, field) {
    None => "",
    Some(v) => match jv.as_str(v) {
      Some(s) => s,
      None => "",
    },
  }
}

fn find_skill(skills :: List[Skill], name :: Str) -> Option[Skill] {
  list.fold(skills, None, fn (acc :: Option[Skill], s :: Skill) -> Option[Skill] {
    match acc {
      Some(_) => acc,
      None => if s.capability.name == name {
        Some(s)
      } else {
        None
      },
    }
  })
}

# ---- Agent-card endpoint -----------------------------------------
#
# `agent_card_response` is what the `/.well-known/agent.json` GET
# returns. Pure string builder — no effects.
fn agent_card_response(agent :: AgentDef) -> Str {
  card.card_to_pretty(agent.card)
}

# ---- tasks/sendSubscribe — SSE body builders --------------------
#
# `is_subscribe_body` peeks at the method field so mount.lex can
# route the request to the SSE path without a full parse round-trip.
#
# `dispatch_subscribe_str` runs the skill and concatenates all SSE
# frames into a single `Str`. For lex-web callers (where
# `resp.Response.body :: Str`) this is the right function; conformant
# SSE clients parse the events correctly when the response carries
# `content-type: text/event-stream`.
#
# For callers using `std.net.serve_fn` directly, call
# `dispatch_sse_frames` and wrap the result with
# `BodyStream(iter.from_list(frames))` for true chunked streaming.
fn is_subscribe_body(body :: Str) -> Bool {
  str.contains(body, "\"tasks/sendSubscribe\"")
}

fn dispatch_subscribe_str(agent :: AgentDef, body :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Str {
  list.fold(dispatch_sse_frames(agent, body), "", fn (acc :: Str, frame :: Str) -> Str {
    str.concat(acc, frame)
  })
}

fn dispatch_sse_frames(agent :: AgentDef, body :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] List[Str] {
  match proto.parse_request(body) {
    Err(rpcerr) => [ssem.encode_data(proto.response_to_json(ResErr(IdNull, rpcerr)))],
    Ok(req) => build_subscribe_frames(agent, req),
  }
}

fn build_subscribe_frames(agent :: AgentDef, req :: proto.Request) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] List[Str] {
  let params := req.params
  match required_str(params, "id") {
    Err(e) => [sse_error_frame(req.id, proto.err_invalid_params(), e)],
    Ok(task_id) => match required_context_id(params) {
      Err(e) => [sse_error_frame(req.id, proto.err_invalid_params(), e)],
      Ok(ctx_id) => match required_obj(params, "message") {
        Err(e) => [sse_error_frame(req.id, proto.err_invalid_params(), e)],
        Ok(mj) => match msg.parse_message(mj) {
          Err(e) => [sse_error_frame(req.id, proto.err_invalid_params(), str.concat("invalid message: ", e))],
          Ok(m) => {
            let recv_payload := str.join(["{\"task_id\":\"", task_id, "\",\"context_id\":\"", ctx_id, "\"}"], "")
            let __recv := emit_trail(agent.trail, kinds.a2a_task_received(), None, recv_payload)
            let skill_name := optional_str(params, "skill")
            run_skill_subscribe(agent, req.id, task_id, ctx_id, m, skill_name)
          },
        },
      },
    },
  }
}

fn run_skill_subscribe(agent :: AgentDef, rpc_id :: proto.RpcId, task_id :: Str, ctx_id :: Str, m :: msg.Message, skill_name :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] List[Str] {
  let resolved := if str.is_empty(skill_name) {
    match list.head(agent.skills) {
      Some(s) => Some(s),
      None => None,
    }
  } else {
    find_skill(agent.skills, skill_name)
  }
  match resolved {
    None => [sse_error_frame(rpc_id, proto.err_unsupported_op(), str.concat("unknown skill: ", skill_name))],
    Some(skill) => emit_skill_frames(skill, agent.store, agent.trail, rpc_id, task_id, ctx_id, m),
  }
}

fn emit_skill_frames(skill :: Skill, store_ref :: Option[Actor[Map[Str, tk.Task]]], trail_log :: Option[trail.Log], rpc_id :: proto.RpcId, task_id :: Str, ctx_id :: Str, m :: msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] List[Str] {
  let bindings := [("args", bindings_from_message(m))]
  match cap.gate(skill.capability, bindings) {
    Deny(_) => {
      let t := tk.submitted(task_id, ctx_id, m)
      let failed := match tk.advance(t, TSFailed, None) {
        Ok(ft) => ft,
        Err(_) => t,
      }
      [ssem.encode_status(tk.status_update(failed, None))]
    },
    Inconclusive(_) => {
      let t := tk.submitted(task_id, ctx_id, m)
      let failed := match tk.advance(t, TSFailed, None) {
        Ok(ft) => ft,
        Err(_) => t,
      }
      [ssem.encode_status(tk.status_update(failed, None))]
    },
    Allow => {
      let initial := tk.submitted(task_id, ctx_id, m)
      let working := match tk.advance(initial, TSWorking, None) {
        Ok(t) => t,
        Err(_) => initial,
      }
      let __e1 := emit_trail(trail_log, kinds.a2a_task_state_change(), None, str.join(["{\"task_id\":\"", task_id, "\",\"from_state\":\"submitted\",\"to_state\":\"working\"}"], ""))
      let working_frame := ssem.encode_status(tk.status_update(working, None))
      let outcome := skill.handle(m)
      let stamped_reply := stamp_reply_id(outcome.reply)
      let with_reply := match tk.advance(working, outcome.next_state, stamped_reply) {
        Ok(t) => t,
        Err(_) => working,
      }
      let final_task := list.fold(outcome.artifacts, with_reply, fn (acc :: tk.Task, a :: msg.Artifact) -> tk.Task {
        match tk.add_artifact(acc, a) {
          Ok(t) => t,
          Err(_) => acc,
        }
      })
      let __e2 := emit_trail(trail_log, kinds.a2a_task_state_change(), None, str.join(["{\"task_id\":\"", task_id, "\",\"from_state\":\"working\",\"to_state\":\"", tk.state_label(final_task.state), "\"}"], ""))
      let __e3 := emit_msg_sent_if_reply(trail_log, task_id, stamped_reply)
      let __discard := persist(store_ref, final_task)
      let final_frame := ssem.encode_status(tk.status_update(final_task, stamped_reply))
      [working_frame, final_frame]
    },
  }
}

# Encode a JSON-RPC error response as an SSE `data:` frame. Used for
# parse errors and spec-denied rejections on the subscribe path.
fn sse_error_frame(rpc_id :: proto.RpcId, code :: Int, message :: Str) -> Str {
  ssem.encode_data(proto.response_to_json(proto.fail(rpc_id, code, message)))
}

