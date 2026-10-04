# Maintainer Architecture

## Module Layout

- `XcodeMCPCore`
  - Package-internal JSON-RPC, framing, clocks, HTTP wire I/O, and subprocess ownership.
  - Shared by the SDK and proxy without depending on either consumer.
- `XcodeMCPKit`
  - Public client SDK facade and MCP value types.
  - Package-scoped `MCPClientSessionAuthority` owns transport recipes,
    connection identity, HTTP session recovery, connection state, and close
    completion for both the direct SDK and the proxy STDIO adapter.
  - `InitializedMCPClientSession` owns request IDs, response correlation, and
    request-scoped progress lanes; it does not own transport/session lifecycle.
- `XcodeMCPDocumentationSearch`
  - Installed documentation assets, selection cache, generated helper source,
    helper preparation/invocation, and asset repair operations.
  - Takes immutable installation/query values and returns typed documents.
    It does not own Xcode process inventory, MCP sessions, or provider routing.
- `XcodeMCPNativeRuntime` and `XcodeMCPNativeHost`
  - Load selected Xcode frameworks and invoke native tool contracts through
    ABIBridge 0.7 method handles.
  - Own workspace-model resources, native action streams, GUI connections,
    and helper STDIO framing/initialization.
  - Missing native contracts return diagnostics; tool failures and transport
    failures retain their separate MCP meanings.
- `XcodeMCPProxyRuntimeContract`
  - Package request/reply/session/snapshot values and serving protocols shared
    by Runtime, HTTP, and facade composition. No execution state or I/O owner.
- `XcodeMCPProxyRuntime`
  - Proxy control plane, request/session ownership, native/GUI routing,
    connection topology, canonical native catalogs, and feature workflows.
- `XcodeMCPProxyHTTP`
  - HTTP listener lifecycle, transport validation, response encoding, and SSE delivery.
  - Depends on the runtime contract and Core without linking the concrete Runtime.
    It does not own runtime policy.
- `XcodeMCPProxyKit`
  - Public server/adapter embedding facades and composition of runtime, HTTP,
    discovery publication, and permission automation.
  - CLI composition, installer implementation, build metadata, and launch
    diagnostics are package/executable concerns rather than public library API.
- `XcodeMCPPermissionAutomation`
  - Package-internal AX adapter, permission-dialog matcher, one-scan state, and
    owned polling lifecycle shared by the proxy and maintainer diagnostic.
  - Owns one scanner task per caller-supplied PID so a slow helper AX call does
    not delay approval of another Xcode process's dialog.
  - Consumes caller-supplied Xcode/helper and agent identities. The proxy adds
    connection-heading matching to configured-agent matching; the diagnostic
    uses only configured-agent matching. It does not own process inventory or
    launch processes.
- `XcodeMCPPermissionApproverTool`
  - Maintainer executable that validates explicit existing PIDs and runs the
    shared permission automation until interrupted. It never launches
    a native connection and is not installed by the release installer.

## Ownership Boundaries

- `ProcessControlPlaneAuthority`
  - Owns route membership/exposure, activation attempts and their resources,
    per-process tool catalogs, and the canonical tool projection in one lock.
    Transitions return cancellation/I/O effects for execution outside the lock.
  - Route-activation `tools/list` uses the configured request timeout, not the
    short discovery/control-plane cap. The activation watchdog and RPC share
    that deadline owner.
- `WindowOwnershipAuthority` and `WindowRoutingResolver`
  - The authority owns window/tab identity and `windowEpoch`; the stateless
    resolver combines its snapshot with an immutable route snapshot. Neither
    mutates catalog lifecycle.
- `UpstreamTopologyAuthority`
  - Owns actual upstream slots, stable IDs, membership/order, and topology
    epoch. Routers, health state, schedulers, and debug views key local state by
    those IDs instead of mirroring the slot array.
- `CanonicalHandshakeState` and `ControlPlaneCoordinator`
  - Handshake state is independent from catalog/window epochs. The coordinator
    owns shared load tasks and waiters, but writes semantic state only through
    authority leases and transitions.
- `XcodeProcessEventMonitor`
  - Owns the KVO subscription and cached snapshots derived from
    `NSWorkspace.runningApplications`. Each callback reads the current atomic
    property; it does not treat the KVO change payload as a full snapshot.
    GUI routing and auto-approve consume this cache; they must not add
    independent `pgrep`, libproc, or periodic membership scans.
  - Readiness changes are generation-fenced. Route cooldown recovery is a
    route-identity-fenced one-shot timer, not a process rescan.
