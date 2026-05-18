# lex-agent — Server-Sent Events encoder + decoder
#
# A2A streaming responses (`tasks/sendSubscribe`) carry an SSE stream
# of `StatusUpdate` events terminated by a final-frame marker. Each
# event is a single `data: <json>` line followed by a blank line:
#
#   data: {"id":"task_abc","state":"working","final":false}
#
#   data: {"id":"task_abc","state":"completed","final":true}
#
# This module wraps the encode / decode in pure helpers — the
# transport (HTTP write half on the server, `http.stream_lines` on
# the client) lives in `server.lex` / `client.lex`.

import "std.list" as list
import "std.str"  as str

import "lex-schema/json_value" as jv

import "./task" as tk

# ---- Encoder -----------------------------------------------------

# Render a single SSE `data:` frame from a Json payload. Closes with
# the mandatory empty line (`\n\n`) — SSE field-delimiter is `\n\n`
# between events, single `\n` inside an event.
fn encode_data(payload :: jv.Json) -> Str {
  str.concat("data: ", str.concat(jv.stringify(payload), "\n\n"))
}

# Encode a Task status update as an SSE frame.
fn encode_status(u :: tk.StatusUpdate) -> Str {
  encode_data(tk.status_to_json(u))
}

# Encode a list of updates back-to-back. Useful for tests / one-shot
# rendering; live servers will trickle these out over time.
fn encode_stream(updates :: List[tk.StatusUpdate]) -> Str {
  list.fold(updates, "", fn (acc :: Str, u :: tk.StatusUpdate) -> Str {
    str.concat(acc, encode_status(u))
  })
}

# ---- Decoder -----------------------------------------------------
#
# `decode_payloads` consumes a list of raw SSE lines (the shape
# `std.http.stream_lines` yields) and returns the parsed payloads.
# Comments (`:` prefix) and field types other than `data:` are
# ignored. A line of `data: [DONE]` ends the stream — mirroring the
# OpenAI SSE convention, which most A2A reference servers follow.

fn decode_payloads(lines :: List[Str]) -> List[jv.Json] {
  let collected := list.fold(lines, { items: [], done: false },
    fn (acc :: { items :: List[jv.Json], done :: Bool }, line :: Str) -> { items :: List[jv.Json], done :: Bool } {
      if acc.done { acc }
      else { decode_line(acc, line) }
    })
  collected.items
}

fn decode_line(
  acc :: { items :: List[jv.Json], done :: Bool },
  line :: Str
) -> { items :: List[jv.Json], done :: Bool } {
  match str.strip_prefix(line, "data: ") {
    None => acc,
    Some(payload) => {
      if payload == "[DONE]" {
        { items: acc.items, done: true }
      } else {
        match jv.parse(payload) {
          Err(_) => acc,
          Ok(j)  => { items: list.concat(acc.items, [j]), done: false },
        }
      }
    },
  }
}

# Decode the payloads into structured `StatusUpdate`s. Anything
# missing fields is silently dropped — clients consuming an A2A
# stream from a third-party reference impl may see auxiliary
# events; we surface only the canonical shape and let consumers
# resync via `tasks/get`.

fn decode_statuses(lines :: List[Str]) -> List[tk.StatusUpdate] {
  let payloads := decode_payloads(lines)
  list.fold(payloads, [],
    fn (acc :: List[tk.StatusUpdate], j :: jv.Json) -> List[tk.StatusUpdate] {
      match decode_status(j) {
        None    => acc,
        Some(u) => list.concat(acc, [u]),
      }
    })
}

fn decode_status(j :: jv.Json) -> Option[tk.StatusUpdate] {
  # Tolerate both modern (`taskId`) and legacy (`id`) framing — older
  # A2A reference servers still emit the bare `id` form.
  let id_field := match jv.get_field(j, "taskId") {
    Some(v) => Some(v),
    None    => jv.get_field(j, "id"),
  }
  match id_field {
    None => None,
    Some(idj) => match jv.as_str(idj) {
      None => None,
      Some(id) => match jv.get_field(j, "state") {
        None => None,
        Some(sj) => match jv.as_str(sj) {
          None => None,
          Some(s) => match tk.state_of(s) {
            None => None,
            Some(state) => {
              let fin := match jv.get_field(j, "final") {
                Some(fj) => match jv.as_bool(fj) { Some(b) => b, None => false },
                None     => tk.is_terminal(state),
              }
              Some({ task_id: id, state: state, message: None, final: fin })
            },
          },
        },
      },
    },
  }
}
