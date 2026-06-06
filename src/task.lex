# lex-agent — A2A Task lifecycle
#
# A2A tasks carry the state lifecycle:
#
#   submitted → working → input-required → working → completed | canceled | failed
#
# Server emits status updates on a `tasks/sendSubscribe` SSE stream;
# clients track them. We model the lifecycle as a tagged ADT so
# transitions can be exhaustively pattern-matched; an invalid
# transition surfaces as a typed `TaskError`, never a runtime panic.
#
# Wire shape mirrors the Google A2A spec — `state` is a string code,
# `message` is an optional A2A Message (the current "input-required"
# prompt, the final "completed" reply, etc.), `artifacts` is a list
# of Artifact records, `metadata` is a free-form Json object.
#
# Pure value module.

import "std.list" as list

import "std.str" as str

import "lex-schema/json_value" as jv

import "./message" as msg

# ---- Lifecycle state ---------------------------------------------
type TaskState = TSSubmitted | TSWorking | TSInputRequired | TSCompleted | TSCanceled | TSFailed

fn state_label(s :: TaskState) -> Str {
  match s {
    TSSubmitted => "submitted",
    TSWorking => "working",
    TSInputRequired => "input-required",
    TSCompleted => "completed",
    TSCanceled => "canceled",
    TSFailed => "failed",
  }
}

fn state_of(s :: Str) -> Option[TaskState] {
  if s == "submitted" {
    Some(TSSubmitted)
  } else {
    if s == "working" {
      Some(TSWorking)
    } else {
      if s == "input-required" {
        Some(TSInputRequired)
      } else {
        if s == "completed" {
          Some(TSCompleted)
        } else {
          if s == "canceled" {
            Some(TSCanceled)
          } else {
            if s == "failed" {
              Some(TSFailed)
            } else {
              None
            }
          }
        }
      }
    }
  }
}

# Terminal states — neither side can re-open.
fn is_terminal(s :: TaskState) -> Bool {
  match s {
    TSCompleted => true,
    TSCanceled => true,
    TSFailed => true,
    _ => false,
  }
}

# ---- Task ---------------------------------------------------------
type Task = { id :: Str, context_id :: Str, state :: TaskState, message :: Option[msg.Message], artifacts :: List[msg.Artifact], history :: List[msg.Message] }

# Construct a fresh task in `submitted` state.
fn submitted(id :: Str, context_id :: Str, initial :: msg.Message) -> Task {
  { id: id, context_id: context_id, state: TSSubmitted, message: None, artifacts: [], history: [initial] }
}

# ---- Transitions -------------------------------------------------
#
# `advance(task, next_state, msg?)` enforces the legal lifecycle:
#
#   submitted → working          OK
#   working   → input-required   OK
#   working   → completed | canceled | failed   OK
#   input-required → working     OK
#   *terminal* → anything        rejected
#
# Any other move surfaces a `TaskError`.
type TaskError = InvalidTransition({ from :: Str, to :: Str }) | UnknownState(Str)

fn task_error_message(e :: TaskError) -> Str {
  match e {
    InvalidTransition(t) => str.concat("invalid transition ", str.concat(t.from, str.concat(" → ", t.to))),
    UnknownState(s) => str.concat("unknown state: ", s),
  }
}

fn legal_transition(from :: TaskState, to :: TaskState) -> Bool {
  if is_terminal(from) {
    false
  } else {
    match from {
      TSSubmitted => match to {
        TSWorking => true,
        TSCanceled => true,
        TSFailed => true,
        _ => false,
      },
      TSWorking => match to {
        TSInputRequired => true,
        TSCompleted => true,
        TSCanceled => true,
        TSFailed => true,
        TSWorking => true,
        _ => false,
      },
      TSInputRequired => match to {
        TSWorking => true,
        TSCanceled => true,
        TSFailed => true,
        _ => false,
      },
      _ => false,
    }
  }
}

fn advance(t :: Task, to :: TaskState, m :: Option[msg.Message]) -> Result[Task, TaskError] {
  if legal_transition(t.state, to) {
    let new_history := match m {
      None => t.history,
      Some(x) => list.concat(t.history, [x]),
    }
    Ok({ id: t.id, context_id: t.context_id, state: to, message: m, artifacts: t.artifacts, history: new_history })
  } else {
    Err(InvalidTransition({ from: state_label(t.state), to: state_label(to) }))
  }
}

# Add an artifact mid-flight — legal in any non-terminal state.
fn add_artifact(t :: Task, a :: msg.Artifact) -> Result[Task, TaskError] {
  if is_terminal(t.state) {
    Err(InvalidTransition({ from: state_label(t.state), to: "add-artifact" }))
  } else {
    Ok({ id: t.id, context_id: t.context_id, state: t.state, message: t.message, artifacts: list.concat(t.artifacts, [a]), history: t.history })
  }
}

