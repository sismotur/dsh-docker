#!/usr/bin/env python3
"""Regression test: AnthropicBlockStopSanitizer fixes dsh MALFORMED_RESPONSE.

Replays the live-captured LiteLLM sequence where content_block_stop for tool
index 0 arrived before a late input_json_delta on the same index.
"""

from __future__ import annotations

import json
import sys
from typing import Any


class AnthropicBlockStopSanitizer:
    """Mirror of litellm_hooks.AnthropicBlockStopSanitizer for offline tests."""

    def __init__(self) -> None:
        self._deferred_stops: dict[int, dict[str, Any]] = {}

    def feed(self, chunk: Any) -> list[Any]:
        if not isinstance(chunk, dict):
            return [chunk]
        t = chunk.get("type")
        if t == "content_block_stop":
            idx = chunk.get("index")
            if isinstance(idx, int):
                self._deferred_stops[idx] = chunk
                return []
            return [chunk]
        if t in ("message_delta", "message_stop"):
            out = self.flush_stops()
            out.append(chunk)
            return out
        return [chunk]

    def flush_stops(self) -> list[dict[str, Any]]:
        if not self._deferred_stops:
            return []
        out = [self._deferred_stops[i] for i in sorted(self._deferred_stops)]
        self._deferred_stops.clear()
        return out

    def flush_all(self) -> list[Any]:
        return self.flush_stops()


def dsh_parse(events: list[dict]) -> None:
    """Subset of dsh-llm-deepseek translate() open-block rules."""
    blocks: dict[int, dict] = {}
    started = False
    reason = None
    for event in events:
        t = event["type"]
        if t == "message_start":
            if started:
                raise AssertionError("duplicate message_start")
            started = True
            continue
        if t not in (
            "content_block_start",
            "content_block_delta",
            "content_block_stop",
            "message_delta",
            "message_stop",
        ):
            continue
        if not started:
            raise AssertionError("event precedes message_start")
        if t == "content_block_start":
            idx = event["index"]
            if idx in blocks or reason is not None:
                raise AssertionError("block starts after settlement or repeats an index")
            blocks[idx] = {"closed": False, "type": event["content_block"]["type"], "json": ""}
        elif t in ("content_block_delta", "content_block_stop"):
            block = blocks.get(event["index"])
            if block is None or block["closed"]:
                raise AssertionError("delta/stop without an open block")
            if t == "content_block_delta":
                d = event["delta"]
                if d.get("type") == "input_json_delta":
                    block["json"] += d.get("partial_json") or ""
            else:
                block["closed"] = True
        elif t == "message_delta":
            if event.get("delta", {}).get("stop_reason") is not None:
                reason = event["delta"]["stop_reason"]
        elif t == "message_stop":
            if reason is None or any(not b["closed"] for b in blocks.values()):
                raise AssertionError("message_stop without settled blocks and stop reason")
            return
    raise AssertionError("stream ended before message_stop")


# Exact event order from a live multi-tool TF/LiteLLM stream (malformed without sanitizer)
RAW = [
    {"type": "message_start", "message": {"id": "m", "role": "assistant", "content": [], "model": "x"}},
    {
        "type": "content_block_start",
        "index": 0,
        "content_block": {"type": "tool_use", "id": "c1", "name": "Bash", "input": {}},
    },
    {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": '{"command":"'}},
    {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": "pwd"}},
    {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": '"'}},
    {"type": "content_block_stop", "index": 0},
    {"type": "content_block_start", "index": 1, "content_block": {"type": "text", "text": ""}},
    {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "\n"}},
    # late tool delta on already-stopped index 0 — dsh MALFORMED without sanitizer
    {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": "}"}},
    {"type": "content_block_stop", "index": 1},
    {
        "type": "content_block_start",
        "index": 2,
        "content_block": {"type": "tool_use", "id": "c2", "name": "Read", "input": {}},
    },
    {
        "type": "content_block_delta",
        "index": 2,
        "delta": {"type": "input_json_delta", "partial_json": '{"path":"package.json"}'},
    },
    {"type": "content_block_stop", "index": 2},
    {"type": "message_delta", "delta": {"stop_reason": "tool_use", "stop_sequence": None}, "usage": {}},
    {"type": "message_stop"},
]


def main() -> int:
    try:
        dsh_parse(RAW)
    except AssertionError as e:
        assert "delta/stop without an open block" in str(e), e
    else:
        print("FAIL: raw stream unexpectedly passed")
        return 1

    san = AnthropicBlockStopSanitizer()
    fixed: list = []
    for ev in RAW:
        fixed.extend(san.feed(ev))
    fixed.extend(san.flush_all())

    dsh_parse(fixed)

    json0 = ""
    for ev in fixed:
        if ev.get("type") == "content_block_delta" and ev.get("index") == 0:
            json0 += ev["delta"].get("partial_json") or ""
    parsed = json.loads(json0)
    assert parsed == {"command": "pwd"}, parsed

    types = [e["type"] for e in fixed]
    assert types.count("content_block_stop") == 3
    msg_delta_at = types.index("message_delta")
    assert all(i < msg_delta_at for i, t in enumerate(types) if t == "content_block_stop")

    print("OK stream sanitizer regression")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
