#!/usr/bin/env python3
"""Save a dated crash report for a selected period through a local XcodeMCPKit server."""

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import signal
from threading import Event
from uuid import uuid4

from crash_report_logs import in_window, parse_log
from crash_report_mcp import MCPError, XcodeMCPClient


TERMINAL = {"completed", "failed", "cancelled", "interrupted"}
PERIOD_LABELS = {"last24Hours": "Last Day", "last14Days": "2週間", "last365Days": "1年"}
LIMITATIONS = [
    "期間はXcodeの集計指定に従います。各issueのnative期間を保持し、取得日と発生日を区別します。",
    "一覧の終端確認と、Apple側の全発生ログを取得できた保証は別です。個別ログはOrganizerに保存されたサンプルです。",
    "個別ログは指定期間外の発生日時を含みます。日時不明・期間不明はunknownとして残します。",
    "端末数は発生件数ではありません。欠けた時系列の区間を0として補いません。",
    "起動後経過時間は、原文にある発生日時と起動日時の差です。時刻が不明な場合はunknownです。",
    "Crashlyticsハンドラの有無だけでは、初期化・送信の成否を確定できません。",
]


class HostJobUnobserved(MCPError):
    """A host-owned acquisition may remain active after transport failure."""


class ReadCancelled(Exception):
    """A local read stopped before receiving its terminal checkpoint."""


def now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    temporary.replace(path)


def load_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def _diagnostic(report, scope, message):
    report["errors"].append({"scope": scope, "message": str(message)})


def _acquire(client, query, folder, label, progress, cancel):
    try:
        job = client.call_tool("StartCrashSync", {**query, "source": "network", "max_records": 200, "max_bytes": 2097152})
    except MCPError as error:
        raise HostJobUnobserved(f"Could not confirm StartCrashSync's result; a host job may have been accepted. No further acquisition was started. {error}") from error
    cancellation_sent = False
    write_json(folder / f"{label}-job.json", job)
    while job["state"] not in TERMINAL:
        progress({"jobId": job["jobId"], "state": job["state"], "phase": job.get("progress", {}).get("phase", "acquiring")})
        try:
            if cancel.is_set() and not cancellation_sent:
                client.call_tool("CancelCrashSync", {"job_id": job["jobId"]})
                cancellation_sent = True
            job = client.call_tool("WaitForCrashSync", {"job_id": job["jobId"],
                "after_revision": job["revision"], "wait_seconds": 30})
        except MCPError as error:
            raise HostJobUnobserved(f"Host job {job['jobId']} may still be running. Observe it with WaitForCrashSync; last state is saved in {label}-job.json. {error}") from error
        write_json(folder / f"{label}-job.json", job)
    return job


def _job_complete(job):
    result = job.get("result") or {}
    cache = result.get("cacheInfo") or {}
    return (job["state"] == "completed" and result.get("status") == "complete"
            and cache.get("sourceComplete") is True and cache.get("acquisitionComplete") is True
            and not job.get("errors") and not result.get("errors"))


def _save_acquisition(job, folder, label):
    """Keep the immutable source snapshot, not the cache's historic issue union."""
    result = job.get("result") or {}
    metadata = load_json(result["metadataPath"]) if result.get("metadataPath") else {}
    write_json(folder / f"{label}-metadata.json", metadata)
    provenance = metadata.get("importProvenance") or metadata.get("provenance") or {}
    source = load_json(provenance["cachePath"]) if provenance.get("cachePath") else {}
    write_json(folder / f"{label}-source.json", source)
    return metadata, source


def _job_errors(job):
    errors = []
    for error in [*job.get("errors", []), *(job.get("result") or {}).get("errors", [])]:
        if error not in errors:
            errors.append(error)
    return errors or ([] if _job_complete(job) else [{"message": f"Acquisition state: {job['state']}; source/import coverage incomplete."}])


def _issue_points(metadata, source, artifacts, report):
    points = source.get("value", {}).get("points")
    if isinstance(points, list):
        return points
    # Partial scans can retain their old complete cache while saving new pages only.
    # These page descriptors belong to this acquisition, unlike the historic Read union.
    pages = metadata.get("native", {}).get("pages", [])
    recovered = []
    read_pages = 0
    for index, page in enumerate(pages):
        try:
            value = load_json(page["cachePath"])
            write_json(artifacts / f"issues-source-page-{index}.json", value)
            page_points = value.get("value", {}).get("points")
            if not isinstance(page_points, list):
                raise MCPError("Saved acquisition page has no points array.")
            recovered.extend(page_points)
            read_pages += 1
        except (MCPError, OSError, ValueError, KeyError, TypeError) as error:
            _diagnostic(report, "issues", f"Could not read acquired issue page {index}: {error}")
    if read_pages:
        return recovered
    raise MCPError("The current issue source snapshot is unavailable; historic cache membership was not substituted.")