- `XcodeMCPProxyHTTP` gateway
  - `HTTPRequestSecurityPolicy` validates Origin for every route before any
    side effect. The gateway enforces session headers and negotiated protocol
    versions using runtime-owned session state and parses individual messages.
  - Rejects JSON-RPC batch arrays at the HTTP boundary without invoking the
    session or upstream.
  - Tool-specific response shaping lives in dedicated surface helpers, not inline in forwarding hot paths.
- CLI commands
  - `ProxyServerCommand`, `ProxyAdapterCommand`, and `ProxyInstallCommand` own
    the `swift-argument-parser` option, help, version, and input-validation
    contracts. Each invocation is parsed once into typed values.
  - Server environment and file configuration precedence is resolved after
    parsing and before the existing launcher/runtime lifecycle begins.
  - `XcodeMCPPermissionApproverCommand` accepts only explicit Xcode/helper PIDs,
    agent root PIDs, and exact path/name candidates. It has no command-launch
    surface.

## Dependency Direction

- `XcodeMCPCore` contains package implementation shared by the SDK and proxy.
  It depends on Logging, NIOCore, and NIOConcurrencyHelpers; no consumer target
  may become a dependency of Core. Shared declarations retain package access.
- `XcodeMCPKit` depends on Core and owns the public client API, domain values,
  session authority, progress, and transport wrappers. Core wire values are
  converted at this SDK boundary and do not become public aliases.
- Runtime and HTTP depend on Core rather than the public SDK. Runtime owns
  execution policy and request lifetimes; HTTP owns network delivery. The native
  host owns ordinary DocumentationSearch execution. Optional documentation
  backend components retain their Core/NIOCore boundary. The
  runtime serving protocol in `XcodeMCPProxyRuntimeContract` connects these
  two owners. The contract retains the NIOCore timeout value without exposing
  channels or event loops.
- `XcodeMCPProxyKit` composes Runtime, HTTP, permission automation, and the SDK
  session authority used by its STDIO adapter. Its internal files contain
  facade, CLI, installation, and launch concerns.
- `XcodeMCPPermissionAutomation` depends only on `Logging`. `XcodeMCPProxyKit`
  and `XcodeMCPPermissionApproverTool` depend on it; the automation target does
  not depend back on proxy/runtime targets.
- `XcodeMCPProxyCLI`, `XcodeMCPProxyServer`, and `XcodeMCPProxyInstall` depend on
  `XcodeMCPProxyKit`; `XcodeMCPProxyToolVerifier` depends on `XcodeMCPKit`;
  `ProxyBuildInfoTool` is a standalone build-tool dependency of
  `ProxyBuildInfoPlugin`.

Use the relevant `xcodebuild test` schemes with an explicit macOS destination
when moving files or changing imports. Core tests use Core directly; SDK and
proxy integration tests keep their actual consumer dependencies. Documentation
backend tests use lower process fakes and shared filesystem fixtures without
linking the runtime coordinator. Public product
contract tests compile consumers from a separate package. Run
`scripts/verify-proxy-target-boundaries.sh` to check dependency direction;
private implementation targets are not new public products.

## Focused Test Ownership

| Test target | Owner and coverage |
| --- | --- |
| `XcodeMCPCoreTests` | Wire/framing primitives and low-level HTTP transport lifecycle; no SDK or proxy implementation dependency. |
| `XcodeMCPProcessRuntimeTests` | Process I/O and termination through fake drivers and opt-in live smoke cases; no SDK dependency. |
| `XcodeMCPDocumentationSearchTests` | Assets, repair, helper generation and invocation through lower process fakes. |
| `XcodeMCPProxyHTTPTests` | HTTP/SSE delivery and gateway lifecycle using the runtime contract fake. |
| `XcodeMCPProxyRuntimeTests` | Coordination, scheduling, routing and provider policy; no HTTP or facade dependency. |
| `ProxyIntegrationTests` | Actual HTTP/runtime composition and public configuration paths. |

When Xcode provides a matching test scheme, run it directly. For example:

```sh
xcodebuild test -workspace XcodeMCPKit.xcworkspace -scheme XcodeMCPProxyRuntimeTests -destination 'platform=macOS'
```

