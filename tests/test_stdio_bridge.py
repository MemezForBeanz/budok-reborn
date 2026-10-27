"""The stdio bridge Claude Desktop runs: token discovery, token rotation, game restarts, offline start."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, ClassVar

import pytest

BRIDGE = Path(__file__).resolve().parent.parent / "connectors" / "python" / "budok_stdio.py"
INIT = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}}}


class FakeGame(BaseHTTPRequestHandler):
    token: ClassVar[str] = "first"
    sessions: ClassVar[set[str]] = set()
    counter: ClassVar[int] = 0
    invalid_json: ClassVar[bool] = False

    def log_message(self, *_args: object) -> None:
        pass

    def _send(self, status: int, body: Any = None, headers: dict[str, str] | None = None) -> None:
        data = b"" if body is None else json.dumps(body).encode()
        self.send_response(status)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self) -> None:
        message = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.headers.get("Authorization") != f"Bearer {FakeGame.token}":
            self._send(401, {"error": "bad token"})
            return
        if "id" not in message:
            self._send(202)
            return
        if message["method"] == "initialize":
            FakeGame.counter += 1
            sid = f"s{FakeGame.counter}"
            FakeGame.sessions.add(sid)
            self._send(200, {"jsonrpc": "2.0", "id": message["id"], "result": {"protocolVersion": "2025-06-18",
                       "capabilities": {"tools": {}}, "serverInfo": {"name": "budok", "version": "t"}}}, {"Mcp-Session-Id": sid})
            return
        if self.headers.get("Mcp-Session-Id") not in FakeGame.sessions:
            self._send(404, {"jsonrpc": "2.0", "id": None, "error": {"code": -32001, "message": "session not found"}})
            return
        if FakeGame.invalid_json:
            # What Godot's JSON.print makes of a NaN.
            body = ('{"jsonrpc": "2.0", "id": ' + json.dumps(message["id"]) + ', "result": {"x": nan}}').encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        result = {"tools": [{"name": "get_status"}]} if message["method"] == "tools/list" else {
            "content": [{"type": "text", "text": "{\"ok\": true}"}], "isError": False}
        self._send(200, {"jsonrpc": "2.0", "id": message["id"], "result": result})


@pytest.fixture()
def env(tmp_path: Path):
    server = ThreadingHTTPServer(("127.0.0.1", 0), FakeGame)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    settings = tmp_path / "data" / "YourOnlyMoveIsHUSTLE" / "budok" / "config.json"
    settings.parent.mkdir(parents=True)

    def write_settings(token: str) -> None:
        settings.write_text(json.dumps({"mcp": {"auth_token": token, "port": server.server_address[1]}}))

    FakeGame.token = "first"
    FakeGame.sessions = set()
    FakeGame.invalid_json = False
    write_settings("first")
    bridge_env = {**os.environ, "XDG_DATA_HOME": str(tmp_path / "data"), "XDG_CACHE_HOME": str(tmp_path / "cache"), "HOME": str(tmp_path)}
    yield write_settings, bridge_env
    server.shutdown()


class BridgeProcess:
    def __init__(self, env: dict[str, str], *args: str) -> None:
        self.proc = subprocess.Popen([sys.executable, "-I", str(BRIDGE), *args], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True, env=env)

    def request(self, message: dict[str, Any]) -> dict[str, Any]:
        assert self.proc.stdin and self.proc.stdout
        self.proc.stdin.write(json.dumps(message) + "\n")
        self.proc.stdin.flush()
        return json.loads(self.proc.stdout.readline())

    def call(self, request_id: int) -> dict[str, Any]:
        return self.request({"jsonrpc": "2.0", "id": request_id, "method": "tools/call", "params": {"name": "get_status", "arguments": {}}})

    def close(self) -> None:
        self.proc.kill()
        self.proc.wait(timeout=5)


def test_token_is_read_from_the_game_and_rotation_is_picked_up(env) -> None:
    write_settings, bridge_env = env
    bridge = BridgeProcess(bridge_env)
    try:
        assert bridge.request(INIT)["result"]["serverInfo"]["name"] == "budok"
        assert "result" in bridge.call(2)
        # The player clicks "New token" in game: server and settings file change together.
        FakeGame.token = "second"
        write_settings("second")
        assert "result" in bridge.call(3), "bridge should re-read the token and reconnect"
    finally:
        bridge.close()


def test_game_restart_drops_session_and_bridge_reconnects(env) -> None:
    _write_settings, bridge_env = env
    bridge = BridgeProcess(bridge_env)
    try:
        bridge.request(INIT)
        FakeGame.sessions.clear()  # what a game restart looks like to the bridge
        assert "result" in bridge.call(2)
    finally:
        bridge.close()


def test_explicit_wrong_token_gives_a_clear_error(env) -> None:
    _write_settings, bridge_env = env
    bridge = BridgeProcess(bridge_env, "--token", "nope")
    try:
        init = bridge.request(INIT)
        assert "token rejected" in init["result"]["serverInfo"]["title"]
        assert "token was rejected" in bridge.call(2)["error"]["message"]
    finally:
        bridge.close()


def test_invalid_json_from_the_game_still_gets_an_answer(env) -> None:
    _write_settings, bridge_env = env
    bridge = BridgeProcess(bridge_env)
    try:
        bridge.request(INIT)
        FakeGame.invalid_json = True
        reply = bridge.call(2)
        assert reply["id"] == 2 and "not valid JSON" in reply["error"]["message"]
    finally:
        bridge.close()


def test_offline_start_answers_initialize_and_explains(tmp_path: Path) -> None:
    bridge_env = {**os.environ, "XDG_DATA_HOME": str(tmp_path), "XDG_CACHE_HOME": str(tmp_path), "HOME": str(tmp_path)}
    bridge = BridgeProcess(bridge_env, "--url", "http://127.0.0.1:9/mcp", "--token", "x")
    try:
        init = bridge.request(INIT)
        assert "game not running" in init["result"]["serverInfo"]["title"]
        start = time.monotonic()
        error = bridge.call(2)["error"]["message"]
        assert "start YOMI Hustle" in error and time.monotonic() - start < 10
    finally:
        bridge.close()
