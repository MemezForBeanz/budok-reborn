#!/usr/bin/env python3
"""Minimal, dependency-free MCP client for the budok mod (Streamable HTTP, JSON responses).

Use it to script the game from outside (series, benchmarks, CI smoke tests) or as a starting point for
your own automation. Any MCP client works the same way; this one only needs the standard library.

    python budok_connector.py --token TOKEN status
    python budok_connector.py --token TOKEN characters
    python budok_connector.py --token TOKEN tool simulate '{"action": "Grab"}'
    python budok_connector.py --token TOKEN series --p1 Ninja --p2 Cowboy --games 3 --controllers ai ai

The token is shown in the in-game budok panel (F8). BUDOK_URL / BUDOK_TOKEN environment variables work too.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from typing import Any

PROTOCOL_VERSION = "2025-06-18"
DEFAULT_URL = "http://127.0.0.1:8765/mcp"


class McpError(RuntimeError):
    """A JSON-RPC error or a tool result flagged isError."""


class BudokClient:
    def __init__(self, url: str = DEFAULT_URL, token: str = "", timeout: float = 70.0) -> None:
        self.url = url
        self.token = token
        self.timeout = timeout
        self.session_id: str | None = None
        self._next_id = 1

    # --- transport ---

    def _post(self, message: dict[str, Any]) -> tuple[dict[str, Any] | None, dict[str, str]]:
        headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        if self.session_id:
            headers["Mcp-Session-Id"] = self.session_id
            headers["MCP-Protocol-Version"] = PROTOCOL_VERSION
        request = urllib.request.Request(self.url, data=json.dumps(message).encode(), headers=headers, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                body = response.read().decode()
                return (json.loads(body) if body else None), dict(response.headers)
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")
            raise McpError(f"HTTP {error.code}: {detail}") from None

    def request(self, method: str, params: dict[str, Any] | None = None) -> Any:
        message = {"jsonrpc": "2.0", "id": self._next_id, "method": method, "params": params or {}}
        self._next_id += 1
        reply, _headers = self._post(message)
        if reply is None:
            raise McpError(f"empty reply to {method}")
        if "error" in reply:
            raise McpError(f"{method}: {reply['error'].get('message')}")
        return reply["result"]

    def notify(self, method: str, params: dict[str, Any] | None = None) -> None:
        self._post({"jsonrpc": "2.0", "method": method, "params": params or {}})

    # --- MCP ---

    def initialize(self) -> dict[str, Any]:
        message = {
            "jsonrpc": "2.0",
            "id": self._next_id,
            "method": "initialize",
            "params": {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "budok-connector", "version": "1.0"},
            },
        }
        self._next_id += 1
        reply, headers = self._post(message)
        if reply is None or "error" in reply:
            raise McpError(f"initialize failed: {reply}")
        self.session_id = headers.get("Mcp-Session-Id") or headers.get("mcp-session-id")
        self.notify("notifications/initialized")
        return reply["result"]

    def list_tools(self) -> list[dict[str, Any]]:
        return self.request("tools/list")["tools"]

    def call(self, name: str, arguments: dict[str, Any] | None = None) -> dict[str, Any]:
        result = self.request("tools/call", {"name": name, "arguments": arguments or {}})
        payload = result.get("structuredContent")
        if payload is None:
            text = "".join(block.get("text", "") for block in result.get("content", []) if block.get("type") == "text")
            payload = json.loads(text) if text else {}
        if result.get("isError"):
            raise McpError(f"{name}: {payload.get('error') or payload}")
        return payload

    def close(self) -> None:
        if not self.session_id:
            return
        headers = {"Mcp-Session-Id": self.session_id}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        try:
            urllib.request.urlopen(urllib.request.Request(self.url, headers=headers, method="DELETE"), timeout=5)
        except (urllib.error.URLError, OSError):
            pass
        self.session_id = None

    def __enter__(self) -> BudokClient:  # noqa: PYI034
        self.initialize()
        return self

    def __exit__(self, *_exc: object) -> None:
        self.close()

    # --- helpers ---

    def wait_for_match_end(self, poll_s: float = 2.0, timeout_s: float = 3600.0) -> dict[str, Any]:
        """Poll get_status until the running match reports a result."""
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            match = self.call("get_status")["match"]
            if match.get("last_result") and not match.get("in_match") and not match.get("starting"):
                return match["last_result"]
            time.sleep(poll_s)
        raise McpError("match did not finish in time")


def run_series(client: BudokClient, p1: str, p2: str, games: int, controllers: list[str], starting_hp: int | None) -> dict[str, int]:
    """Play a series between two non-human controllers (ai = in-game API-key model)."""
    if "mcp" in controllers:
        raise SystemExit("series only drives ai/human controllers; write your own loop to play mcp slots")
    wins = {"p1": 0, "p2": 0, "draw": 0}
    for game in range(1, games + 1):
        args: dict[str, Any] = {"p1": p1, "p2": p2, "controllers": {"p1": controllers[0], "p2": controllers[1]}, "claim": "none"}
        if starting_hp:
            args["starting_hp"] = starting_hp
        client.call("start_match", args)
        result = client.wait_for_match_end()
        wins[result["winner"]] += 1
        print(f"game {game}: winner {result['winner']} hp {result['hp']}", flush=True)
        time.sleep(3)
    return wins


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", default=os.environ.get("BUDOK_URL", DEFAULT_URL))
    parser.add_argument("--token", default=os.environ.get("BUDOK_TOKEN", ""))
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status")
    sub.add_parser("characters")
    sub.add_parser("tools")
    tool = sub.add_parser("tool", help="call any tool with JSON arguments")
    tool.add_argument("name")
    tool.add_argument("arguments", nargs="?", default="{}")
    series = sub.add_parser("series", help="play several matches and report the score")
    series.add_argument("--p1", required=True)
    series.add_argument("--p2", required=True)
    series.add_argument("--games", type=int, default=3)
    series.add_argument("--controllers", nargs=2, default=["ai", "ai"], metavar=("P1", "P2"))
    series.add_argument("--starting-hp", type=int)
    args = parser.parse_args(argv)

    try:
        with BudokClient(args.url, args.token) as client:
            if args.command == "status":
                output: Any = client.call("get_status")
            elif args.command == "characters":
                output = client.call("list_characters")["characters"]
            elif args.command == "tools":
                output = [f"{t['name']}: {t.get('description', '')}" for t in client.list_tools()]
            elif args.command == "tool":
                output = client.call(args.name, json.loads(args.arguments))
            else:
                output = run_series(client, args.p1, args.p2, args.games, args.controllers, args.starting_hp)
    except (McpError, urllib.error.URLError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(json.dumps(output, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
