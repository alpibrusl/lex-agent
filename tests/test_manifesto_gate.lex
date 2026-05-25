# Tests for the manifesto gate demo — the pure, dependency-free core.
#
# The server runs exactly this `cap.gate` evaluation before dispatching
# any handler (see src/server.lex `run_skill` / `bindings_from_message`).
# These tests assert the manifesto's claim directly: a well-formed input
# is Allowed, a malformed input is Denied — verification, not trust.

import "std.str" as str

import "std.list" as list

import "lex-schema/schema" as sch

import "lex-spec/spec" as sp

import "lex-spec/capability" as cap

# Same capability + precondition as examples/manifesto_gate.lex.
fn summarize_capability() -> cap.Capability {
  let base := cap.inbound("summarize", "Summarize the input text.", { title: "SummarizeArgs", description: "", fields: [sch.required_str("text", [StrNonEmpty])] })
  cap.with_precondition(base, { name: "input_nonempty", quantifiers: [QRecord({ name: "args", fields: [{ name: "text", ty: TStr }] })], predicate: EBinop({ op: "!=", lhs: EField({ binding: "args", field: "text" }), rhs: EConst(VStr("")) }) })
}

# Mirrors src/server.lex `bindings_from_message`: a single `args` record
# carrying the message role and first text part.
fn bindings(text :: Str) -> List[(Str, sp.SpecValue)] {
  [("args", VRecord({ name: "Args", fields: [("role", VStr("user")), ("text", VStr(text))] }))]
}

fn good_input_allowed() -> Result[Unit, Str] {
  match cap.gate(summarize_capability(), bindings("the quarterly report")) {
    Allow => Ok(()),
    Deny(r) => Err(str.concat("well-formed input was denied: ", r)),
    Inconclusive(r) => Err(str.concat("well-formed input was inconclusive: ", r)),
  }
}

fn empty_input_denied() -> Result[Unit, Str] {
  match cap.gate(summarize_capability(), bindings("")) {
    Deny(_) => Ok(()),
    Allow => Err("empty input was allowed — the gate failed to fire"),
    Inconclusive(r) => Err(str.concat("empty input was inconclusive, expected deny: ", r)),
  }
}

fn run_all() -> Unit {
  let results := [good_input_allowed(), empty_input_denied()]
  let failures := list.fold(results, 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => n,
      Err(_) => n + 1,
    }
  })
  if failures == 0 {
    ()
  } else {
    let __discard := 1 / 0
    ()
  }
}

