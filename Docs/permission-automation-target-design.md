# Xcode Permission Automation Target Design

## Scope contract

### Outcome

- The proxy server and an in-repository diagnostic command reuse one AX permission-dialog automation owner.
- The diagnostic command never launches `mcpbridge`; it only monitors explicitly supplied Xcode and agent process identities.
- Permission automation tests synchronize on explicit scan/lifecycle boundaries and do not poll with `Task.yield()` or `Task.sleep()`.

### Compatibility

- Keep the existing `XcodeMCPProxyServerConfiguration.ApprovalPolicy` and `--auto-approve` behavior.
- Do not add a public Swift library product. The extracted module is package-internal and changes in lockstep with the proxy.
- Add one maintainer executable product. It is not added to the release installer.

### Non-goals

- The extraction is not the fix for route activation abandoning a permission-gated `tools/list` request after the control-plane timeout. That runtime invariant remains owned by `ProcessControlPlaneAuthority` and is fixed and tested separately.
- Do not introduce a second process inventory inside the proxy. The proxy continues to use `XcodeProcessEventMonitor` as its only running-application source of truth.
- Do not make the diagnostic command a generic command runner or a direct `mcpbridge` launcher.

## Phase 1 findings

1. `XcodeMCPProxyKit` currently owns 1,235 lines of AX access, dialog snapshots, matching, and polling in four files. The 70-line `PermissionDialogExecutableResolver` is proxy configuration composition and has a different owner.
2. The AX implementation imports AppKit and ApplicationServices, but its live dependency assembly also imports `XcodeMCPProxyRuntime` only for proxy logging and `XcodeMCPKit` for clock/dependency helpers. Those imports prevent independent reuse even though the dialog matcher has no runtime or MCP protocol dependency.
3. `XcodePermissionDialog.AutoApprover` is the second-largest source file in `XcodeMCPProxyKit` at 568 lines. Poll scheduling, one-cycle scanning, match policy, retry suppression, lifecycle, AX I/O, and proxy-specific live assembly are combined.
4. The proxy already has the correct process-inventory owner: `XcodeProcessEventMonitor` publishes cached Xcode/helper PIDs through `ProxyRuntimeInventorySnapshot`. The extracted target should consume a PID provider instead of discovering processes.
5. The AutoApprover tests live in `ProxyIntegrationTests` and two lifecycle tests wait by repeatedly calling `Task.sleep`. This does not provide a deterministic completion boundary.
6. The original failing run shows Xcode 27 initialized but never cataloged, no auto-approval log for its PID, and repeated catalog timeouts. A later normal-proxy reproduction auto-approved both Xcode 26.6 and 27.0 dialogs and cataloged both routes in under 500 ms. This proves the AX path can handle both processes, but the original info-level log cannot determine why the Xcode 27 dialog was missed in that run.

## Target graph

Recommended topology: one package-internal platform adapter target plus one maintainer executable consumer.

```text
XcodeMCPProxyKit --------------------> XcodeMCPPermissionAutomation ----> Logging
       |                                          ^
       v                                          |
XcodeMCPProxyRuntime               XcodeMCPPermissionApproverTool
       |
       v
  XcodeMCPKit
```

- `XcodeMCPPermissionAutomation`: inspects, matches, and approves Xcode MCP permission dialogs through macOS AX.
- `XcodeMCPProxyKit`: composes proxy configuration, runtime inventory, executable candidates, logging, and the automation lifecycle.
- `XcodeMCPPermissionApproverTool`: monitors only caller-supplied Xcode PIDs and agent identity candidates for diagnostics; it does not launch an MCP bridge.
- `XcodeMCPProxyRuntime`: remains the proxy's only running-Xcode/helper inventory owner.

This is an internal target rather than a separate package because all consumers ship from this repository with one version and compatibility baseline. It is not a library product because no external Swift consumer story exists.

## Owner map

| Concern | Owner after migration |
| --- | --- |
| Running Xcode/helper membership in the proxy | `XcodeProcessEventMonitor` |
| Proxy upstream executable/name/PID candidate composition | `XcodeMCPProxyKit` composition root |
| AX authorization and window/button I/O | `XcodeMCPPermissionAutomation.AXClient` |
| Dialog structural and ownership match policy | `XcodeMCPPermissionAutomation.Matcher` |
| One scan's match, retry suppression, press, and diagnostics | `XcodeMCPPermissionAutomation.Scanner` |
| Per-process poll task lifecycle | `XcodeMCPPermissionAutomation.AutoApprover` |
| Diagnostic CLI argument validation and signals | `XcodeMCPPermissionApproverTool` |
| Route activation/catalog deadline | `ProcessControlPlaneAuthority` / runtime activation |

