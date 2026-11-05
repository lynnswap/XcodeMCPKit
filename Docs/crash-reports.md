# Generate a crash report

The report button and CLI save an issue list, sample logs, and acquisition
metadata together under a dated output directory. Daily checks use Apple's
`mcpbridge` by default: the last 14 days, requesting the top 100 issues by
affected-device count. The requested and returned counts are recorded separately.
This is a top-issues report, without a guarantee of exhaustive issue or sample
coverage. Native results do not identify network versus cache provenance.

The report UI and Markdown are in Japanese. JSON field names are stable English
identifiers. Keep GUI Xcode running with an open workspace and App Store Connect
account access. `--auto-approve` on the proxy can approve its bridge connection.
Standard acquisition does not operate Organizer.

## Start the report page

Use a checkout and Python 3.10+. These scripts have no third-party dependencies
and are not installed by Homebrew. Start XcodeMCPKit using the
[quick start](../README.md#quick-start), then run:

```bash
python3 scripts/crash_report.py \
  --bundle-id com.example.app --platform iOS \
  --mcp-url http://localhost:8765/mcp \
  --output "$HOME/Documents/XcodeCrashReports" --serve
```

Open the printed local URL, choose the output folder, and press
**レポートを作成**. Standard mode fixes the aggregation period to two weeks
and starts with 100 requested issues. Its native `GetTopCrashIssues` and
`GetCrashIssueLogs` calls use a tab returned by `XcodeListWindows`; the bundle
and platform are supplied explicitly. A native failure is saved as a report
failure or partial result, without switching to Organizer. If native detail
lookup reports `Signature name not found`, the reporter repeats the same top
query and retries those failed details once after the initial pass. It keeps
the original issue list, failed responses, and attempt history; summaries count
retries and recoveries. Other failures are not retried automatically.

Select **Organizer（画面操作）** to use the extended sync tools. That mode offers
Last Day (`last24Hours`), two weeks (`last14Days`), and one year (`last365Days`).
It requires Accessibility access for the native host and a usable GUI session.
It waits while Xcode is foreground or the Mac is locked. Refresh waits default
to unlimited (`0`); a positive value bounds each refresh while unlocked.
Explicit Organizer errors remain failures. Use **このissueをスキップ** to cancel
and drain a stalled detail acquisition before continuing; the report stays
partial. Issue-list acquisition can be stopped but not skipped.

The page listens on `127.0.0.1:8767`; use `--port` to change it. It serves report
files only within the selected output directory. Closing the browser does not
stop collection. Standard-mode cancellation stops after the current native
request returns; Organizer cancellation waits for its host job's cleanup.

## Run without the page

Omit `--serve` to save a standard report directly. Use `--count` to change the
requested number of top issues. Direct MCP callers retain Apple's default of 5
when they omit `count`; the reporter explicitly requests 100.

For extended Organizer acquisition:

```bash
python3 scripts/crash_report.py \
  --bundle-id com.example.app --platform iOS \
  --backend organizer --time-period last24Hours \
  --output "$HOME/Documents/XcodeCrashReports"
```

Organizer mode also accepts `--time-period last14Days` or `last365Days` and
`--refresh-timeout-seconds`. Standard mode accepts only `last14Days`.
Direct Organizer MCP acquisition retains a 90-second refresh default; the
reporter sends `refresh_timeout_seconds: 0`. `WaitForOrganizerCrashSync` has a
separate observation limit.

Each invocation saves its files in `OUTPUT/YYYY-MM-DD/HHMMSS-runID/`,
using the Mac's local date. Multiple runs on the same day remain together in
that date's folder without overwriting previous reports. Standard output contains
JSON progress lines followed by the Markdown path. Exit status is `0` when the
requested acquisitions and reads completed, `1` for a failed or partial report,
and `130` after cancellation. `Ctrl-C` requests cancellation, then waits for the current native response or
Organizer host cleanup before saving the report. Reports from earlier runs
remain unchanged. Coordinate Organizer runs with interactive collection to avoid overlapping
Organizer work.

## Saved files

Each run contains:

- `report.md`: issue and sample overview, acquisition failures, and evidence.
- `report.json`: the same evidence with structured timestamps, native windows,
  elapsed seconds, faulting thread frames, and raw log references.
- `raw/`: sample text returned by standard MCP encoded as UTF-8, or byte-for-byte
  copies of Organizer samples, named by SHA-256.
- `artifacts/`: host job results, acquisition metadata, source snapshots, and
  reader responses used for this run. Paths within those source artifacts can
  still refer to the original Mac's cache; `raw/` copies travel with the report.

In standard mode, the native top-issues response defines report membership.
In Organizer mode, the current issue source snapshot, or its saved pages after
a partial scan, defines which issues this run includes.
Historic issues retained by the local change store are not added to the list.
Organizer mode reads every selected issue's log stream through its terminal
checkpoint, including unchanged samples already saved on this Mac. The original persistent
[MCP cache](configuration.md#crash-data-storage) is retained separately.

`complete` means the selected native tool calls, or Organizer source
acquisitions and local imports/reads, completed. It does not mean Apple returned every crash occurrence. The native
source supplies samples and affected-device counts, not an exhaustive event
stream. A failed detail refresh can still produce a partial report with saved
logs and explicit unknown freshness.

In Organizer mode, the selected period controls issue acquisition and the
returned distribution. Standard mode supplies no native distribution window,
so sample window membership remains unknown.
Last Day uses `last24Hours`, rather than an assumed local calendar date. Native
per-issue distribution start/end timestamps are retained when available; sample
timestamps use the half-open interval `[start, end)`. Missing dates or windows
remain `unknown`. If only an unrefreshed distribution was recovered, its window
and sample comparisons appear separately as references and do not establish
current coverage. Individual samples can be older than the selected period.

The parser extracts elapsed time, exception and termination details, a maximum
of 40 faulting thread frames, explicit launch termination markers, and observed
Crashlytics handler frames. These are evidence, not a verdict. A waiting handler
does not prove a crash was captured or uploaded; its absence does not prove the
crash preceded Firebase initialization. Unknown timestamps and incomplete
acquisitions remain explicit in the report.

In Organizer mode, if a transport failure interrupts observation of a host job, its last known ID
and state remain in `artifacts/*-job.json`. The report error identifies the job;
use `WaitForOrganizerCrashSync` or `CancelOrganizerCrashSync` to resolve it before starting another
collection. A failed HTTP request does not stop a host-owned job.

## Verify changes to the reporter

```bash
python3 -B -m unittest discover -s scripts/tests -p 'test_crash_report*.py' -v
```
