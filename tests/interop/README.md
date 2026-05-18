# Interop harness

This directory carries the cross-framework wire-format tests that
satisfy [#481](https://github.com/alpibrusl/lex-lang/issues/481)'s
acceptance criteria:

- "AgentCard emission round-trips with a Python A2A SDK example."
- "Server accepts `tasks/send` from a Python A2A client and dispatches
  to a Lex-defined Capability handler."
- "Client `send_task` against a Python A2A server (Google ADK
  reference) parses the response."

The pieces:

| File | Purpose |
|---|---|
| `requirements.txt` | Pinned `a2a-sdk==1.0.3` (the Google Python SDK). |
| `validate_with_a2a_sdk.py` | Parses JSON files through `a2a.compat.v0_3` Pythonic types. Exits non-zero on any validation failure. CI uses this as both a snapshot check and a live-response check. |
| `snapshots/agent_card.json` | Golden AgentCard the way `01_ping_pong.lex` would emit it. Hand-maintained; bump alongside any wire-shape change. |
| `snapshots/task_completed.json` | Golden Task in the terminal "completed" state, including history + reply. |
| `snapshots/message_user.json` | Golden inbound Message. |
| `reference_server.py` | Tiny Python A2A reference server. Every payload it serves is validated through `a2a-sdk` on the way out, so it can't accidentally drift from the canonical wire shape. Used by `examples/04_calls_public_agent.lex` as the peer. |

## Running locally

```bash
# 1. Install the SDK.
pip install -r tests/interop/requirements.txt

# 2. Validate the committed snapshots.
python3 tests/interop/validate_with_a2a_sdk.py \
    --card    tests/interop/snapshots/agent_card.json \
    --task    tests/interop/snapshots/task_completed.json \
    --message tests/interop/snapshots/message_user.json \
    --strict

# 3. Smoke-test the reference server.
python3 tests/interop/reference_server.py --port 4041 &
curl -fsS http://127.0.0.1:4041/.well-known/agent.json | python3 -m json.tool

# 4. Cross-framework: Lex client → Python server.
lex run --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent \
    examples/04_calls_public_agent.lex demo
```

Expected output of step 4:

```
card: name=py-echo
send-task: state=completed text=pong: hello
send-task-denied: code=-32099 message=spec-denied: predicate false: (args.text != "")
```

## Why the v0.3 compat namespace?

`a2a-sdk` 1.0+ ships protobuf-generated types as its primary surface.
The JSON encoding the canonical A2A spec uses (`{"state":"completed"}`)
isn't what protobuf JSON serialisation produces by default
(`{"state":"TASK_STATE_COMPLETED"}`). The `a2a.compat.v0_3.types`
namespace keeps the Pydantic models for the canonical JSON wire
format — that's what we round-trip lex-agent's emit through.

If the SDK ever drops the v0.3 compat module, the right move is to
either pin to a version that still has it OR shift our snapshots to
the protobuf JSON form (and bring the wire shape over to match).

## What this DOESN'T cover (yet)

- **A2A v1.0 protobuf-form interop.** When upstream agents move to
  the protobuf shape on the wire, we'll need an emitter variant on
  the Lex side that produces `{"state":"TASK_STATE_COMPLETED"}` etc.
  Tracked in the `tasks/sendSubscribe`-streaming follow-up.
- **OAuth / DID identity flows.** A2A's auth is layered; v0.1 ships
  unauthenticated for local-dev.
- **Bi-directional streaming SSE.** `tasks/sendSubscribe` falls back
  to a single frame today (lex-lang#487 upstream).
