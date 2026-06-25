# lex-agent — A2A client
#
# Two responsibilities:
#
#   1. `fetch_agent_card(peer_url)` — GET `peer_url/.well-known/agent.json`
#      and parse it into an `AgentCard` (so callers can introspect a
#      remote agent's skills before invoking).
#
#   2. `send_task(peer_url, message, opts)` — POST a `tasks/send`
#      JSON-RPC request and parse the response.
#
#   3. `subscribe(peer_url, message, opts)` — POST a
#      `tasks/sendSubscribe` and decode the SSE stream into typed
#      `StatusUpdate`s via `stream.lex`.
#
# Trail-aware variants (`send_task_traced`, `subscribe_traced`) emit
# an `a2a.*` event before the network call. Pass a `trail.Log` from
# `trail.open_memory()` in tests or `trail.open(path)` in production.
#
# Effects: `[net]` for HTTP, `[llm]` semantic annotation when callers
# want to gate AI-side dispatch separately. The send / subscribe
# paths do NOT declare `[llm]` directly — they're plain HTTP — but
# wrappers in lex-llm that put outbound capabilities behind the
# model's tool list pick that up at the next layer.

import "std.http" as http

import "std.bytes" as bytes

import "std.list" as list

import "std.str" as str

import "std.map" as map

import "std.stream" as stream

import "lex-schema/json_value" as jv

import "lex-trail/log" as trail

import "lex-trail/kinds" as kinds

import "./protocol" as proto

import "./agent_card" as card

import "./message" as msg

import "./task" as tk

import "./stream" as ssem

# ---- AgentCard fetch ---------------------------------------------
fn agent_card_url(peer_url :: Str) -> Str {
  let trimmed := if str.ends_with(peer_url, "/") {
    str.slice(peer_url, 0, str.len(peer_url) - 1)
  } else {
    peer_url
  }
  str.concat(trimmed, "/.well-known/agent.json")
}

# Fetch + parse. Returns `Err(Str)` if the HTTP call fails or the
# response body isn't a valid card.
fn fetch_agent_card(peer_url :: Str) -> [net] Result[card.AgentCard, Str] {
  match http.get(agent_card_url(peer_url)) {
    Err(e) => Err(str.concat("http error: ", http_err_str(e))),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(m) => Err(str.concat("body decode: ", m)),
      Ok(s) => parse_card_response(s),
    },
  }
}

# Pretty-print the structured `HttpError` variant as a plain string.
# The variant carries an optional payload; we surface it where present.
fn http_err_str(e :: HttpError) -> Str {
  match e {
    TimeoutError => "timeout",
    TlsError(m) => str.concat("tls: ", m),
    NetworkError(m) => str.concat("network: ", m),
    DecodeError(m) => str.concat("decode: ", m),
  }
}

# Card parser — minimal. v0.1 picks out name / description /
# version / url and decodes the skills array as opaque Json (full
# schema-round-trip is in `agent_card.lex`'s test suite). Real
# clients calling `fetch_agent_card` typically only need name +
# skill names + endpoint URLs to route through.
fn parse_card_response(body :: Str) -> Result[card.AgentCard, Str] {
  match jv.parse(body) {
    Err(p) => Err(str.concat("agent card parse error: ", p.message)),
    Ok(j) => Ok({ name: pull_str(j, "name", ""), description: pull_str(j, "description", ""), version: pull_str(j, "version", "0.0.0"), url: pull_str(j, "url", ""), provider: { organization: "", url: "" }, capabilities: card.default_capabilities(), default_input_modes: [], default_output_modes: [], skills: [] }),
  }
}

fn pull_str(j :: jv.Json, field :: Str, default :: Str) -> Str {
  match jv.get_field(j, field) {
    None => default,
    Some(v) => match jv.as_str(v) {
      Some(s) => s,
      None => default,
    },
  }
}

# ---- Send options ------------------------------------------------
type SendOpts = { task_id :: Str, context_id :: Str, skill :: Str }

fn default_opts() -> SendOpts {
  { task_id: "task_0", context_id: "ctx_0", skill: "" }
}

# Build the JSON-RPC params payload for `tasks/send`. Pure — callers
# stamp a fresh messageId on the Message via `stamp_message` BEFORE
# calling, so this function stays free of effects (the caller already
# owns the `[crypto, random]` row from gen_message_id anyway).
fn build_send_params(m :: msg.Message, opts :: SendOpts) -> jv.Json {
  let base := [("id", JStr(opts.task_id)), ("contextId", JStr(opts.context_id)), ("message", msg.message_to_json(m))]
  if str.is_empty(opts.skill) {
    JObj(base)
  } else {
    JObj(list.concat(base, [("skill", JStr(opts.skill))]))
  }
}

# Stamp a fresh messageId on the outbound message if it's blank.
# Split out from build_send_params so the pure params-builder stays
# pure — only this helper carries the [crypto, random] row.
fn stamp_message(m :: msg.Message) -> [crypto, random] msg.Message {
  if str.is_empty(m.message_id) {
    msg.with_message_id(m, msg.gen_message_id())
  } else {
    m
  }
}

