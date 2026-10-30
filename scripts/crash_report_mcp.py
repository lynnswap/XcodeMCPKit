"""Streamable HTTP client for a local XcodeMCPKit report run."""

import json
from http.client import HTTPException
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import ProxyHandler, Request, build_opener


class MCPError(RuntimeError):
    pass


class XcodeMCPClient:
    def __init__(self, url, timeout=90):
        endpoint = urlsplit(url)
        if endpoint.scheme not in ("http", "https") or endpoint.hostname not in ("localhost", "127.0.0.1", "::1"):
            raise ValueError("Use a local XcodeMCPKit HTTP endpoint; report artifacts are local files.")
        self.url, self.timeout = url, timeout
        self.headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
        self.opener = build_opener(ProxyHandler({}))
        self.next_id = 0
        self.initialized = False

    def _post(self, body):
        request = Request(self.url, data=json.dumps(body).encode(), headers=self.headers, method="POST")
        try:
            with self.opener.open(request, timeout=self.timeout) as response:
                session = response.headers.get("Mcp-Session-Id")
                if session:
                    self.headers["Mcp-Session-Id"] = session
                if response.status == 202 or "id" not in body:
                    return None
                if "text/event-stream" not in response.headers.get("Content-Type", ""):
                    return json.loads(response.read())
                data = []
                for raw_line in response:
                    line = raw_line.decode("utf-8").rstrip("\r\n")
                    if line.startswith("data:"):
                        data.append(line[5:].lstrip())
                    elif not line and data:
                        event = json.loads("\n".join(data))
                        data = []
                        if event.get("id") == body["id"]:
                            return event
                raise MCPError("The MCP event stream ended before its response.")
        except HTTPError as error:
            raise MCPError(f"Xcode MCP returned HTTP {error.code}.") from error
        except (HTTPException, URLError, OSError, TimeoutError, ValueError, UnicodeError) as error:
            raise MCPError(f"Could not read the local Xcode MCP response: {error}") from error

    def request(self, method, params=None):
        self.next_id += 1
        body = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            body["params"] = params
        response = self._post(body)
        if not isinstance(response, dict) or response.get("id") != self.next_id:
            raise MCPError("The MCP response has no matching request ID.")
        if "error" in response:
            raise MCPError(str(response["error"].get("message", response["error"])))
        return response.get("result")

    def initialize(self):
        if self.initialized:
            return
        result = self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "xcode-crash-report", "version": "1.0"}})
        self.headers["MCP-Protocol-Version"] = result["protocolVersion"]
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized"})
        self.initialized = True

    def call_tool(self, name, arguments):
        self.initialize()
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        if not isinstance(result, dict):
            raise MCPError(f"{name} returned no tool result.")
        if result.get("isError"):
            message = "\n".join(c.get("text", "") for c in result.get("content", []) if c.get("type") == "text")
            raise MCPError(message or f"{name} failed.")
        if isinstance(result.get("structuredContent"), dict):
            return result["structuredContent"]
        for content in result.get("content", []):
            if content.get("type") == "text":
                try:
                    decoded = json.loads(content["text"])
                except (ValueError, KeyError):
                    continue
                if isinstance(decoded, dict):
                    return decoded
        raise MCPError(f"{name} returned no structured JSON object.")
