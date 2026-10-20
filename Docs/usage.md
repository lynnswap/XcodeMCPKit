# Workspace and tool usage

Start the server and [connect your MCP client](../README.md#connect-your-mcp-client).
Use `XcodeListWorkspaces` to find a workspace, then pass its `workspaceIdentifier`
to the operation you need. The same tool names and inputs work with headless
models and GUI Xcode windows.

## Find or open a workspace

`XcodeListWorkspaces` returns entries with `workspaceIdentifier`, `name`, `kind`,
and a path when available. It includes open GUI workspaces and loaded headless
models. Two GUI tabs for the same path remain separate entries because they can
have different editor state and operation settings.

For example, call `GetBuildLog` with a returned identifier:

```json
{
  "workspaceIdentifier": "workspace-from-the-list",
  "severity": "error"
}
```

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
an explicit Open is unnecessary.

An identifier refers to one workspace in its owning host. The proxy translates
it to the native workspace or GUI tab identifier. Keep using that identifier;
no host-selection call or catalog refresh is needed. Identifiers belong to the
MCP session that returned them. After starting a new MCP session or restarting a
host, list or open the workspace again to obtain a current identifier.

`XcodeCloseWorkspace` releases the calling session's handle. A headless model
closes, releasing its preview resources, once no other session references it.
For a GUI workspace, it releases the proxy handle and leaves the Xcode window open.
Disconnecting from the server does not close GUI windows or quit Xcode.

## Files, schemes, and destinations

Headless models use saved project and source files. Save changes before using
a headless workspace; opening the same path in Xcode does not transfer unsaved
buffers, scheme selection, destination, or debugger state. Use the GUI entry from
`XcodeListWorkspaces` when the operation should use that window's state.

Inspect settings with `XcodeListSchemes`, `XcodeListRunDestinations`, and
`XcodeListTestPlans`. Change them with `XcodeSwitchScheme`,
`XcodeSwitchRunDestination`, and `XcodeSwitchTestPlan`. A test run needs a scheme
with testable targets and a usable test plan. Sessions referencing the same native
workspace share these settings. Use a separate checkout, such as a Git worktree,
when concurrent clients need different settings for the same project.

`RenderPreview` defaults to a 300-second timeout; the SDK, proxy, and STDIO adapter
default to 600 seconds per request. Set an external client's deadline above the
preview timeout to leave time for preparation and cleanup. In a headless workspace,
RenderPreview builds saved changes and captures a fresh snapshot. Successful
headless renders retain reusable planning, products, processes, and an owned
Simulator; code, resource, or destination changes invalidate the corresponding
state. Failure, timeout, cancellation, workspace close, and host shutdown clean up
those headless resources. GUI requests use their Xcode window's native preview
execution and resource lifecycle.

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

## Choose another Xcode installation

Host selection is optional for normal workspace operations. To open a headless
model with another installation or attach to a specific GUI process, call
`XcodeMCPKitListHosts`, then include its `hostIdentifier` in `XcodeOpenWorkspace`:

```json
{
  "path": "/Users/me/Projects/App/App.xcworkspace",
  "hostIdentifier": "host-from-the-list"
}
```

Each installation has one headless host process, shared by every MCP session;
each running GUI Xcode process has one bridge. Opening more workspaces or
connecting more clients does not start additional processes for the same Xcode.
When the same GUI path has several tabs, use their individual identifiers from
`XcodeListWorkspaces`.

DerivedData and build databases retain Xcode's existing locations and locking.
The optional [shared compilation cache](configuration.md#compilation-caching)
can reuse compatible compilation work across installations.

## Tools, failures, and cancellation

`tools/list` describes the proxy's public operations. Backend tool availability
can differ by installation; a call reports when its owning host cannot perform
an operation. GUI tab identifiers and native schema changes are internal to the
proxy. Tools without a workspace, such as `DocumentationSearch`, use the default
host. Restart after installing newer developer documentation to select its index.

Tool failures retain MCP `isError` and available diagnostics or partial output.
Transport failures remain request errors. Cancellation stops queued work before
dispatch; after dispatch it requests a stop and waits for owned work to drain.
It does not roll back completed edits. A connection failure does not establish
whether a mutation completed, and delivery-unknown mutations are not replayed.

Calls for one headless workspace run in order through cleanup. Different
workspaces can progress independently within the
[headless execution limits](configuration.md#owned-headless-execution-limits).
Other hosts retain their own queues. GUI work follows Xcode's execution contract.
