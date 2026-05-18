# lex-agent — lex-web integration
#
# `mount(router, agent)` registers the two A2A endpoints onto a
# `lex-web/router.Router` and returns the augmented router:
#
#   GET  /.well-known/agent.json   — AgentCard discovery document
#   POST /                          — JSON-RPC 2.0 dispatch
#
# After mounting, the caller wires the router through any of
# lex-web's transports — `router.dispatch` plus `std.net.serve_fn`
# in the common case. Middlewares (request-id correlation,
# structured access logs, body-size limit, gzip negotiation) attach
# to the same router; the A2A routes inherit them for free.
#
# The card route is pure — it just renders the AgentDef's
# pre-built card. The POST route is effectful (declares the same
# wide row lex-web's `route_effectful` accepts) because handler
# closures inside `dispatch_request` may need IO, SQL, etc.
#
# SSE detection: when the request body contains `tasks/sendSubscribe`,
# `rpc_route` calls `srv.dispatch_subscribe_str` and returns the
# concatenated SSE frames with `content-type: text/event-stream`.
# Other JSON-RPC methods take the usual `resp.json(...)` path.
#
# Effects: none in `mount` itself — it only builds router records.

import "std.map" as map

import "lex-web/ctx"      as ctx
import "lex-web/response" as resp
import "lex-web/router"   as router
import "lex-web/body"     as wbody

import "./server" as srv

# Discovery endpoint. The card is built once at agent-construction
# time; rendering is a pure string fold over the AgentCard record.
fn card_route(agent :: srv.AgentDef) -> (ctx.Ctx) -> resp.Response {
  fn (_c :: ctx.Ctx) -> resp.Response {
    resp.json(srv.agent_card_response(agent))
  }
}

# JSON-RPC dispatch endpoint. Reads the raw body and routes:
#   - `tasks/sendSubscribe` → SSE frames (content-type: text/event-stream)
#   - all other methods    → JSON-RPC response (application/json)
#
# The HTTP status is always 200 — JSON-RPC errors ride inside the
# response envelope, not the HTTP layer.
fn rpc_route(agent :: srv.AgentDef) -> (ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response {
  fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response {
    let body_str := wbody.raw_body(c)
    if srv.is_subscribe_body(body_str) {
      let sse_body := srv.dispatch_subscribe_str(agent, body_str)
      {
        status:  200,
        body:    sse_body,
        headers: map.from_list([
          ("content-type",  "text/event-stream"),
          ("cache-control", "no-cache"),
          ("connection",    "keep-alive"),
        ]),
      }
    } else {
      let response := srv.dispatch_request(agent, body_str)
      resp.json(response)
    }
  }
}

# Mount both A2A routes onto an existing lex-web router. Returns
# the augmented router — chainable with further `router.route` /
# `router.use_mw` calls.
fn mount(r :: router.Router, agent :: srv.AgentDef) -> router.Router {
  let with_card := router.route(r, "GET", "/.well-known/agent.json",
    card_route(agent))
  router.route_effectful(with_card, "POST", "/", rpc_route(agent))
}
