# XcodeMCPProxyKit public API surface audit (read-only evidence)

## 1. Census (confirmed)

Public declarations exist ONLY in the 7 top-level files of `Sources/XcodeMCPProxyKit/` (all paths below relative to `/Users/kn/Dev/XcodeMCPKit`):

| File | public decls |
|---|---|
| XcodeMCPProxyServer.swift | 58 |
| XcodeMCPProxyStdioAdapter.swift | 55 |
| XcodeMCPProxyInstaller.swift | 40 |
| XcodeMCPProxyServer+Launch.swift | 29 |
| XcodeMCPProxyServer+PortDiagnostics.swift | 6 |
| XcodeMCPProxyRunners.swift | 3 |
| XcodeMCPProxyServer+Startup.swift | 1 |
| **Total** | **~192** (41 type decls + 147 member decls, per `rg 'public (struct|enum|final class|class|protocol|actor)'` = 41 and `rg 'public (func|var|let|init|static)'` = 147) |

**Internal/ false positive**: the `public` hits in `Internal/Session/DocumentationProvider.swift:1540-1591` are inside multi-line string literals that generate `.swiftinterface` shim text for `DVTFoundation`/`IDEIntelligenceChat` (see `dvtInterface(target:)` / `chatInterface(target:)` builders at DocumentationProvider.swift:1534-1596). **No genuine public decls hide under Internal/.** `XcodeMCPProxyConsole.swift` and `XcodeMCPProxyLogging.swift` are `package`-level, not public (XcodeMCPProxyConsole.swift:3, XcodeMCPProxyLogging.swift:3).

41 public types = server family 14 (XcodeMCPProxyServerConfiguration + 10 nested: BindAddress, Upstream, Limits, Discovery, ApprovalPolicy, RefreshCodeIssuesMode, FeaturePolicy, ToolPolicy, InitializeHandshake, ClientInfo; XcodeMCPProxyServer + Endpoint + LifecycleError), launch family 7 (XcodeMCPProxyProductMetadata; server LaunchAction/LaunchOptions/LaunchPlan/LaunchResolutionError+Presentation; PortInUseError), adapter family 12 (ResolutionOptions, AdapterEndpoint+Source, Resolver+Error, AdapterConfiguration, StdioAdapter + its LaunchAction/LaunchOptions/LaunchPlan/LaunchResolutionError+Presentation), installer family 8 (Configuration, Installer, LaunchAction, LaunchOptions, LaunchPlan, Binary, InstallPlan, Error).

## 2. Consumer-reachability classification (confirmed)

The repo's own executables are genuinely thin shells that consume **only** the three `run(arguments:environment:stdout:stderr:)` facades plus two `package` helpers:
- `Sources/XcodeMCPProxyCLI/XcodeMCPProxyCLI.swift` (19 lines): `XcodeMCPProxyLogging.bootstrap` (package) + `XcodeMCPProxyStdioAdapter.run` + `XcodeMCPProxyConsole.writeStandardErrorLine` (package).
- `Sources/XcodeMCPProxyServer/XcodeMCPProxyServer.swift` (21 lines): `XcodeMCPProxyServer.bootstrapLogging` (package, Launch.swift:267) + `XcodeMCPProxyServer.run`.
- `Sources/XcodeMCPProxyInstall/main.swift` (12 lines): `XcodeMCPProxyInstaller.run`.
- `Sources/XcodeMCPProxyToolVerifier/main.swift` imports only `XcodeMCPKit`, not the proxy kit (main.swift:1-2).

