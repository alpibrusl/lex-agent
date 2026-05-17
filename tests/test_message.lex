# Tests for `src/message.lex` — A2A Message / Part parsing.

import "std.list" as list
import "std.str"  as str

import "lex-schema/json_value" as jv

import "../src/message" as msg

fn round_trip_user_text() -> Result[Unit, Str] {
  let m := msg.user_text("hello")
  let j := msg.message_to_json(m)
  match msg.parse_message(j) {
    Err(e)  => Err(str.concat("parse: ", e)),
    Ok(m2)  => match m2.role {
      RoleUser => match list.head(m2.parts) {
        Some(TextPart(s)) => if s == "hello" { Ok(()) } else { Err("text lost") },
        _ => Err("expected TextPart"),
      },
      _ => Err("role lost"),
    },
  }
}

fn parse_data_part() -> Result[Unit, Str] {
  let body := "{\"role\":\"agent\",\"parts\":[{\"type\":\"data\",\"data\":{\"x\":1}}]}"
  match jv.parse(body) {
    Err(_) => Err("parse JSON"),
    Ok(j)  => match msg.parse_message(j) {
      Err(e) => Err(str.concat("parse msg: ", e)),
      Ok(m)  => match list.head(m.parts) {
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
    Ok(j)  => match msg.parse_message(j) {
      Err(e) => Err(str.concat("parse msg: ", e)),
      Ok(m)  => match list.head(m.parts) {
        Some(FilePart(f)) => match f.data {
          FileUri(u) => if u == "https://x/r.csv" { Ok(()) } else { Err("uri lost") },
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
    Ok(j)  => match msg.parse_message(j) {
      Err(_) => Ok(()),
      Ok(_)  => Err("should have rejected `system`"),
    },
  }
}

fn missing_role_rejected() -> Result[Unit, Str] {
  let body := "{\"parts\":[]}"
  match jv.parse(body) {
    Err(_) => Err("parse"),
    Ok(j)  => match msg.parse_message(j) {
      Err(_) => Ok(()),
      Ok(_)  => Err("should have rejected missing role"),
    },
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [
    round_trip_user_text(),
    parse_data_part(),
    parse_file_part_uri(),
    unknown_role_rejected(),
    missing_role_rejected(),
  ]
}

fn run_all() -> Int {
  list.fold(suite(), 0, fn (acc :: Int, v :: Result[Unit, Str]) -> Int {
    match v {
      Ok(_)  => acc,
      Err(_) => acc + 1,
    }
  })
}
