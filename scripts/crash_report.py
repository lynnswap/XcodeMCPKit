#!/usr/bin/env python3
"""Save a dated crash report for a selected period through a local XcodeMCPKit server."""

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import math
import re
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
MCP_LIMITATIONS = [
    "一覧は本家MCPが返す直近14日間の影響端末数上位です。全issueを取得した一覧ではありません。",
    "本家MCPは応答がネット取得かキャッシュ由来かを示しません。取得時刻だけではデータの鮮度を確定できません。",
    "個別ログは本家MCPが返したサンプルです。全発生ログや、各issueの全サンプルを取得した保証はありません。",
    *LIMITATIONS[2:],
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


def _preserve_log(issue, raw, folder, **identity):
    digest = hashlib.sha256(raw).hexdigest()
    relative = f"raw/{digest}.crash"
    (folder / relative).write_bytes(raw)
    try:
        parsed = parse_log(raw.decode("utf-8"))
    except UnicodeError:
        parsed = parse_log(raw.decode("utf-8", errors="replace"))
        parsed["parseWarnings"].append("Invalid UTF-8 was replaced for parsing; the raw file preserves the original bytes.")
    parsed.update(identity, contentId=digest, rawPath=relative,
        windowMembership=in_window(parsed.get("crashedAt"), issue["window"]["startDate"], issue["window"]["endDate"]))
    reference = issue.get("referenceWindow") or {}
    parsed["referenceWindowMembership"] = in_window(parsed.get("crashedAt"), reference.get("startDate"), reference.get("endDate"))
    issue["logs"].append(parsed)


def _native_result(client, name, arguments, artifact):
    result = client.call_tool(name, arguments)
    write_json(artifact, result)
    if result.get("success") is not True:
        raise MCPError(result.get("message") or f"{name} did not succeed")
    return result


def _native_issues(client, query, report, artifacts, count):
    windows = client.call_tool("XcodeListWindows", {})
    write_json(artifacts / "windows-mcp.json", windows)
    tabs = re.findall(r"\btabIdentifier:\s*([^,\s]+)", windows.get("message", ""))
    if not tabs:
        raise MCPError("本家MCP用のXcodeタブがありません。Xcodeでワークスペースを開いてください。")
    # The bundle and platform are explicit; the tab supplies the native tool's GUI context only.
    query = {"bundle_id": query["bundle_id"], "platform": query["platform"], "tabIdentifier": tabs[0]}
    result = _native_result(client, "GetTopCrashIssues", {**query, "count": count}, artifacts / "issues-mcp.json")
    signatures = json.loads(result["data"])["signatures"]
    report["listAcquisition"] = {"backend": "mcpbridge", "complete": True, "selection": "topIssues",
        "requestedCount": count, "returnedCount": len(signatures), "freshness": "unknown",
        "artifact": "artifacts/issues-mcp.json", "tabIdentifier": tabs[0]}
    for name, point in sorted(signatures.items(), key=lambda item: (-item[1]["deviceCount"], item[0])):
        report["issues"].append({"issueId": None, "name": name, "uniqueDeviceCount": point["deviceCount"],
            "source": point, "status": "pending", "window": _window({}, "last14Days"),
            "referenceWindow": None, "acquisition": None, "logs": []})
    return query


def _native_logs(client, query, issue, folder, artifacts, label):
    result = _native_result(client, "GetCrashIssueLogs", {**query, "signature_name": issue["name"]},
                            artifacts / f"{label}-mcp.json")
    section = result["data"].split("## Performance Data", 1)[-1]
    payload, _ = json.JSONDecoder().raw_decode(section[section.index("{"):])
    issue["issueId"] = payload.get("signatureId")
    issue["acquisition"] = {"backend": "mcpbridge", "complete": True, "freshness": "unknown",
        "artifact": f"artifacts/{label}-mcp.json"}
    for raw in payload["crashLogs"]:
        _preserve_log(issue, raw.encode("utf-8"), folder, logId=None, observedAt=now())


def _acquire(client, query, folder, label, progress, cancel, skip=None):
    try:
        job = client.call_tool("StartOrganizerCrashSync", {**query, "source": "network", "max_records": 200, "max_bytes": 2097152})
    except MCPError as error:
        raise HostJobUnobserved(f"Could not confirm StartOrganizerCrashSync's result; a host job may have been accepted. No further acquisition was started. {error}") from error
    cancellation_sent = False
    write_json(folder / f"{label}-job.json", job)
    try:
        while job["state"] not in TERMINAL:
            progress({"jobId": job["jobId"], "state": job["state"], "phase": job.get("progress", {}).get("phase", "acquiring"),
                      "skipAllowed": skip is not None and not cancellation_sent})
            try:
                if (cancel.is_set() or (skip is not None and skip.is_set())) and not cancellation_sent:
                    client.call_tool("CancelOrganizerCrashSync", {"job_id": job["jobId"]})
                    cancellation_sent = True
                job = client.call_tool("WaitForOrganizerCrashSync", {"job_id": job["jobId"],
                    "after_revision": job["revision"], "wait_seconds": 1})
            except MCPError as error:
                raise HostJobUnobserved(f"Host job {job['jobId']} may still be running. Observe it with WaitForOrganizerCrashSync; last state is saved in {label}-job.json. {error}") from error
            write_json(folder / f"{label}-job.json", job)
    finally:
        progress({"skipAllowed": False})
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
        page = client.call_tool("ReadOrganizerCrashChanges", arguments)
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
    if report.get("backend") == "mcpbridge":
        acquisition = report.get("listAcquisition") or {}
        lines.extend([f"取得元: 本家MCP / 要求 {acquisition.get('requestedCount', '不明')}件 / 取得 {acquisition.get('returnedCount', 0)}件。", ""])
        if summary.get("retriedIssueCount"):
            lines.extend([f"署名の再問い合わせ: {summary['retriedIssueCount']}件 / 回復 {summary['recoveredIssueCount']}件。最初の失敗は取得記録に保持しています。", ""])
    lines.extend(f"- {text}" for text in report["limitations"])
    lines.extend(["", "## issueとサンプル", ""])
    for issue in report["issues"]:
        window = issue["window"]
        lines.extend([f"### {_markdown_text(issue['name'])}", "", f"ID: `{issue['issueId'] or '不明'}` / 端末数: {_markdown_text(issue['uniqueDeviceCount'])} / ログ取得: {issue['status']}", "",
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
    if report.get("backend") == "mcpbridge":
        retried = [issue for issue in report["issues"] if (issue.get("acquisition") or {}).get("attempts")]
        report["summary"].update(retriedIssueCount=len(retried),
            recoveredIssueCount=sum(issue["status"] == "complete" for issue in retried))
    write_json(folder / "report.json", report)
    temporary = folder / "report.md.tmp"
    temporary.write_text(render_markdown(report), encoding="utf-8")
    temporary.replace(folder / "report.md")


def generate_report(bundle_id, platform, mcp_url, output_root, progress=None, cancel_event=None, client=None,
                    time_period=None, refresh_timeout_seconds=0, skip_event=None, backend="mcpbridge", count=100):
    if backend not in ("mcpbridge", "organizer"):
        raise ValueError(f"Unsupported crash backend: {backend}")
    time_period = time_period or ("last14Days" if backend == "mcpbridge" else "last24Hours")
    if backend == "mcpbridge" and time_period != "last14Days":
        raise ValueError("本家MCPの一覧は直近14日間固定です。別の期間はOrganizer版を選択してください。")
    if isinstance(count, bool) or not isinstance(count, int) or count <= 0:
        raise ValueError("count must be a positive integer")
    if time_period not in PERIOD_LABELS:
        raise ValueError(f"Unsupported crash aggregation period: {time_period}")
    if isinstance(refresh_timeout_seconds, bool) or not isinstance(refresh_timeout_seconds, (int, float)) or not math.isfinite(refresh_timeout_seconds) or refresh_timeout_seconds < 0:
        raise ValueError("refresh_timeout_seconds must be finite and nonnegative; 0 means unlimited")
    progress = progress or (lambda value: None)
    cancel = cancel_event or Event()
    skip = skip_event or Event()
    local_time = datetime.now().astimezone()
    report_date = local_time.strftime("%Y-%m-%d")
    folder = Path(output_root).expanduser().resolve() / report_date / (local_time.strftime("%H%M%S") + "-" + uuid4().hex[:8])
    artifacts = folder / "artifacts"
    artifacts.mkdir(parents=True)
    (folder / "raw").mkdir()
    report = {"schemaVersion": 1, "bundleId": bundle_id, "platform": platform, "timePeriod": time_period, "reportDate": report_date,
        "startedAt": now(), "finishedAt": None, "status": "running", "reportPath": str(folder / "report.md"),
        "outputDirectory": str(folder), "issues": [], "errors": [], "backend": backend,
        "limitations": MCP_LIMITATIONS if backend == "mcpbridge" else LIMITATIONS,
        "listAcquisition": None, "refreshTimeoutSeconds": refresh_timeout_seconds if backend == "organizer" else None}
    _save_report(report, folder)
    query = {"bundle_id": bundle_id, "platform": platform, "time_period": time_period}
    acquisition_options = {"refresh_timeout_seconds": refresh_timeout_seconds}
    try:
        client = client or XcodeMCPClient(mcp_url)
        progress({"phase": "issues", "completedIssues": 0, "totalIssues": 0})
        if backend == "mcpbridge":
            query = _native_issues(client, query, report, artifacts, count)
        else:
            job = _acquire(client, {**query, **acquisition_options, "collection": "issues"}, artifacts, "issues", progress, cancel)
            report["listAcquisition"] = {"jobId": job["jobId"], "complete": _job_complete(job), "artifact": "artifacts/issues-job.json"}
            for error in _job_errors(job):
                _diagnostic(report, "issues", error.get("message", str(error)))
            metadata, source = _save_acquisition(job, artifacts, "issues")
            points = _issue_points(metadata, source, artifacts, report)
            # ReadOrganizerCrashChanges retains absent issues. Only this scan's source points define membership.
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
        retry = []
        for index, issue in enumerate(report["issues"]):
            if cancel.is_set():
                break
            label = f"issue-{index + 1}"
            skip.clear()
            progress({"phase": "logs", "completedIssues": index, "totalIssues": len(report["issues"]),
                      "issueId": issue["issueId"], "skipAllowed": False, "skipRequested": False})
            try:
                if backend == "mcpbridge":
                    _native_logs(client, query, issue, folder, artifacts, label)
                    issue["status"] = "complete"
                else:
                    issue_error_count = len(report["errors"])
                    logs_query = {**query, "collection": "logs", "issue_id": issue["issueId"]}
                    job = _acquire(client, {**logs_query, **acquisition_options}, artifacts, label, progress, cancel, skip)
                    issue["acquisition"] = {"jobId": job["jobId"], "complete": _job_complete(job), "artifact": f"artifacts/{label}-job.json"}
                    for error in _job_errors(job):
                        _diagnostic(report, issue["issueId"] or issue["name"], error.get("message", str(error)))
                    try:
                        metadata, _ = _save_acquisition(job, artifacts, label)
                        issue["window"] = _window(metadata, time_period)
                        issue["referenceWindow"] = _reference_window(metadata, time_period)
                    except (OSError, ValueError, KeyError, TypeError) as error:
                        _diagnostic(report, issue["issueId"] or issue["name"], f"Could not preserve acquisition metadata: {error}")
                    for record in _read_logs(client, logs_query, artifacts, label, cancel):
                        try:
                            _preserve_log(issue, Path(record["path"]).read_bytes(), folder,
                                logId=record["logId"], observedAt=record.get("observedAt"), nativeOccurredAt=record.get("occurredAt"))
                        except (OSError, ValueError, UnicodeError, KeyError) as error:
                            _diagnostic(report, issue["issueId"] or issue["name"], f"Could not preserve/parse saved log {record.get('logId')}: {error}")
                    if skip.is_set():
                        issue["status"] = "skipped"
                        _diagnostic(report, issue["issueId"] or issue["name"], "利用者がこのissueの取得をスキップしました。保存済みログの取得範囲は未完了です。")
                    else:
                        issue["status"] = "complete" if _job_complete(job) and len(report["errors"]) == issue_error_count else "partial"
            except ReadCancelled as error:
                issue["status"] = "cancelled"
                _diagnostic(report, issue["issueId"] or issue["name"], error)
                break
            except (MCPError, OSError, ValueError, KeyError, TypeError) as error:
                if backend == "mcpbridge" and isinstance(error, MCPError) and "Signature name not found" in str(error):
                    issue["status"] = "retryPending"
                    issue["acquisition"] = {"backend": "mcpbridge", "complete": False,
                        "artifact": f"artifacts/{label}-mcp.json", "error": str(error)}
                    retry.append((label, issue, str(error)))
                else:
                    issue["status"] = "failed"
                    _diagnostic(report, issue["issueId"] or issue["name"], error)
                if isinstance(error, HostJobUnobserved):
                    break
            _save_report(report, folder)
            progress({"phase": "logs", "completedIssues": index + 1, "totalIssues": len(report["issues"])})
        if retry and not cancel.is_set():
            # A repeated top query can restore native signature resolution. Keep original list membership.
            try:
                _native_result(client, "GetTopCrashIssues", {**query, "count": count}, artifacts / "issues-retry-mcp.json")
                report["retryListRequest"] = {"success": True, "artifact": "artifacts/issues-retry-mcp.json"}
            except (MCPError, OSError, ValueError, KeyError, TypeError) as error:
                report["retryListRequest"] = {"success": False, "error": str(error)}
            for index, (label, issue, original_error) in enumerate(retry):
                if cancel.is_set():
                    break
                progress({"phase": "retrying", "completedIssues": index, "totalIssues": len(retry), "skipAllowed": False})
                attempts = [dict(issue["acquisition"])]
                try:
                    _native_logs(client, query, issue, folder, artifacts, label + "-retry")
                    issue["status"] = "complete"
                    attempts.append(dict(issue["acquisition"]))
                except (MCPError, OSError, ValueError, KeyError, TypeError) as error:
                    issue["status"] = "failed"
                    attempts.append({"artifact": f"artifacts/{label}-retry-mcp.json", "error": str(error)})
                    _diagnostic(report, issue["issueId"] or issue["name"], f"{original_error}; retry: {error}")
                issue["acquisition"]["attempts"] = attempts
                _save_report(report, folder)
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
    parser.add_argument("--backend", choices=("mcpbridge", "organizer"), default="mcpbridge")
    parser.add_argument("--count", type=int, default=100, help="Requested top issue count for the standard MCP route.")
    parser.add_argument("--time-period", choices=tuple(PERIOD_LABELS))
    parser.add_argument("--refresh-timeout-seconds", type=float, default=0,
                        help="Unlocked seconds per Organizer refresh; 0 (default) waits until ready or cancelled.")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--serve", action="store_true", help="Show the local report button in a browser.")
    parser.add_argument("--port", type=int, default=8767)
    args = parser.parse_args()
    if args.serve:
        from crash_report_web import serve_reports
        serve_reports(args.bundle_id, args.platform, args.mcp_url, args.output, args.port, time_period=args.time_period,
                      refresh_timeout_seconds=args.refresh_timeout_seconds, backend=args.backend, count=args.count)
        return 0
    cancel = Event()
    signal.signal(signal.SIGINT, lambda *_: cancel.set())
    report = generate_report(args.bundle_id, args.platform, args.mcp_url, args.output,
        progress=lambda value: print(json.dumps(value, ensure_ascii=False), flush=True), cancel_event=cancel, time_period=args.time_period,
        refresh_timeout_seconds=args.refresh_timeout_seconds, backend=args.backend, count=args.count)
    print(report["reportPath"])
    return 0 if report["status"] == "complete" else 130 if report["status"] == "cancelled" else 1


if __name__ == "__main__":
    raise SystemExit(main())
