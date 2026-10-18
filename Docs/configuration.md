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

Use `XcodeMCPKitListHosts` and `XcodeMCPKitSelectHost` to change a client
session's host without restarting the shared server. See
[host selection](usage.md#select-an-xcode-host).

## Server options

Use `xcode-mcp-proxy-server --help` and `xcode-mcp-proxy --help` for CLI usage.

| Option | Description |
| --- | --- |
| `--listen host:port` | Listen address. Defaults to `localhost:8765`; cannot be combined with `--host` or `--port`. |
| `--host host` / `--port port` | Listen host and port when `--listen` is not used. Port `0` selects an available port. |
| `--request-timeout seconds` | Request timeout. `0` disables non-initialize timeouts; initialization remains bounded. |
| `--max-body-bytes bytes` | Maximum accepted HTTP request body size. |
| `--force-restart` | Terminate an existing `xcode-mcp-proxy-server` on the listen port before starting. |
| `--dry-run` | Print the resolved server command without starting it. |

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

### Compilation caching

Native hosts enable compilation caching and Swift/Clang prefix mapping by
default for builds, tests, runs, and previews. Xcode maps project, intermediate,
product, SDK, and toolchain paths to common virtual paths, allowing
compatible compilations from different worktrees to reuse cached results.

The compilation cache uses the existing `CompilationCachingCASPath` preference
from `org.swift.swift-build` (with `com.apple.dt.XCBuild` as a fallback). Without
a preference, hosts use
`~/Library/Developer/Xcode/DerivedData/CompilationCache.noindex`. This location
stays the same when workspaces use different DerivedData directories. DerivedData
locations and build databases are not changed.

Inherited environment values take precedence over these defaults:

| Variable | Default |
| --- | --- |
| `COMPILATION_CACHE_ENABLE_CACHING_DEFAULT` | `YES` |
| `SWIFT_ENABLE_PREFIX_MAPPING` / `SWIFT_ENABLE_PROJECT_PREFIX_MAPPING` | `YES` |
| `CLANG_ENABLE_PREFIX_MAPPING` / `CLANG_ENABLE_PROJECT_PREFIX_MAPPING` | `YES` |
| `CompilationCachingCASPath` | Existing preference or the shared path above. |

Project build settings can override caching and prefix mapping. For example,
`COMPILATION_CACHE_ENABLE_CACHING=NO` disables caching for that project.
Restart the server to apply environment or preference changes to running hosts.
These defaults apply to XcodeMCPKit's hosts; they do not change saved projects,
GUI Xcode preferences, or shell commands.

Compiler source locations such as Swift's `#filePath` can contain mapped virtual
paths. Tests or tools that read source files or fixtures at runtime need the real
checkout path as a separate runtime input, or bundled resources; deriving a file
URL from `#filePath` can fail after prefix mapping.

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
