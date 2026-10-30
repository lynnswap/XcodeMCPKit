import io
from http.client import IncompleteRead
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from crash_report_mcp import MCPError, XcodeMCPClient


class Response(io.BytesIO):
    def __init__(self, body, content_type="application/json", status=200):
        super().__init__(body)
        self.headers = {"Content-Type": content_type, "Mcp-Session-Id": "session"}
        self.status = status


class Opener:
    def __init__(self, responses):
        self.responses = iter(responses)
        self.requests = []

    def open(self, request, timeout):
        self.requests.append(request)
        return next(self.responses)


class MCPTransportTests(unittest.TestCase):
    def test_truncated_http_body_becomes_a_transport_error(self):
        class TruncatedResponse(Response):
            def read(self, *args):
                raise IncompleteRead(b'{"id":', 50)
        client = XcodeMCPClient("http://localhost:8765/mcp")
        client.initialized = True
        client.opener = Opener([TruncatedResponse(b"")])
        with self.assertRaisesRegex(MCPError, "IncompleteRead"):
            client.call_tool("WaitForCrashSync", {"job_id": "active"})

    def test_initialization_session_and_sse_response_with_unrelated_notification(self):
        client = XcodeMCPClient("http://localhost:8765/mcp")
        client.opener = Opener([
            Response(json.dumps({"id": 1, "result": {"protocolVersion": "2025-06-18"}}).encode()),
            Response(b"", status=202),
            Response(b'data: {"method":"notifications/progress"}\n\n'
                     b'data: {"id":2,"result":{"structuredContent":{"state":"completed"}}}\n\n', "text/event-stream"),
        ])
        self.assertEqual(client.call_tool("WaitForCrashSync", {"job_id": "abc"}), {"state": "completed"})
        requests = client.opener.requests
        self.assertEqual(json.loads(requests[1].data)["method"], "notifications/initialized")
        self.assertEqual(requests[2].get_header("Mcp-session-id"), "session")
        self.assertEqual(requests[2].get_header("Mcp-protocol-version"), "2025-06-18")

    def test_tool_error_is_not_mistaken_for_successful_structured_data(self):
        client = XcodeMCPClient("http://127.0.0.1:8765/mcp")
        client.initialized = True
        client.opener = Opener([Response(json.dumps({"id": 1, "result": {"isError": True,
            "structuredContent": {"status": "failed"}, "content": [{"type": "text", "text": "cache unavailable"}]}}).encode())])
        with self.assertRaisesRegex(MCPError, "cache unavailable"):
            client.call_tool("ReadCrashChanges", {})

    def test_text_json_fallback_and_incomplete_stream(self):
        client = XcodeMCPClient("http://localhost:8765/mcp")
        client.initialized = True
        client.opener = Opener([
            Response(json.dumps({"id": 1, "result": {"content": [{"type": "text", "text": '{"state":"running"}'}]}}).encode()),
            Response(b'data: {"method":"notifications/progress"}\n\n', "text/event-stream"),
        ])
        self.assertEqual(client.call_tool("StartCrashSync", {}), {"state": "running"})
        with self.assertRaisesRegex(MCPError, "ended"):
            client.call_tool("WaitForCrashSync", {})


if __name__ == "__main__":
    unittest.main()
