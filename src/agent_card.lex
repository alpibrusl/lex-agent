# lex-agent — AgentCard
#
# An AgentCard is the discovery document served at
# `/.well-known/agent.json`. It carries:
#
#   - name, description, version, url, endpoint URLs
#   - capabilities flags (streaming, push notifications)
#   - skills — the list of (Inbound) capabilities the agent advertises
#
# Skills carry their `inputSchema` / `outputSchema` as JSON Schema
# 2020-12, derived from lex-schema `ModelSchema` values via
# `schema.to_json_schema`. The same `Capability` value (from
# `lex-spec/capability`) supplies both the schema for the agent card
# and the precondition for server-side gating.
#
# Pure value module.

import "std.list" as list
import "std.str"  as str

import "lex-schema/json_value" as jv
import "lex-schema/schema"     as sch

import "lex-spec/capability"   as cap

# ---- Capability flags --------------------------------------------

type Capabilities = {
  streaming :: Bool,
  push_notifications :: Bool,
  state_transition_history :: Bool,
}

fn default_capabilities() -> Capabilities
  examples {
    default_capabilities() => {
      streaming: true,
      push_notifications: false,
      state_transition_history: true,
    },
  }
{
  { streaming: true, push_notifications: false, state_transition_history: true }
}

# ---- Provider info -----------------------------------------------

type Provider = {
  organization :: Str,
  url :: Str,
}

# ---- AgentCard ---------------------------------------------------

type AgentCard = {
  name :: Str,
  description :: Str,
  version :: Str,
  url :: Str,                       # base URL — same host JSON-RPC endpoints hang off
  provider :: Provider,
  capabilities :: Capabilities,
  default_input_modes :: List[Str],   # e.g. ["text", "data"]
  default_output_modes :: List[Str],
  skills :: List[cap.Capability],
}

# Build an AgentCard with sensible defaults.
fn make(
  name :: Str,
  description :: Str,
  version :: Str,
  url :: Str,
  skills :: List[cap.Capability]
) -> AgentCard {
  {
    name: name,
    description: description,
    version: version,
    url: url,
    provider: { organization: "", url: "" },
    capabilities: default_capabilities(),
    default_input_modes: ["text", "data"],
    default_output_modes: ["text", "data"],
    skills: skills,
  }
}

# ---- JSON serialization ------------------------------------------

fn skill_to_json(c :: cap.Capability) -> jv.Json {
  # `tags` is required by the A2A v0.3+ spec; we emit an empty array
  # by default. Capability values that want richer discovery metadata
  # can extend `lex-spec/capability` with a future `tags` field and
  # pipe it through here without changing the wire shape.
  let base := [
    ("id",          JStr(c.name)),
    ("name",        JStr(c.name)),
    ("description", JStr(c.description)),
    ("tags",        JList([])),
    ("inputSchema", sch.to_json_schema(c.params)),
  ]
  let with_output := match c.reply {
    None    => base,
    Some(s) => list.concat(base, [("outputSchema", sch.to_json_schema(s))]),
  }
  let with_pre := match c.precondition {
    None    => with_output,
    Some(_) => list.concat(with_output, [
      # Don't leak the predicate AST on the wire; just an opaque flag
      # so clients know to re-evaluate-or-trust-the-server.
      ("hasPrecondition", JBool(true)),
    ]),
  }
  JObj(with_pre)
}

fn capabilities_to_json(c :: Capabilities) -> jv.Json {
  JObj([
    ("streaming",              JBool(c.streaming)),
    ("pushNotifications",      JBool(c.push_notifications)),
    ("stateTransitionHistory", JBool(c.state_transition_history)),
  ])
}

fn provider_to_json(p :: Provider) -> jv.Json {
  JObj([
    ("organization", JStr(p.organization)),
    ("url",          JStr(p.url)),
  ])
}

# Full card → Json. Output round-trips through `parse_card` below.
fn card_to_json(a :: AgentCard) -> jv.Json {
  JObj([
    ("name",               JStr(a.name)),
    ("description",        JStr(a.description)),
    ("version",            JStr(a.version)),
    ("url",                JStr(a.url)),
    ("provider",           provider_to_json(a.provider)),
    ("capabilities",       capabilities_to_json(a.capabilities)),
    ("defaultInputModes",  JList(list.map(a.default_input_modes,
      fn (s :: Str) -> jv.Json { JStr(s) }))),
    ("defaultOutputModes", JList(list.map(a.default_output_modes,
      fn (s :: Str) -> jv.Json { JStr(s) }))),
    ("skills",             JList(list.map(a.skills, skill_to_json))),
  ])
}

# Render the card as a JSON string — what `/.well-known/agent.json`
# serves.
fn card_to_str(a :: AgentCard) -> Str { jv.stringify(card_to_json(a)) }

# Pretty-printed variant for human inspection / agent-card files.
fn card_to_pretty(a :: AgentCard) -> Str { jv.stringify_pretty(card_to_json(a)) }