# ---- JSON wire conversion ----------------------------------------
fn task_to_json(t :: Task) -> jv.Json {
  let base := [("kind", JStr("task")), ("id", JStr(t.id)), ("contextId", JStr(t.context_id)), ("status", JObj([("state", JStr(state_label(t.state)))])), ("artifacts", JList(list.map(t.artifacts, msg.artifact_to_json))), ("history", JList(list.map(t.history, msg.message_to_json)))]
  let with_msg := match t.message {
    None => base,
    Some(m) => list.concat(base, [("message", msg.message_to_json(m))]),
  }
  JObj(with_msg)
}

# Inverse of `task_to_json`. The durable (SQLite) task store persists
# tasks as their canonical wire JSON and rebuilds them on read, so
# this is the load half of that round-trip. `id` and `status.state`
# are required (a stored task without them is corrupt); `message`,
# `artifacts`, and `history` are reconstructed best-effort, dropping
# any individual entry that fails to parse rather than failing the
# whole task — A2A parse tolerance, applied to our own storage.
fn task_from_json(j :: jv.Json) -> Result[Task, Str] {
  match jv.get_field(j, "id") {
    None => Err("task json missing `id`"),
    Some(idj) => match jv.as_str(idj) {
      None => Err("task `id` must be a string"),
      Some(id) => match parse_state_field(j) {
        Err(e) => Err(e),
        Ok(st) => Ok({ id: id, context_id: parse_context_id_field(j), state: st, message: parse_message_field(j), artifacts: parse_artifacts_field(j), history: parse_history_field(j) }),
      },
    },
  }
}

fn parse_context_id_field(j :: jv.Json) -> Str {
  match jv.get_field(j, "contextId") {
    Some(v) => match jv.as_str(v) {
      Some(s) => s,
      None => "",
    },
    None => "",
  }
}

fn parse_state_field(j :: jv.Json) -> Result[TaskState, Str] {
  match jv.get_field(j, "status") {
    None => Err("task json missing `status`"),
    Some(sj) => match jv.get_field(sj, "state") {
      None => Err("task `status` missing `state`"),
      Some(sv) => match jv.as_str(sv) {
        None => Err("task `state` must be a string"),
        Some(s) => match state_of(s) {
          None => Err(str.concat("unknown task state: ", s)),
          Some(ts) => Ok(ts),
        },
      },
    },
  }
}

fn parse_message_field(j :: jv.Json) -> Option[msg.Message] {
  match jv.get_field(j, "message") {
    None => None,
    Some(mj) => match msg.parse_message(mj) {
      Ok(m) => Some(m),
      Err(_) => None,
    },
  }
}

fn parse_history_field(j :: jv.Json) -> List[msg.Message] {
  match jv.get_field(j, "history") {
    None => [],
    Some(hj) => match jv.as_list(hj) {
      None => [],
      Some(items) => list.fold(items, [], fn (acc :: List[msg.Message], it :: jv.Json) -> List[msg.Message] {
        match msg.parse_message(it) {
          Ok(m) => list.concat(acc, [m]),
          Err(_) => acc,
        }
      }),
    },
  }
}

fn parse_artifacts_field(j :: jv.Json) -> List[msg.Artifact] {
  match jv.get_field(j, "artifacts") {
    None => [],
    Some(aj) => match jv.as_list(aj) {
      None => [],
      Some(items) => list.fold(items, [], fn (acc :: List[msg.Artifact], it :: jv.Json) -> List[msg.Artifact] {
        match msg.parse_artifact(it) {
          Ok(a) => list.concat(acc, [a]),
          Err(_) => acc,
        }
      }),
    },
  }
}

# A "status update" SSE event — the wire-frame an `tasks/sendSubscribe`
# subscriber receives between full Task snapshots. Keeps the payload
# small: state code + optional message.
type StatusUpdate = { task_id :: Str, state :: TaskState, message :: Option[msg.Message], final :: Bool }

fn status_update(t :: Task, m :: Option[msg.Message]) -> StatusUpdate {
  { task_id: t.id, state: t.state, message: m, final: is_terminal(t.state) }
}

fn status_to_json(u :: StatusUpdate) -> jv.Json {
  let base := [("kind", JStr("status-update")), ("taskId", JStr(u.task_id)), ("state", JStr(state_label(u.state))), ("final", JBool(u.final))]
  match u.message {
    None => JObj(base),
    Some(m) => JObj(list.concat(base, [("message", msg.message_to_json(m))])),
  }
}

