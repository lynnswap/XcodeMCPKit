# Workspace and tool usage

Start the server and [connect your MCP client](../README.md#connect-your-mcp-client).
Open a saved project with `XcodeOpenWorkspace`, then pass its
`workspaceIdentifier` to the operation you need. Operations use saved workspace
models in the server's owned headless hosts.

## Find or open a workspace

To load a saved project, call `XcodeOpenWorkspace`:

```json
{
  "path": "/Users/me/Projects/App/App.xcworkspace"
}
```

It accepts a `.xcworkspace`, `.xcodeproj`, Swift package directory, or
`Package.swift` and returns a `workspaceIdentifier` for subsequent operations.
Without an explicit host, Open uses the server's default headless installation.
Workspace operations also accept an absolute path for that default host when
an explicit Open is unnecessary. A path opens the workspace for the session as
Open does, so later calls with the same path reuse the loaded model. The
session's handle for it appears in `XcodeListWorkspaces`.

`XcodeListWorkspaces` returns already loaded headless models, with entries
containing `workspaceIdentifier`, `name`, `kind`, and a path when available.
Listing and operating on these models is independent of running Xcode windows
and GUI connection approval.

For example, call `GetBuildLog` with a returned identifier:

```json
{
  "workspaceIdentifier": "workspace-from-the-list",
  "severity": "error"
}
```

An identifier refers to one workspace in its owning host. The proxy translates
it to the native workspace identifier. Keep using that identifier;
no host-selection call or catalog refresh is needed. Identifiers belong to the
MCP session that returned them. After starting a new MCP session or restarting a
host, list or open the workspace again to obtain a current identifier.

A headless model stays open while any MCP session references it through a
`workspaceIdentifier`, a device interaction session, or a launch reference.
`XcodeCloseWorkspace` releases the calling session's handle; ending a device
session, or the end or expiry of an MCP session, releases its references too.
When the last reference is released and requests already running against the
model finish, the model closes and releases its preview resources.

## Files, schemes, and destinations

Headless models use saved project and source files. Save changes before using
a headless workspace. Opening the same path in Xcode does not transfer unsaved
buffers, scheme selection, destination, or debugger state into the saved model.

Inspect settings with `XcodeListSchemes`, `XcodeListRunDestinations`, and
`XcodeListTestPlans`. Change them with `XcodeSwitchScheme`,
`XcodeSwitchRunDestination`, and `XcodeSwitchTestPlan`. A test run needs a scheme
with testable targets and a usable test plan.

In a headless workspace, each MCP session keeps its own scheme, run destination,
and test plan. A session starts with the workspace's settings when it opens or
creates the workspace, or when it first uses a workspace found through
`XcodeListWorkspaces`. Its switches apply only to its own later operations. Before each
of its operations, the host restores the session's settings, and no other
session's operation on that workspace runs in between. If Xcode cannot restore
them, for example because the destination is no longer available, the operation
fails instead of running with another session's settings. Build logs, issues,
and preview state remain shared by every session that uses the workspace.

`RenderPreview` defaults to a 300-second timeout. The proxy sets no request
timeout by default, and the SDK defaults to 600 seconds. Set an external client's deadline above the
preview timeout to leave time for preparation and cleanup. In a headless workspace,
RenderPreview builds saved changes and captures a fresh snapshot. Successful
headless renders retain reusable planning, products, processes, and an owned
Simulator; code, resource, or destination changes invalidate the corresponding
state. Failure, timeout, cancellation, workspace close, and host shutdown clean up
those headless resources.

## Device and launch sessions

`RunProject` returns a `launchSessionReference`. Pass it to `GetConsoleOutput`
to read that launch's logs without resupplying a workspace or selecting a host.
The proxy retains the creating host and native launch reference.

`DeviceInteractionStartSession` accepts an optional `workspaceIdentifier`. With
one, it prepares project-bound interaction, including build/install operations;
without one, it prepares standalone device interaction. Follow-up tools use the
returned `interactionSessionKey` consistently, and the proxy supplies its owning
host and workspace. End the session with `DeviceInteractionEndSession` when done.
After starting a new MCP session or restarting a host, start a new device session.

Native device, debugger, signing, and account permissions still apply.

## Collect crash reports

Use `SyncCrashReports` to acquire data, then `ReadCrashChanges` to read saved
changes in bounded pages. Sync never marks anything consumed. Read uses only
the durable local cache and does not start Xcode or contact Apple.
Crash data and progress survive restarts in the
[persistent crash cache](configuration.md#crash-data-storage).

For network acquisition that can outlive an MCP request, call `StartCrashSync`
with an explicit bundle and platform:

```json
{
  "bundle_id": "com.example.app",
  "platform": "iOS",
  "collection": "issues",
  "time_period": "last365Days"
}
```

Start saves a job and returns its `jobId` promptly. Product lookup, Organizer
startup, acquisition, and local import run in the background. Start accepts the
same source, filters, and import budgets as Sync, with required `bundle_id` and
`platform`; it accepts neither `workspaceIdentifier` nor a cursor. A job follows
all local import continuations automatically.

Pass the returned ID to `WaitForCrashSync`:

```json
{
  "job_id": "job-id-from-start",
  "after_revision": 1,
  "wait_seconds": 30
}
```

Wait returns when the job changes, reaches a terminal state, or the wait limit
expires. Pass the previous Start or Wait response's `revision` as `after_revision`
to wait for a newer revision. Omit it to use the revision when this wait begins.
`wait_seconds` defaults to 1 and accepts 0 through 30, including
fractional seconds; 0 reads the current state immediately. Wait limits and client
disconnects leave the job running. Follow the returned `revision` and `progress`;
progress can include the current `phase`, `capturedPages`, `capturedRecords`,
resolved `query`, and import `cacheInfo`.

Job states are `queued`, `running`, `cancelling`, `completed`, `failed`,
`cancelled`, and `interrupted`. A job's `result` retains its latest Sync response,
including cumulative import counts, source completeness, and saved artifact
paths. A record import failure ends automatic processing with a partial result
and a saved `nextCursor` for an explicit retry through `SyncCrashReports`.
Source errors alone still allow the job to import acquired data. Check the
result's diagnostics and coverage as with a direct Sync call. A failed job is
returned as job state and errors; a successful status query remains a successful
MCP call.

Call `CancelCrashSync` with `{"job_id":"job-id-from-start"}` to request a stop.
It returns promptly with `cancelling` while active work and Organizer cleanup
finish. Continue using Wait until a terminal state and inspect any cleanup
errors. Saved imports remain available through Read. Job records survive a restart;
unfinished jobs without a live owner become `interrupted` when next observed.

To retry an `interrupted`, `failed`, or `cancelled` job, call `ResumeCrashSync`:

```json
{
  "job_id": "job-id-to-resume"
}
```

Resume returns a new `jobId` with `previousJobId` pointing to the original job,
whose results remain available. It uses the saved query, source, and budgets,
recovers saved pages and pending imports, then scans network sources again from
the first page. Progress keeps recovered import counts and response paths even
if the new acquisition fails. Recovery failures are reported in
`progress.recoveryErrors` while a new scan is attempted. Use the new ID for Wait
and Cancel. Existing Read checkpoints continue to identify the same consumer
position. Jobs with a live owner and
completed jobs cannot be resumed. A saved Sync continuation also remains usable
for resuming only local import through `SyncCrashReports`.

For acquisition and one bounded import batch within a single MCP call, use
`SyncCrashReports`. For example, synchronize issue metadata with:

```json
{
  "bundle_id": "com.example.app",
  "platform": "iOS",
  "collection": "issues",
  "time_period": "last14Days"
}
```

`collection` defaults to `issues`, or to `logs` when `issue_id` is supplied.
Use `app_version` and `is_beta` to filter issue metadata; omit them to include
all versions and release channels. Supported periods are `last24Hours`,
`last14Days` (default), and `last365Days`. `platform` identifies where the app
ran. For an iOS app running on macOS or visionOS, also pass
`upload_platform: "iOS"`; it otherwise defaults to `platform`.

Sync reports counts, diagnostics, source metadata paths, and `cacheInfo` rather
than returning every record or log body. Its `max_records` (default 100) and
`max_bytes` (default 64 MiB) bound each import step. A single oversized file is
streamed as one step so it cannot block all later files. Follow `nextCursor`
with `{"cursor":"returned-sync-cursor"}` to finish pending local imports.
Sync cursor retries replay their saved results. `cacheInfo` retains sync and
pending-work information across sessions, including the next sync cursor.

Read issue changes with `ReadCrashChanges`:

```json
{
  "bundle_id": "com.example.app",
  "platform": "iOS",
  "collection": "issues",
  "time_period": "last14Days",
  "limit": 25,
  "max_bytes": 262144
}
```

`limit` defaults to 25; `max_bytes` defaults to 256 KiB and bounds the encoded
structured result, including its metadata and cursors, before MCP/JSON-RPC
wrapping. Follow `nextCursor` using only `{"cursor":"returned-read-cursor"}`.
A read window fixes its upper change boundary, ordering, and page results.
Repeated reads with the same cursor return the same page without another
acquisition. Changes observed while the window is being read appear in the next
window. Oversized records are returned through local artifact references.
If the budget cannot fit the result envelope and one compact record, the call
reports the required minimum. Retry the query or continuation with a larger
`max_bytes`. A continuation's increase applies only before that
page has returned a successful response; saved responses keep their original
budget and contents. The baseline, upper boundary, and read position are retained.
Each item appears with its latest version at that window's boundary. Intermediate
versions are combined; an item that returns to its checkpoint content is not a
change. This is a state difference, rather than a history of every update.

Process a page before saving its continuation. Only the terminal page returns
a `checkpoint`. Persist that checkpoint and pass it to the next Read call to
start a window containing later changes. Reading a response does not advance a
server-side consumer position. Each consumer keeps its own cursor or checkpoint;
consumers sharing a token file must coordinate their writes. A read checkpoint
covers local observations and does not discard pending acquisition work.

The persistent cache retains blobs, record versions, and saved cursor responses
so readers can resume after a restart. It does not expire unread versions or
enforce a storage quota automatically. Removing the cache invalidates its tokens;
start a new sync and read without the old checkpoint afterward. See
[cache location settings](configuration.md#crash-data-storage) to place it on
a volume with suitable capacity.

Pass a saved issue's stable `issueId` to Sync to acquire its samples:

```json
{
  "bundle_id": "com.example.app",
  "platform": "iOS",
  "collection": "logs",
  "issue_id": "issueId-from-the-issue-record"
}
```

Then read the same `logs` collection with `ReadCrashChanges`, saving its cursor
and checkpoint independently of the issue-metadata stream. Query fields and the
collection can be omitted when a token identifies the scope. Tokens for another
scope or cache are rejected; unavailable tokens do not become empty successful
results.

Samples use shared SHA-256 content blobs. Unchanged saved files reuse the
existing blob instead of being read and saved again when their file identity
and generation can be verified. Changed bytes produce a different content ID.
`logId` identifies the logical saved sample within its query scope;
`contentId` identifies its SHA-256 byte version. An updated sample retains its
logical ID and returns a new content ID.
Log paths name local files; sample counts are neither crash occurrence counts
nor affected-device counts. Samples may include earlier Organizer downloads.

The default `order: "observedNewestFirst"` reads the most recently observed
local changes first. It does not mean the crashes happened most recently.
For logs, `order: "occurredAtDescending"` orders known event dates first, with
unknown dates last. The order is frozen for each read window. Provider issue
rankings reflect affected devices and can change during a scan. Missing issues
are not evidence of deletion or resolution.

For example, start a log read in crash-event order with:

```json
{
  "bundle_id": "com.example.app",
  "platform": "iOS",
  "issue_id": "issueId-from-the-issue-record",
  "order": "occurredAtDescending"
}
```

Issue metadata has no provider revision. An unchanged issue list does not prove
that existing issues have no new samples or symbolication changes; synchronize
their log collections again to check. Organizer downloads samples and device
distributions across all versions, builds, and channels for the last year.
Log Sync rejects `app_version` and `is_beta`. `time_period` selects a returned
device distribution without filtering samples. Missing intervals stay unknown,
and interval unique-device counts cannot be added to obtain the period count.

### Network access and saved results

Network Sync requires existing App Store Connect account access in the selected
Xcode and macOS Accessibility access for the native host. No API key is needed.
Each network call starts a dedicated GUI Xcode instance and closes it after
completion, failure, or cancellation. Xcode can appear and become active; other
workspace operations remain headless. Collection clears the name search and
unresolved-only display filter without changing any issue's resolved state.
A short list without a scrollbar temporarily uses a normal pointer scroll
gesture. Interference stops acquisition while preserving completed work.

Sync defaults to `source: "network"`. It verifies refreshed exact-query cache
entries and collects issue pages until a normal idle empty page establishes the
end. A short page alone does not establish completion. Network calls share a
lock while accessing Xcode's Products cache. Read windows freeze the resulting
observations; they are not atomic snapshots of Apple's service.

`source: "cache"` imports the server's exact saved source metadata without
starting Xcode. Explicit `bundle_id` and `platform` work without an available
workspace or a current Products inventory entry. `source:
"networkWithCacheFallback"` retains refresh errors and the saved fetch time.
Partial attempts preserve existing exact saved snapshots and usable recovery
data. A failed detail refresh can recover Organizer samples with unknown
freshness; this does not make a cached distribution current.
Saved metadata keeps the primary `provenance` and the actual import's
`importProvenance` separately when recovery supplies the imported records.

Check `status`, `errors`, and `cacheInfo` separately from read completion.
Sync returns `failed` and MCP `isError` when no source is available, such as a
cache miss or a refresh failure without fallback data. `cacheInfo.sourceAvailable`
is then false. A successful empty source remains `complete`; usable partial
source data remains `partial` with its errors preserved.
Partial imports and acquisition failures retain completed blobs and pending
work. Finishing a local read does not establish that every provider incident
has been downloaded. Native fetch times are local refresh times; no provider
update timestamp or delta token is available.

## Choose another Xcode installation

Host selection is optional for normal workspace operations. To open a headless
model with another installation, call
`XcodeMCPKitListHosts`, then include its `hostIdentifier` in `XcodeOpenWorkspace`:

```json
{
  "path": "/Users/me/Projects/App/App.xcworkspace",
  "hostIdentifier": "host-from-the-list"
}
```

Each installation has one headless host process, shared by every MCP session.
Opening more workspaces or connecting more clients does not start additional
processes for the same Xcode installation.

The default installation's host runs while the server runs. A host for another
installation stops after no MCP session has used it or held a reference to it
for five minutes, and starts again on its next use.

DerivedData and build databases retain Xcode's existing locations and locking.
The optional [shared compilation cache](configuration.md#compilation-caching)
can reuse compatible compilation work across installations.

## Tools, failures, and cancellation

`tools/list` describes the proxy's public operations. Backend tool availability
can differ by installation; a call reports when its owning host cannot perform
an operation. Native workspace identifiers and schema changes are internal to
the proxy. Tools without a workspace, such as `DocumentationSearch`, use the default
host. Restart after installing newer developer documentation to select its index.

Tool failures retain MCP `isError` and available diagnostics or partial output.
Transport failures remain request errors. Cancellation stops queued work before
dispatch; after dispatch it requests a stop and waits for owned work to drain.
It does not roll back completed edits. A connection failure does not establish
whether a mutation completed, and delivery-unknown mutations are not replayed.

Calls for one headless workspace run in order through cleanup. Different
workspaces can progress independently within the
[headless execution limits](configuration.md#owned-headless-execution-limits).
Other hosts retain their own queues.
