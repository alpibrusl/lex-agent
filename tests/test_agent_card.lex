# Tests for `src/agent_card.lex` — AgentCard JSON shape.

import "std.list" as list

import "std.str" as str

import "lex-schema/constraints" as c

import "lex-schema/schema" as sch

import "lex-spec/capability" as cap

import "../src/agent_card" as card

fn echo_skill() -> cap.Capability {
  cap.inbound("echo", "echo input back", { title: "EchoArgs", description: "", fields: [sch.required_str("text", [StrNonEmpty])] })
}

fn demo_card() -> card.AgentCard {
  card.make("ping-pong", "demo agent", "0.1.0", "http://localhost:4040", [echo_skill()])
}

fn name_in_json() -> Result[Unit, Str] {
  let s := card.card_to_str(demo_card())
  if str.contains(s, "\"name\":\"ping-pong\"") {
    Ok(())
  } else {
    Err(s)
  }
}

fn capabilities_in_json() -> Result[Unit, Str] {
  let s := card.card_to_str(demo_card())
  if str.contains(s, "\"streaming\":true") {
    Ok(())
  } else {
    Err("streaming missing")
  }
}

fn skill_listed() -> Result[Unit, Str] {
  let s := card.card_to_str(demo_card())
  if str.contains(s, "\"name\":\"echo\"") and str.contains(s, "\"inputSchema\":") {
    Ok(())
  } else {
    Err(str.concat("skill missing: ", s))
  }
}

fn skill_input_schema_includes_constraint() -> Result[Unit, Str] {
  let s := card.card_to_str(demo_card())
  if str.contains(s, "\"minLength\":1") {
    Ok(())
  } else {
    Err("StrNonEmpty should emit minLength:1")
  }
}

# Wire shape: A2A v0.3+ requires AgentSkill.tags.
fn skill_emits_tags() -> Result[Unit, Str] {
  let s := card.card_to_str(demo_card())
  if str.contains(s, "\"tags\":[]") {
    Ok(())
  } else {
    Err(str.concat("missing tags field: ", s))
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [name_in_json(), capabilities_in_json(), skill_listed(), skill_input_schema_includes_constraint(), skill_emits_tags()]
}

fn run_all() -> Int {
  list.fold(suite(), 0, fn (acc :: Int, v :: Result[Unit, Str]) -> Int {
    match v {
      Ok(_) => acc,
      Err(_) => acc + 1,
    }
  })
}