# Build a full JSON-RPC envelope for `tasks/send` or sendSubscribe.
fn build_envelope(method :: Str, params :: jv.Json, id :: proto.RpcId) -> Str {
  let env := JObj([("jsonrpc", JStr("2.0")), ("id", proto.id_to_json(id)), ("method", JStr(method)), ("params", params)])
  jv.stringify(env)
}

# ---- send_task ---------------------------------------------------
fn send_task(peer_url :: Str, m :: msg.Message, opts :: SendOpts) -> [net, crypto, random] Result[jv.Json, proto.RpcError] {
  let stamped := stamp_message(m)
  let params := build_send_params(stamped, opts)
  let body := build_envelope(proto.method_tasks_send(), params, IdStr(opts.task_id))
  match http.post(peer_url, bytes.from_str(body), "application/json") {
    Err(e) => Err(proto.error(proto.err_internal(), str.concat("http error: ", http_err_str(e)))),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(m) => Err(proto.error(proto.err_internal(), str.concat("body decode: ", m))),
      Ok(s) => parse_response_body(s),
    },
  }
}

# Decode the server response. JSON-RPC: `error` field present → Err;
# `result` field → Ok.
fn parse_response_body(body :: Str) -> Result[jv.Json, proto.RpcError] {
  match jv.parse(body) {
    Err(p) => Err(proto.error(proto.err_parse(), p.message)),
    Ok(j) => match jv.get_field(j, "error") {
      Some(ej) => Err(parse_rpc_error(ej)),
      None => match jv.get_field(j, "result") {
        Some(r) => Ok(r),
        None => Err(proto.error(proto.err_internal(), "response has neither `result` nor `error`")),
      },
    },
  }
}

fn parse_rpc_error(j :: jv.Json) -> proto.RpcError {
  let code := match jv.get_field(j, "code") {
    Some(v) => match jv.as_int(v) {
      Some(n) => n,
      None => proto.err_internal(),
    },
    None => proto.err_internal(),
  }
  let message := match jv.get_field(j, "message") {
    Some(v) => match jv.as_str(v) {
      Some(s) => s,
      None => "<no message>",
    },
    None => "<no message>",
  }
  let data := jv.get_field(j, "data")
  match data {
    None => proto.error(code, message),
    Some(d) => proto.error_with_data(code, message, d),
  }
}

# ---- subscribe --------------------------------------------------
#
# POST a sendSubscribe and decode the SSE stream into StatusUpdates.
# `http.stream_lines` yields a lazy `Stream[Str]` (lex-lang 0.10), read
# line-by-line off the socket; good enough for A2A servers that close
# the connection after the terminal frame.
fn subscribe(peer_url :: Str, m :: msg.Message, opts :: SendOpts, api_key :: Str) -> [net, crypto, random, stream] Result[List[tk.StatusUpdate], Str] {
  let stamped := stamp_message(m)
  let params := build_send_params(stamped, opts)
  let body := build_envelope(proto.method_tasks_send_subscribe(), params, IdStr(opts.task_id))
  let headers := build_headers(api_key)
  match http.stream_lines(peer_url, headers, body) {
    Err(e) => Err(str.concat("stream error: ", e)),
    Ok(s) => Ok(decode_stream(s)),
  }
}

fn build_headers(api_key :: Str) -> Map[Str, Str] {
  if str.is_empty(api_key) {
    map.from_list([("content-type", "application/json"), ("accept", "text/event-stream")])
  } else {
    map.from_list([("authorization", str.concat("Bearer ", api_key)), ("content-type", "application/json"), ("accept", "text/event-stream")])
  }
}

# Collect the lazy line stream into a List[Str] then run it through the
# stream decoder. Consuming the stream carries the `[stream]` effect.
fn decode_stream(s :: Stream[Str]) -> [stream] List[tk.StatusUpdate] {
  let lines := stream_to_list(s)
  ssem.decode_statuses(lines)
}

# Drain the lazy `Stream[Str]` into a List[Str] via `std.stream`.
fn stream_to_list(s :: Stream[Str]) -> [stream] List[Str] {
  stream.collect(s)
}

# ---- Trail-aware variants ----------------------------------------
#
# `send_task_traced` and `subscribe_traced` emit an `a2a.*` event
# before executing the underlying network call. Emission is
# best-effort: a write failure never surfaces to the caller.
fn send_task_traced(log :: trail.Log, parent :: Option[Str], peer_url :: Str, m :: msg.Message, opts :: SendOpts) -> [net, crypto, random, sql, time] Result[jv.Json, proto.RpcError] {
  let payload := str.join(["{\"task_id\":\"", opts.task_id, "\",\"to_agent\":\"", peer_url, "\",\"skill\":\"", opts.skill, "\"}"], "")
  let __evt := trail.append(log, kinds.a2a_task_sent(), parent, payload)
  send_task(peer_url, m, opts)
}

fn subscribe_traced(log :: trail.Log, parent :: Option[Str], peer_url :: Str, m :: msg.Message, opts :: SendOpts, api_key :: Str) -> [net, crypto, random, sql, time, stream] Result[List[tk.StatusUpdate], Str] {
  let payload := str.join(["{\"task_id\":\"", opts.task_id, "\",\"to_agent\":\"", peer_url, "\"}"], "")
  let __evt := trail.append(log, kinds.a2a_msg_sent(), parent, payload)
  subscribe(peer_url, m, opts, api_key)
}

