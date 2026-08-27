# Tests for `src/protocol.lex` — JSON-RPC 2.0 parse / render.

import "std.list" as list

import "std.str" as str

import "lex-schema/json_value" as jv

import "../src/protocol" as proto

fn parse_valid_request() -> Result[Unit, Str] {
  let body := "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tasks/send\",\"params\":{}}"
  match proto.parse_request(body) {
    Err(e) => Err(str.concat("expected Ok: ", e.message)),
    Ok(req) => match req.method == "tasks/send" {
      true => Ok(()),
      false => Err(str.concat("bad method: ", req.method)),
    },
  }
}

fn rejects_wrong_jsonrpc_version() -> Result[Unit, Str] {
  let body := "{\"jsonrpc\":\"1.5\",\"id\":1,\"method\":\"x\",\"params\":{}}"
  match proto.parse_request(body) {
    Err(_) => Ok(()),
    Ok(_) => Err("should have rejected jsonrpc 1.5"),
  }
}

fn rejects_missing_method() -> Result[Unit, Str] {
  let body := "{\"jsonrpc\":\"2.0\",\"id\":1,\"params\":{}}"
  match proto.parse_request(body) {
    Err(_) => Ok(()),
    Ok(_) => Err("should have rejected missing method"),
  }
}

fn render_ok_includes_result() -> Result[Unit, Str] {
  let r := proto.ok(IdInt(42), JStr("done"))
  let s := proto.response_to_str(r)
  if str.contains(s, "\"jsonrpc\":\"2.0\"") and str.contains(s, "\"id\":42") and str.contains(s, "\"result\":\"done\"") {
    Ok(())
  } else {
    Err(str.concat("bad rendering: ", s))
  }
}

fn render_error_includes_code() -> Result[Unit, Str] {
  let r := proto.fail(IdStr("x"), proto.err_spec_denied(), "blocked")
  let s := proto.response_to_str(r)
  if str.contains(s, "\"error\":") and str.contains(s, "\"code\":-32099") and str.contains(s, "blocked") {
    Ok(())
  } else {
    Err(str.concat("bad error rendering: ", s))
  }
}

fn parses_string_id() -> Result[Unit, Str] {
  let body := "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"tasks/get\",\"params\":{}}"
  match proto.parse_request(body) {
    Err(e) => Err(e.message),
    Ok(req) => match req.id {
      IdStr(s) => if s == "abc" {
        Ok(())
      } else {
        Err(str.concat("got: ", s))
      },
      _ => Err("expected IdStr"),
    },
  }
}

fn render_null_id() -> Result[Unit, Str] {
  let r := proto.fail(IdNull, proto.err_parse(), "bad json")
  let s := proto.response_to_str(r)
  if str.contains(s, "\"id\":null") {
    Ok(())
  } else {
    Err(s)
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [parse_valid_request(), rejects_wrong_jsonrpc_version(), rejects_missing_method(), render_ok_includes_result(), render_error_includes_code(), parses_string_id(), render_null_id()]
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

