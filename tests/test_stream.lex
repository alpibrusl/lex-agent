# Tests for `src/stream.lex` — SSE encode + decode.

import "std.list" as list

import "std.str" as str

import "../src/message" as msg

import "../src/task" as tk

import "../src/stream" as ssem

fn encode_includes_data_prefix() -> Result[Unit, Str] {
  let u := { task_id: "t_1", state: TSWorking, message: None, final: false }
  let s := ssem.encode_status(u)
  if str.starts_with(s, "data: ") and str.ends_with(s, "\n\n") {
    Ok(())
  } else {
    Err(str.concat("bad encode: ", s))
  }
}

fn decode_basic_event() -> Result[Unit, Str] {
  let lines := ["data: {\"id\":\"t_1\",\"state\":\"working\",\"final\":false}", "", "data: {\"id\":\"t_1\",\"state\":\"completed\",\"final\":true}", ""]
  let xs := ssem.decode_statuses(lines)
  if list.len(xs) == 2 {
    Ok(())
  } else {
    Err(str.concat("expected 2 events, got ", "?"))
  }
}

fn decode_skips_done_marker() -> Result[Unit, Str] {
  let lines := ["data: {\"id\":\"t_1\",\"state\":\"working\",\"final\":false}", "data: [DONE]", "data: {\"id\":\"t_1\",\"state\":\"completed\",\"final\":true}"]
  let xs := ssem.decode_statuses(lines)
  if list.len(xs) == 1 {
    Ok(())
  } else {
    Err("DONE should terminate")
  }
}

fn decode_ignores_comments() -> Result[Unit, Str] {
  let lines := [": ping", "", "data: {\"id\":\"t_1\",\"state\":\"working\",\"final\":false}"]
  let xs := ssem.decode_statuses(lines)
  if list.len(xs) == 1 {
    Ok(())
  } else {
    Err("comment broke parse")
  }
}

fn decode_drops_malformed_payloads() -> Result[Unit, Str] {
  let lines := ["data: not json", "data: {\"id\":\"t_1\",\"state\":\"working\",\"final\":false}"]
  let xs := ssem.decode_statuses(lines)
  if list.len(xs) == 1 {
    Ok(())
  } else {
    Err("malformed crashed parse")
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [encode_includes_data_prefix(), decode_basic_event(), decode_skips_done_marker(), decode_ignores_comments(), decode_drops_malformed_payloads()]
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

