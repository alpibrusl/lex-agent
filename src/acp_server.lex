# lex-agent — ACP (Agent Communication Protocol) helpers
#
# ACP is a REST protocol from the BeeAI project for agent interoperability.
# Reference: https://agentcommunicationprotocol.dev
#
# Endpoints an ACP server exposes:
#   GET  /            — agent info
#   POST /runs        — synchronous run
#   POST /runs/stream — SSE streaming run
#
# Request  wire shape:
#   { "input": [{ "role": "user",
#                 "content": [{ "type": "text", "text": "..." }] }] }
#
# Response wire shape:
#   { "run_id": "...", "agent_id": "...", "status": "completed",
#     "output": [{ "role": "assistant",
#                  "content": [{ "type": "text", "text": "..." }] }] }
#
# Pure value module — no effects.

import "lex-schema/json_value" as jv

import "std.str" as str

import "std.list" as list

# ---- Agent info --------------------------------------------------
type AcpAgentInfo = { name :: Str, description :: Str, version :: Str, url :: Str }

fn agent_info_json(info :: AcpAgentInfo) -> Str {
  jv.stringify(JObj([("name", JStr(info.name)), ("description", JStr(info.description)), ("version", JStr(info.version)), ("url", JStr(info.url)), ("capabilities", JObj([("input", JList([JStr("text")])), ("output", JList([JStr("text")]))]))]))
}

# ---- Request parsing --------------------------------------------
#
# Returns the text of the first user message content part,
# or Err if the body is not valid JSON.
fn parse_run_request(body :: Str) -> Result[Str, Str] {
  match jv.parse(body) {
    Err(e) => Err(str.concat("json parse error: ", e.message)),
    Ok(j) => Ok(extract_first_user_text(j)),
  }
}

fn extract_first_user_text(j :: jv.Json) -> Str {
  match jv.get_field(j, "input") {
    None => "",
    Some(JList(ms)) => list.fold(ms, "", fn (acc :: Str, m :: jv.Json) -> Str {
      if str.is_empty(acc) {
        match jv.get_field(m, "content") {
          Some(JList(parts)) => list.fold(parts, acc, fn (a :: Str, p :: jv.Json) -> Str {
            if str.is_empty(a) {
              match jv.get_field(p, "text") {
                Some(JStr(t)) => t,
                _ => a,
              }
            } else {
              a
            }
          }),
          _ => acc,
        }
      } else {
        acc
      }
    }),
    _ => "",
  }
}

# ---- Response building ------------------------------------------
fn run_response(run_id :: Str, agent_id :: Str, status :: Str, text :: Str) -> Str {
  jv.stringify(JObj([("run_id", JStr(run_id)), ("agent_id", JStr(agent_id)), ("status", JStr(status)), ("output", JList([JObj([("role", JStr("assistant")), ("content", JList([JObj([("type", JStr("text")), ("text", JStr(text))])]))])]))]))
}

fn run_response_ok(run_id :: Str, agent_id :: Str, text :: Str) -> Str {
  run_response(run_id, agent_id, "completed", text)
}

fn run_response_error(run_id :: Str, agent_id :: Str, message :: Str) -> Str {
  run_response(run_id, agent_id, "failed", message)
}

# ---- SSE frame builders ----------------------------------------
fn sse_frame(event :: Str, data :: Str) -> Str {
  str.join(["event: ", event, "\ndata: ", data, "\n\n"], "")
}

fn sse_started_frame(run_id :: Str) -> Str {
  sse_frame("run.started", jv.stringify(JObj([("run_id", JStr(run_id)), ("status", JStr("running"))])))
}

fn sse_text_chunk_frame(text :: Str) -> Str {
  sse_frame("message", jv.stringify(JObj([("type", JStr("text")), ("text", JStr(text))])))
}

fn sse_completed_frame(run_id :: Str, agent_id :: Str, text :: Str) -> Str {
  sse_frame("run.completed", run_response(run_id, agent_id, "completed", text))
}

fn sse_error_frame(run_id :: Str, agent_id :: Str, message :: Str) -> Str {
  sse_frame("run.failed", run_response(run_id, agent_id, "failed", message))
}

