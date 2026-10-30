"""Keep extracted crash evidence separate from a diagnosis."""

from datetime import datetime, timezone
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from crash_report_logs import in_window, parse_log


TEXT = """Version: 1.2 (34)
Hardware Model: ExampleDevice
OS Version: Example OS 1.0
Date/Time: 2026-01-02 09:00:00.2500 +0900
Launch Time: 2026-01-02 08:59:59.5000 +0900
Exception Type: EXC_CRASH (SIGABRT)
Termination Reason: Namespace DYLD, Code 1 Library missing
Triggered by Thread: 0
Thread 0 Crashed:
0   dyld 0x1000 abort_with_payload + 8
Thread 1:
0   ExampleApp 0x2000 FIRCLSMachExceptionServer + 4
"""


class CrashReportLogTests(unittest.TestCase):
    def test_text_extracts_times_and_waiting_handler_without_diagnosing(self):
        parsed = parse_log(TEXT)
        self.assertEqual(parsed["elapsedSeconds"], 0.75)
        self.assertEqual(parsed["crashedAt"], "2026-01-02T09:00:00.250000+09:00")
        self.assertEqual((parsed["appVersion"], parsed["build"]), ("1.2", "34"))
        self.assertEqual(parsed["osVersion"], "Example OS 1.0")
        self.assertEqual(parsed["hardware"], "ExampleDevice")
        self.assertEqual(parsed["terminationNamespace"], "DYLD")
        self.assertEqual(parsed["faultingThreadFrames"], ["0   dyld 0x1000 abort_with_payload + 8"])
        self.assertEqual(parsed["crashlyticsHandlerFrames"], ["0   ExampleApp 0x2000 FIRCLSMachExceptionServer + 4"])
        self.assertFalse(parsed["launchTerminationMarker"])
        self.assertEqual(parsed["parseWarnings"], [])
        self.assertEqual(set(parsed), {
            "crashedAt", "launchedAt", "elapsedSeconds", "appVersion", "build", "osVersion", "hardware",
            "exceptionType", "terminationReason", "terminationNamespace", "faultingThreadFrames",
            "launchTerminationMarker", "crashlyticsHandlerFrames", "parseWarnings",
        })

    def test_concatenated_ips_resolves_faulting_images_and_retains_marker(self):
        metadata = {"app_version": "2.0", "build_version": "45", "timestamp": "2026-01-02T00:00:01Z"}
        report = {"procLaunch": "2026-01-01T23:59:59Z", "modelCode": "ExampleDevice",
                  "osVersion": {"train": "Example OS", "build": "B1"},
                  "exception": {"type": "EXC_CRASH", "signal": "SIGABRT"},
                  "termination": {"namespace": "DYLD", "details": ["(terminated at launch; ignore backtrace)"]},
                  "faultingThread": 0, "usedImages": [{"name": "dyld"}, {"name": "ExampleApp"}],
                  "threads": [{"frames": [{"imageIndex": 0, "imageOffset": 16}]},
                              {"frames": [{"imageIndex": 1, "symbol": "FIRCLSMachExceptionReadMessage", "symbolLocation": 4}]}]}
        parsed = parse_log(json.dumps(metadata) + "\n" + json.dumps(report))
        self.assertEqual(parsed["elapsedSeconds"], 2)
        self.assertEqual((parsed["appVersion"], parsed["build"]), ("2.0", "45"))
        self.assertEqual(parsed["exceptionType"], "EXC_CRASH SIGABRT")
        self.assertEqual(parsed["osVersion"], "Example OS B1")
        self.assertEqual(parsed["faultingThreadFrames"], ["Thread 0 frame 0: dyld + 0x10"])
        self.assertIn("Thread 1 frame 0: ExampleApp FIRCLSMachExceptionReadMessage + 4", parsed["crashlyticsHandlerFrames"])
        self.assertTrue(parsed["launchTerminationMarker"])
        self.assertEqual(parsed["parseWarnings"], [])

    def test_invalid_missing_naive_and_reversed_dates_remain_unknown(self):
        for old, new, field in [
            ("2026-01-02 09:00:00.2500 +0900", "not-a-date", "crashedAt"),
            ("2026-01-02 08:59:59.5000 +0900", "2026-01-02 08:59:59", "launchedAt"),
            ("2026-01-02 08:59:59.5000 +0900", "", "launchedAt"),
        ]:
            with self.subTest(value=new):
                parsed = parse_log(TEXT.replace(old, new))
                self.assertIsNone(parsed[field])
                self.assertIsNone(parsed["elapsedSeconds"])
                self.assertTrue(parsed["parseWarnings"])
        reversed_dates = parse_log(TEXT.replace("08:59:59.5000", "09:00:01.0000"))
        self.assertIsNotNone(reversed_dates["crashedAt"])
        self.assertIsNone(reversed_dates["elapsedSeconds"])
        self.assertTrue(reversed_dates["parseWarnings"])

    def test_json_prefix_and_text_fallback_preserve_available_evidence(self):
        parsed = parse_log('{"bundleInfo":{"CFBundleVersion":"34"}}\n' + TEXT)
        self.assertEqual(parsed["build"], "34")
        self.assertEqual(parsed["elapsedSeconds"], 0.75)
        self.assertEqual(len(parsed["faultingThreadFrames"]), 1)
        self.assertTrue(parsed["parseWarnings"])
        partial = parse_log('{"app_version":"1.2"}\n{"threads":')
        self.assertEqual(partial["appVersion"], "1.2")
        self.assertIsNone(partial["crashedAt"])
        self.assertTrue(partial["parseWarnings"])

    def test_handler_and_launch_words_in_binary_images_are_not_stack_evidence(self):
        parsed = parse_log(TEXT.split("Thread 1:")[0] + "\nBinary Images:\n"
                           "0x2000 ExampleApp FIRCLSMachExceptionServer (terminated at launch; ignore backtrace)\n")
        self.assertEqual(parsed["crashlyticsHandlerFrames"], [])
        self.assertFalse(parsed["launchTerminationMarker"])
        self.assertTrue(parse_log(TEXT.replace("Triggered by Thread: 0", "(terminated at launch; ignore backtrace)\nTriggered by Thread: 0"))["launchTerminationMarker"])

    def test_faulting_thread_ambiguity_and_frame_limit(self):
        ambiguous = parse_log(TEXT.replace("Triggered by Thread: 0", "Triggered by Thread: 1"))
        self.assertEqual(ambiguous["faultingThreadFrames"], [])
        self.assertTrue(ambiguous["crashlyticsHandlerFrames"])
        self.assertTrue(ambiguous["parseWarnings"])
        frames = [{"symbol": f"function_{index}"} for index in range(42)]
        parsed = parse_log(json.dumps({"threads": [{"triggered": True, "frames": frames}]}))
        self.assertEqual(len(parsed["faultingThreadFrames"]), 40)
        self.assertIn("function_39", parsed["faultingThreadFrames"][-1])

    def test_unknown_log_keeps_unknown_values(self):
        parsed = parse_log("Unrecognized report")
        self.assertIsNone(parsed["crashedAt"])
        self.assertIsNone(parsed["elapsedSeconds"])
        self.assertEqual(parsed["faultingThreadFrames"], [])
        self.assertEqual(parsed["crashlyticsHandlerFrames"], [])
        self.assertFalse(parsed["launchTerminationMarker"])
        self.assertTrue(parsed["parseWarnings"])

    def test_window_uses_half_open_bounds_and_compares_absolute_instants(self):
        start, end = "2026-01-02T00:00:00Z", "2026-01-03T00:00:00Z"
        self.assertEqual(in_window(start, start, end), "inside")
        self.assertEqual(in_window(end, start, end), "outside")
        self.assertEqual(in_window("2026-01-01T23:59:59.999999Z", start, end), "outside")
        self.assertEqual(in_window("2026-01-02T09:00:00+09:00", start, end), "inside")
        self.assertEqual(in_window(datetime(2026, 1, 2, tzinfo=timezone.utc), start, end), "inside")

    def test_window_does_not_treat_unknown_as_outside(self):
        for crashed, start, end in [
            (None, "2026-01-02T00:00:00Z", "2026-01-03T00:00:00Z"),
            ("invalid", "2026-01-02T00:00:00Z", "2026-01-03T00:00:00Z"),
            ("2026-01-02T00:00:00", "2026-01-02T00:00:00Z", "2026-01-03T00:00:00Z"),
            ("2026-01-02T00:00:00Z", "2026-01-03T00:00:00Z", "2026-01-02T00:00:00Z"),
            ("2026-01-02T00:00:00Z", "2026-01-02T00:00:00Z", "2026-01-02T00:00:00Z"),
        ]:
            with self.subTest(crashed=crashed, start=start, end=end):
                self.assertEqual(in_window(crashed, start, end), "unknown")


if __name__ == "__main__":
    unittest.main()