Story mapping of the ~192 public decls:
- **(a) embedder hosting the proxy**: XcodeMCPProxyServer.swift 58 decls + Startup 1 + adapter-embedding subset of StdioAdapter.swift (endpoint resolver/options/endpoint/config/lifecycle, ~33 decls) ≈ **48%**. Real story, documented in Sources/XcodeMCPProxyKit/README.md:29-118, and pinned by external-consumer compile tests (Tests/PublicProductContractTests/PublicProductContractTests.swift:872-975 build a scratch package importing only the products).
- **(b) custom launcher CLI**: Launch.swift 29 + PortDiagnostics 6 + Runners 3 + adapter launch-plan subset ~22 + installer 40 ≈ **80 decls ≈ 42%** of the surface. In-repo, nothing consumes this except tests and the internal `Launcher`s that back `run()`.
- **(c) only this repo's executables**: strictly, only the 3 `run()` facades (XcodeMCPProxyRunners.swift:20,52,82). But see finding below: the launch-plan surface (b) exists to justify a story that is not actually implementable externally, so in practice (b) collapses toward (c).

## 3. The custom-launcher story is public-but-incomplete (confirmed, key finding)

Sources/XcodeMCPProxyKit/README.md:24-27 sells "a custom launcher needs the same parsing, dry-run, force-restart, and version behavior as the bundled executables". A launcher built from public API cannot deliver that:
- `LaunchOptions.forceRestart` is public (Launch.swift:57), but the terminate/detect capability is not: `Launcher` is `package` (XcodeMCPProxyServer+Launcher.swift:7), `ExistingServerController` is internal (XcodeMCPProxyServer+ExistingServerController.swift:9), `ExistingProxyServerProcessController` is under Internal/.
- `PortInUseError` is public (PortDiagnostics.swift:6) but the detection predicate `isAddressAlreadyInUse` is `package` (PortDiagnostics.swift:53) and `detectExistingServerProcessIDs` is package/internal — an external launcher can construct the diagnostic but can never detect the condition or fill `processIdentifiers`.
- Logging parity is package-only: `XcodeMCPProxyServer.bootstrapLogging` (Launch.swift:267) and `XcodeMCPProxyLogging` (XcodeMCPProxyLogging.swift:3) are `package`; `ProxyLogging.bootstrap` (env `MCP_LOG_LEVEL`/`LOG_LEVEL` parsing, Internal/Session/Support/ProxyLogging.swift:11-28,38-46) is internal.

So the ~80-decl launch-plan surface is simultaneously (i) unused by the repo's own executables (they call `run()`), and (ii) insufficient for the external story it documents. Either `run()` is the contract and the plan machinery should shrink, or the plan machinery is the contract and force-restart/port-detection/logging must be public. This is the quantified file-bucket/target-boundary smell: **~42% of the public surface is CLI-facade machinery whose only complete consumer is the package-internal Launcher**.

## 4. LaunchPlan modeling defect (confirmed)

All three `LaunchPlan`s flatten action-dependent payload into optionals: server `configuration: XcodeMCPProxyServerConfiguration?` (Launch.swift:74), adapter `configuration?`/`endpoint?` (StdioAdapter.swift:223,226), installer `configuration?` (Installer.swift:58). Consequences, all in-repo:
- The repo's own launchers each carry a synthetic can't-happen guard: "server launch plan is missing configuration" (Launcher.swift:98-103), "adapter launch plan is missing endpoint" (StdioAdapter.swift:777-779), "installer launch plan is missing configuration" (Installer.swift:462-465). Three copies of defensive handling for a state the type system created.
- The package README itself demonstrates the force-unwrap: `XcodeMCPProxyServer(configuration: plan.configuration!)` at Sources/XcodeMCPProxyKit/README.md:139.
Fix hypothesis (marked as hypothesis): `LaunchAction` with associated values (`case start(XcodeMCPProxyServerConfiguration)`), eliminating the optionals and the three guards.

## 5. Triplicated launch-plan family (confirmed duplication signal)

Three parallel `LaunchAction`/`LaunchOptions`/`LaunchPlan`/`LaunchResolutionError` families with near-identical shape (Launch.swift:34-131, StdioAdapter.swift:190-283, Installer.swift:29-83). Duplicated private helpers: `executableName(arguments:defaultExecutableName:)` exists 4x (Launch.swift:22-29 in ProductMetadata, Launch.swift:359-366, StdioAdapter.swift:659-666, Installer.swift:394-401); `nonEmpty` 2x (Launch.swift:347, StdioAdapter.swift:160). `LaunchResolutionError.Presentation` differs per family (`conciseUsageHint|fullUsage` vs `plain|fullUsage|serverOnlyFlagHint`) — same concept, incompatible types. Git history shows this surface accreted through repeated absorb/refactor commits (d820b13b, bbf04c69, d9cd50e5, ac68bb1f, 5ad600bd).

