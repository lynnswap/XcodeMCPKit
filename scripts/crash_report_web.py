"""Loopback UI for saving crash reports with the shared collector."""

from copy import deepcopy
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import threading
from urllib.parse import quote, unquote, urlsplit


class ReportBusy(RuntimeError):
    pass


class ReportController:
    def __init__(self, bundle_id, platform, mcp_url, output_root, generator=None, work_lock=None,
                 time_period="last24Hours"):
        self.bundle_id = bundle_id
        self.platform = platform
        self.mcp_url = mcp_url
        self.output_root = Path(output_root).expanduser().resolve()
        self.time_period = time_period
        self.generator = generator
        self.work_lock = work_lock or threading.Lock()
        self._lock = threading.RLock()
        self._cancel = threading.Event()
        self._worker = None
        self._published = {}
        self._state = self._initial_state()

    def _initial_state(self):
        return {"status": "idle", "running": False, "bundleId": self.bundle_id,
                "platform": self.platform, "startedAt": None, "finishedAt": None,
                "timePeriod": self.time_period, "outputRoot": str(self.output_root),
                "progress": {}, "result": None, "files": {}, "lastError": None}

    def status(self):
        with self._lock:
            return deepcopy(self._state)

    def start(self, time_period=None, output_root=None):
        with self._lock:
            if self._state["running"]:
                raise ReportBusy("レポートを作成中です。完了するか、停止してから再実行してください。")
            time_period = time_period if time_period is not None else self._state["timePeriod"]
            if time_period not in ("last24Hours", "last14Days", "last365Days"):
                raise ValueError("取得期間を選択してください。")
            output_root = output_root if output_root is not None else self._state["outputRoot"]
            if not isinstance(output_root, (str, Path)) or not str(output_root).strip():
                raise ValueError("保存先フォルダを指定してください。")
            output_root = Path(output_root).expanduser().resolve()
            if not self.work_lock.acquire(blocking=False):
                raise ReportBusy("別の取得処理が実行中です。その処理を停止してからレポートを作成してください。")
            self._cancel = threading.Event()
            self._state = {**self._initial_state(), "status": "running", "running": True,
                           "startedAt": self._now(), "timePeriod": time_period, "outputRoot": str(output_root)}
            self._worker = threading.Thread(target=self._run, args=(time_period, output_root),
                                            name="CrashReport", daemon=True)
            try:
                self._worker.start()
            except Exception:
                self._state["running"] = False
                self.work_lock.release()
                raise
            return self.status()

    def cancel(self):
        with self._lock:
            if self._state["running"]:
                self._cancel.set()
                self._state["status"] = "cancelling"
            return self.status()

    def _progress(self, value):
        with self._lock:
            self._state["progress"].update(deepcopy(value))

    def _run(self, time_period, output_root):
        try:
            generator = self.generator
            if generator is None:
                from crash_report import generate_report
                generator = generate_report
            result = generator(bundle_id=self.bundle_id, platform=self.platform, mcp_url=self.mcp_url,
                               output_root=output_root, time_period=time_period,
                               progress=self._progress, cancel_event=self._cancel)
            files = self._publish(result, output_root)
            with self._lock:
                self._state.update(status=result["status"], result=deepcopy(result), files=files)
        except Exception as error:
            with self._lock:
                self._state.update(status="failed", lastError=str(error) or type(error).__name__)
        finally:
            with self._lock:
                self._state.update(running=False, finishedAt=self._now())
                self.work_lock.release()

    def _publish(self, result, output_root):
        path_value = result.get("reportPath")
        directory_value = result.get("outputDirectory")
        if not path_value and not directory_value:
            return {}
        report = Path(path_value).resolve() if path_value else None
        directory = Path(directory_value).resolve() if directory_value else report.parent
        relative = directory.relative_to(output_root)
        if len(relative.parts) != 2 or (report is not None and report.parent != directory):
            raise ValueError("The report output must be a run directory inside the configured output root")
        run = relative.as_posix()
        with self._lock:
            self._published[run] = directory
        files = {name: "/reports/" + quote(run, safe="/") + "/" + name
                 for name in ("report.md", "report.json") if (directory / name).is_file()}
        return files

    def output_file(self, run, name):
        with self._lock:
            directory = self._published.get(run)
        if directory is None:
            return None
        path = (directory / name).resolve()
        if path.is_relative_to(directory) and path.is_file():
            return path
        return None

    def close(self):
        self.cancel()
        if self._worker:
            self._worker.join()

    @staticmethod
    def _now():
        return datetime.now(timezone.utc).isoformat()


