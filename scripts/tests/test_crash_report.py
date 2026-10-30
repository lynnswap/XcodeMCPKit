import copy
import json
from pathlib import Path
import sys
import tempfile
from threading import Event
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from crash_report import generate_report
from crash_report_mcp import MCPError


class FakeMCP:
    def __init__(self, root):
        self.root = root
        self.calls = []
        self.cancelled = False
        self.partial_detail = False
        self.fail_second_page = False
        self.running = False
        self.unobserved_detail = False
        self.partial_list = False
        self.window_period = "last24Hours"
        self.points = [{"analyticsPointIdentifier": "current", "analyticsPointName": "Example startup",
                        "uniqueDeviceCountFilteredWithTimePeriod": 2}]
        self.raw = root / "sample.crash"
        self.raw.write_text("Date/Time: 2026-10-29 12:00:00.000 +0000\n"
            "Launch Time: 2026-10-29 11:59:59.500 +0000\n"
            "Version: 1.2 (3)\nException Type: EXC_BAD_ACCESS\n"
            "Triggered by Thread: 0\n\nThread 0 Crashed:\n0 ExampleApp 0x123 startup + 4\n", encoding="utf-8")
        self.unknown_raw = root / "unknown.crash"
        self.unknown_raw.write_text("Unrecognized log; preserve the original.\n", encoding="utf-8")

    def save(self, name, value):
        path = self.root / name
        path.write_text(json.dumps(value), encoding="utf-8")
        return str(path)

    def job(self, collection):
        source = self.save(f"{collection}-source.json", {"isComplete": True, "value": {"points": self.points}})
        metadata = {"provenance": {"cachePath": source}}
        if collection == "issues" and self.partial_list:
            metadata["provenance"]["cachePath"] = None
            metadata["native"] = {"pages": [{"cachePath": source}]}
        if collection == "logs" and not self.partial_detail:
            metadata["timeSeries"] = {"timePeriod": self.window_period, "startDate": "2026-10-16T01:00:00Z", "endDate": "2026-10-30T01:00:00Z"}
        elif collection == "logs":
            metadata["native"] = {"cachedDistribution": {"header": {"lastRefresh": "2026-10-30T00:00:00Z"},
                "body": {"timeSeriesDistribution": {"timeDistributionMetaDatas": [
                    {"timePeriod": "last24Hours", "startDate": "2026-10-29T01:00:00Z", "endDate": "2026-10-30T01:00:00Z"}]}}}}
        metadata_path = self.save(f"{collection}-metadata.json", metadata)
        partial = (collection == "logs" and self.partial_detail) or (collection == "issues" and self.partial_list)
        return {"jobId": collection, "state": "failed" if partial else "completed", "revision": 3,
            "errors": [{"message": "Detail refresh failed"}] if partial else [],
            "result": {"status": "partial" if partial else "complete", "errors": [], "metadataPath": metadata_path,
                       "cacheInfo": {"sourceComplete": not partial, "acquisitionComplete": not partial}}}

    def call_tool(self, name, arguments):
        self.calls.append((name, copy.deepcopy(arguments)))
        if name == "StartCrashSync":
            if self.running or (self.unobserved_detail and arguments["collection"] == "logs"):
                return {"jobId": arguments["collection"], "state": "running", "revision": 1, "result": None}
            return self.job(arguments["collection"])
        if name == "CancelCrashSync":
            self.cancelled = True
            return {"state": "cancelling"}
        if name == "WaitForCrashSync":
            if self.unobserved_detail and arguments["job_id"] == "logs":
                raise MCPError("Disconnected")
            job = self.job(arguments["job_id"])
            if self.cancelled:
                job["state"] = "cancelled"
            return job
        if name == "ReadCrashChanges":
            if "cursor" in arguments:
                if self.fail_second_page:
                    raise MCPError("Second saved page unavailable")
                return {"status": "complete", "changes": [{"logId": "unknown", "path": str(self.unknown_raw)}], "checkpoint": "done"}
            if arguments["collection"] != "logs":
                raise AssertionError("Do not substitute a historic issue union for current source membership")
            return {"status": "complete", "changes": [{"logId": "sample", "path": str(self.raw)}], "nextCursor": "page-2"}
        raise AssertionError((name, arguments))


class CrashReportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.client = FakeMCP(self.root)

    def generate(self, **kwargs):
        return generate_report("com.example.app", "iOS", "http://localhost:8765/mcp", self.root / "reports", client=self.client, **kwargs)

    def test_report_uses_current_scan_and_preserves_all_raw_evidence_and_unknowns(self):
        result = self.generate()
        self.assertEqual(result["status"], "complete")
        self.assertEqual([i["issueId"] for i in result["issues"]], ["current"])
        self.assertEqual(result["summary"], dict(issueCount=1, logCount=2, insideWindow=1, outsideWindow=0, unknownWindow=1, issuesWithoutLogs=0))
        log = result["issues"][0]["logs"][0]
        self.assertEqual(log["elapsedSeconds"], 0.5)
        folder = Path(result["outputDirectory"])
        self.assertEqual((folder / log["rawPath"]).read_bytes(), self.client.raw.read_bytes())
        saved = json.loads((folder / "report.json").read_text())
        self.assertEqual(saved, result)
        markdown = Path(result["reportPath"]).read_text()
        self.assertIn(log["rawPath"], markdown)
        self.assertNotIn("AIエージェントへの依頼", markdown)
        self.assertTrue((folder / "artifacts/issues-source.json").is_file())
        self.assertTrue(all(args.get("time_period") == "last24Hours" and args["source"] == "network"
                            for name, args in self.client.calls if name == "StartCrashSync"))

    def test_detail_failure_keeps_saved_logs_with_unknown_window_and_visible_error(self):
        self.client.partial_detail = True
        result = self.generate()
        self.assertEqual(result["status"], "partial")
        self.assertEqual(result["issues"][0]["status"], "partial")
        self.assertEqual(result["summary"]["unknownWindow"], 2)
        self.assertEqual(result["issues"][0]["logs"][0]["referenceWindowMembership"], "inside")
        self.assertEqual(result["issues"][0]["referenceWindow"]["source"], "cachedDistributionUnknownFreshness")
        self.assertIn("Detail refresh failed", Path(result["reportPath"]).read_text())

    def test_later_read_failure_does_not_discard_first_page_logs(self):
        self.client.fail_second_page = True
        result = self.generate()
        self.assertEqual(result["status"], "partial")
        self.assertEqual(result["summary"]["logCount"], 1)
        self.assertIn("Second saved page unavailable", result["errors"][-1]["message"])

    def test_cancellation_waits_for_host_cleanup_and_saves_partial_report(self):
        self.client.running = True
        cancel = Event()
        def progress(value):
            if value.get("jobId"):
                cancel.set()
        result = self.generate(progress=progress, cancel_event=cancel)
        self.assertEqual(result["status"], "cancelled")
        self.assertTrue(self.client.cancelled)
        names = [name for name, _ in self.client.calls]
        self.assertLess(names.index("CancelCrashSync"), names.index("WaitForCrashSync"))
        self.assertTrue(Path(result["reportPath"]).is_file())

    def test_cancelling_between_read_pages_keeps_samples_without_claiming_issue_completion(self):
        cancel = Event()
        original = self.client.call_tool
        def cancel_after_first_page(name, arguments):
            result = original(name, arguments)
            if name == "ReadCrashChanges" and result.get("nextCursor"):
                cancel.set()
            return result
        self.client.call_tool = cancel_after_first_page
        result = self.generate(cancel_event=cancel)
        self.assertEqual(result["status"], "cancelled")
        self.assertEqual(result["issues"][0]["status"], "cancelled")
        self.assertEqual(result["summary"]["logCount"], 1)
        self.assertTrue(any("terminal checkpoint" in error["message"] for error in result["errors"]))

    def test_empty_current_list_is_a_report_with_explicit_sample_limitations(self):
        self.client.points = []
        result = self.generate()
        self.assertEqual(result["status"], "complete")
        self.assertEqual(result["summary"]["issueCount"], 0)
        self.assertIn("全発生ログ", Path(result["reportPath"]).read_text())
        self.assertFalse(any(name == "ReadCrashChanges" for name, _ in self.client.calls))

    def test_runs_do_not_overwrite_previous_reports(self):
        first = self.generate()
        before = Path(first["reportPath"]).read_bytes()
        second = self.generate()
        self.assertNotEqual(first["outputDirectory"], second["outputDirectory"])
        self.assertEqual(Path(first["reportPath"]).read_bytes(), before)
        self.assertEqual(Path(first["outputDirectory"]).parent.name, first["reportDate"])

    def test_requested_period_is_used_for_list_logs_and_native_window(self):
        self.client.window_period = "last14Days"
        result = self.generate(time_period="last14Days")
        self.assertEqual(result["timePeriod"], "last14Days")
        starts = [args for name, args in self.client.calls if name == "StartCrashSync"]
        self.assertTrue(all(args["time_period"] == "last14Days" for args in starts))
        self.assertEqual(result["summary"]["insideWindow"], 1)
        self.assertEqual(result["issues"][0]["window"]["source"], "nativeDistribution")
        self.assertIn("対象期間: 2週間", Path(result["reportPath"]).read_text())

    def test_unreadable_text_encoding_retains_raw_sample_and_parse_uncertainty(self):
        self.client.unknown_raw.write_bytes(b"Unknown text\xff")
        result = self.generate()
        log = result["issues"][0]["logs"][1]
        self.assertEqual((Path(result["outputDirectory"]) / log["rawPath"]).read_bytes(), b"Unknown text\xff")
        self.assertEqual(log["windowMembership"], "unknown")
        self.assertTrue(any("Invalid UTF-8" in warning for warning in log["parseWarnings"]))

    def test_partial_list_without_aggregate_snapshot_keeps_current_acquired_pages(self):
        self.client.partial_list = True
        result = self.generate()
        self.assertEqual(result["status"], "partial")
        self.assertEqual([issue["issueId"] for issue in result["issues"]], ["current"])
        self.assertEqual(result["summary"]["logCount"], 2)
        self.assertTrue((Path(result["outputDirectory"]) / "artifacts/issues-source-page-0.json").is_file())

    def test_unobserved_host_job_stops_before_starting_another_issue(self):
        self.client.unobserved_detail = True
        self.client.points.append({"analyticsPointIdentifier": "next", "analyticsPointName": "Next issue"})
        result = self.generate()
        self.assertEqual(result["status"], "partial")
        self.assertEqual([issue["status"] for issue in result["issues"]], ["failed", "pending"])
        starts = [args for name, args in self.client.calls if name == "StartCrashSync"]
        self.assertEqual(len(starts), 2)
        self.assertIn("Host job logs may still be running", result["errors"][-1]["message"])

    def test_raw_copy_failure_is_partial_for_both_the_issue_and_report(self):
        self.client.raw.unlink()
        result = self.generate()
        self.assertEqual(result["status"], "partial")
        self.assertEqual(result["issues"][0]["status"], "partial")
        self.assertEqual(result["summary"]["logCount"], 1)


if __name__ == "__main__":
    unittest.main()
