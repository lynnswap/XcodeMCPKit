# Generate a crash report

Use the local report button or CLI to collect Xcode's issue list for a selected
period and acquire each issue's saved samples. Reports, raw logs, and acquisition
metadata are saved together under a dated output directory.

The report UI and generated Markdown are in Japanese. JSON field names are
stable English identifiers.

## Start the report page

Use a checkout of this repository and Python 3.10+. These standalone scripts
have no third-party Python dependencies and are not installed by Homebrew.
Start XcodeMCPKit as described in the [quick start](../README.md#quick-start).
Keep the selected Xcode running with App Store Connect access and the native
host's Accessibility permission. Network collection operates its Organizer;
it waits while Xcode is the foreground application. A scheduled invocation
needs the same usable macOS login session.

From the checkout, run:

```bash
python3 scripts/crash_report.py \
  --bundle-id com.example.app \
  --platform iOS \
  --mcp-url http://localhost:8765/mcp \
  --output "$HOME/Documents/XcodeCrashReports" \
  --serve
```

Open the printed local URL, choose the period and output folder, then press
**レポートを作成**. Available periods are Last Day (`last24Hours`), two weeks
(`last14Days`), and one year (`last365Days`). Last Day is the initial selection.
The page shows progress, a stop button, the saved path, and Markdown and JSON
links.

The page listens on `127.0.0.1:8767`; change it with `--port`. It accepts only
local requests and serves files within the chosen report output directory.
Reports can contain private diagnostic data, so choose a suitable location
outside the source checkout. Closing the browser does not stop collection.
Use the stop button to request cancellation and wait for Organizer cleanup.

## Run without the page

Use the same command without `--serve` for a manual terminal run or a scheduler:

```bash
python3 scripts/crash_report.py \
  --bundle-id com.example.app --platform iOS \
  --output "$HOME/Documents/XcodeCrashReports"
```

Use `--time-period last14Days` or `--time-period last365Days` to change the
period. Each invocation saves its files in `OUTPUT/YYYY-MM-DD/HHMMSS-runID/`,
using the Mac's local date. Multiple runs on the same day remain together in
that date's folder without overwriting previous reports. Standard output contains
JSON progress lines followed by the Markdown path. Exit status is `0` when the
requested acquisitions and reads completed, `1` for a failed or partial report,
and `130` after cancellation. `Ctrl-C` requests cancellation and waits for the
active host job to stop before saving the report. Reports from earlier runs
remain unchanged. Coordinate scheduled runs with interactive collection to
avoid overlapping Organizer work.

## Saved files

Each run contains:

- `report.md`: issue and sample overview, acquisition failures, and evidence.
- `report.json`: the same evidence with structured timestamps, native windows,
  elapsed seconds, faulting thread frames, and raw log references.
- `raw/`: byte-for-byte copies of the saved sample logs, named by SHA-256.
- `artifacts/`: host job results, acquisition metadata, source snapshots, and
  reader responses used for this run. Paths within those source artifacts can
  still refer to the original Mac's cache; `raw/` copies travel with the report.

The current issue source snapshot, or its saved pages after a partial scan,
defines which issues this run includes.
Historic issues retained by the local change store are not added to the list.
Every selected issue's log stream is read through its terminal checkpoint,
including unchanged samples already saved on this Mac. The original persistent
[MCP cache](configuration.md#crash-data-storage) is retained separately.

`complete` means the requested source acquisitions and local imports/reads
completed. It does not mean Apple returned every crash occurrence. The native
source supplies samples and affected-device counts, not an exhaustive event
stream. A failed detail refresh can still produce a partial report with saved
logs and explicit unknown freshness.

The selected period controls issue acquisition and the returned distribution.
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

If a transport failure interrupts observation of a host job, its last known ID
and state remain in `artifacts/*-job.json`. The report error identifies the job;
use `WaitForCrashSync` or `CancelCrashSync` to resolve it before starting another
collection. A failed HTTP request does not stop a host-owned job.

## Verify changes to the reporter

```bash
python3 -B -m unittest discover -s scripts/tests -p 'test_crash_report*.py' -v
```
