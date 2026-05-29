# lex-agent — A2A Message / Part / Artifact ADTs
#
# A2A messages carry an ordered list of `Part`s. Parts are
# heterogeneous: text (raw string), data (structured JSON), or file
# (URI / bytes). `Artifact` is the same shape with a name + index,
# used in task outputs.
#
# Wire shape mirrors the Google A2A spec:
#
#   { "kind": "message",
#     "messageId": "msg_...",
#     "role": "user" | "agent",
#     "parts": [
#       { "type": "text", "text": "..." },
#       { "type": "data", "data": { ... } },
#       { "type": "file", "name": "...", "mimeType": "...",
#                          "uri": "..." | "bytes": "<base64>" }
#     ] }
#
# `messageId` is required by the A2A spec — callers either pass an
# explicit id to the `*_with_id` builders, or use the effectful
# `gen_message_id()` helper to mint a fresh one. The convenience
# `user_text` / `agent_text` builders default to an empty string
# `messageId` so they stay pure for tests; production callers (the
# server's reply path, the client's outbound envelope) generate an id
# via `gen_message_id`.
#
# `kind: "message"` is the discriminator the A2A SDK uses to tell
# Messages apart from Tasks / TaskUpdates on the wire — emit it
# unconditionally, accept it as optional on parse for tolerance.

import "std.list" as list

import "std.str" as str

import "std.crypto" as crypto

import "lex-schema/json_value" as jv

# ---- File part data ----------------------------------------------
type FileRef = FileUri(Str) | FileBytes(Str)

type FilePartData = { name :: Str, mime_type :: Str, data :: FileRef }

# ---- Part ADT -----------------------------------------------------
type Part = TextPart(Str) | DataPart(jv.Json) | FilePart(FilePartData)

type Role = RoleUser | RoleAgent

fn role_label(r :: Role) -> Str {
  match r {
    RoleUser => "user",
    RoleAgent => "agent",
  }
}

fn role_of(s :: Str) -> Option[Role] {
  if s == "user" {
    Some(RoleUser)
  } else {
    if s == "agent" {
      Some(RoleAgent)
    } else {
      None
    }
  }
}

type Message = { message_id :: Str, role :: Role, parts :: List[Part] }

# Convenience builders --------------------------------------------------
#
# The `*_text` / `*_data` builders default `message_id` to "" so test
# fixtures and pure call-sites don't need to thread an effectful id
# through their setup. Production callers (server reply, client send)
# go through `*_with_id` (or call `gen_message_id` first and feed the
# result in).
fn user_text(s :: Str) -> Message {
  { message_id: "", role: RoleUser, parts: [TextPart(s)] }
}

fn agent_text(s :: Str) -> Message {
  { message_id: "", role: RoleAgent, parts: [TextPart(s)] }
}

fn agent_data(data :: jv.Json) -> Message {
  { message_id: "", role: RoleAgent, parts: [DataPart(data)] }
}

fn user_text_with_id(id :: Str, s :: Str) -> Message {
  { message_id: id, role: RoleUser, parts: [TextPart(s)] }
}

fn agent_text_with_id(id :: Str, s :: Str) -> Message {
  { message_id: id, role: RoleAgent, parts: [TextPart(s)] }
}

fn agent_data_with_id(id :: Str, data :: jv.Json) -> Message {
  { message_id: id, role: RoleAgent, parts: [DataPart(data)] }
}

# Stamp / overwrite an existing Message's id — useful when a caller
# constructed the Message via the pure builders and only now has a
# random source available.
fn with_message_id(m :: Message, id :: Str) -> Message {
  { message_id: id, role: m.role, parts: m.parts }
}

# Fresh A2A-style id. 32 hex characters of crypto-random — collision
# resistant, unpredictable, and short enough to read in logs.
fn gen_message_id() -> [crypto, random] Str {
  str.concat("msg_", crypto.random_str_hex(16))
}

# ---- Artifact -----------------------------------------------------
#
# An A2A artifact is a named, indexed bundle of Parts attached to a
# task. Multiple artifacts per task — e.g. an analysis run that
# produces a chart + a CSV.
type Artifact = { name :: Str, index :: Int, parts :: List[Part] }

# ---- JSON wire conversion ----------------------------------------
#
# Both Message and Artifact serialise to / parse from Json. We use
# the `Json` ADT from lex-schema rather than `std.json` so callers
# get total error reporting on malformed wire input.
fn part_to_json(p :: Part) -> jv.Json {
  match p {
    TextPart(s) => JObj([("type", JStr("text")), ("text", JStr(s))]),
    DataPart(d) => JObj([("type", JStr("data")), ("data", d)]),
    FilePart(fp) => JObj(list.concat([("type", JStr("file")), ("name", JStr(fp.name)), ("mimeType", JStr(fp.mime_type))], file_ref_to_json(fp.data))),
  }
}

