# Configuration

For installation and MCP client registration, see the
[README quick start](../README.md#quick-start).

## Xcode compatibility

The selected installation's native contracts determine available tools; the
server does not use a version allowlist or switch installations after failure.
Missing frameworks or API contracts produce initialization diagnostics.

Xcode 27 / Swift 6.4 on macOS 26.6.2 is the verified environment for headless
initialization and saved-project operations with SIP and AMFI enabled. Other
installations need their own validation. Catalog discovery does not establish
that every tool works: previews, device operations, and account-dependent tools
can require permissions or services beyond those used by build and test.

The default host first tries the server's explicitly configured developer
directory, its inherited `DEVELOPER_DIR`, and `xcode-select -p`, in that order.
Unavailable selections, including Command Line Tools and removed Xcode copies,
produce a diagnostic and do not prevent discovery of installed Xcode apps.

Automatic discovery combines macOS's registered application inventory, Spotlight,
and the system and user Applications directories, including subdirectories.
It accepts renamed apps and nonstandard locations, resolves symbolic links,
and skips stale registrations, missing native frameworks, and installations
that require a newer macOS. When several candidates remain, it selects the
highest `CFBundleShortVersionString`, with the app path breaking ties.

The selected installation is logged at startup and retained when the host
restarts. A registered host whose installation has been removed reports that
failure instead of changing its installation. The standalone helper's
`--developer-dir` also selects an exact installation; omit it for automatic
discovery. Native initialization still checks the selected Xcode's API contracts;
a failure after selection does not switch a running host to another installation.
The standard `DEVELOPER_DIR` environment variable can prefer an installation:

```bash
DEVELOPER_DIR=/Applications/Xcode_27.0.app/Contents/Developer xcode-mcp-proxy-server
```

To use another installation for a workspace, pass a `hostIdentifier` from
`XcodeMCPKitListHosts` to `XcodeOpenWorkspace`. The returned workspace handle
retains that host for subsequent operations. See
[choosing another Xcode installation](usage.md#choose-another-xcode-installation).

## Server options

Use `xcode-mcp-proxy-server --help` and `xcode-mcp-proxy --help` for CLI usage.

| Option | Description |
| --- | --- |
| `--listen host:port` | Listen address. Defaults to `localhost:8765`; cannot be combined with `--host` or `--port`. |
| `--host host` / `--port port` | Listen host and port when `--listen` is not used. Port `0` selects an available port. |
| `--request-timeout seconds` | Request timeout. Requests have none by default, and `0` also means none; starting a host remains bounded. |
| `--max-body-bytes bytes` | Maximum accepted HTTP request body size. |
| `--share-compilation-cache` | Enable shared compilation caching and Swift/Clang prefix mapping in native hosts. Off by default; see [compilation caching](#compilation-caching). |
| `--auto-approve` | Automatically allow GUI Xcode MCP connection dialogs for all agents, including external clients. Off by default; requires macOS Accessibility access. |
| `--debug-endpoints` | Serve `/debug/upstreams` and `/debug/reset` when the listener is loopback. Off by default. |
| `--force-restart` | Terminate an existing `xcode-mcp-proxy-server` on the listen port before starting. |
| `--dry-run` | Print the resolved server command without starting it. |

## Owned headless execution limits

Each owned headless process has an independent execution queue with these limits:

| Resource | Limit |
| --- | --- |
| Concurrent tool calls | 4 |
| Heavy calls (`BuildProject`, `RunProject`, `RunAllTests`, `RunSomeTests`, `RenderPreview`) | 1 |
| Queued request budget, measured by incoming JSON-RPC sizes | 32 MiB |

Calls for the same workspace remain exclusive through preparation, native stream
consumption, and cleanup. Mutations without a workspace selector are exclusive
with every workspace in that process. The limits have no public configuration
option and do not serialize other headless hosts or GUI Xcode processes. See
[operation ordering and cancellation](usage.md#tools-failures-and-cancellation)
for admission and completion boundaries.

## Environment variables

| Variable | Description |
| --- | --- |
| `LISTEN` | Listen address, for example `127.0.0.1:8765`. |
| `HOST` / `PORT` | Listen host and port when `LISTEN` is unset. |
| `XCODE_MCP_NATIVE_HOST_BUNDLE` | Helper bundle override for custom embedded/install layouts. |
| `DEVELOPER_DIR` | Xcode selection for the native host. |
| `MCP_LOG_LEVEL` | `trace`, `debug`, `info`, `notice`, `warning`, `error`, or `critical`. Defaults to `info`; `debug` includes HTTP access and routing telemetry. |
| `XCODE_MCP_PROXY_ENDPOINT` | STDIO adapter upstream URL. `--url` takes precedence. |
| `XCODE_MCP_PROXY_DISCOVERY_FILE` | Discovery file override for isolated local/live test runs. |
| `XCODE_MCP_PROXY_CACHE_ROOT` | Cache root for the discovery path when `XCODE_MCP_PROXY_DISCOVERY_FILE` is unset. |

### Automatic connection approval

`--auto-approve` monitors running Xcode permission-dialog processes and presses
`Allow` on MCP connection dialogs. It includes agents connecting directly to
Xcode outside the proxy. Grant macOS Accessibility access to the process hosting
the server when prompted; otherwise dialogs remain for manual approval.

The monitor runs until the server shuts down. It recognizes the English
`Allow “…” to access Xcode?` heading and the supported English and Japanese
sentences naming an agent that requests Xcode's tools. The default button must
be `Allow` or `許可`, or use `action-button-1` when its title is unavailable.
Agent names, PIDs, and executable paths alone do not identify a connection
request. Other dialogs keep their normal behavior.
Use a GUI workspace returned by `XcodeListWorkspaces` to work with its window.
The default installation for saved models remains the owned headless host.

### Compilation caching

Start the server with `--share-compilation-cache` to reuse compatible
compilation results across worktrees:

```bash
xcode-mcp-proxy-server --share-compilation-cache
```

This opt-in enables compilation caching and Swift/Clang prefix mapping in native
hosts for builds, tests, runs, and previews. Xcode maps project, intermediate,
product, SDK, and toolchain paths to common virtual paths. Without the flag,
hosts preserve existing build settings and cache preferences.

The compilation cache uses the existing `CompilationCachingCASPath` preference
from `org.swift.swift-build` (with `com.apple.dt.XCBuild` as a fallback). Without
a preference, hosts use
`~/Library/Developer/Xcode/DerivedData/CompilationCache.noindex`. This location
stays the same when workspaces use different DerivedData directories. DerivedData
locations and build databases are not changed.

With the flag enabled, inherited environment values take precedence over these
defaults:

| Variable | Default |
| --- | --- |
| `COMPILATION_CACHE_ENABLE_CACHING_DEFAULT` | `YES` |
| `SWIFT_ENABLE_PREFIX_MAPPING` / `CLANG_ENABLE_PREFIX_MAPPING` | `YES`, except in code-coverage builds. |
| `SWIFT_ENABLE_PROJECT_PREFIX_MAPPING` | `YES` when Swift batch mode is disabled. |
| `CLANG_ENABLE_PROJECT_PREFIX_MAPPING` | `YES`. |
| `SWIFT_ENABLE_BATCH_MODE` | `NO` when Swift compilation caching and prefix mapping are enabled; otherwise the normal default. |
| `CompilationCachingCASPath` | Existing preference or the shared path above. |

Coverage builds keep compilation caching enabled but disable prefix mapping by
default, so Xcode and `xccov` can resolve source paths in coverage reports.
Their compilation keys remain dependent on checkout and DerivedData paths.

Swift uses single-file compilation jobs to avoid
[Swift #92545](https://github.com/swiftlang/swift/issues/92545), a crash when
replaying cached diagnostics for batched jobs with mixed mapped and unmapped
inputs. Job-level parallelism and cache reuse remain enabled. If a target
explicitly enables batch mode, project prefix mapping defaults to `NO` for that
target. With a toolchain containing the [compiler fix](https://github.com/swiftlang/swift/pull/92779),
callers can explicitly enable both batch mode and project prefix mapping.

Project build settings can override caching and prefix mapping. For example,
`COMPILATION_CACHE_ENABLE_CACHING=NO` disables caching for that project.
Restart the server to apply environment or preference changes to running hosts.
These defaults apply to XcodeMCPKit's hosts; they do not change saved projects,
GUI Xcode preferences, or shell commands.

Compiler source locations such as Swift's `#filePath` can contain mapped virtual
paths. Tests or tools that read source files or fixtures at runtime need the real
checkout path as a separate runtime input, or bundled resources; deriving a file
URL from `#filePath` can fail after prefix mapping.

Debugger source lookup can also require manual LLDB source-map settings for
sources in dependency projects. If the debugger cannot display source files,
configure the relevant source maps or restart the server without
`--share-compilation-cache`.

Reuse depends on compiler support and matching compilation inputs. Custom paths
outside Xcode's standard mappings may require project-specific
`SWIFT_OTHER_PREFIX_MAPPINGS` / `CLANG_OTHER_PREFIX_MAPPINGS`. Projects using
Swift macros can also require a build service that normalizes macro executable
paths, such as the [custom Swift Build service](https://github.com/lynnswap/swift-build/tree/main/Utilities/CustomXcodeBuildService).

### Custom build services

The native host inherits Swift Build's service overrides:
`SWBBUILDSERVICE_PATH`, `XCBBUILDSERVICE_PATH`,
`SWBBUILDSERVICE_BUNDLE_PATH`, and `XCBBUILDSERVICE_BUNDLE_PATH`.
If the server's environment contains a nonempty value for any of these
variables, that selection takes precedence over launchd's settings.

Otherwise, each native host launch reads these variables from the user's
launchd context with `launchctl getenv`, in the order listed above, and uses
the first nonempty value. This also picks up settings registered with
`launchctl setenv` after the server's terminal was opened. Restart the server
to apply a changed setting to an already running native host.

For an explicit override, start the server with the service executable path:

```sh
XCBBUILDSERVICE_PATH=/path/to/SWBBuildServiceBundle xcode-mcp-proxy-server
```

When neither environment specifies a service, Swift Build uses the selected
Xcode's bundled service. If reading launchd's settings fails, the server logs
a warning and starts the native host with its inherited environment.