## 6. Dead / contradictory public API (confirmed)

- `XcodeMCPProxyStdioAdapter.rewriteURLFlagToStdio` (StdioAdapter.swift:420-481): zero production call sites; only Tests/ProxyCLITests/StdioAdapterRunnerTests.swift:35 and Tests/PublicProductContractTests/PublicProductContractTests.swift:1007. Its doc calls `--url` "legacy" while `adapterUsage()` documents `--url` and never mentions `--stdio` (StdioAdapter.swift:385-409); `parseLaunchOptions` accepts both and `resolveLaunchPlan` errors when both are given (StdioAdapter.swift:537-541). The public helper converts a documented flag into an undocumented one.
- `--request-timeout` with a non-numeric value is silently ignored, keeping default 300 (StdioAdapter.swift:589-591) — fail-fast violation in public CLI parsing.
- Adapter display plans hardcode `requestTimeout: 300` in `LaunchOptions` regardless of argv (StdioAdapter.swift:489-495) — cosmetic inconsistency.

## 7. Embedder story quality (mixed)

Good (confirmed):
- Configuration ergonomics: all nested types have full-default `init`s and `.default` statics (Server.swift:24,89,106,144,166,206); `XcodeMCPProxyServerConfiguration()` works zero-arg (Server.swift:264-274); every README example was checked against real signatures and matches (README.md:37-43 vs Server.swift:264; README.md:87-100 vs Server.swift:264 + MCPJSONValue literal conformances at Sources/XcodeMCPKit/MCPJSONValue.swift:129-171; README.md:182-187 vs StdioAdapter.swift:337; README.md:211-217 vs Installer.swift:15,154). No signature drift found.
- One-shot lifecycle is explicit and documented: `LifecycleError.alreadyStarted` doc says create a new instance (Server.swift:386-390); README.md:117-118 repeats it. Comparable to Apple's NWListener one-shot start/cancel pattern; acceptable.
- Contract tests compile the public surface from an out-of-package consumer (PublicProductContractTests.swift:872-1080) — strong practice.

Gaps (confirmed):
- **No observability hooks.** Upstream health (`Upstream.HealthState`, Internal/RuntimeCore/Bridge/UpstreamHealthState.swift:5-10), the rich per-upstream debug snapshot (Internal/Session/Session/ProxyDebugSnapshot.swift:38-60: healthState, consecutiveRequestTimeouts, recentStderr, protocol violations...), and session registry are internal; the only access is the proxy's own HTTP endpoints `GET /health`, `GET /debug/upstreams`, `POST /debug/reset` (Internal/HTTPGateway/HTTP/HTTPRoute.swift:14-18). An embedder must poll its own server over HTTP. No delegate, no AsyncStream of events, no metrics.
- **Logger not injectable.** `logger = ProxyLogging.make("server")` hardcoded (Server.swift:475); label prefix "XcodeMCPProxy" fixed (ProxyLogging.swift:7). Only global swift-log bootstrap reaches it.
- **Discovery write failure is swallowed** into a warning log (Server.swift:658-666); `startAndWriteDiscovery()` cannot report it to the embedder.
- **EventLoopGroup created in `init`** (Server.swift:500) with no `deinit`; a constructed-but-never-started server leaks its NIO thread unless `shutdown()` is called.
- **`start()` is synchronous and blocks on NIO `.wait()`** (Server.swift:613,619,626,634 via Startup.swift:14) — no `async` variant for a library whose README quickstart is async code.
- `Upstream` case parameters (`processesPerXcode`, `sessionID`) are undocumented (Server.swift:38-46); `configurationFilePath` is `String?` while `Discovery.fileURL` is `URL?` (Server.swift:228 vs 103) — inconsistent path typing in one struct.

