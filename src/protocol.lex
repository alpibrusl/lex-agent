# lex-agent — JSON-RPC 2.0 envelope + method dispatch
#
# A2A messaging rides JSON-RPC 2.0 over HTTPS. This module defines:
#
#   - `Request`  — `{ jsonrpc: "2.0", id, method, params }`
#   - `Response` — `{ jsonrpc: "2.0", id, result | error }`
#   - `RpcError` — `{ code, message, data? }`
#
# The four methods v0.1 supports:
#
#   - `tasks/send`           — submit a task; reply with the final or
#                              current Task snapshot.
#   - `tasks/get`            — fetch a task by id.
#   - `tasks/cancel`         — request cancellation.
#   - `tasks/sendSubscribe`  — submit a task, stream StatusUpdates
#                              via SSE.
#
# Pure value module.

import "std.list" as list

import "std.str" as str

import "std.int" as int

import "lex-schema/json_value" as jv

# ---- Standard error codes ----------------------------------------
#
# JSON-RPC reserved: -32700 .. -32600 (parse / invalid request),
# -32601 (method not found), -32602 (invalid params), -32603 (internal).
# A2A-specific (recommended by the spec):
#   -32001  task not found
#   -32002  task not cancelable
#   -32003  push notifications not supported
#   -32004  unsupported operation
#   -32005  content type not supported
# We add:
#   -32099  spec-denied — the capability's precondition didn't hold
fn err_parse() -> Int {
  0 - 32700
}

fn err_invalid_request() -> Int {
  0 - 32600
}

fn err_method_not_found() -> Int {
  0 - 32601
}

fn err_invalid_params() -> Int {
  0 - 32602
}

fn err_internal() -> Int {
  0 - 32603
}

fn err_task_not_found() -> Int {
  0 - 32001
}

fn err_not_cancelable() -> Int {
  0 - 32002
}

fn err_unsupported_op() -> Int {
  0 - 32004
}

fn err_spec_denied() -> Int {
  0 - 32099
}

# ---- Types --------------------------------------------------------
#
# `RpcId` is the request id — either a numeric, a string, or null
# (notifications, no reply). We model it as an ADT so the response
# echoes the same shape.
type RpcId = IdInt(Int) | IdStr(Str) | IdNull

fn id_to_json(id :: RpcId) -> jv.Json {
  match id {
    IdInt(n) => JInt(n),
    IdStr(s) => JStr(s),
    IdNull => JNull,
  }
}

fn id_from_json(j :: jv.Json) -> RpcId {
  match j {
    JInt(n) => IdInt(n),
    JStr(s) => IdStr(s),
    _ => IdNull,
  }
}

type Request = { id :: RpcId, method :: Str, params :: jv.Json }

type RpcError = { code :: Int, message :: Str, data :: Option[jv.Json] }

fn error(code :: Int, message :: Str) -> RpcError {
  { code: code, message: message, data: None }
}

fn error_with_data(code :: Int, message :: Str, data :: jv.Json) -> RpcError {
  { code: code, message: message, data: Some(data) }
}

type Response = ResOk((RpcId, jv.Json)) | ResErr((RpcId, RpcError))

fn method_tasks_send() -> Str {
  "tasks/send"
}

fn method_tasks_get() -> Str {
  "tasks/get"
}

fn method_tasks_cancel() -> Str {
  "tasks/cancel"
}

fn method_tasks_send_subscribe() -> Str {
  "tasks/sendSubscribe"
}

# ---- Request parsing ---------------------------------------------
fn parse_request(body :: Str) -> Result[Request, RpcError] {
  match jv.parse(body) {
    Err(p) => Err(error(err_parse(), str.concat("parse error: ", p.message))),
    Ok(j) => parse_request_json(j),
  }
}

fn parse_request_json(j :: jv.Json) -> Result[Request, RpcError] {
  let ver_ok := match jv.get_field(j, "jsonrpc") {
    Some(v) => match jv.as_str(v) {
      Some(s) => s == "2.0",
      None => false,
    },
    None => false,
  }
  if not ver_ok {
    Err(error(err_invalid_request(), "missing or invalid `jsonrpc` field"))
  } else {
    let id := match jv.get_field(j, "id") {
      None => IdNull,
      Some(v) => id_from_json(v),
    }
    match jv.get_field(j, "method") {
      None => Err(error(err_invalid_request(), "missing `method`")),
      Some(mj) => match jv.as_str(mj) {
        None => Err(error(err_invalid_request(), "`method` must be string")),
        Some(m) => {
          let params := match jv.get_field(j, "params") {
            Some(p) => p,
            None => JObj([]),
          }
          Ok({ id: id, method: m, params: params })
        },
      },
    }
  }
}

# ---- Response rendering ------------------------------------------
fn response_to_json(r :: Response) -> jv.Json {
  match r {
    ResOk(id, result) => JObj([("jsonrpc", JStr("2.0")), ("id", id_to_json(id)), ("result", result)]),
    ResErr(id, err) => {
      let inner := [("code", JInt(err.code)), ("message", JStr(err.message))]
      let full := match err.data {
        None => inner,
        Some(d) => list.concat(inner, [("data", d)]),
      }
      JObj([("jsonrpc", JStr("2.0")), ("id", id_to_json(id)), ("error", JObj(full))])
    },
  }
}

fn response_to_str(r :: Response) -> Str {
  jv.stringify(response_to_json(r))
}

# Convenience builders ----------------------------------------------
fn ok(id :: RpcId, result :: jv.Json) -> Response {
  ResOk(id, result)
}

fn fail(id :: RpcId, code :: Int, message :: Str) -> Response {
  ResErr(id, error(code, message))
}

fn fail_with_data(id :: RpcId, code :: Int, message :: Str, data :: jv.Json) -> Response {
  ResErr(id, error_with_data(code, message, data))
}

