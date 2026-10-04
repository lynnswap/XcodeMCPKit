# Workspace and tool usage

Start the server and [connect your MCP client](../README.md#connect-your-mcp-client).
Workspace tools use the same endpoint for headless and GUI work.

## Select a workspace

Pass an absolute project or workspace path as the standard `workspaceIdentifier`
argument. For example, call `BuildProject` with:

```json
{
  "workspaceIdentifier": "/Users/me/Projects/App/App.xcworkspace"
}
```

An open GUI owner takes priority. If no GUI owns the path, the native host loads
its workspace model for the operation. You do not need to open a GUI window or
call `XcodeOpenWorkspace` first. The same selection applies to file, scheme,
destination, build, and test tools that accept `workspaceIdentifier`.

`XcodeOpenWorkspace` explicitly preloads a headless model and returns its native
identifier. `XcodeListWorkspaces` lists those models. Close an owned model with
`XcodeCloseWorkspace` when finished; closing it does not close a user's GUI window.
The host closes resources it owns during shutdown.

### Multiple Xcode instances

Use `XcodeListWindows` to inspect GUI tabs. When several tabs own the same path,
select a `tabIdentifier` from the reported candidates. Each GUI connection uses
its owning Xcode installation and tool definitions.

A known GUI owner that lacks a requested tool returns an availability error.
A lost known owner also produces an error; the server does not replay the
operation in another workspace. Native workspace identifiers select their
owning host independently of unrelated GUI inventory failures.

### Editor and operation state

GUI operations use Xcode's workspace context, active scheme, and selected run
destination. GUI builds save pending editor changes before building. Native
file-reading tools return disk content, including when a GUI editor has unsaved
changes; an unsaved buffer is not part of their reading contract.

Tools without workspace scope, such as `DocumentationSearch`, prefer the native
host when it advertises the requested tool. Debugger and device-interaction
sessions remain with the provider that created them.

## Discover tools

Call `tools/list` to discover the tools supplied by usable native and GUI
connections. Tool names and schemas come from Xcode, so availability can differ
between installations. The MCP client controls which tools an agent may call.

Each explicit `tools/list` refreshes discovery. Concurrent callers share an
in-flight load while keeping independent deadlines. If some providers have
refreshed and another is pending, a caller can receive the fresh providers;
remaining reads continue and publish `tools/list_changed` when they update the
catalog. A refresh fails if no provider supplies a fresh result.

When a selected SDK cannot initialize the headless host, a usable GUI catalog
remains available for that GUI's operations. Requests that require a headless
model retain the headless failure.

### Provider metadata

Shared tool names preserve schema variants through workspace, tab, and
interaction-session selectors. Calls without a selector use the default
provider's input schema. Routing selectors absent from the selected SDK's
definition are removed before dispatch.

Each tool's `_meta["com.lynnswap.xcode-mcpkit/providers"]` lists its providers and
their original `descriptor`, including input and output schemas. A call uses
the selected owner's definition throughout the operation, so another catalog
refresh cannot change its response contract.

Initialize and catalog results expose installation facts under
`_meta["com.lynnswap.xcode-mcpkit/origin"]`, including the Xcode installation,
process, and cancellation contract. See [architecture](architecture.md#catalog-ownership)
for catalog ownership and transport details.

## Cancellation

Cancellation follows the selected connection's reported `toolCancellation`:

| Contract | Behavior |
| --- | --- |
| `task` | The headless host cancels its native action task. |
| `nativeMessage` | The GUI connection sends the SDK's native cancellation message. |
| `waitForNativeCompletion` | After dispatch, cancellation is advisory; the operation remains tracked until native completion or connection failure. |

The inspected Xcode 27 GUI connection supports native cancellation. Xcode 26.6
uses advisory cancellation after dispatch. The SDK's native message decoder
determines this capability, rather than its version number. Cancelling queued
work can prevent dispatch.

Shutdown reports dispatched calls whose native cancellation or completion was
not confirmed. Closing a connection does not establish that Xcode stopped its
native operation.
