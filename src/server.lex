# lex-agent — A2A server
#
# Glues together:
#
#   - AgentCard at `/.well-known/agent.json`
#   - JSON-RPC dispatch at `/`  (POST)
#   - Spec precondition gating before any handler runs
#
# v0.1 wires `tasks/send` and `tasks/get`. `tasks/cancel` and
# `tasks/sendSubscribe` are stubbed — the SSE path needs the live
# write half of `std.net` which is in flight upstream (lex-lang#487
# closed eager-buffer; truly persistent SSE write is a follow-up).
# For now `sendSubscribe` falls back to a single-frame stream with
# the final task state.
#
# Effects: `[net]` to bind, `[concurrent]` because handler dispatch
# uses `std.conc` actors to maintain a per-server task store.

import "std.list" as list
import "std.str"  as str

import "lex-schema/json_value" as jv

import "lex-spec/capability" as cap
import "lex-spec/spec"       as sp

import "./protocol"   as proto
import "./agent_card" as card
import "./task"       as tk
import "./message"    as msg
import "./stream"     as ssem

# ---- Handler signature -------------------------------------------
#
# A skill handler is supplied by the agent author. It takes the
# (already-validated) input message and returns the next task state
# plus optional output message / artifacts.

type HandlerOutcome = {
  next_state :: tk.TaskState,
  reply :: Option[msg.Message],
  artifacts :: List[msg.Artifact],
}

# Pair a capability declaration with its concrete handler. The
# `Capability` value supplies the schema (for validation), the
# precondition (for the gate), and the direction (must be
# `Inbound`). Effects on `handle` intentionally widened to the union
# [net, io, llm, proc] so handlers can do useful work without
# requiring the server to re-declare per-handler.
type Skill = {
  capability :: cap.Capability,
  handle :: (msg.Message) -> [net, io, llm, proc] HandlerOutcome,
}

# ---- AgentDef ----------------------------------------------------

type AgentDef = {
  card :: card.AgentCard,
  skills :: List[Skill],
}

fn make_agent_def(c :: card.AgentCard, skills :: List[Skill]) -> AgentDef {
  { card: c, skills: skills }
}

# ---- Routing -----------------------------------------------------
#
# `dispatch_request(agent, body)` is the single entry point: takes a
# raw HTTP body, returns a JSON-RPC response string. Pure-ish: the
# only effects come from the handler closures.

fn dispatch_request(
  agent :: AgentDef,
  body :: Str
) -> [net, io, llm, proc] Str {
  match proto.parse_request(body) {
    Err(rpcerr) => proto.response_to_str(ResErr(IdNull, rpcerr)),
    Ok(req)     => proto.response_to_str(handle_method(agent, req)),
  }
}

fn handle_method(agent :: AgentDef, req :: proto.Request) -> [net, io, llm, proc] proto.Response {
  if req.method == proto.method_tasks_send() {
    handle_tasks_send(agent, req)
  } else { if req.method == proto.method_tasks_get() {
    handle_tasks_get(agent, req)
  } else { if req.method == proto.method_tasks_cancel() {
    handle_tasks_cancel(agent, req)
  } else { if req.method == proto.method_tasks_send_subscribe() {
    # v0.1: same path as `tasks/send`. Caller still sees the final
    # task state; live SSE streaming layered on top in `serve_sse`.
    handle_tasks_send(agent, req)
  } else {
    proto.fail(req.id, proto.err_method_not_found(),
      str.concat("method not supported: ", req.method))
  }}}}
}

# ---- tasks/send --------------------------------------------------
#
# Wire shape:
#
#   { "params": {
#       "id":        "task_...",
#       "sessionId": "sess_...",
#       "message":   { "role": "user", "parts": [...] },
#       "skill":     "<capability_name>"        # extension to vanilla A2A
#   } }
#
# A2A reference servers route to skills via prior `tasks/get` of the
# AgentCard skill list; we accept an explicit `skill` field for
# directness. If omitted, we attempt single-skill dispatch.

fn handle_tasks_send(
  agent :: AgentDef,
  req :: proto.Request
) -> [net, io, llm, proc] proto.Response {
  let params := req.params
  match required_str(params, "id") {
    Err(e) => proto.fail(req.id, proto.err_invalid_params(), e),
    Ok(task_id) => match required_str(params, "sessionId") {
      Err(e) => proto.fail(req.id, proto.err_invalid_params(), e),
      Ok(sess_id) => match required_obj(params, "message") {
        Err(e) => proto.fail(req.id, proto.err_invalid_params(), e),
        Ok(mj) => match msg.parse_message(mj) {
          Err(e) => proto.fail(req.id, proto.err_invalid_params(),
            str.concat("invalid message: ", e)),
          Ok(m) => {
            let skill_name := optional_str(params, "skill")
            dispatch_skill(agent, req.id, task_id, sess_id, m, skill_name)
          },
        },
      },
    },
  }
}