Use `swift build --target XcodeMCPProxyRuntimeTests -v` to inspect that target's
compilation graph. `swift test --filter` selects execution and may build other
test targets; it is not proof of compilation isolation. SDK transport-integration
cases remain in `XcodeMCPKitTests`; use a package test scheme containing that
target, or `swift test --filter XcodeMCPKitTests` if the generated SDK scheme
has no test action. Xcode may group other targets into a package test scheme
rather than generate a dedicated scheme for every target.

`XcodeMCPCoreTestSupport` owns generic clocks and process-I/O fakes. Shared
proxy synchronization and filesystem fixtures stay in `XcodeMCPProxyTestSupport`.
`XcodeMCPProxyRuntimeTestSupport` shares lower upstream fakes and coordinator
fixture helpers between unit and integration tests through testable imports;
it does not add production API or test-only production branches. Fixtures used
by only one suite remain with that suite.

The seven coordinator suites keep their CI filter names and live in separate
files. HTTP/configuration integration cases run in the remaining shard. When
moving tests, compare discovery identifiers with module/suite moves accounted
for, then verify each identifier is selected by exactly one CI shard.

## Protocol Boundaries

- `stdout`
  - Protocol payloads only. Do not send logs or debug text here.
- `stderr`
  - Human-readable logging only.
- HTTP request bodies
  - Parse once per request and pass the parsed payload through forwarding/local handling; do not re-parse in hot-path helpers unless the payload is synthesized internally.
- Resource lifecycle
  - Public `close()`, `stop()`, and `shutdown()` methods are the graceful
    completion contracts. They stop admission, cancel and await owned tasks,
    close transport/channel resources, then publish terminal state.
  - `deinit` is a synchronous cancellation backstop only. It must not create an
    unowned cleanup task or promise graceful protocol shutdown.
- Discovery
  - A discovery record is a URL hint. Only a connection plus standard
    initialize handshake establishes reachability; PID liveness is not truth.

## Local Verification

- Fast regression suite:
  - `swift test -Xswiftc -strict-concurrency=minimal`
- Process / pipe suite:
  - `XCODE_MCP_RUN_PROCESS_TESTS=1 swift test --no-parallel --filter XcodeMCPProcessRuntimeTests -Xswiftc -strict-concurrency=minimal`
  - `XCODE_MCP_RUN_PROCESS_TESTS=1 swift test --no-parallel --filter ProxyStdioAdapterTests -Xswiftc -strict-concurrency=minimal`
- Full local maintainer check:
  - `scripts/check.sh`
- Permission diagnostic contract:
  - `swift test --filter XcodeMCPPermissionAutomationTests -Xswiftc -strict-concurrency=minimal`
  - `swift test --filter XcodeMCPPermissionApproverToolTests -Xswiftc -strict-concurrency=minimal`

These checks use lower process/transport fixtures and do not require GUI Xcode
or a live native helper unless explicitly selected.

## Permission dialog diagnostic

To diagnose permission dialogs without launching a native connection, run the
package-only maintainer tool with explicit existing process identities:

```bash
swift run xcode-mcp-permission-approver \
  --xcode-pid <xcode-pid> \
  --agent-pid <proxy-server-pid> \
  --agent-path <proxy-server-path> \
  --assistant-name XcodeMCPKit
```

## Release Flow

Create a draft with the approved version, title, notes, and source commit, then
dispatch `release.yml` from the default branch. A successful run attaches the
verified assets and publishes that same release automatically. Its title and
notes are preserved; no local process needs to wait for the run.

```bash
gh release create v1.2.3 --repo lynnswap/XcodeMCPKit --draft \
  --target <approved-commit-sha> --title v1.2.3 \
  --notes-file /path/to/release-notes.md
gh workflow run release.yml --repo lynnswap/XcodeMCPKit --ref main -f version=v1.2.3
```

For a prerelease, add `--prerelease` when creating the draft. The workflow retains
that setting. An existing draft prepared in GitHub can target `main`; the first
job pins it to the workflow's full commit SHA. A draft already targeting a SHA
must match the workflow commit. Creating or editing a draft does not start the
workflow; dispatch it once with the draft's tag.

The workflow runs package tests and the process/STDIO adapter suites, builds the
arm64 archive, and verifies checksums, archive contents, and generated installer
contents. The publish job downloads the build's artifact by ID, checks it against
the build's archive digest, uploads the three assets, and verifies their uploaded
digests before publishing. It creates any missing tag at the tested commit before
making the draft public. A tag creation conflict or failure stops publication;
an existing tag must point to the tested commit. The target stays fixed even if
`main` advances during the run.