def _send(handler, value, status=200, content_type="application/json; charset=utf-8"):
    data = value if isinstance(value, bytes) else json.dumps(value, ensure_ascii=False, allow_nan=False).encode()
    handler.send_response(status)
    handler.send_header("Content-Type", content_type)
    handler.send_header("Content-Length", str(len(data)))
    handler.send_header("Cache-Control", "no-store")
    handler.send_header("X-Content-Type-Options", "nosniff")
    handler.end_headers()
    handler.wfile.write(data)


def _same_origin(handler):
    port = handler.server.server_address[1]
    hosts = (f"127.0.0.1:{port}", f"localhost:{port}")
    return (handler.headers.get("Host") in hosts and handler.headers.get("Origin") in
            (None, *("http://" + host for host in hosts)))


def route_report_request(handler, controller, method, path):
    path = urlsplit(path).path
    if path != "/crash-report" and not path.startswith(("/api/crash-report/", "/reports/")):
        return False
    if not _same_origin(handler):
        _send(handler, {"error": "同じローカル画面からアクセスしてください。"}, 403)
        return True
    if method == "GET" and path == "/crash-report":
        _send(handler, Path(__file__).with_name("crash_report_ui.html").read_bytes(),
              content_type="text/html; charset=utf-8")
    elif method == "GET" and path == "/api/crash-report/status":
        _send(handler, controller.status())
    elif method == "GET" and path.startswith("/reports/"):
        parts = unquote(path[len("/reports/"):]).split("/")
        file = None
        if len(parts) >= 3 and all(part not in ("", ".", "..") for part in parts):
            file = controller.output_file("/".join(parts[:2]), "/".join(parts[2:]))
        if file is None:
            _send(handler, {"error": "レポートのファイルが見つかりません。"}, 404)
        else:
            content_type = "application/json; charset=utf-8" if file.suffix == ".json" else "text/plain; charset=utf-8"
            _send(handler, file.read_bytes(), content_type=content_type)
    elif method == "POST" and path in ("/api/crash-report/start", "/api/crash-report/cancel"):
        if handler.headers.get("Content-Type", "").split(";")[0].strip() != "application/json":
            _send(handler, {"error": "application/json で送信してください。"}, 415)
            return True
        try:
            length = int(handler.headers.get("Content-Length", "0"))
            if length < 0:
                raise ValueError("Invalid Content-Length")
            body = handler.rfile.read(length)
            parameters = json.loads(body) if body else {}
            if not isinstance(parameters, dict):
                raise ValueError("Expected a JSON object")
        except (ValueError, UnicodeError):
            _send(handler, {"error": "リクエスト JSON を解釈できません。"}, 400)
            return True
        try:
            _send(handler, controller.start(time_period=parameters.get("timePeriod"),
                                           output_root=parameters.get("outputRoot"))
                  if path.endswith("/start") else controller.cancel(),
                  202 if path.endswith("/start") else 200)
        except ReportBusy as error:
            _send(handler, {"error": str(error), **controller.status()}, 409)
        except ValueError as error:
            _send(handler, {"error": str(error)}, 400)
    else:
        _send(handler, {"error": "対応する操作がありません。"}, 404)
    return True


def serve_reports(bundle_id, platform, mcp_url, output_root, port, time_period="last24Hours"):
    controller = ReportController(bundle_id, platform, mcp_url, output_root, time_period=time_period)

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            path = "/crash-report" if urlsplit(self.path).path == "/" else self.path
            if not route_report_request(self, controller, "GET", path):
                _send(self, {"error": "見つかりません。"}, 404)

        def do_POST(self):
            if not route_report_request(self, controller, "POST", self.path):
                _send(self, {"error": "見つかりません。"}, 404)

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"Crash reports: http://127.0.0.1:{server.server_address[1]}/crash-report", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        controller.close()
        server.server_close()
