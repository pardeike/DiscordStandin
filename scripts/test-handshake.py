#!/usr/bin/env python3
"""Exercise the real stdio boundary without credentials or Discord requests."""

import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import time
import unittest


EXECUTABLE = str(Path(sys.argv.pop(1)).resolve())


class HandshakeTests(unittest.TestCase):
    def setUp(self):
        self.process = subprocess.Popen(
            [EXECUTABLE, "server"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        self.addCleanup(self.close_server)
        self.pending = b""

    def close_server(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.process.stdin.close()
        self.process.stdout.close()

    def send(self, message):
        self.process.stdin.write(json.dumps(message).encode() + b"\n")
        self.process.stdin.flush()

    def response(self, request_id):
        deadline = time.monotonic() + 5
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            while True:
                while b"\n" in self.pending:
                    line, self.pending = self.pending.split(b"\n", 1)
                    response = json.loads(line)
                    self.assertEqual(response.get("jsonrpc"), "2.0")
                    if response.get("id") == request_id:
                        return response
                remaining = deadline - time.monotonic()
                self.assertGreater(remaining, 0, "MCP response timed out")
                self.assertTrue(selector.select(remaining), "MCP response timed out")
                chunk = os.read(self.process.stdout.fileno(), 65536)
                self.assertTrue(chunk, "Server exited before responding")
                self.pending += chunk

    def initialize(self, capabilities, **overrides):
        params = {
            "protocolVersion": "2025-06-18",
            "clientInfo": {"name": "handshake-regression", "version": "1.0"},
            "capabilities": capabilities,
        }
        params.update(overrides)
        self.send({"jsonrpc": "2.0", "id": "init", "method": "initialize", "params": params})
        return self.response("init")

    def assert_ready(self, capabilities):
        response = self.initialize(capabilities)
        self.assertNotIn("error", response)
        self.assertEqual(response["result"]["serverInfo"]["name"], "DiscordStandin")
        self.assertIn("tools", response["result"]["capabilities"])
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        self.send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        tools = self.response(2)["result"]["tools"]
        names = {tool["name"] for tool in tools}
        self.assertEqual(len(tools), 14)
        self.assertEqual(len(names), 14)
        self.assertIn("discord_get_message", names)
        self.assertIn("discord_delete_messages", names)
        self.send({"jsonrpc": "2.0", "id": 3, "method": "ping"})
        self.assertEqual(self.response(3)["result"], {})
        # The adapter must not swallow ordinary request errors after initialization.
        self.send({"jsonrpc": "2.0", "id": 4, "method": "unknown-method", "params": {}})
        self.assertEqual(self.response(4)["error"]["code"], -32601)

    def test_empty_capabilities(self):
        self.assert_ready({})

    def test_object_experimental_capabilities(self):
        self.assert_ready({"experimental": {"example": {}}})

    def test_nested_experimental_and_standard_capabilities(self):
        self.assert_ready({
            "experimental": {"extension": {"enabled": True, "versions": [1, 2]}},
            "roots": {"listChanged": True},
            "elicitation": {"form": {}, "url": {}},
        })

    def test_legacy_string_experimental_capabilities(self):
        self.assert_ready({"experimental": {"example": "supported"}})

    def test_invalid_standard_capabilities_remain_rejected(self):
        response = self.initialize({"experimental": {"example": {}}, "roots": "invalid"})
        self.assertIn("error", response)

    def test_invalid_client_info_remains_rejected(self):
        response = self.initialize({"experimental": {"example": {}}}, clientInfo={})
        self.assertIn("error", response)

    def test_invalid_experimental_container_remains_rejected(self):
        self.assertIn("error", self.initialize({"experimental": []}))


if __name__ == "__main__":
    unittest.main()
