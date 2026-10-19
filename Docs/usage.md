# Workspace and tool usage

Start the server and [connect your MCP client](../README.md#connect-your-mcp-client).
The server runs tools in owned headless hosts or running Xcode application processes.

## Select an Xcode host

Each MCP session starts on the server's selected default Xcode. Call
`XcodeMCPKitListHosts` to list owned headless hosts, installed Xcode candidates,
and running Xcode application processes. Each entry reports its `kind`
(`headless` or `gui`), installation, and default/selected status. Running entries
include a `processIdentifier`. Listing does not start every candidate.

Pass a returned identifier to `XcodeMCPKitSelectHost`:

```json
{
  "hostIdentifier": "host-from-the-list"
}
```

The server starts an available candidate when needed and changes only the
calling MCP session. Its next `tools/list` returns the selected Xcode's tools.
Requests already admitted before the change finish on their original host.
GUI targets share one `mcpbridge` connection per Xcode application process.
Different Xcode processes can execute requests concurrently, including processes
from the same installation.

To use the same Xcode installation in another independent headless host, add
`"createsNewHost": true`. Select an existing host identifier to return to a
previous host while it remains registered. `createsNewHost` applies to headless
targets; select the existing entry for a running GUI process. Independent
headless hosts keep separate workspace models, schemes, destinations, and
test-plan selections. Start the server with
`--share-compilation-cache` to enable shared compilation caching and Swift/Clang
prefix mapping across its hosts. This option is off by default. See
[compilation caching](configuration.md#compilation-caching) for usage and limits.

DerivedData and build databases retain Xcode's existing locations. Builds targeting
the same build database can encounter Xcode's native lock, including when a GUI
Xcode build is using it.

Workspace and device-session identifiers belong to the host that returned them.
Select that host before reusing its identifiers. Absolute workspace paths resolve
inside the selected host. Tool results identify their host under
`_meta["com.lynnswap.xcode-mcpkit/hostIdentifier"]`.

Selection lasts for the MCP session. Clients that pool one MCP session across
several conversations share that selection. A new or recovered client session
starts on the default host; select the previous host again if needed.

An independent headless host is reclaimed after its last selecting session and
outstanding requests release it. Switching away, deleting a session, or session
expiry can trigger this cleanup. Its host, workspace, and device-session
identifiers then become invalid. Select an installed Xcode candidate or create
another independent host, and reopen the workspace by absolute path to obtain
fresh identifiers. The default host and ordinary installation candidates remain
registered for reuse.

After a GUI target's final selecting session, request, and channel are released,
the proxy stops its `mcpbridge` and retains the process entry. Selecting that
entry again reconnects after the old bridge has finished stopping. The GUI
Xcode application keeps running.

## Select a workspace

Use the selected target's `tools/list` response to choose its workspace selector.
GUI tools commonly accept a `tabIdentifier` returned by `XcodeListWindows`;
headless tools accept `workspaceIdentifier`. Xcode supplies these schemas, so
inspect the catalog when switching targets.

For a headless target, pass an absolute project, workspace, or Swift package path as
`workspaceIdentifier`. For example, call `BuildProject` with:

```json
{
  "workspaceIdentifier": "/Users/me/Projects/App/App.xcworkspace"
}
```

The native registry loads the project model when needed. Opening Xcode or calling
`XcodeOpenWorkspace` first is optional for ordinary file, scheme, destination,
build, and test operations that accept `workspaceIdentifier`.

Swift packages accept either their directory or `Package.swift`. Both paths refer
to the same native workspace and can also be passed to `XcodeOpenWorkspace`.
The host waits for package dependencies to resolve before waiting for the
workspace's initial run destination.

`XcodeOpenWorkspace` explicitly preloads a model and returns its native identifier.
`XcodeListWorkspaces` lists the host's models. `XcodeCloseWorkspace` closes an
owned model and releases its preview processes, staged products, and owned
Simulator. Host shutdown releases those resources for all remaining models. These
operations do not manage windows in a separate Xcode application. Host restart
invalidates native identifiers, so use the absolute project path to load it again.

Before executing a tool, the host closes models whose saved workspace or project
directories have been removed. It skips models still used by another request;
a later cleanup can close them after that request finishes. Other loaded
workspaces remain available. Cleanup failures are reported on the host's stderr
and do not fail a request for another workspace.

Native errors are reported without presenting a modal error panel. Errors raised
in a tool request set its MCP `isError` result and retain any partial output and
the native error details. Errors raised outside a request are recorded on stderr.
The host continues accepting requests without waiting for a GUI response or an
unlocked desktop. This does not replay a failed operation or confirm that its
effects were rolled back.

## Saved files and operation settings

An owned headless host reads saved project and source files. Save editor changes
before an MCP operation. Opening the same project in Xcode does not transfer its
unsaved buffers, active scheme, selected destination, or debugger session to the host.

`RenderPreview` builds saved changes and captures a new image for each request.
Repeated requests reuse preview planning when build products and preview settings
are unchanged.
Successful calls retain the workspace's preview processes and owned Simulator for
later requests. Changes to build products, resources, or destination invalidate the
retained preview metadata and staged products. Failure, timeout, or cancellation
cleans up the affected preview session; cleanup failures remain in the error.

Use `XcodeListSchemes`, `XcodeListRunDestinations`, and `XcodeListTestPlans` to
inspect the project's settings. Select the required values with
`XcodeSwitchScheme`, `XcodeSwitchRunDestination`, and `XcodeSwitchTestPlan` before
building or testing. A test run requires a scheme with testable targets and a
usable test plan; configure and save those project files first. All sessions using
the same host and workspace share these selections.

Tools without workspace scope, such as `DocumentationSearch`, run in the same
host without loading a project. DocumentationSearch uses the latest installed
developer documentation at host startup, ordered by Xcode version and then
documentation release. Restart the server after installing a newer documentation
asset. The host does not download documentation or persist search settings.

Device and debugger operations use the host's native sessions. Their permissions
and runtime requirements still apply.

## Concurrent operations

Each owned headless process has its own session actor and execution queue. A
request holds its workspace permit from model preparation through stream
consumption and cleanup. Calls for the same workspace run in order; different
workspaces can progress independently. A mutation without a workspace selector
holds the whole process while it runs.

A headless process runs up to four tool calls concurrently, including at most one
heavy call (`BuildProject`, `RunProject`, `RunAllTests`, `RunSomeTests`, or
`RenderPreview`). The queue budgets waiting requests by their incoming JSON-RPC
sizes, up to 32 MiB in total. The host rejects additional queued requests when
that budget is exhausted and creates request artifacts only after admission.
These limits apply separately to each owned process. Other headless hosts and
GUI Xcode processes retain independent execution.

## Discover tools

Call `tools/list` to discover the selected target's tools. Xcode supplies tool
names and schemas dynamically. Headless targets expose the enabled headless
catalog; GUI targets expose their native bridge catalog, including supported
window and editor tools. The MCP client controls which advertised tools an
agent may call.

Each explicit `tools/list` refreshes the catalog. Concurrent callers share an
in-flight load while retaining independent deadlines and cancellation. The proxy
preserves the native descriptors and captures the definition used by each call,
so a later refresh cannot change that call's response contract. Native tool
failures retain MCP `isError`; transport and protocol failures are request errors.

For owned headless targets, initialize and catalog results report installation
facts under `_meta["com.lynnswap.xcode-mcpkit/origin"]`, including the Xcode installation,
process, and `toolCancellation: "task"` contract. See
[architecture](architecture.md#catalog-ownership) for lifecycle ownership.

## Cancellation

MCP cancellation targets the matching request. Cancelling queued headless work
prevents backend dispatch and artifact creation. After dispatch, cancellation
requests a stop; it does not undo file edits or other completed effects.

The headless helper continues consuming the original native stream after the
request is cancelled. Cancellation signals observed native Operations while an
owned relay waits for the stream's natural terminal. Cleanup waits for that
relay, observed Operation completions, and owned preview/crash producer Tasks
before closing workspace resources and releasing the execution permit. A later
request for the same workspace waits for this cleanup.

If an action exposes no cancellable Operation, draining its stream can wait for
natural completion. This boundary does not join opaque native Swift Task handles.
GUI cancellation follows the selected Xcode process's bridge contract.

Headless shutdown stops admission, cancels pending requests, waits for owned
tasks, and closes native workspace resources. A failed connection is not evidence
that an operation completed or rolled back; mutations with unknown delivery are not
replayed automatically.