## 8. Installer as public library API (confirmed smell)

`XcodeMCPProxyInstaller` (40 decls, ~21% of surface) is a source-install flow: it locates binaries next to the running executable, walks up to find `.build` to detect the repo root, and shells `swift build` via `ProxyProductBuilder` (Installer.swift:273-350,375-392). Its only production consumer is the 12-line `xcode-mcp-proxy-install` main. This is CLI plumbing living in the embeddable library product purely so the executable can be thin — the clearest target-boundary/file-bucket instance in the surface. Docs/maintainer-architecture.md:33 openly describes the target as owning "public proxy facades, CLI composition, installer helpers, and HTTP gateway internals" — i.e., the bucket is documented, not accidental.

## Speculation (explicitly not confirmed)
- Whether any external consumer of the launch-plan API exists outside this repo was not verifiable from the repo; the classification of (b) collapsing into (c) rests on the confirmed package-only gaps in section 3, not on observed consumers.
- The fix directions in findings are hypotheses; no design decision has been validated against maintainer intent beyond Docs/maintainer-architecture.md:33-37.

# CANDIDATE FINDINGS

## [high] ~42% of public surface is CLI launch-plan machinery not usable end-to-end by external consumers and unused by the repo's own executables (module-boundary)
EVIDENCE: Launch-plan families total ~80 of ~192 public decls (Launch.swift:34-131,148-262; StdioAdapter.swift:190-283,484-572; Installer.swift:29-228; PortDiagnostics.swift:6-51; Runners.swift:20-94). Repo executables consume only run() facades (Sources/XcodeMCPProxyCLI/XcodeMCPProxyCLI.swift:8, Sources/XcodeMCPProxyServer/XcodeMCPProxyServer.swift:10, Sources/XcodeMCPProxyInstall/main.swift:4). External launchers cannot implement forceRestart or port-in-use detection: Launcher is package (XcodeMCPProxyServer+Launcher.swift:7), ExistingServerController internal (XcodeMCPProxyServer+ExistingServerController.swift:9), isAddressAlreadyInUse package (XcodeMCPProxyServer+PortDiagnostics.swift:53), logging bootstrap package (XcodeMCPProxyServer+Launch.swift:267). README sells the story anyway (Sources/XcodeMCPProxyKit/README.md:24-27).
DIRECTION: Hypothesis: pick one contract — either run() is the launcher API (demote resolveLaunchPlan/LaunchPlan families to package) or launch plans are the API (make force-restart, port detection, and logging bootstrap public). Current split is two half-stories.

## [high] LaunchPlan optional-payload modeling forces force-unwraps and three synthetic can't-happen guards (kit-api)
EVIDENCE: configuration is Optional on all three LaunchPlans (Launch.swift:74, StdioAdapter.swift:223,226, Installer.swift:58). Repo's own launchers guard with synthetic errors: 'server launch plan is missing configuration' (XcodeMCPProxyServer+Launcher.swift:98-103), 'adapter launch plan is missing endpoint' (XcodeMCPProxyStdioAdapter.swift:777-779), 'installer launch plan is missing configuration' (XcodeMCPProxyInstaller.swift:462-465). Package README demonstrates plan.configuration! (Sources/XcodeMCPProxyKit/README.md:139).
DIRECTION: Hypothesis: move payload into LaunchAction associated values (case start(XcodeMCPProxyServerConfiguration)), deleting the optionals and all three guards.

## [medium] Installer facade (~21% of public surface) is CLI plumbing living in the embeddable library product (module-boundary)
EVIDENCE: XcodeMCPProxyInstaller = 40 public decls (XcodeMCPProxyInstaller.swift); behavior includes .build-directory repo-root discovery and shelling swift build (Installer.swift:327-331,375-392). Sole production consumer is 12-line Sources/XcodeMCPProxyInstall/main.swift. Docs/maintainer-architecture.md:33 documents the target as a bucket ('public proxy facades, CLI composition, installer helpers, and HTTP gateway internals').
DIRECTION: Hypothesis: installer has no embedder story; move it (or at least its public-ness) into the install executable target or a separate non-product target.