## Package API sketch

The module has package visibility only. AX snapshots, matcher details, scanner state, and fake dependencies remain internal to the target and its tests.

```swift
package enum XcodePermissionDialogAutomation {
    package static func isAllowedProcessBundleIdentifier(_ identifier: String?) -> Bool

    package struct Configuration: Sendable {
        package init(
            permissionDialogProcessIDs: @escaping @Sendable () -> [pid_t],
            agentPathCandidates: @escaping @Sendable () -> Set<String>,
            assistantNameCandidates: @escaping @Sendable () -> Set<String>,
            agentProcessIDCandidates: @escaping @Sendable () -> Set<pid_t>,
            pollInterval: Duration = .milliseconds(250)
        )
    }

    package final class AutoApprover: @unchecked Sendable {
        package init(configuration: Configuration, logger: Logger)

        package func start()
        package func shutdown() async
        package func cancel()

        package static func executablePathCandidates(
            arguments: [String] = CommandLine.arguments,
            executableURL: URL? = Bundle.main.executableURL,
            additional: [String] = []
        ) -> Set<String>

        package static func descendantProcessIDCandidates(
            of processID: pid_t = ProcessInfo.processInfo.processIdentifier
        ) -> Set<pid_t>
    }
}
```

`start()` is idempotent and one-shot. `shutdown()` is the graceful completion boundary and awaits the poll task. `cancel()` is the synchronous unwinding/deinitialization backstop.

`AutoApprover` reconciles the caller-owned process inventory and gives every Xcode/helper PID an independent scanner task. A slow or temporarily unresponsive AX call for one helper must not delay approval of a dialog owned by another Xcode or helper process. Authorization prompting and monitoring-log state are shared across those scanners; retry suppression and window evidence remain process-local.

Cancellation does not interrupt a synchronous AX call. The supervisor therefore retains a removed PID's monitor until that task has actually finished and does not create a replacement for a re-added PID in the meantime. This keeps the one-scanner-per-PID invariant across transient inventory snapshots.

The internal designated initializer accepts the AX client and clock used by target-local tests. The package initializer always constructs the live AX client and live clock, so proxy and CLI consumers cannot accidentally install test behavior.

## Consumer usage

### Proxy composition

```swift
let approver = XcodePermissionDialogAutomation.AutoApprover(
    configuration: .init(
        permissionDialogProcessIDs: {
            runtime.inventorySnapshot().permissionDialogProcessIDs
        },
        agentPathCandidates: { proxyExecutableCandidates(config, runtime) },
        assistantNameCandidates: { assistantNames(config) },
        agentProcessIDCandidates: {
            XcodePermissionDialogAutomation.AutoApprover
                .descendantProcessIDCandidates()
        }
    ),
    logger: ProxyLogging.make("xcode.permission")
)
```

### Diagnostic command

```text
swift run xcode-mcp-permission-approver \
  --xcode-pid 3675 \
  --xcode-pid 9844 \
  --agent-pid 12000 \
  --agent-path /path/to/xcode-mcp-proxy-server \
  --assistant-name XcodeMCPKit
```

The command requires at least one Xcode PID and one exact agent identity candidate. It monitors until interrupted and performs no process launch. Supplying a PID that is not a live allowed Xcode/helper process fails fast.

The diagnostic snapshots each explicit process's PID and launch time at startup. Every poll accepts only that exact live identity, so an exited process is removed and a later process that reuses the same PID is never treated as caller-authorized. SIGINT and SIGTERM send cancellation without awaiting synchronous AX inspection because process termination is the diagnostic command's completion boundary.

## Access-control plan

Package declarations are limited to:

- `XcodePermissionDialogAutomation`
- `isAllowedProcessBundleIdentifier(_:)`, used by the diagnostic command to
  apply the same Xcode/helper allowlist as the matcher
- `Configuration` and its initializer
- `AutoApprover`, its live initializer, lifecycle methods, and the two candidate helpers

