# Module/Package Boundary Audit — Evidence Report

## 1. Package.swift targets vs Sources/ directories

**Confirmed at correction HEAD `eab7260d`:** 8 dirs under `Sources/`; all 8 are referenced by targets (XcodeMCPKit Package.swift:53-63, XcodeMCPKitTesting :64-72, XcodeMCPProxyKit :73-89 default path, XcodeMCPProxyCLI :124-130, XcodeMCPProxyServer :131-135, XcodeMCPProxyInstall :136-140, XcodeMCPProxyToolVerifier :141-146, ProxyBuildInfoTool :147-150).

**Correction:** the initial collection reported an untracked empty `Sources/XcodeMCPProxyRuntime/` directory, but it is absent at the correction HEAD and an empty directory cannot be represented in Git. It is therefore neither a repository finding nor a cleanup task. The historical target itself is confirmed: commit 6f5cfd7e created `XcodeMCPProxyRuntime` with 14 files; dc5041e5 moved them into `Sources/XcodeMCPProxyKit/Internal/RuntimeCore/` and removed the target 2h13m later.

**Target-structure churn timeline (all 2026-06-28, one day):**
- 08:38 9f1d091e: split proxy test targets (ProxyContractTests/ProxySessionTests → RuntimeCoordinator/DocumentationProvider/ToolSurface/StartupLogging tests; +XcodeMCPProxyRuntimeTestSupport)
- 08:55 6f5cfd7e: split `XcodeMCPRuntime` → `XcodeMCPCore` + `XcodeMCPProcessRuntime` + `XcodeMCPClientRuntime` + `XcodeMCPProxyRuntime` (4 internal targets)
- 11:08 dc5041e5: absorb `XcodeMCPProxyRuntime` back into XcodeMCPProxyKit (**target lived 2h13m**)
- 13:26 1e7edcda: rename test/support targets to owner names
- 23:27 cb33e4d0 ("fix(package): seal public product target boundaries"): absorb `XcodeMCPCore`/`XcodeMCPProcessRuntime` into `XcodeMCPKit`. Internal-target split fully reverted within ~15h; final mechanism is `package` access + contract tests. The former targets survive as directories `Sources/XcodeMCPKit/Internal/{ClientRuntime,CoreRuntime,ProcessRuntime}` (find output).

**Stale contract-test residue (confirmed):** `Tests/PublicProductContractTests/PublicProductContractTests.swift:588-592` still checks that a scratch client package fails to `import XcodeMCPCore` / `import XcodeMCPProcessRuntime` — module names that ceased to exist at cb33e4d0. These import-failure assertions are now trivially green (no module by that name exists anywhere) and no longer test the boundary. The only check still exercising the real invariant is `runtimeHelperLeakCheck` (same file, :594-600), which asserts `MCP` is "inaccessible due to 'package' protection level". The test spawns nested `swift build` on generated packages (:252-260, SpawnedProcessGroup :375+).

## 2. Access-level audit (`package` declarations)

**Counts (rg over decl keywords):**
- raw keyword lines matching `^\s*package\b`: XcodeMCPKit **385**, XcodeMCPProxyKit **121**, XcodeMCPKitTesting **9**, all executables 0.
- actual keyword lines matching `^\s*public\b`: XcodeMCPKit **70**, XcodeMCPProxyKit **191**, XcodeMCPKitTesting **39**. ProxyKit has 215 raw hits, of which 24 are string-literal false positives described below.
- XcodeMCPKit's public **type** surface is only 10 names: Bridge, MCPContent, MCPJSONValue, MCPProgress, MCPTool, MCPToolResult, Transport, XcodeMCP, XcodeMCPConfiguration, XcodeMCPError.
- XcodeMCPKit's `package` **type declaration** count is86 using `^\s*package\s+(?:(?:final\s+)?class|actor|enum|protocol|struct|typealias)\b`: 85 under `Sources/XcodeMCPKit/Internal/` plus nested `XcodeMCPConfiguration.Transport.Storage` at `Sources/XcodeMCPKit/XcodeMCP.swift:55`.

**Cross-target consumption (confirmed):** 79 of 114 ProxyKit .swift files `import XcodeMCPKit`. Of the 86 package type names, ~60 appear in ProxyKit source. Verified concrete usages:
- `ClockClient` — Sources/XcodeMCPProxyKit/Stdio/StdioAdapter.swift:9,15,39 (35 refs total)
- `StdioFramer` — StdioAdapter.swift:59; Internal/Session/Runtime/RuntimeCoordinator+UpstreamRouting.swift:1049
- `JSONRPC.*` — StdioAdapter.swift:221-222,376-380 (226 refs)
- `JSONValue` — Internal/Session/Runtime/RuntimeCoordinator.swift:137-139 (176 refs)
- `UpstreamSession` — Internal/Session/DocumentationProvider.swift:485,501,1968
- No redeclarations of JSONRPC/JSONValue exist in ProxyKit (rg: 0 hits), confirming these are Kit's types.