## [medium] Triplicated LaunchAction/LaunchOptions/LaunchPlan/LaunchResolutionError families with 4x-duplicated helpers (kit-api)
EVIDENCE: Parallel families at Launch.swift:34-131, StdioAdapter.swift:190-283, Installer.swift:29-83; executableName helper duplicated 4x (Launch.swift:22-29, Launch.swift:359-366, StdioAdapter.swift:659-666, Installer.swift:394-401); incompatible Presentation enums (Launch.swift:109-115 vs StdioAdapter.swift:258-267). Accreted via absorb refactors (commits d820b13b, bbf04c69, d9cd50e5, ac68bb1f).
DIRECTION: Hypothesis: one generic launch-plan shape (or per-command enums sharing a common error/presentation type) if the launcher story survives finding 1.

## [medium] No embedder observability: upstream health, debug snapshot, and session events are HTTP-only internals (kit-api)
EVIDENCE: Upstream.HealthState internal (Internal/RuntimeCore/Bridge/UpstreamHealthState.swift:5-10); rich per-upstream snapshot internal (Internal/Session/Session/ProxyDebugSnapshot.swift:38-60); only exposure is GET /health, GET /debug/upstreams, POST /debug/reset (Internal/HTTPGateway/HTTP/HTTPRoute.swift:14-18). Logger hardcoded, not injectable (XcodeMCPProxyServer.swift:475; ProxyLogging.swift:7). Discovery-file write failure only logged (XcodeMCPProxyServer.swift:658-666).
DIRECTION: Hypothesis: if embedding is the primary story, expose a typed health/endpoint snapshot or event stream on XcodeMCPProxyServer; at minimum make discovery write failure observable.

## [low] rewriteURLFlagToStdio is dead public API and contradicts documented CLI usage (kit-api)
EVIDENCE: Only call sites are tests (Tests/ProxyCLITests/StdioAdapterRunnerTests.swift:35, Tests/PublicProductContractTests/PublicProductContractTests.swift:1007). Doc comment calls --url 'legacy' (XcodeMCPProxyStdioAdapter.swift:419) while adapterUsage documents --url and omits --stdio entirely (StdioAdapter.swift:385-409); resolveLaunchPlan rejects using both (StdioAdapter.swift:537-541).
DIRECTION: Hypothesis: delete the helper (or document --stdio and the migration story); reconcile which flag is canonical.

## [low] XcodeMCPProxyServer acquires an EventLoopGroup in init with no deinit cleanup and only a blocking sync start (proxy-session)
EVIDENCE: MultiThreadedEventLoopGroup created in init (XcodeMCPProxyServer.swift:500); no deinit; only shutdown() releases it (Server.swift:590-600). start()/startAndWriteDiscovery() block on NIO .wait() (Server.swift:613,619,626,634) with no async variant, while README quickstart is async code (Sources/XcodeMCPProxyKit/README.md:45-55).
DIRECTION: Hypothesis: lazy-create the ELG at start, or add deinit assertion/cleanup; consider async start() aligned with Apple session-style APIs.

## [low] Minor public-config inconsistencies: silent --request-timeout parse failure, String vs URL path typing, undocumented Upstream case parameters (kit-api)
EVIDENCE: Non-numeric --request-timeout silently keeps default 300 (XcodeMCPProxyStdioAdapter.swift:589-591); configurationFilePath is String? while Discovery.fileURL is URL? in the same struct (XcodeMCPProxyServer.swift:228 vs 103); Upstream case params processesPerXcode/sessionID have no doc comments (Server.swift:38-46); adapter display LaunchOptions hardcodes requestTimeout 300 (StdioAdapter.swift:489-495).
DIRECTION: Hypothesis: reject invalid timeout values; unify on URL; document sessionID semantics.