fn dispatch_skill(
  agent :: AgentDef,
  rpc_id :: proto.RpcId,
  task_id :: Str,
  sess_id :: Str,
  m :: msg.Message,
  skill_name :: Str
) -> [net, io, llm, proc] proto.Response {
  let resolved := if str.is_empty(skill_name) {
    match list.head(agent.skills) {
      Some(s) => Some(s),
      None    => None,
    }
  } else { find_skill(agent.skills, skill_name) }
  match resolved {
    None => proto.fail(rpc_id, proto.err_unsupported_op(),
      str.concat("unknown skill: ", skill_name)),
    Some(skill) => run_skill(skill, rpc_id, task_id, sess_id, m),
  }
}

fn run_skill(
  skill :: Skill,
  rpc_id :: proto.RpcId,
  task_id :: Str,
  sess_id :: Str,
  m :: msg.Message
) -> [net, io, llm, proc] proto.Response {
  # Build the bindings the precondition expects. v0.1 exposes a
  # single `args` binding wrapping the inbound message as a Json
  # `VRecord("Message", ...)`. Real agents will add session state.
  let bindings := [
    ("args", bindings_from_message(m)),
  ]
  match cap.gate(skill.capability, bindings) {
    Deny(reason) => proto.fail(rpc_id, proto.err_spec_denied(),
      str.concat("spec-denied: ", reason)),
    Inconclusive(reason) => proto.fail(rpc_id, proto.err_spec_denied(),
      str.concat("spec-inconclusive: ", reason)),
    Allow => {
      let initial := tk.submitted(task_id, sess_id, m)
      let advanced := match tk.advance(initial, TSWorking, None) {
        Ok(t)  => t,
        Err(_) => initial,
      }
      let outcome := skill.handle(m)
      let with_reply := match tk.advance(advanced, outcome.next_state, outcome.reply) {
        Ok(t)  => t,
        Err(_) => advanced,
      }
      let final_task := list.fold(outcome.artifacts, with_reply,
        fn (acc :: tk.Task, a :: msg.Artifact) -> tk.Task {
          match tk.add_artifact(acc, a) {
            Ok(t)  => t,
            Err(_) => acc,
          }
        })
      proto.ok(rpc_id, tk.task_to_json(final_task))
    },
  }
}

# Build a SpecValue-shaped record from an inbound Message so simple
# preconditions can pattern-match on `args.role`, `args.first_text`,
# etc. v0.1 surfaces `role` and `text` (first TextPart) — extend
# this as call sites need richer fields.
fn bindings_from_message(m :: msg.Message) -> sp.SpecValue {
  let first := first_text_part(m.parts)
  VRecord({
    name: "Args",
    fields: [
      ("role", VStr(msg.role_label(m.role))),
      ("text", VStr(first)),
    ],
  })
}

fn first_text_part(parts :: List[msg.Part]) -> Str {
  list.fold(parts, "", fn (acc :: Str, p :: msg.Part) -> Str {
    if str.is_empty(acc) {
      match p { TextPart(s) => s, _ => acc }
    } else { acc }
  })
}

# ---- tasks/get ---------------------------------------------------
#
# v0.1: we don't yet maintain a persistent task store inside the
# server module (that's a `std.conc` actor pattern — landed in
# `examples/02_persistent_store.lex`). The default behaviour returns
# `task-not-found`. Callers wanting persistence wrap this server in
# their own actor-backed store.

fn handle_tasks_get(
  agent :: AgentDef,
  req :: proto.Request
) -> [net, io, llm, proc] proto.Response {
  let _ := agent
  match required_str(req.params, "id") {
    Err(e) => proto.fail(req.id, proto.err_invalid_params(), e),
    Ok(id) => proto.fail(req.id, proto.err_task_not_found(),
      str.concat("task not found: ", id)),
  }
}

fn handle_tasks_cancel(
  agent :: AgentDef,
  req :: proto.Request
) -> [net, io, llm, proc] proto.Response {
  let _ := agent
  match required_str(req.params, "id") {
    Err(e) => proto.fail(req.id, proto.err_invalid_params(), e),
    Ok(id) => proto.fail(req.id, proto.err_not_cancelable(),
      str.concat("no cancel-tracking actor for: ", id)),
  }
}

# ---- Helpers ------------------------------------------------------

fn required_str(j :: jv.Json, field :: Str) -> Result[Str, Str] {
  match jv.get_field(j, field) {
    None => Err(str.concat("missing param: ", field)),
    Some(v) => match jv.as_str(v) {
      Some(s) => Ok(s),
      None    => Err(str.concat("param must be string: ", field)),
    },
  }
}

fn required_obj(j :: jv.Json, field :: Str) -> Result[jv.Json, Str] {
  match jv.get_field(j, field) {
    None    => Err(str.concat("missing param: ", field)),
    Some(v) => match jv.as_obj(v) {
      Some(_) => Ok(v),
      None    => Err(str.concat("param must be object: ", field)),
    },
  }
}

fn optional_str(j :: jv.Json, field :: Str) -> Str {
  match jv.get_field(j, field) {
    None => "",
    Some(v) => match jv.as_str(v) { Some(s) => s, None => "" },
  }
}

fn find_skill(skills :: List[Skill], name :: Str) -> Option[Skill] {
  list.fold(skills, None, fn (acc :: Option[Skill], s :: Skill) -> Option[Skill] {
    match acc {
      Some(_) => acc,
      None    => if s.capability.name == name { Some(s) } else { None },
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