**Verdict on the smell test:** ProxyKit's real dependency surface on the SDK target is overwhelmingly the `package` layer, not the 10-type public API. High-usage decls that would break on a package split (distinctive names, false-positive-safe): JSONRPC, JSONValue, ClockClient, Deadline, RuntimeScheduledTimeout, MethodDispatcher, UpstreamSession/UpstreamSessionFactory, UpstreamReadinessGate, UpstreamSlotControlling, StdioFramer, ProcessRunner, ProcessControlClient, StreamableHTTPMCPClient(+Error/SendResult/MessageDisposition), SSECodec, AsyncTaskSupervisor, MCPBridgeInvocation, MCPBridgeRuntimeError, MCPProtocolVersion, XcrunArguments, Discovery/DiscoveryRecord, FileSystemClient, ExecutableLookupClient, DependencyClient, RequestInspector, UpstreamProcess. Caveat (speculation-boundary): counts for generic nested names (ID 151, Wire 78, Message 48, Request, Event, Config, Storage, Number, Envelope) may include ProxyKit's own nested types; treat those numbers as upper bounds.

**However this is documented as intended:** Docs/maintainer-architecture.md:5-9 describes XcodeMCPKit as containing "internal/package-scoped JSON-RPC, stdio framing, timeout dispatch, request inspection, and local process runtime primitives", and PublicProductContractTests exists to prove external clients cannot reach it. Confirmed implication: the two library products are **inseparable at package granularity** — the "SDK library" boundary exists only at product level. Kit is 6,531 lines vs ProxyKit 36,485 lines (wc).

## 3. Re-export / boundary re-binding

**Confirmed:** zero `@_exported` in Sources and Tests (rg: no output). Only 2 `public typealias` in the whole Sources tree, both nested handler types in Sources/XcodeMCPKitTesting/XcodeMCPTestRuntime.swift:119,124. No umbrella re-exports. Note: rg found 24 `public` decl hits under `Sources/XcodeMCPProxyKit/Internal/`, all in one file — DocumentationProvider.swift ~:1535-1591 — and these are **inside multiline string literals** (generated swiftinterface text for DVTFoundation/IDEIntelligenceChat, see `dvtInterface(target:)` at :1535). Not real public API; flag as grep-audit false positive.

## 4. Executable thin-shell check

**Confirmed thin shells:**
- Sources/XcodeMCPProxyCLI/XcodeMCPProxyCLI.swift — 19 lines; bootstraps logging, delegates to `XcodeMCPProxyStdioAdapter.run` (:7-13).
- Sources/XcodeMCPProxyServer/XcodeMCPProxyServer.swift — 21 lines; delegates to `XcodeMCPProxyKit.XcodeMCPProxyServer.run` (:7-15). Note the **name collision**: executable target/module `XcodeMCPProxyServer` shadows ProxyKit's public type `XcodeMCPProxyServer`, forcing module-qualified access at :7 and :10.
- Sources/XcodeMCPProxyInstall/main.swift — 12 lines; delegates to `XcodeMCPProxyInstaller.run` (:4-9).

**Not a thin shell:** Sources/XcodeMCPProxyToolVerifier/main.swift — **1,288 lines** in one file, one `@main` struct containing the entire live-verification harness: builds the debug proxy server (`buildDebugProxyServer` :280), spawns it (:289), opens the fixture in Xcode (:329), constructs per-tool argument tables (`arguments(for:)` :417, ~200 lines), snapshots/restores fixtures (:712,:725), writes report.json (:360). It uses only Kit **public** API (XcodeMCP x4, MCPTool, MCPJSONValue; zero hits for JSONValue/JSONRPC/StreamableHTTPMCPClient) and depends only on XcodeMCPKit (Package.swift:141-146). It is a verification tool, so logic-in-executable is defensible, but it is a single-file bucket.

**Doc inconsistency (confirmed):** Docs/maintainer-architecture.md:37 states "Executable targets depend on `XcodeMCPProxyKit` only" — false for XcodeMCPProxyToolVerifier (depends on XcodeMCPKit, Package.swift:143) and ProxyBuildInfoTool (no deps, Package.swift:147-150).

## 5. Test topology

14 test targets + 3 support targets under Tests/, all mapped in Package.swift (:90-315). File counts: XcodeMCPCoreTests 11, ProxyCLITests 11, ProxyIntegrationTests 8, ProxyHTTPGatewayTests 8, ProxyRuntimeCoordinatorTests 6, XcodeMCPProcessRuntimeTests 5, ProxyToolSurfaceTests 3, ProxyStressTests 2, singles for KitTests/KitTestingTests/PublicProductContract/StdioAdapter/LiveMCPBridge/DocumentationProvider.

