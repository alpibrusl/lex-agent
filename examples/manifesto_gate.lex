# lex-agent — manifesto demo: the capability gate runs before the handler
#
# Manifesto §IV:
#   "You would keep effects ... a capability gate ... an append-only log.
#    This chain is not understood — it is verified, at every link."
# and the lex-spec "evaluate at both ends" property:
#   "the receiver does not trust the sender's gate."
#
# A `summarize` capability carries a precondition: the inbound text must
# be non-empty. The server evaluates that precondition BEFORE the
# handler runs. A well-formed request reaches the handler and the task
# completes. A malformed (empty) request is rejected at the boundary
# with JSON-RPC error -32099 `spec-denied` — the handler never executes.
# Nobody had to read the handler to know the bad input was refused; the
# gate is verified, not trusted.
#
# Run (requires deps: `lex pkg install` fetches lex-schema + lex-spec):
#   lex run --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent \
#       examples/manifesto_gate.lex demo
#
# The pure core of this claim is also asserted, dependency-free, in
# tests/test_manifesto_gate.lex (runs under `lex test`).

import "std.str" as str

import "std.list" as list

import "lex-schema/schema" as sch

import "lex-schema/constraints" as c

import "lex-spec/spec" as sp

import "lex-spec/capability" as cap

import "../src/agent_card" as card

import "../src/server" as srv

import "../src/message" as msg

import "../src/task" as tk

# A capability whose precondition demands non-empty input. The gate
# evaluates this server-side before dispatch.
fn summarize_capability() -> cap.Capability {
  let base := cap.inbound("summarize", "Summarize the input text.", { title: "SummarizeArgs", description: "", fields: [sch.required_str("text", [StrNonEmpty])] })
  cap.with_precondition(base, { name: "input_nonempty", quantifiers: [QRecord({ name: "args", fields: [{ name: "text", ty: TStr }] })], predicate: EBinop({ op: "!=", lhs: EField({ binding: "args", field: "text" }), rhs: EConst(VStr("")) }) })
}

fn first_text(parts :: List[msg.Part]) -> Str {
  match list.head(parts) {
    Some(TextPart(s)) => s,
    _ => "",
  }
}

# The handler only ever sees input that already passed the gate.
# `Skill.handle` is a record-field closure whose effect row is invariant
# (AGENT_GUIDELINES §1.6): it must be declared verbatim even though this
# body is pure. The body uses only a subset (here: none) of the row.
fn summarize_handler(m :: msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] srv.HandlerOutcome {
  { next_state: TSCompleted, reply: Some(msg.agent_text(str.concat("summary of: ", first_text(m.parts)))), artifacts: [] }
}

fn make_agent() -> srv.AgentDef {
  srv.make_agent_def(card.make("summarizer", "demo", "0.1.0", "http://localhost:4040", [summarize_capability()]), [{ capability: summarize_capability(), handle: summarize_handler }])
}

fn good_envelope() -> Str {
  str.concat("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tasks/send\",\"params\":{", str.concat("\"id\":\"t_1\",\"contextId\":\"ctx_1\",", "\"message\":{\"kind\":\"message\",\"messageId\":\"m_in_1\",\"role\":\"user\",\"parts\":[{\"type\":\"text\",\"text\":\"the quarterly report\"}]}}}"))
}

fn empty_envelope() -> Str {
  str.concat("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tasks/send\",\"params\":{", str.concat("\"id\":\"t_2\",\"contextId\":\"ctx_1\",", "\"message\":{\"kind\":\"message\",\"messageId\":\"m_in_2\",\"role\":\"user\",\"parts\":[{\"type\":\"text\",\"text\":\"\"}]}}}"))
}

fn demo() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Str {
  let agent := make_agent()
  let good := srv.dispatch_request(agent, good_envelope())
  let bad := srv.dispatch_request(agent, empty_envelope())
  str.concat("--- valid request: gate passes, handler runs, task completes ---\n", str.concat(good, str.concat("\n\n--- empty input: gate denies at the boundary (-32099), handler never runs ---\n", bad)))
}

