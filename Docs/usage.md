# Workspace and tool usage

Start the server and [connect your MCP client](../README.md#connect-your-mcp-client).
The server runs tools in its owned headless host.

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

## Saved files and operation settings

The host reads saved project and source files. Save editor changes before an MCP
operation. Opening the same project in Xcode does not transfer its unsaved buffers,
active scheme, selected destination, or debugger session to the host.

Xcode and an agent can work on the same saved project. Coordinate edits to each
file: MCP writes are not merged with an unsaved editor buffer, and saving that
buffer later can conflict with or replace the agent's changes.

Use `XcodeListSchemes`, `XcodeListRunDestinations`, and `XcodeListTestPlans` to
inspect the project's settings. Select the required values with
`XcodeSwitchScheme`, `XcodeSwitchRunDestination`, and `XcodeSwitchTestPlan` before
building or testing. A test run requires a scheme with testable targets and a
usable test plan; configure and save those project files first.

Tools without workspace scope, such as `DocumentationSearch`, run in the same
host without loading a project. Device and debugger operations use the host's
native sessions. Their permissions and runtime requirements still apply.

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
