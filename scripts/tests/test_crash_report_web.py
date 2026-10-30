"""Exercise the report button through the generator and HTTP boundaries."""

from contextlib import contextmanager
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from crash_report_web import ReportBusy, ReportController, route_report_request


def saved_report(root, name="run-one", status="complete"):
    directory = root / "2026-01-01" / name
    directory.mkdir(parents=True)
    (directory / "raw").mkdir()
    (directory / "raw/sample.crash").write_text("saved sample")
    result = {"status": status, "reportPath": str(directory / "report.md"),
              "outputDirectory": str(directory), "summary": {"issueCount": 1, "logCount": 1}, "issues": []}
    (directory / "report.md").write_text("# Last Day\nSaved evidence.\n")
    (directory / "report.json").write_text(json.dumps(result))
    return result


@contextmanager
def report_server(controller):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if not route_report_request(self, controller, "GET", self.path):
                self.send_error(404)

        def do_POST(self):
            if not route_report_request(self, controller, "POST", self.path):
                self.send_error(404)

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        yield server.server_address[1]
    finally:
        server.shutdown()
        server.server_close()
        worker.join()


class CrashReportWebTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def controller(self, generator, work_lock=None):
        controller = ReportController("example.App", "iOS", "http://localhost:8765/mcp", self.root,
                                      generator=generator, work_lock=work_lock)
        self.addCleanup(controller.close)
        return controller

    def finish(self, controller):
        controller._worker.join(timeout=3)
        self.assertFalse(controller._worker.is_alive())
        return controller.status()

    def request(self, port, method, path, parameters=None, **headers):
        connection = HTTPConnection("127.0.0.1", port, timeout=3)
        try:
            connection.request(method, path, body=json.dumps(parameters or {}) if method == "POST" else None,
                               headers={"Content-Type": "application/json", **headers})
            response = connection.getresponse()
            return response.status, response.getheader("Content-Type"), response.read()
        finally:
            connection.close()

    def test_background_execution_preserves_result_progress_and_report_files(self):
        entered, release = threading.Event(), threading.Event()
        calls = []

        def generate(**arguments):
            calls.append(arguments)
            arguments["progress"]({"phase": "logs", "completedIssues": 1, "totalIssues": 2})
            arguments["progress"]({"phase": "importing", "state": "running"})
            entered.set()
            release.wait(timeout=2)
            return saved_report(self.root, status="partial")

        controller = self.controller(generate)
        self.addCleanup(release.set)
        with report_server(controller) as port:
            code, _, body = self.request(port, "POST", "/api/crash-report/start")
            self.assertEqual(code, 202)
            self.assertTrue(json.loads(body)["running"])
            self.assertTrue(entered.wait(timeout=1))
            self.assertEqual(controller.status()["progress"]["completedIssues"], 1)
            code, _, body = self.request(port, "POST", "/api/crash-report/start")
            self.assertEqual(code, 409)
            self.assertIn("作成中", json.loads(body)["error"])
            release.set()
            state = self.finish(controller)
            self.assertEqual(state["status"], "partial")
            self.assertEqual(len(calls), 1)
            self.assertEqual(calls[0]["bundle_id"], "example.App")
            self.assertEqual(calls[0]["platform"], "iOS")
            self.assertEqual(calls[0]["mcp_url"], "http://localhost:8765/mcp")
            self.assertEqual(calls[0]["time_period"], "last24Hours")
            self.assertNotIn("agentPrompt", state)
            code, mime, body = self.request(port, "GET", state["files"]["report.md"])
            self.assertEqual((code, mime, body), (200, "text/plain; charset=utf-8", b"# Last Day\nSaved evidence.\n"))
            code, mime, body = self.request(port, "GET", state["files"]["report.json"])
            self.assertEqual(code, 200)
            self.assertEqual(json.loads(body)["status"], "partial")
            code, _, body = self.request(port, "GET", "/reports/2026-01-01/run-one/raw/sample.crash")
            self.assertEqual((code, body), (200, b"saved sample"))

    def test_selected_period_and_output_folder_are_fixed_per_run_and_old_links_survive(self):
        calls = []
        def generate(**arguments):
            calls.append(arguments)
            return saved_report(arguments["output_root"], name="run-" + str(len(calls)))
        controller = self.controller(generate)
        self.assertEqual(controller.status()["outputRoot"], str(self.root.resolve()))
        with report_server(controller) as port:
            first_root = self.root / "first-output"
            self.assertEqual(self.request(port, "POST", "/api/crash-report/start", parameters={
                "timePeriod": "last14Days", "outputRoot": str(first_root)})[0], 202)
            first = self.finish(controller)
            first_url = first["files"]["report.md"]
            self.assertEqual(calls[0]["time_period"], "last14Days")
            self.assertEqual(calls[0]["output_root"], first_root.resolve())
            self.assertEqual(first["timePeriod"], "last14Days")
            self.assertEqual(self.request(port, "POST", "/api/crash-report/start", parameters={
                "timePeriod": "last365Days", "outputRoot": str(self.root / "second-output")})[0], 202)
            self.finish(controller)
            self.assertEqual(calls[1]["time_period"], "last365Days")
            self.assertEqual(self.request(port, "GET", first_url)[0], 200)
            self.assertEqual(self.request(port, "POST", "/api/crash-report/start", parameters={
                "timePeriod": "invalid"})[0], 400)
            self.assertEqual(len(calls), 2)

    def test_cancellation_waits_for_generator_cleanup_before_releasing_shared_work(self):
        entered, cleanup = threading.Event(), threading.Event()
        lock = threading.Lock()

        def generate(**arguments):
            entered.set()
            arguments["cancel_event"].wait(timeout=2)
            cleanup.wait(timeout=2)
            return saved_report(self.root, status="cancelled")

        controller = self.controller(generate, work_lock=lock)
        self.addCleanup(cleanup.set)
        controller.start()
        self.assertTrue(entered.wait(timeout=1))
        state = controller.cancel()
        self.assertEqual(state["status"], "cancelling")
        self.assertTrue(state["running"])
        self.assertFalse(lock.acquire(blocking=False))
        cleanup.set()
        self.assertEqual(self.finish(controller)["status"], "cancelled")
        self.assertTrue(lock.acquire(blocking=False))
        lock.release()

    def test_existing_collection_excludes_reports_without_starting_or_cancelling_it(self):
        lock = threading.Lock()
        lock.acquire()
        self.addCleanup(lock.release)
        calls = []
        controller = self.controller(lambda **arguments: calls.append(arguments), work_lock=lock)
        with report_server(controller) as port:
            code, _, body = self.request(port, "POST", "/api/crash-report/start")
        self.assertEqual(code, 409)
        self.assertIn("別の取得", json.loads(body)["error"])
        self.assertEqual(calls, [])
        self.assertEqual(controller.status()["status"], "idle")

    def test_generator_exception_remains_visible_and_a_later_run_can_succeed(self):
        calls = []

        def generate(**arguments):
            calls.append(arguments)
            if len(calls) == 1:
                raise OSError("The MCP server could not be reached")
            return saved_report(self.root)

        controller = self.controller(generate)
        controller.start()
        self.assertEqual(self.finish(controller)["lastError"], "The MCP server could not be reached")
        controller.start()
        state = self.finish(controller)
        self.assertEqual(state["status"], "complete")
        self.assertIsNone(state["lastError"])
        self.assertEqual(len(calls), 2)

    def test_output_routes_reject_unpublished_files_traversal_and_outside_symlinks(self):
        secret = self.root / "private.txt"
        secret.write_text("private")
        controller = self.controller(lambda **_: saved_report(self.root))
        controller.start()
        self.finish(controller)
        (self.root / "2026-01-01/run-one/escape.txt").symlink_to(secret)
        with report_server(controller) as port:
            for path in ("/reports/private.txt", "/reports/other/report.md", "/reports/2026-01-01/run-one/escape.txt",
                         "/reports/2026-01-01/run-one/%2e%2e/private.txt", "/reports/2026-01-01/run-one/raw/%2e%2e/%2e%2e/private.txt"):
                with self.subTest(path=path):
                    self.assertEqual(self.request(port, "GET", path)[0], 404)

    def test_cross_origin_start_is_rejected_and_ui_does_not_insert_dynamic_html(self):
        controller = self.controller(lambda **_: saved_report(self.root))
        with report_server(controller) as port:
            code, _, _ = self.request(port, "POST", "/api/crash-report/start", Origin="https://unrelated.example")
            self.assertEqual(code, 403)
            self.assertEqual(controller.status()["status"], "idle")
            code, mime, body = self.request(port, "GET", "/crash-report")
            self.assertEqual(code, 200)
            self.assertEqual(mime, "text/html; charset=utf-8")
            self.assertNotIn(b"innerHTML", body)
            self.assertNotIn(b"clipboard", body)
            self.assertNotIn(b"agentPrompt", body)
            for value in (b"last24Hours", b"last14Days", b"last365Days", b"output-root"):
                self.assertIn(value, body)


if __name__ == "__main__":
    unittest.main()