**The split carries documented meaning** (not pure accretion): default fast suite vs env-gated process suite (`XCODE_MCP_RUN_PROCESS_TESTS`, maintainer-architecture.md:59-60), opt-in stress (`XCODE_MCP_RUN_STRESS_TESTS`, :87), live mcpbridge (`XCODE_MCP_RUN_LIVE_MCPBRIDGE_TESTS`, :112), and product-boundary contract (PublicProductContractTests). But the per-owner proxy split (RuntimeCoordinator/DocumentationProvider/ToolSurface/HTTPGateway/CLI/Stdio/Integration) dates from the same one-day churn (9f1d091e, 28626543 "split proxy runtime tests by owner", 1e7edcda "align test targets with owners").

**@testable pattern (confirmed counts, files per target):** `@testable import XcodeMCPProxyKit` appears in **40 files across 10 targets**(9 test targets + 1 support target): ProxyCLITests 9, ProxyHTTPGatewayTests 8, ProxyIntegrationTests 8, ProxyRuntimeCoordinatorTests 6, ProxyToolSurfaceTests 3, XcodeMCPProxyInternalTestSupport 2, and 1 each in DocumentationProvider/LiveMCPBridge/StdioAdapter/Stress. `@testable import XcodeMCPKit`: 5 files (ProcessRuntimeTests 3, KitTests 1, RuntimeCoordinatorTests 1). Essentially **every proxy test target reaches ProxyKit internals directly** — the tested contracts (RuntimeCoordinator, HTTPHandler, DocumentationProvider) have no owner-level `package` surface for tests.

**Support-target mechanism is inconsistent (confirmed):**
- XcodeMCPProxyTestSupport (1 file, 646 lines) and XcodeMCPCoreTestSupport (1 file, 498 lines) expose helpers via `package` decls (45 and 25 respectively) — consumed without @testable.
- XcodeMCPProxyInternalTestSupport (2 files, 2,747 lines; RuntimeCoordinatorTestSupport.swift alone 2,584 lines) has **zero** package/public decls; it does `@testable import XcodeMCPProxyKit` internally (2 files) and extends internal type `RuntimeCoordinator` (RuntimeCoordinatorTestSupport.swift:11), and its consumers do `@testable import XcodeMCPProxyInternalTestSupport` (4 occurrences: HTTPGateway 1, DocumentationProvider 1, RuntimeCoordinator 2) — a second-order @testable chain.
- Same-name smell: both AsyncTestSupport.swift files share a name but have disjoint content (Proxy: HTTP test server/gates/TestUptimeClock; Core: TestClock/resource gates/TimeoutRace — diff of symbol lists shows no overlap). Not duplication, but file-bucket naming.

## 6. Tools/mcp_bench.swift, ProxyBuildInfoTool, Plugin

- Tools/mcp_bench.swift: 564-line standalone script (all-private types), referenced by **no** Package.swift target (rg 'Tools|mcp_bench' Package.swift: 0), documented only in Docs/mcp-benchmark.md. Speculation: functionally overlaps scripts/benchmark-live-server.py (maintainer-architecture.md:95-107) — two parallel live-benchmark harnesses.
- Plugins/ProxyBuildInfoPlugin/ProxyBuildInfoPlugin.swift: writes `BuildInfo.generated.swift` into `context.pluginWorkDirectoryURL` (:13) — does **not** write into module sources; clean. Applied only to XcodeMCPProxyKit (Package.swift:86-88).
- Sources/ProxyBuildInfoTool/ProxyBuildInfoTool.swift (158 lines): version resolution order = env `XCODE_MCP_BUILD_VERSION` → `git describe --tags --always --dirty` (:116-127) → "dev" (:96). Structural note: the plugin's `.buildCommand` declares `outputFiles` but **no inputFiles** (plugin :23-29), so SPM has no way to know the git state changed; the tool self-mitigates rebuild churn by content-comparing before writing (:19-23), but a stale version between builds (tag added, no source change) is possible. Build output depends on git working-tree state (`--dirty`).

## Speculation (explicitly not citation-backed)

- The ~60/86 package-type consumption count is an upper bound; a compiler-verified number would require building with the decls demoted.
- The one-day split-then-collapse churn (6f5cfd7e → cb33e4d0) suggests the internal-target experiment was abandoned for `package` access deliberately; the current shape appears stable since 2026-06-28, while the stale PublicProductContractTests entries are unswept residue of that pivot.

# CANDIDATE FINDINGS

