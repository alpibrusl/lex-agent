"""Validate lex-agent's wire format against the Google A2A Python SDK.

This is the canonical interop test for issue #481's acceptance
criterion "AgentCard emission round-trips with a Python A2A SDK
example". It:

  1. Loads a JSON snapshot produced by lex-agent (the offline
     dispatch example or a curl against `01_ping_pong.lex` in CI).
  2. Parses each snapshot through the Pythonic types in
     `a2a.compat.v0_3` (which mirror the JSON wire format
     lex-agent targets — a2a-sdk 1.0+ also ships protobuf types
     but those use ENUM_NAME wire encoding for states, which is a
     different surface).
  3. Exits non-zero if anything fails to parse, with a structured
     error report so CI logs point at the offending field.

Usage:
  python3 tests/interop/validate_with_a2a_sdk.py \\
      --card    tests/interop/snapshots/agent_card.json \\
      --task    tests/interop/snapshots/task_completed.json \\
      --message tests/interop/snapshots/message_user.json
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def _import_v3():
    """Defer the import so `--help` works without the SDK installed."""
    try:
        from a2a.compat.v0_3 import types as v3  # type: ignore
    except ImportError as e:
        print(
            f"FAIL: cannot import a2a.compat.v0_3.types ({e}). "
            "Install with `pip install -r tests/interop/requirements.txt`.",
            file=sys.stderr,
        )
        sys.exit(2)
    return v3


def _load(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def _check(label: str, doc: dict, parser) -> tuple[bool, str]:
    try:
        obj = parser(doc)
    except Exception as e:  # pydantic ValidationError or other
        return False, f"{label}: {type(e).__name__}: {e}"
    return True, f"{label}: OK ({obj.__class__.__name__})"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--card", help="AgentCard JSON path")
    parser.add_argument("--task", help="Task JSON path")
    parser.add_argument("--message", help="Message JSON path")
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Treat missing snapshot files as errors instead of skipping.",
    )
    args = parser.parse_args(argv)

    v3 = _import_v3()

    targets = [
        ("AgentCard", args.card, v3.AgentCard.model_validate),
        ("Task", args.task, v3.Task.model_validate),
        ("Message", args.message, v3.Message.model_validate),
    ]
    passed = 0
    failed: list[str] = []
    skipped: list[str] = []

    for label, path, parser_fn in targets:
        if not path:
            skipped.append(label)
            continue
        p = Path(path)
        if not p.is_file():
            if args.strict:
                failed.append(f"{label}: snapshot not found at {path}")
            else:
                skipped.append(f"{label} ({path} missing)")
            continue
        doc = _load(str(p))
        ok, msg = _check(label, doc, parser_fn)
        if ok:
            passed += 1
            print(msg)
        else:
            failed.append(msg)

    if skipped:
        print(f"skipped: {', '.join(skipped)}")
    if failed:
        print("\n--- failures ---")
        for f in failed:
            print(f)
        print(f"\n{passed} passed, {len(failed)} failed")
        return 1
    print(f"\n{passed} passed, 0 failed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