Failures before publication leave the draft available. Rerun failed jobs to reuse
successful builds; uploads replace the draft's assets with the verified files.
If publication fails after tag creation, the tag remains at the tested commit
and is reused on retry.
Remove unrelated draft attachments before retrying publication. Keep the tag,
target commit, and prerelease setting unchanged during a run. Title and note edits
are preserved. If publication succeeded but confirmation failed, rerunning the
publish job verifies the public release's assets and tag without modifying it.

GitHub Releases contain `install.sh`, `xcode-mcp-proxy-darwin-arm64.tar.gz`, and
`SHA256SUMS.txt`. The archive contains both proxy executables and the signed
`bin/XcodeMCPNativeHost.app`. The checksum file covers both the archive and installer.
x86_64 and universal archives are not produced.

`scripts/build-native-host.sh` is the sole owner of native app Info.plist,
selected-Xcode entitlement extraction, and signing. Source installation and
release assembly invoke it rather than duplicate that configuration. Native
packaging has been verified with Xcode 27 / Swift 6.4. The release build job
must select an installation containing the required native service/GUI
contracts; missing contracts fail with diagnostics instead of a version allowlist.

Installers stage on the destination filesystem and verify the app signature
before replacement. Darwin atomic directory swap moves an existing app into
staging; cleanup failure reports the completed install and remaining staging
path. Binary rename and executable permissions retain their install contract.
Archive verification permits only the expected proxy files and signed native
app subtree, including CodeResources. It rejects bundled Apple frameworks and
links. Darwin verifies the app signature; publication also checks the trusted
archive digest on the downloaded artifact.

Release orchestration tests run in CI and locally with:

```bash
python3 -m unittest discover -s scripts/tests -v
```

## Stress Suite

- In-process entry point:
  - `XCODE_MCP_RUN_STRESS_TESTS=1 swift test --no-parallel --filter ProxyStressTests -Xswiftc -strict-concurrency=minimal`
- Purpose:
  - Validate high-volume HTTP/session multiplexing without a live native helper.
- Isolation rules:
  - Opt-in only; excluded from default `swift test`, `scripts/check.sh`, and CI.
  - Uses an in-process HTTP server and fake upstream.
  - Current coverage opens 4 MCP sessions and sends 1,000 parallel `DocumentationSearch` calls per session.

### Running Server Benchmark

- Entry point:
  - `python3 scripts/benchmark-live-server.py --agents 4 --requests-per-agent 100`
- Purpose:
  - Benchmark an already-running `xcode-mcp-proxy-server` with real `DocumentationSearch` calls.
- Isolation rules:
  - Manual-only; excluded from default `swift test`, `scripts/check.sh`, and CI.
  - Resolves the endpoint from `--endpoint`, `XCODE_MCP_PROXY_ENDPOINT`, discovery file, then `http://localhost:8765/mcp`.
  - Rejects non-loopback endpoints by default; `--allow-non-loopback` is required to benchmark a remote endpoint.
  - Defaults to 4 agents, each represented by one persistent HTTP connection and one MCP session.
  - Each agent sends 100 `DocumentationSearch` requests in a closed loop, then reports throughput and per-request latency percentiles.
  - Deletes benchmark MCP sessions before exit.

## Native live verification

The legacy `ProxyLiveMCPBridgeTests` suite name remains a CI/test identifier.
Its owned-host cases launch the signed native app, verify initialization and the
catalog, and close their helper on EOF. They do not require an existing GUI
process. Use the opt-in environment and explicit test scheme documented by the
suite before starting a live run.

For GUI behavior, use an existing Xcode owner and inspect its native windows,
active scheme, and file results. Do not infer unsaved-buffer behavior from a
headless read. Isolate disposable workspaces under a temporary root and close
only resources created by the run.

## Cleanup Expectations

- Live runs must terminate the dedicated in-process proxy server.
- Live runs must write discovery output only under their temp root.
- Do not rely on the user’s default `~/Library/Caches/XcodeMCPProxy/endpoint.json` during tests.

## Review Checklist

- `stdout` is never used for logging or debug formatting.
- Shared state accessed across callbacks/tasks is either actor-isolated or explicitly synchronized.
- Request parsing is not duplicated on the hot path.
- Bind/start/stop failure paths clean up listeners, timers, and child tasks.
- Canonical initialize/tools cache cannot survive upstream exit/quarantine/eager retry windows.
- New feature code does not add tool-specific branching to forwarding when a dedicated helper/workflow can own it instead.