## [medium] PublicProductContractTests import checks reference modules that no longer exist (XcodeMCPCore, XcodeMCPProcessRuntime) — assertions are trivially green (module-boundary)
EVIDENCE: Tests/PublicProductContractTests/PublicProductContractTests.swift:588-592 lowLevelImportChecks name 'XcodeMCPCore'/'XcodeMCPProcessRuntime'; those targets were removed in cb33e4d0 'fix(package): seal public product target boundaries'; only runtimeHelperLeakCheck (:594-600, package protection of 'MCP') still tests the live boundary
DIRECTION: Hypothesis: rewrite the contract test to assert the actual invariant (package-level decls inaccessible from product clients) and drop the dead-module import checks

## [medium] XcodeMCPProxyKit consumes XcodeMCPKit almost entirely via its package-level surface (~60 of 86 package types; 79/114 files import Kit) — library products are inseparable below product granularity (module-boundary)
EVIDENCE: raw package keyword lines: Kit 385 vs public 70 (10 public types); verified cross-target uses e.g. ClockClient (ProxyKit Stdio/StdioAdapter.swift:9), StdioFramer (:59), JSONRPC (:221), JSONValue (Internal/Session/Runtime/RuntimeCoordinator.swift:137), UpstreamSession (Internal/Session/DocumentationProvider.swift:485); documented as intended in Docs/maintainer-architecture.md:5-9
DIRECTION: Hypothesis: accept as the deliberate design (package = internal shared surface, sealed by contract tests) and document that the two library products cannot be split into separate packages without promoting ~40-60 types; only define an owner-level surface if a split is actually wanted

## [medium] Proxy test contracts have no owner-level surface: @testable import XcodeMCPProxyKit from 40 files / 10 targets, plus a 2,584-line internal test-support file with a second-order @testable chain and inconsistent support mechanisms (test-topology)
EVIDENCE: @testable counts per target (rg): ProxyCLITests 9, ProxyHTTPGatewayTests 8, ProxyIntegrationTests 8, ProxyRuntimeCoordinatorTests 6, ProxyToolSurfaceTests 3, others 1 each; XcodeMCPProxyInternalTestSupport has zero package/public decls, does @testable import XcodeMCPProxyKit and extends internal RuntimeCoordinator (RuntimeCoordinatorTestSupport.swift:11), while sibling supports (Tests/XcodeMCPProxyTestSupport 45, Tests/XcodeMCPCoreTestSupport 25) use package decls instead
DIRECTION: Hypothesis: give the heavily-tested ProxyKit contracts (RuntimeCoordinator, HTTPHandler, DocumentationProvider) a package-scoped seam consumed by test support without @testable, and unify the two support-target visibility mechanisms

## [low] Doc claim 'Executable targets depend on XcodeMCPProxyKit only' is false for 2 of 5 executable targets (docs)
EVIDENCE: Docs/maintainer-architecture.md:37 vs Package.swift:141-146 (XcodeMCPProxyToolVerifier depends on XcodeMCPKit) and :147-150 (ProxyBuildInfoTool, no deps)
DIRECTION: Hypothesis: correct the doc sentence to name the shipped proxy executables explicitly

## [low] XcodeMCPProxyToolVerifier is a 1,288-line single-file executable containing the entire live-verification harness (executables)
EVIDENCE: Sources/XcodeMCPProxyToolVerifier/main.swift (wc 1288): buildDebugProxyServer :280, startDebugProxyServer :289, openFixtureInXcode :329, per-tool argument tables :417+, fixture snapshot/restore :712/:725; uses only Kit public API (XcodeMCP/MCPTool/MCPJSONValue, zero package-type hits)
DIRECTION: Hypothesis: acceptable as a tool since it stays on public API; if kept, split the file by concern rather than moving logic into libraries

## [low] Executable target XcodeMCPProxyServer shadows ProxyKit public type XcodeMCPProxyServer, forcing module-qualified access (naming)
EVIDENCE: Sources/XcodeMCPProxyServer/XcodeMCPProxyServer.swift:7,10 must write XcodeMCPProxyKit.XcodeMCPProxyServer to disambiguate
DIRECTION: Hypothesis: cosmetic; rename executable module or facade type only if it causes real friction

## [low] ProxyBuildInfoPlugin buildCommand declares no inputFiles while version derives from git state (git describe --dirty) (build-plugin)
EVIDENCE: Plugins/ProxyBuildInfoPlugin/ProxyBuildInfoPlugin.swift:23-29 (outputFiles only); Sources/ProxyBuildInfoTool/ProxyBuildInfoTool.swift:116-127 (git describe), :19-23 (content-compare mitigation); output written to pluginWorkDirectoryURL (:13) — not into module sources, that part is clean
DIRECTION: Hypothesis: stale-version window between builds is possible; evaluate whether release builds always pass XCODE_MCP_BUILD_VERSION (env override at plugin :19-21) making the git path best-effort only
