# Tests for `src/message.lex` — A2A Message / Part parsing.

import "std.list" as list

import "std.str" as str

import "lex-schema/json_value" as jv

import "../src/message" as msg

fn round_trip_user_text() -> Result[Unit, Str] {
  let m := msg.user_text("hello")
  let j := msg.message_to_json(m)
  match msg.parse_message(j) {
    Err(e) => Err(str.concat("parse: ", e)),
    Ok(m2) => match m2.role {
      RoleUser => match list.head(m2.parts) {
        Some(TextPart(s)) => if s == "hello" {
          Ok(())
        } else {
          Err("text lost")
        },
        _ => Err("expected TextPart"),
      },
      _ => Err("role lost"),
    },
  }
}

# Wire shape: A2A v0.3+ requires `kind: "message"` and `messageId`.
fn emits_kind_and_message_id() -> Result[Unit, Str] {
  let m := msg.user_text_with_id("msg_abc", "hi")
  let s := jv.stringify(msg.message_to_json(m))
  if str.contains(s, "\"kind\":\"message\"") and str.contains(s, "\"messageId\":\"msg_abc\"") {
    Ok(())
  } else {
    Err(str.concat("missing required v0.3 fields: ", s))
  }
}

# Round-trip preserves the messageId.
fn message_id_round_trips() -> Result[Unit, Str] {
  let m := msg.agent_text_with_id("msg_xyz", "pong")
  match msg.parse_message(msg.message_to_json(m)) {
    Err(e) => Err(e),
    Ok(m2) => if m2.message_id == "msg_xyz" {
      Ok(())
    } else {
      Err(str.concat("id lost: ", m2.message_id))
    },
  }
}

# Tolerance: parsing a message without messageId is accepted (older
# producers / stub fixtures), defaults to "".
fn missing_message_id_tolerated() -> Result[Unit, Str] {
  let body := "{\"role\":\"user\",\"parts\":[{\"type\":\"text\",\"text\":\"hi\"}]}"
  match jv.parse(body) {
    Err(_) => Err("parse"),
    Ok(j) => match msg.parse_message(j) {
      Err(e) => Err(str.concat("rejected: ", e)),
      Ok(m) => if str.is_empty(m.message_id) {
        Ok(())
      } else {
        Err("unexpected id")
      },
    },
  }
}

fn parse_data_part() -> Result[Unit, Str] {
  let body := "{\"role\":\"agent\",\"parts\":[{\"type\":\"data\",\"data\":{\"x\":1}}]}"
  match jv.parse(body) {
    Err(_) => Err("parse JSON"),
    Ok(j) => match msg.parse_message(j) {
      Err(e) => Err(str.concat("parse msg: ", e)),
      Ok(m) => match list.head(m.parts) {
        Some(DataPart(_)) => Ok(()),
        _ => Err("expected DataPart"),
      },
    },
  }
}

fn parse_file_part_uri() -> Result[Unit, Str] {
  let body := "{\"role\":\"agent\",\"parts\":[{\"type\":\"file\",\"name\":\"r.csv\",\"mimeType\":\"text/csv\",\"uri\":\"https://x/r.csv\"}]}"
  match jv.parse(body) {
    Err(_) => Err("parse JSON"),
    Ok(j) => match msg.parse_message(j) {
      Err(e) => Err(str.concat("parse msg: ", e)),
      Ok(m) => match list.head(m.parts) {
        Some(FilePart(f)) => match f.data {
          FileUri(u) => if u == "https://x/r.csv" {
            Ok(())
          } else {
            Err("uri lost")
          },
          _ => Err("expected FileUri"),
        },
        _ => Err("expected FilePart"),
      },
    },
  }
}

fn unknown_role_rejected() -> Result[Unit, Str] {
  let body := "{\"role\":\"system\",\"parts\":[]}"
  match jv.parse(body) {
    Err(_) => Err("parse"),
    Ok(j) => match msg.parse_message(j) {
      Err(_) => Ok(()),
      Ok(_) => Err("should have rejected `system`"),
    },
  }
}

fn missing_role_rejected() -> Result[Unit, Str] {
  let body := "{\"parts\":[]}"
  match jv.parse(body) {
    Err(_) => Err("parse"),
    Ok(j) => match msg.parse_message(j) {
      Err(_) => Ok(()),
      Ok(_) => Err("should have rejected missing role"),
    },
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [round_trip_user_text(), emits_kind_and_message_id(), message_id_round_trips(), missing_message_id_tolerated(), parse_data_part(), parse_file_part_uri(), unknown_role_rejected(), missing_role_rejected()]
}

fn run_all_count() -> Int {
  list.fold(suite(), 0, fn (acc :: Int, v :: Result[Unit, Str]) -> Int {
    match v {
      Ok(_) => acc,
      Err(_) => acc + 1,
    }
  })
}

# `lex test` calls `run_all` and DISCARDS what it returns (lex-lang#757), so a
# returned failure count reports `ok` however many assertions failed. Only a
# raise fails a file — the same idiom lex-ems, lex-web and lex-guard use.
# Run `run_all_count` directly to see which assertions failed.
fn run_all() -> Unit {
  if run_all_count() == 0 {
    ()
  } else {
    let __boom := 1 / 0
    ()
  }
}