def _window(metadata, time_period):
    selected = metadata.get("timeSeries") or {}
    if selected.get("timePeriod") != time_period:
        series = metadata.get("native", {}).get("distribution", {}).get("body", {}).get("timeSeriesDistribution", {})
        selected = next((x for x in series.get("timeDistributionMetaDatas", []) if x.get("timePeriod") == time_period), {})
    return {"startDate": selected.get("startDate"), "endDate": selected.get("endDate"),
            "timeSeries": selected or None, "source": "nativeDistribution" if selected else "unknown"}


def _reference_window(metadata, time_period):
    native = metadata.get("native", {})
    distribution = native.get("cachedDistribution")
    if not distribution:
        return None
    window = _window({"native": {"distribution": distribution}}, time_period)
    window.update(source="cachedDistributionUnknownFreshness",
        refreshedAt=native.get("cachedDistributionFetchedAt") or distribution.get("header", {}).get("lastRefresh"))
    return window


def _read_logs(client, query, folder, label, cancel):
    arguments = {**query, "limit": 200, "max_bytes": 2097152, "order": "occurredAtDescending"}
    page_number = 0
    while True:
        if cancel.is_set():
            raise ReadCancelled("Saved log read was cancelled before its terminal checkpoint.")
        page = client.call_tool("ReadCrashChanges", arguments)
        write_json(folder / f"{label}-read-{page_number}.json", page)
        if page.get("status") != "complete":
            raise MCPError(f"Saved log read was {page.get('status')}: {page.get('errors')}")
        for record in page.get("changes", []):
            yield record
        if not page.get("nextCursor"):
            if not page.get("checkpoint"):
                raise MCPError("Saved log read has no terminal checkpoint.")
            break
        arguments = {"cursor": page["nextCursor"]}
        page_number += 1


def _markdown_text(value):
    return str(value if value is not None else "不明").replace("\\", "\\\\").replace("|", "\\|").replace("\n", " ").replace("\r", " ").replace("<", "&lt;").replace(">", "&gt;")


def render_markdown(report):
    summary = report["summary"]
    status = {"running": "取得中", "complete": "取得処理完了", "partial": "一部未完了", "failed": "取得失敗", "cancelled": "停止"}[report["status"]]
    lines = ["# クラッシュレポート", "", f"対象: `{report['bundleId']}` / {report['platform']}", "",
        f"レポート日: {report['reportDate']} / 対象期間: {PERIOD_LABELS[report['timePeriod']]}", "",
        f"生成: {report['startedAt']} → {report.get('finishedAt') or '処理中'}  ", f"取得状況: **{status}**。", "",
        f"一覧: {summary['issueCount']} issue / ログ: {summary['logCount']}サンプル。",
        f"native期間内 {summary['insideWindow']} / 期間外 {summary['outsideWindow']} / 期間判定不明 {summary['unknownWindow']}。", "",
        "## 取得範囲", ""]
    lines.extend(f"- {text}" for text in report["limitations"])
    lines.extend(["", "## issueとサンプル", ""])
    for issue in report["issues"]:
        window = issue["window"]
        lines.extend([f"### {_markdown_text(issue['name'])}", "", f"ID: `{issue['issueId']}` / 端末数: {_markdown_text(issue['uniqueDeviceCount'])} / ログ取得: {issue['status']}", "",
            f"native期間: {_markdown_text(window['startDate'])} ≤ 発生日時 < {_markdown_text(window['endDate'])}", ""])
        reference = issue.get("referenceWindow")
        if reference:
            lines.extend([f"参考: 更新を確認できなかった保存済み分布の期間は {_markdown_text(reference['startDate'])} ～ {_markdown_text(reference['endDate'])}（取得時刻 {_markdown_text(reference['refreshedAt'])}）。現在の取得成功を示す値としては扱いません。", ""])
        lines.extend([
            "| 原文 | 発生日時 | 起動後秒数 | 期間判定 | アプリ / build | OS / デバイス |",
            "|---|---|---:|---|---|---|"])
        for log in issue["logs"]:
            cells = [f"[ログ]({log['rawPath']})", log.get("crashedAt"), log.get("elapsedSeconds"), log["windowMembership"],
                     f"{log.get('appVersion')} / {log.get('build')}", f"{log.get('osVersion')} / {log.get('hardware')}"]
            lines.append("| " + " | ".join(_markdown_text(x) for x in cells) + " |")
        if not issue["logs"]:
            lines.extend(["", "個別ログ未取得。発生の有無・起動時点の判定はできません。"])
        for log in issue["logs"]:
            lines.extend(["", f"原文 `{log['rawPath']}`: 例外 {_markdown_text(log.get('exceptionType'))} / 終了理由 {_markdown_text(log.get('terminationReason'))}",
                f"起動時終了の明示マーカー: {log.get('launchTerminationMarker')} / Crashlyticsハンドラ検出: {bool(log.get('crashlyticsHandlerFrames'))}"])
            for frame in log.get("faultingThreadFrames", []):
                lines.append("    " + frame.replace("\n", " ").replace("\r", " "))
            if log.get("parseWarnings"):
                lines.append("解析上の不明点: " + _markdown_text("; ".join(log["parseWarnings"])))
            if reference:
                lines.append("保存済み分布の期間との比較（参考）: " + log["referenceWindowMembership"])
        lines.append("")
    if report["errors"]:
        lines.extend(["## 未完了・エラー", ""])
        lines.extend(f"- {_markdown_text(error['scope'])}: {_markdown_text(error['message'])}" for error in report["errors"])
    return "\n".join(lines) + "\n"