All AX elements, snapshots, errors, matching evidence, scanner operations, clock seams, and retry state remain `internal`. There are no new `public` or `open` declarations in the library target.

## Variation axes

| Axis | Single absorption point | Variant-addition check |
| --- | --- | --- |
| Proxy vs diagnostic candidate sources | `Configuration` providers at each composition root | Change only the consumer composition |
| Live vs deterministic AX I/O | Internal AX client dependency | Add one fake implementation in target tests |
| Live vs deterministic polling time | Internal clock dependency | Supply `TestClock`; production code is unchanged |
| Dialog copy/version differences | `Matcher` | Add one matcher case and fixture |
| Xcode/helper process membership | Caller-owned PID provider | Proxy changes only `XcodeProcessEventMonitor`; tool changes only CLI validation |

## Deletions and moves

- Move `PermissionDialogAXClient.swift`, `PermissionDialogMatcher.swift`, `PermissionDialogSnapshot.swift`, and `XcodePermissionDialogAutoApprover.swift` out of `XcodeMCPProxyKit`.
- Keep `PermissionDialogExecutableResolver.swift` in `XcodeMCPProxyKit` because it owns `ProxyConfig`, `ExecutableLookupClient`, and `XcrunArguments` composition.
- Remove `XcodeMCPProxyRuntime` and `XcodeMCPKit` imports from the automation implementation.
- Move permission automation tests out of `ProxyIntegrationTests` into `XcodeMCPPermissionAutomationTests`.
- Delete wall-clock polling loops from those tests.
- Replace the synchronous `stop()`-only lifecycle with awaited `shutdown()` plus synchronous `cancel()` unwinding.

## Avoided shapes

- `XcodeMCPPermissionAutomation` must not import `XcodeMCPProxyKit` or `XcodeMCPProxyRuntime`.
- The new target must not create an `NSWorkspace` process inventory; the proxy supplies its cached snapshot and the diagnostic tool supplies validated explicit PIDs.
- `PermissionDialogExecutableResolver` must not move into the new target with `ProxyConfig` dependencies.
- The diagnostic executable must not launch arbitrary commands or `mcpbridge`.
- Tests must not expose a production test hook and must not wait by cycling `Task.yield()` or `Task.sleep()`.
- The target must not become a public library product until an external Swift consumer exists.

## Test plan

- Matcher unit tests remain synchronous fixture-to-decision tests.
- Scanner unit tests invoke exactly one scan and assert its result directly, including a two-Xcode fixture where both matching dialogs are approved in one scan.
- AX failure classification and retry suppression are tested by explicit scanner inputs and a fake monotonic clock.
- Poll lifecycle tests use `TestClock.sleep(untilSuspendedBy:)`, then await `shutdown()`. There is no scheduler-yield or wall-clock polling loop.
- A blocking fake helper AX client proves that another Xcode PID is approved while the helper inspection remains blocked.
- A remove/re-add fixture proves that a cancelled but AX-blocked PID monitor is not overlapped by a replacement.
- Proxy integration tests keep a recording approver at the composition boundary and verify start/shutdown/cancel ownership.
- Diagnostic CLI tests validate required exact PIDs/identity candidates and verify that no child process is launched.
- Diagnostic CLI tests verify that exited and PID-reused explicit identities are excluded.
- An empty process inventory still requests Accessibility authorization immediately when automation starts.
- Run `swift test -Xswiftc -strict-concurrency=minimal`, process suites, `scripts/check.sh`, and `codex-review`.
- Run one freshly built normal proxy on an alternate port with Xcode 26.6 and 27.0 open and `--auto-approve`; verify both PIDs reach `route_activation_cataloged`. Do not run `mcpbridge` directly.

## Finding-to-design mapping

| Finding | Design response |
| --- | --- |
| 1 | Four AX/automation files move to the dedicated target; the proxy resolver stays put |
| 2 | The target accepts logger/clock/candidate inputs and has no proxy-runtime or MCP-core import |
| 3 | Scanner and lifecycle owners split the combined implementation |
| 4 | Configuration consumes the runtime's cached PID provider |
| 5 | Dedicated target tests use direct scan results and `TestClock` suspension boundaries |
| 6 | Add the two-Xcode scan contract and a separate runtime activation-timeout regression |

## Design gate

Implementation starts only after this target graph, package-only surface, maintainer-tool scope, and separate runtime-timeout fix are approved.
