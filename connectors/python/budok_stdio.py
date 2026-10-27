#!/usr/bin/env python3
"""stdio <-> HTTP bridge for MCP clients that only launch local commands (Claude Desktop, ...).

Standard library only, no Node.js needed. Configure your client to run:

    python3 /path/to/budok_stdio.py --token YOUR_TOKEN

Behaviour on top of plain forwarding:
- If the game restarts (new server, old session gone), the bridge re-initializes and retries,
  so the chat client does not need restarting.
- If the game is not running, requests get a clear error and the bridge keeps running. The tool
  list from the last successful connection is cached, so tools still show up and start working
  as soon as the game is up.
Logs go to stderr (shown in the client's MCP log); stdout carries only JSON-RPC.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

DEFAULT_URL = "http://127.0.0.1:8765/mcp"
CACHE = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "budok" / "tools.json"
HTTP_TIMEOUT = 120
NOT_RUNNING = -32000


class TokenRejected(ConnectionError):
    """The server answered 401: wrong or regenerated token."""


TOKEN_HELP = "the budok token was rejected; copy it again from Mod List -> budok -> Connect and update your client config"


def log(message: str) -> None:
    print(f"[budok-stdio] {message}", file=sys.stderr, flush=True)


class Bridge:
    def __init__(self, url: str, token: str) -> None:
        self.url = url
        self.token = token
        self.session: str | None = None
        self.init_params: dict[str, Any] | None = None
        self.write_lock = threading.Lock()
        self.session_lock = threading.Lock()

    # --- output ---

    def send(self, message: Any) -> None:
        with self.write_lock:
            sys.stdout.write(json.dumps(message) + "\n")
            sys.stdout.flush()

    # --- HTTP ---

    def post(self, message: Any) -> tuple[int, Any, str | None]:
        headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        if self.session:
            headers["Mcp-Session-Id"] = self.session
        request = urllib.request.Request(self.url, data=json.dumps(message).encode(), headers=headers, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response:
                body = response.read().decode()
                session = response.headers.get("Mcp-Session-Id")
                return response.status, (json.loads(body) if body else None), session
        except urllib.error.HTTPError as error:
            body = error.read().decode(errors="replace")
            try:
                return error.code, json.loads(body), None
            except ValueError:
                return error.code, {"error": body}, None

    def initialize_upstream(self) -> Any:
        """(Re)creates the server session using the client's original initialize params."""
        status, reply, session = self.post({"jsonrpc": "2.0", "id": "bridge-init", "method": "initialize",
                                            "params": self.init_params or {}})
        if status == 401:
            raise TokenRejected(TOKEN_HELP)
        if status != 200 or not isinstance(reply, dict) or "result" not in reply:
            raise ConnectionError(f"initialize failed (HTTP {status}): {reply}")
        self.session = session
        self.post({"jsonrpc": "2.0", "method": "notifications/initialized"})
        log(f"connected to {self.url}")
        return reply["result"]

    # --- handling ---

    def handle(self, message: dict[str, Any]) -> None:
        method = message.get("method")
        has_id = "id" in message
        try:
            if method == "initialize":
                self.init_params = message.get("params", {})
                with self.session_lock:
                    self.session = None
                    try:
                        result = self.initialize_upstream()
                    except TokenRejected:
                        log(TOKEN_HELP)
                        result = self.offline_initialize("token rejected")
                    except (urllib.error.URLError, ConnectionError, OSError) as error:
                        log(f"game not reachable yet ({error}); answering initialize locally")
                        result = self.offline_initialize()
                self.send({"jsonrpc": "2.0", "id": message["id"], "result": result})
                return
            if method == "notifications/initialized":
                return
            reply = self.forward(message)
            if method == "tools/list" and isinstance(reply, dict) and "result" in reply:
                self.cache_tools(reply["result"])
            if has_id and reply is not None:
                self.send(reply)
        except TokenRejected:
            log(TOKEN_HELP)
            if has_id:
                self.send({"jsonrpc": "2.0", "id": message["id"], "error": {"code": NOT_RUNNING, "message": TOKEN_HELP}})
        except (urllib.error.URLError, ConnectionError, OSError) as error:
            if not has_id:
                return
            if method == "tools/list" and CACHE.is_file():
                self.send({"jsonrpc": "2.0", "id": message["id"], "result": json.loads(CACHE.read_text())})
                return
            self.send({"jsonrpc": "2.0", "id": message["id"], "error": {
                "code": NOT_RUNNING,
                "message": f"budok is not reachable at {self.url}: start YOMI Hustle with the budok mod ({error})"}})

    def forward(self, message: dict[str, Any]) -> Any:
        with self.session_lock:
            if self.session is None and self.init_params is not None:
                self.initialize_upstream()
        status, reply, _ = self.post(message)
        if status == 404 and self.init_params is not None:
            # Game restarted: the old session is gone. Reconnect once and retry.
            log("session expired (game restarted?), reconnecting")
            with self.session_lock:
                self.initialize_upstream()
            status, reply, _ = self.post(message)
        if status == 202:
            return None
        if status == 401:
            raise TokenRejected(TOKEN_HELP)
        return reply

    def offline_initialize(self, reason: str = "game not running") -> dict[str, Any]:
        requested = (self.init_params or {}).get("protocolVersion", "2025-06-18")
        hint = TOKEN_HELP if reason == "token rejected" else (
            "The YOMI Hustle game is not running yet. Start it with the budok mod; tools work as soon as it is up.")
        return {
            "protocolVersion": requested,
            "capabilities": {"tools": {"listChanged": False}, "resources": {}, "prompts": {}},
            "serverInfo": {"name": "budok", "title": f"budok - YOMI Hustle ({reason})", "version": "bridge"},
            "instructions": hint,
        }

    @staticmethod
    def cache_tools(result: Any) -> None:
        try:
            CACHE.parent.mkdir(parents=True, exist_ok=True)
            CACHE.write_text(json.dumps(result))
        except OSError:
            pass

    def run(self) -> None:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                message = json.loads(line)
            except ValueError:
                log(f"ignoring non-JSON input: {line[:80]}")
                continue
            for item in message if isinstance(message, list) else [message]:
                if not isinstance(item, dict):
                    continue
                if item.get("method") == "initialize":
                    # Finish the handshake before anything that depends on the session.
                    self.handle(item)
                else:
                    # Threads keep long polls (wait_for_turn) from blocking other requests.
                    threading.Thread(target=self.handle, args=(item,), daemon=True).start()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", default=os.environ.get("BUDOK_URL", DEFAULT_URL))
    parser.add_argument("--token", default=os.environ.get("BUDOK_TOKEN", ""))
    args = parser.parse_args()
    url = args.url
    token = args.token
    if "?token=" in url and not token:
        url, token = url.split("?token=", 1)
    Bridge(url, token).run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
