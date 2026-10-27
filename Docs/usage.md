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

Call `ListCrashIssues` with the app's bundle identifier and platform. Xcode's
existing App Store Connect account access is required; no API key is needed.
Configure the account in the selected Xcode installation and grant the native
host Accessibility access before fetching. Each network call starts a dedicated
GUI instance of that Xcode installation and closes that instance when the call
completes, fails, or is cancelled. You do not need to open Xcode manually.
Organizer windows can appear and Xcode can become active during collection.
Normal workspace operations continue to use headless models.

In its dedicated instance, the tool selects the requested product and filters,
clears the name search, and turns off "Show only unresolved crash logs".
These operations do not change any issue's resolved state.

When a short list has no scrollbar, collection temporarily moves the pointer
over Organizer to send a normal scroll gesture. It restores the original
position if you have not moved the pointer yourself. Switching windows or
moving the pointer during that gesture stops collection. Completed pages are
retained; retry `pagination.nextPage` from the partial result after the interruption.

```json
{
  "bundle_id": "com.example.app",
  "platform": "iOS",
  "time_period": "last14Days"
}
```

Omit `page` to collect all pages in one call using one dedicated Xcode instance.
The response contains `pages` and combined `issues`, together with the resolved
`query`, `pagination`, `provenance`, and `errors`. If collection fails partway
through, it returns a partial result with the successful pages and
`pagination.nextPage` set to the failed page. Retry that page with the same
filters, for example by adding `"page": 2`.

Specify `page` to retrieve or retry a single zero-based page. `page_size` is
fixed at 25. Every nonempty page requires a probe of the next page, including a
page with fewer than 25 issues. An empty page establishes the end only when
Organizer also reports a normal, idle list. Rankings can change between calls;
merge records by `issueId`. A missing issue does not establish that it was resolved.

Use `app_version` to select a version and `is_beta` to select TestFlight (`true`)
or App Store (`false`); omit either to include all. Supported aggregation periods
are `last24Hours`, `last14Days` (default), and `last365Days`. `platform` selects
where the app ran. For an iOS app running on macOS or visionOS, also pass
`upload_platform: "iOS"`. It otherwise defaults to the selected platform.

Pass an issue's stable `issueId` to `GetCrashIssue`; its display name is not an
input:

```json
{
  "bundle_id": "com.example.app",
  "platform": "iOS",
  "issue_id": "issueId-from-the-list",
  "time_period": "last14Days"
}
```

`timeSeries` preserves the native interval boundaries, granularity, and unique
device counts. Missing intervals remain missing, and interval device counts
cannot be added to obtain the period's unique-device count. Organizer's detail
download covers all versions, builds, and release channels over the last year.
`time_period` selects one of its returned `last24Hours`, `last14Days`, or
`last365Days` distributions; it does not filter the downloaded sample logs.
`GetCrashIssue` rejects `app_version` and `is_beta`. The response states these
scopes explicitly and retains the original distributions in `native`.

`logs` contains local file paths and SHA-256 content IDs. A log's content ID can
change when its contents change. Samples can include logs already saved by Organizer
from earlier downloads. `sampleLogCount` counts saved sample files, not crash
occurrences or affected devices. `responsePath` names the complete structured
response saved locally.

The default `source: "network"` opens the requested Organizer route in the
dedicated Xcode instance and waits for the initial network download, then
scrolls to load further pages. It accepts a refreshed native cache entry only
when its complete header matches the query and its issue names match the
displayed list. Each loaded page is also saved in this server's store, because
Organizer retains only eight recent list-cache entries. Network crash calls
share a lock across server processes while accessing Xcode's Products disk cache.

`source: "cache"` reads only this server's saved response for the exact query
and page or all-page request (or issue ID), without starting GUI Xcode. Cached
partial results remain partial. `source: "networkWithCacheFallback"` preserves
the refresh failure, cached diagnostics, and original fetch time when falling back.
Organizer's most-recent cached page is never substituted. `provenance.source`
is `organizer` for a refreshed result, `organizerCache` for saved Organizer samples
recovered after a detail-refresh failure, and `cache` for a server-store read.
Recovered samples have unknown freshness and `provenance.fetchedAt: null`;
their cached distribution is retained in `native.cachedDistribution` without
being returned as current `timeSeries`. Otherwise, `provenance.fetchedAt` is
Organizer's native cache-header refresh time, a local refresh timestamp.
`provenance.sourceUpdatedAt` is null because no provider
update timestamp or conditional change token is available; refetch to detect
updates.

`status` is `complete`, `partial`, or `failed`. A partial response retains usable
data and diagnostics; a failed response also sets MCP `isError`. Errors include
the operation, native domain/code, and available underlying causes. Retry a
failed page with the same inputs. Successful pages and downloads remain on disk
if a later request fails. When sample-file writes fail, the cached raw response
can be reprocessed with `source: "cache"` without another download.

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
