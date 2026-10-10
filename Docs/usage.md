# Workspace and tool usage

Start the server and [connect your MCP client](../README.md#connect-your-mcp-client).
The server runs tools in owned headless hosts.

## Select an Xcode host

Each MCP session starts on the server's selected default Xcode. Call
`XcodeMCPKitListHosts` to list existing hosts and installed Xcode candidates.
The result identifies the default and selected hosts and reports the native PID
when a host is running. Listing does not start every candidate.

Pass a returned identifier to `XcodeMCPKitSelectHost`:

```json
{
  "hostIdentifier": "host-from-the-list"
}
```

The server starts an available candidate when needed and changes only the
calling MCP session. Its next `tools/list` returns the selected Xcode's tools.
Requests already admitted before the change finish on their original host.

To use the same Xcode installation in another independent host, add
`"createsNewHost": true`. Select an existing host identifier to return to a
previous host. Hosts can share an installation while keeping workspace models,
schemes, destinations, and test-plan selections separate. Build storage and
compilation caches retain Xcode's existing sharing behavior. Builds targeting the
same build database can encounter Xcode's native lock, including when a GUI
Xcode build is using it.

Workspace and device-session identifiers belong to the host that returned them.
Select that host before reusing its identifiers. Absolute workspace paths resolve
inside the selected host. Tool results identify their host under
`_meta["com.lynnswap.xcode-mcpkit/hostIdentifier"]`.

Selection lasts for the MCP session. Clients that pool one MCP session across
several conversations share that selection. A new or recovered client session
starts on the default host; select the previous host again if needed. Closing a client
session leaves registered hosts and their shared workspace models available.

## Select a workspace

Pass an absolute project or workspace path as `workspaceIdentifier`. For example,
call `BuildProject` with:

```json
{
  "workspaceIdentifier": "/Users/me/Projects/App/App.xcworkspace"
}
```

The native registry loads the project model when needed. Opening Xcode or calling
`XcodeOpenWorkspace` first is optional for ordinary file, scheme, destination,
build, and test operations that accept `workspaceIdentifier`.

`XcodeOpenWorkspace` explicitly preloads a model and returns its native identifier.
`XcodeListWorkspaces` lists the host's models. `XcodeCloseWorkspace` closes an
owned model; host shutdown closes its remaining models. These operations do not
manage windows in a separate Xcode application. Host restart invalidates native
identifiers, so use the absolute project path to load it again.

Before executing a tool, the host closes models whose saved workspace or project
directories have been removed. Other loaded workspaces remain available. Cleanup
failures are reported on the host's stderr and do not fail a request for another
workspace.

Native errors are reported without presenting a modal error panel. Errors raised
in a tool request set its MCP `isError` result and retain any partial output and
the native error details. Errors raised outside a request are recorded on stderr.
The host continues accepting requests without waiting for a GUI response or an
unlocked desktop. This does not replay a failed operation or confirm that its
effects were rolled back.

## Saved files and operation settings

The host reads saved project and source files. Save editor changes before an MCP
operation. Opening the same project in Xcode does not transfer its unsaved buffers,
active scheme, selected destination, or debugger session to the host.

Use `XcodeListSchemes`, `XcodeListRunDestinations`, and `XcodeListTestPlans` to
inspect the project's settings. Select the required values with
`XcodeSwitchScheme`, `XcodeSwitchRunDestination`, and `XcodeSwitchTestPlan` before
building or testing. A test run requires a scheme with testable targets and a
usable test plan; configure and save those project files first.

Tools without workspace scope, such as `DocumentationSearch`, run in the same
host without loading a project. DocumentationSearch uses the latest installed
developer documentation at host startup, ordered by Xcode version and then
documentation release. Restart the server after installing a newer documentation
asset. The host does not download documentation or persist search settings.

Device and debugger operations use the host's native sessions. Their permissions
and runtime requirements still apply.

## Discover tools

Call `tools/list` to discover the selected Xcode installation's enabled headless
tools. Xcode supplies tool names and schemas dynamically. GUI window, current
editor, and navigator tools are outside this catalog. The MCP client controls
which advertised tools an agent may call.

Each explicit `tools/list` refreshes the catalog. Concurrent callers share an
in-flight load while retaining independent deadlines and cancellation. The proxy
preserves the native descriptors and captures the definition used by each call,
so a later refresh cannot change that call's response contract. Native tool
failures retain MCP `isError`; transport and protocol failures are request errors.

Initialize and catalog results report installation facts under
`_meta["com.lynnswap.xcode-mcpkit/origin"]`, including the Xcode installation,
process, and `toolCancellation: "task"` contract. See
[architecture](architecture.md#catalog-ownership) for lifecycle ownership.

## Cancellation

MCP cancellation cancels the matching native action task. Cancelling queued work
can prevent dispatch. After dispatch, cancellation is cooperative and does not
undo file edits or other effects already performed by the tool.

Shutdown stops admission, cancels pending requests, waits for owned tasks, and
closes native workspace resources. A failed connection is not evidence that an
operation completed or rolled back; mutations with unknown delivery are not
replayed automatically.
