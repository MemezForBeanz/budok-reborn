"""The Python connector against a stub that behaves like the in-game MCP server."""

from __future__ import annotations

import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, ClassVar

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "connectors" / "python"))
from budok_connector import BudokClient, McpError

TOKEN = "secret-token"


class StubHandler(BaseHTTPRequestHandler):
    sessions: ClassVar[set[str]] = set()
    calls: ClassVar[list[dict[str, Any]]] = []

    def log_message(self, *_args: object) -> None:
        pass

    def _send(self, status: int, body: Any = None, headers: dict[str, str] | None = None) -> None:
        data = b"" if body is None else json.dumps(body).encode()
        self.send_response(status)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_DELETE(self) -> None:
        self.sessions.discard(self.headers.get("Mcp-Session-Id", ""))
        self._send(200)

    def do_POST(self) -> None:
        if self.headers.get("Authorization") != f"Bearer {TOKEN}":
            self._send(401, {"error": "missing or wrong token"})
            return
        message = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if "id" not in message:
            self._send(202)
            return
        if message["method"] == "initialize":
            self.sessions.add("s1")
            result = {"protocolVersion": message["params"]["protocolVersion"], "capabilities": {"tools": {}},
                      "serverInfo": {"name": "budok", "version": "test"}}
            self._send(200, {"jsonrpc": "2.0", "id": message["id"], "result": result}, {"Mcp-Session-Id": "s1"})
            return
        if self.headers.get("Mcp-Session-Id") not in self.sessions:
            self._send(404, {"jsonrpc": "2.0", "id": None, "error": {"code": -32001, "message": "session not found"}})
            return
        self.calls.append(message)
        if message["method"] == "tools/list":
            result: Any = {"tools": [{"name": "get_status", "description": "Status", "inputSchema": {"type": "object"}}]}
        elif message["params"]["name"] == "get_status":
            payload = {"ok": True, "match": {"in_match": False, "starting": False, "last_result": {"winner": "p2", "hp": {}}}}
            result = {"content": [{"type": "text", "text": json.dumps(payload)}], "isError": False, "structuredContent": payload}
        elif message["params"]["name"] == "legacy_text_only":
            result = {"content": [{"type": "text", "text": json.dumps({"ok": True, "n": 3})}], "isError": False}
        elif message["params"]["name"] == "fails":
            result = {"content": [{"type": "text", "text": json.dumps({"ok": False, "error": "nope"})}], "isError": True}
        else:
            self._send(200, {"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32602, "message": "unknown tool"}})
            return
        self._send(200, {"jsonrpc": "2.0", "id": message["id"], "result": result})


@pytest.fixture()
def server_url():
    server = ThreadingHTTPServer(("127.0.0.1", 0), StubHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{server.server_address[1]}/mcp"
    server.shutdown()


def test_session_and_structured_results(server_url: str) -> None:
    with BudokClient(server_url, TOKEN) as client:
        assert client.session_id == "s1"
        assert client.list_tools()[0]["name"] == "get_status"
        assert client.call("get_status")["match"]["last_result"]["winner"] == "p2"
        assert client.wait_for_match_end(poll_s=0)["winner"] == "p2"
    assert client.session_id is None


def test_text_only_results_are_parsed(server_url: str) -> None:
    with BudokClient(server_url, TOKEN) as client:
        assert client.call("legacy_text_only") == {"ok": True, "n": 3}


def test_errors_raise(server_url: str) -> None:
    with BudokClient(server_url, TOKEN) as client:
        with pytest.raises(McpError, match="nope"):
            client.call("fails")
        with pytest.raises(McpError, match="unknown tool"):
            client.call("does_not_exist")


def test_bad_token_rejected(server_url: str) -> None:
    with pytest.raises(McpError, match="401"):
        BudokClient(server_url, "wrong").initialize()