fn file_ref_to_json(r :: FileRef) -> List[(Str, jv.Json)] {
  match r {
    FileUri(u) => [("uri", JStr(u))],
    FileBytes(b) => [("bytes", JStr(b))],
  }
}

fn message_to_json(m :: Message) -> jv.Json {
  JObj([("kind", JStr("message")), ("messageId", JStr(m.message_id)), ("role", JStr(role_label(m.role))), ("parts", JList(list.map(m.parts, part_to_json)))])
}

fn artifact_to_json(a :: Artifact) -> jv.Json {
  JObj([("name", JStr(a.name)), ("index", JInt(a.index)), ("parts", JList(list.map(a.parts, part_to_json)))])
}

# ---- Parsing ------------------------------------------------------
#
# `parse_message` returns `Result[Message, Str]`. The wire spec for
# unknown part types says "skip"; we instead surface a typed error
# so callers can decide. Roles outside {user, agent} are rejected.
fn parse_message(j :: jv.Json) -> Result[Message, Str] {
  let message_id := match jv.get_field(j, "messageId") {
    Some(v) => match jv.as_str(v) {
      Some(s) => s,
      None => "",
    },
    None => "",
  }
  match jv.get_field(j, "role") {
    None => Err("missing field: role"),
    Some(rj) => match jv.as_str(rj) {
      None => Err("role must be a string"),
      Some(rs) => match role_of(rs) {
        None => Err(str.concat("unknown role: ", rs)),
        Some(r) => match jv.get_field(j, "parts") {
          None => Err("missing field: parts"),
          Some(pj) => match jv.as_list(pj) {
            None => Err("parts must be an array"),
            Some(items) => match parse_parts(items) {
              Err(e) => Err(e),
              Ok(ps) => Ok({ message_id: message_id, role: r, parts: ps }),
            },
          },
        },
      },
    },
  }
}

fn parse_parts(items :: List[jv.Json]) -> Result[List[Part], Str] {
  let walked := list.fold(items, Ok([]), fn (acc :: Result[List[Part], Str], item :: jv.Json) -> Result[List[Part], Str] {
    match acc {
      Err(e) => Err(e),
      Ok(parts) => match parse_part(item) {
        Err(e2) => Err(e2),
        Ok(p) => Ok(list.concat(parts, [p])),
      },
    }
  })
  walked
}

fn parse_part(j :: jv.Json) -> Result[Part, Str] {
  match jv.get_field(j, "type") {
    None => Err("missing part.type"),
    Some(tj) => match jv.as_str(tj) {
      None => Err("part.type must be a string"),
      Some(t) => {
        if t == "text" {
          match jv.get_field(j, "text") {
            None => Err("text part missing `text`"),
            Some(txt) => match jv.as_str(txt) {
              Some(s) => Ok(TextPart(s)),
              None => Err("text part `text` must be string"),
            },
          }
        } else {
          if t == "data" {
            match jv.get_field(j, "data") {
              None => Err("data part missing `data`"),
              Some(d) => Ok(DataPart(d)),
            }
          } else {
            if t == "file" {
              parse_file_part(j)
            } else {
              Err(str.concat("unknown part.type: ", t))
            }
          }
        }
      },
    },
  }
}

fn parse_file_part(j :: jv.Json) -> Result[Part, Str] {
  let name := match jv.get_field(j, "name") {
    Some(v) => match jv.as_str(v) {
      Some(s) => s,
      None => "",
    },
    None => "",
  }
  let mime := match jv.get_field(j, "mimeType") {
    Some(v) => match jv.as_str(v) {
      Some(s) => s,
      None => "application/octet-stream",
    },
    None => "application/octet-stream",
  }
  match jv.get_field(j, "uri") {
    Some(uj) => match jv.as_str(uj) {
      Some(u) => Ok(FilePart({ name: name, mime_type: mime, data: FileUri(u) })),
      None => Err("file.uri must be string"),
    },
    None => match jv.get_field(j, "bytes") {
      Some(bj) => match jv.as_str(bj) {
        Some(b) => Ok(FilePart({ name: name, mime_type: mime, data: FileBytes(b) })),
        None => Err("file.bytes must be base64 string"),
      },
      None => Err("file part needs either `uri` or `bytes`"),
    },
  }
}