def _save_report(report, folder):
    logs = [log for issue in report["issues"] for log in issue["logs"]]
    counts = Counter(log["windowMembership"] for log in logs)
    report["summary"] = {"issueCount": len(report["issues"]), "logCount": len(logs),
        "insideWindow": counts["inside"], "outsideWindow": counts["outside"], "unknownWindow": counts["unknown"],
        "issuesWithoutLogs": sum(not issue["logs"] for issue in report["issues"])}
    write_json(folder / "report.json", report)
    temporary = folder / "report.md.tmp"
    temporary.write_text(render_markdown(report), encoding="utf-8")
    temporary.replace(folder / "report.md")


def generate_report(bundle_id, platform, mcp_url, output_root, progress=None, cancel_event=None, client=None, time_period="last24Hours"):
    if time_period not in PERIOD_LABELS:
        raise ValueError(f"Unsupported crash aggregation period: {time_period}")
    progress = progress or (lambda value: None)
    cancel = cancel_event or Event()
    local_time = datetime.now().astimezone()
    report_date = local_time.strftime("%Y-%m-%d")
    folder = Path(output_root).expanduser().resolve() / report_date / (local_time.strftime("%H%M%S") + "-" + uuid4().hex[:8])
    artifacts = folder / "artifacts"
    artifacts.mkdir(parents=True)
    (folder / "raw").mkdir()
    report = {"schemaVersion": 1, "bundleId": bundle_id, "platform": platform, "timePeriod": time_period, "reportDate": report_date,
        "startedAt": now(), "finishedAt": None, "status": "running", "reportPath": str(folder / "report.md"),
        "outputDirectory": str(folder), "issues": [], "errors": [], "limitations": LIMITATIONS,
        "listAcquisition": None}
    _save_report(report, folder)
    query = {"bundle_id": bundle_id, "platform": platform, "time_period": time_period}
    try:
        client = client or XcodeMCPClient(mcp_url)
        progress({"phase": "issues", "completedIssues": 0, "totalIssues": 0})
        job = _acquire(client, {**query, "collection": "issues"}, artifacts, "issues", progress, cancel)
        report["listAcquisition"] = {"jobId": job["jobId"], "complete": _job_complete(job), "artifact": "artifacts/issues-job.json"}
        for error in _job_errors(job):
            _diagnostic(report, "issues", error.get("message", str(error)))
        metadata, source = _save_acquisition(job, artifacts, "issues")
        points = _issue_points(metadata, source, artifacts, report)
        # ReadCrashChanges retains absent issues. Only this scan's source points define membership.
        seen = set()
        for point in points:
            issue_id = point["analyticsPointIdentifier"]
            if issue_id in seen:
                continue
            seen.add(issue_id)
            report["issues"].append({"issueId": issue_id, "name": point["analyticsPointName"],
                "uniqueDeviceCount": point.get("uniqueDeviceCountFilteredWithTimePeriod"), "source": point,
                "status": "pending", "window": _window({}, time_period), "referenceWindow": None, "acquisition": None, "logs": []})
        _save_report(report, folder)
        for index, issue in enumerate(report["issues"]):
            if cancel.is_set():
                break
            label = f"issue-{index + 1}"
            progress({"phase": "logs", "completedIssues": index, "totalIssues": len(report["issues"]), "issueId": issue["issueId"]})
            try:
                issue_error_count = len(report["errors"])
                logs_query = {**query, "collection": "logs", "issue_id": issue["issueId"]}
                job = _acquire(client, logs_query, artifacts, label, progress, cancel)
                issue["acquisition"] = {"jobId": job["jobId"], "complete": _job_complete(job), "artifact": f"artifacts/{label}-job.json"}
                for error in _job_errors(job):
                    _diagnostic(report, issue["issueId"], error.get("message", str(error)))
                try:
                    metadata, _ = _save_acquisition(job, artifacts, label)
                    issue["window"] = _window(metadata, time_period)
                    issue["referenceWindow"] = _reference_window(metadata, time_period)
                except (OSError, ValueError, KeyError, TypeError) as error:
                    _diagnostic(report, issue["issueId"], f"Could not preserve acquisition metadata: {error}")
                for record in _read_logs(client, logs_query, artifacts, label, cancel):
                    try:
                        raw = Path(record["path"]).read_bytes()
                        digest = hashlib.sha256(raw).hexdigest()
                        relative = f"raw/{digest}.crash"
                        (folder / relative).write_bytes(raw)
                        try:
                            parsed = parse_log(raw.decode("utf-8"))
                        except UnicodeError:
                            parsed = parse_log(raw.decode("utf-8", errors="replace"))
                            parsed["parseWarnings"].append("Invalid UTF-8 was replaced for parsing; the raw file preserves the original bytes.")
                        parsed.update(logId=record["logId"], contentId=digest, rawPath=relative,
                            observedAt=record.get("observedAt"), nativeOccurredAt=record.get("occurredAt"),
                            windowMembership=in_window(parsed.get("crashedAt"), issue["window"]["startDate"], issue["window"]["endDate"]))
                        reference = issue["referenceWindow"] or {}
                        parsed["referenceWindowMembership"] = in_window(parsed.get("crashedAt"), reference.get("startDate"), reference.get("endDate"))
                        issue["logs"].append(parsed)
                    except (OSError, ValueError, UnicodeError, KeyError) as error:
                        _diagnostic(report, issue["issueId"], f"Could not preserve/parse saved log {record.get('logId')}: {error}")
                issue["status"] = "complete" if _job_complete(job) and len(report["errors"]) == issue_error_count else "partial"
            except ReadCancelled as error:
                issue["status"] = "cancelled"
                _diagnostic(report, issue["issueId"], error)
                break
            except (MCPError, OSError, ValueError, KeyError, TypeError) as error:
                issue["status"] = "failed"
                _diagnostic(report, issue["issueId"], error)
                if isinstance(error, HostJobUnobserved):
                    break
            _save_report(report, folder)
            progress({"phase": "logs", "completedIssues": index + 1, "totalIssues": len(report["issues"])})
        report["status"] = "cancelled" if cancel.is_set() else ("partial" if report["errors"] else "complete")
    except (MCPError, OSError, ValueError, KeyError, TypeError) as error:
        _diagnostic(report, "report", error)
        report["status"] = "cancelled" if cancel.is_set() else ("partial" if report["issues"] else "failed")
    report["finishedAt"] = now()
    _save_report(report, folder)
    progress({"phase": "finished", "state": report["status"], "completedIssues": sum(i["status"] != "pending" for i in report["issues"]),
              "totalIssues": len(report["issues"]), "reportPath": report["reportPath"]})
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--platform", default="iOS", choices=("iOS", "macOS", "watchOS", "tvOS", "visionOS"))
    parser.add_argument("--mcp-url", default="http://localhost:8765/mcp")
    parser.add_argument("--time-period", choices=tuple(PERIOD_LABELS), default="last24Hours")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--serve", action="store_true", help="Show the local report button in a browser.")
    parser.add_argument("--port", type=int, default=8767)
    args = parser.parse_args()
    if args.serve:
        from crash_report_web import serve_reports
        serve_reports(args.bundle_id, args.platform, args.mcp_url, args.output, args.port, time_period=args.time_period)
        return 0
    cancel = Event()
    signal.signal(signal.SIGINT, lambda *_: cancel.set())
    report = generate_report(args.bundle_id, args.platform, args.mcp_url, args.output,
        progress=lambda value: print(json.dumps(value, ensure_ascii=False), flush=True), cancel_event=cancel, time_period=args.time_period)
    print(report["reportPath"])
    return 0 if report["status"] == "complete" else 130 if report["status"] == "cancelled" else 1


if __name__ == "__main__":
    raise SystemExit(main())
