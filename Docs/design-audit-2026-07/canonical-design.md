# Design Audit 2026-07 — Canonical Remediation Design

- Status: **APPROVED / IMPLEMENTED**
- Approved: 2026-07-10
- Implemented: 2026-07-10
- Approval: ユーザーが破壊的変更を含む全判断を委任。以下を実装契約として採用する。
- Design baseline: 4d60f711f11bd39e93e133afac81f5f1814035a4
- Toolchain: Swift 6.3.3 / language mode 6 / strict memory safety / macOS 15.4+
- Baseline: swift test -Xswiftc -strict-concurrency=minimal — 840 tests / 52 suites passed

このファイルを修正実装の唯一の design source of truth とする。実装結果と現行 owner は [README.md の「実装結果」](README.md#実装結果) および `Docs/architecture.md` / `Docs/maintainer-architecture.md` に記録する。README.md の残りは監査時点の結果、design-contracts.md は候補規範、handoff-prompt.md は発見時点の引き継ぎ資料であり、設計判断が競合する場合は本書を優先する。

## 1. 標準形と consumer story

残す consumer story は次の4つだけとする。

1. XcodeMCPKit で local mcpbridge または Streamable HTTP proxy に接続する app / library。
2. XcodeMCPProxyServer を process 内へ埋め込む host。
3. XcodeMCPProxyStdioAdapter を process 内へ埋め込む host。
4. repo の server / stdio adapter / installer executable。server と adapter は public run() facade も提供する。installer implementation は package/executable 専用とする。

外部 custom launcher、public launch-plan inspection、installer library embedding は supported story にしない。互換 wrapper、deprecated mirror、旧 CLI flag redirect は追加しない。

## 2. Product / target topology

新しい package、product、target は追加しない。

| 境界 | 決定 | 理由 |
|---|---|---|
| XcodeMCPKit | SDK、JSON-RPC client session、共通 transport/session lifecycle authority を所有 | direct SDK と stdio adapter が共有すべき lifecycle は package access で提供でき、独立配布や別 versioning を要しない |
| XcodeMCPProxyKit | HTTP gateway、proxy control plane、server/adapter embedding API を所有 | Task A は同一 deploy unit 内の internal ownership 修正であり、別 target 化しても独立 consumer / dependency direction が生まれない |
| executable targets | argv、process exit、installer composition root を所有 | CLI-only parser/installer surface を library の public contract から外す |
| test-support targets | fake transport、owner snapshot helperだけを所有 | production control flow、mirror state、test-only branch を置かない |

XcodeMCPProxyKit → XcodeMCPKit の既存一方向依存を維持する。SDK は proxy implementation を import しない。

## 3. Target owner graph

| 状態 / I/O | canonical owner | 契約 |
|---|---|---|
| SDK transport recipe、HTTP session identity、recovery、connection state、close | MCPClientSessionAuthority actor | direct SDK と stdio adapter の単一 lifecycle authority |
| JSON-RPC request ID、pending response、progress lane | InitializedMCPClientSession actor | transport/session lifecycle を複製しない |
| proxy route membership、exposure、activation attempt、process catalog、canonical tools projection | ProcessControlPlaneAuthority | catalog validityを共有する状態だけを1つの lock 内で遷移。I/O と cancel は effectとしてlock外で実行 |
| window/tab identity、workspace/tab conflict | WindowOwnershipAuthority | windowEpochだけを所有し、catalog stateを変更しない |
| owner candidates + route exposureの合成 | WindowRoutingResolver（stateless） | 両authorityのimmutable snapshotからcomposite proofを作り、forward前にwindow epochとroute admissionを検証 |
| initialize result / source / incompatibility | CanonicalHandshakeState | catalog/window epoch から独立 |
| shared tools/window load taskとwaiter | ControlPlaneCoordinator actor | semantic stateを書かず、authority ticketを開始・完了へ受け渡す |
| actual upstream slot objects、stable ID、membership/order | UpstreamTopologyAuthority | immutable topology snapshotの単一truth。router/health/schedulerはmembershipを複製しない |
| HTTP request security | HTTPRequestSecurityPolicy | route 解決や副作用より前に全 requestへ適用 |
| server listener/runtime/discovery resource lifecycle | XcodeMCPProxyServer lifecycle state | async start、idempotent async shutdown、sanitized snapshot |
| discovery record | filesystem hint | 接続と標準 initialize handshakeだけが到達性を確定する |

永続化は discovery/config file に限定する。catalog、window ownership、connection state、health は process memory の owner が唯一の source of truth であり、adapter/test support に mirror cache を置かない。

## 4. Task 0 — HTTP security boundary

### 4.1 Policy

HTTPRequestSecurityPolicy を request head の単一入口で実行し、/health、/debug/*、MCP GET/POST/DELETE、未知 route をすべて同じ policy に通す。route別の Origin 免除は削除する。

- Origin がない request は、Origin を送らない URLSession/Codex/stdio 等の non-browser client 互換として許可する。これは仕様の推測ではなく product policy として明記する。
- Origin が存在する場合は1値だけを許可する。空、複数値、null、malformed、userinfo/path/query/fragment付き、非HTTP(S)、許可外host/portを 403 にする。
- scheme/host/port は実際の endpoint と照合する。loopback bind は localhost、IPv4 loopback、IPv6 loopbackを許可し、prefix matchは使わない。wildcard bindを任意DNS originの許可に読み替えない。
- security rejection は session作成、debug reset、cache mutation、upstream sendより前に完了する。
- Host-only policyの追加は本修正へ混ぜない。Origin欠如時のHost許可モデルはLAN/wildcard/ephemeral-portの別設計を要する。

### 4.2 Contract tests

全 route × allowed / missing / malformed / disallowed Origin をtable-drivenで検査する。cross-origin /health、/debug/upstreams?includeSensitive=1、/debug/reset、未知 route が 403、missing Origin が各route本来のstatus、拒否時の副作用ゼロを固定する。

## 5. Task A — proxy control-plane rearchitecture

### 5.1 Isolation owner

XcodeMCPProxyKit 内に次を置く。

~~~swift
final class ProcessControlPlaneAuthority: Sendable {
    private let state: NIOLockedValueBox<State>

    func reconcileRoutes(
        _ observed: [XcodeProcessTarget],
        usability: UpstreamUsabilitySnapshot
    ) -> Transition

    func beginCatalogAttempt(
        routeID: ProcessRouteID,
        preferredUpstream: UpstreamSlotID,
        nowUptimeNanoseconds: UInt64
    ) -> (CatalogLease, Transition)?

    func attach(_ resource: AttemptResource, to lease: CatalogLease) -> Transition

    func completeCatalog(
        _ outcome: CatalogOutcome,
        lease: CatalogLease,
        nowUptimeNanoseconds: UInt64
    ) -> CatalogCommit

    func invalidateCatalog(_ reason: CatalogInvalidationReason) -> Transition
    func routingSnapshot() -> RoutingSnapshot
    func admit(_ proof: RouteProof) -> RouteAdmissionLease?
    func snapshot() -> Snapshot
}
~~~

actor にしない。現在の NIO callback/read path を無意味に async 化せず、withLockedValue 内では同期の純粋 state transition だけを実行する。timeout cancel、RPC cancel、notification、upstream start/stop は Transition.effects として返し、RuntimeCoordinator が lock 外で実行する。

### 5.2 Owned state

State は次を同じ isolation 内で所有する。

- active/retired route identity、target、cooldown、upstream membership
- policy別 exposure と exposureEpoch
- catalogEpoch
- routeごとの catalog attempt ID、phase、deadline/retry/RPC/timeout/waiter resource token
- process catalog、upstream↔process mapping、canonical tools projectionとsource

initialize result/source/incompatibility は CanonicalHandshakeState と initializeEpoch に分離する。actual upstream process/channel object は UpstreamTopologyAuthority が所有し、control-plane stateにはstable slot IDだけを置く。

### 5.3 Catalog transaction

~~~swift
struct CatalogLease: Sendable, Hashable {
    fileprivate let catalogEpoch: CatalogEpoch
    fileprivate let routeID: ProcessRouteID
    fileprivate let attemptID: CatalogAttemptID
    fileprivate let upstreamID: UpstreamSlotID
}

enum CatalogCommit: Sendable {
    case accepted(ProcessControlPlaneAuthority.Snapshot, Transition)
    case discarded(StaleCatalogReason, Transition)
}
~~~

completeCatalog は1回の withLockedValue で次を行う。

1. catalog epoch、current route identity/target/upstream、current attempt/phaseを検証する。
2. usable resultならprocess surfaceを置換する。
3. current exposureからcanonical projectionを同じtransactionで再計算・格納する。
4. attemptをterminal phaseへ進め、付随資源をstateから外す。
5. lock外で実行するcancel/notification effectsを返す。

不一致ならprocess/canonical stateを変更せず discarded にする。内部 stale completion は consumer error に変換せず、同じlogical deadline内でcurrent loadへjoinするかcurrent snapshotを返す。proofなしのcatalog書込APIは存在させない。

route replace/retireは同じtransitionでold leaseを失効し、必要なcatalog削除とcanonical再投影を行う。

### 5.4 Attempt resource lifecycle

attemptのphase遷移だけがtimeout、RPC handle、retry、waiter tokenを登録・取り外す。旧attemptへのresource attachは即invalidate effectを返す。attempt N終了後のcallbackはN+1のstateへ触れず、古いleaseとしてdiscardされる。

RuntimeCoordinatorTestHooks のguard通過順序観測は削除する。testはauthorityのsnapshot、commit outcome、effectsを観測する。

### 5.5 Window ownership composition

WindowOwnershipAuthority はentriesとwindowEpochだけを所有し、record/remove/snapshotを提供する。ProcessControlPlaneAuthority はroute/exposureのRoutingSnapshotを提供する。WindowRoutingResolverは次のimmutable入力だけを合成する。

~~~swift
final class WindowOwnershipAuthority: Sendable {
    func record(processID: pid_t, entries: [XcodeListWindowsEntry]) -> WindowTransition
    func remove(processID: pid_t) -> WindowTransition
    func snapshot() -> WindowOwnershipSnapshot
    func validate(_ epoch: WindowEpoch) -> Bool
}

struct WindowRoutingResolver {
    func resolve(
        _ query: WindowOwnerQuery,
        owners: WindowOwnershipSnapshot,
        routes: ProcessControlPlaneAuthority.RoutingSnapshot
    ) -> WindowRouteResolution
}

struct WindowRouteProof: Sendable {
    let windowEpoch: WindowEpoch
    let route: RouteProof
}
~~~

resolverはworkspace precedence、raw-tab conflict、proxy-tab identity、eligible route filteringを一箇所で決め、WindowRouteProofを返す。forward前にWindowOwnershipAuthority.validate(windowEpoch)を行い、続けてProcessControlPlaneAuthority.admit(routeProof)からRouteAdmissionLeaseを取得する。どちらかがrejectした場合は両snapshotを取り直して解決する。admission後のwindow変更は、既に選んだrequestのsnapshot semanticsを変えず、新しいrequestだけへ反映する。route retire/replaceはRouteAdmissionLeaseのownerがrequest lifecycleと整合させる。window更新はwindowEpochだけを進め、catalogEpoch、catalog attempt、tools waiterを変更しない。

### 5.6 Upstream topology authority

UpstreamTopologyAuthority はstable UpstreamSlotID、actual slot object、membership/order、topologyEpochを1つのlockで所有し、append/replace/retire後のimmutable Snapshotを発行する。router、health manager、scheduler、debug recorderは独自のupstream配列/countを持たず、snapshotのIDをkeyに局所stateだけを持つ。未知/retired IDのeventはtopology proofでrejectする。

~~~swift
final class UpstreamTopologyAuthority: Sendable {
    func append(_ slots: [any UpstreamSlotControlling]) -> Transition
    func replace(_ id: UpstreamSlotID, with slot: any UpstreamSlotControlling) -> Transition
    func retire(_ ids: Set<UpstreamSlotID>) -> Transition
    func snapshot() -> Snapshot
    func validate(_ proof: UpstreamTopologyProof) -> Bool
}
~~~

Transitionは新snapshotを1回publishし、componentsへの逐次membership mutationを含まない。call siteのupstreamsBoxとrouter/health/debugへの3連appendを削除する。exposure readは純粋で、prune/reconcileだけがmutationする。

### 5.7 Task A deletion list

- mutable ProcessRouteStore
- mutable ProcessRouteReadinessStore
- mutable ProcessToolSurfaceStore（JSON parsing/fingerprintはstateless codecとして残してよい）
- mutable WindowOwnerIndex とcall-site eligibility/conflict logic（entriesはWindowOwnershipAuthority、合成はWindowRoutingResolverへ移す）
- CanonicalBrokerState のtools catalog、source、共用generation、sync/clear API
- processToolSurfaceMutationLock
- recordAvailableToolsCatalog の直列5段guardとretryの6条件guard
- generation/lease/attemptのcall-site再確認 helper
- availableToolsCatalogRefreshKeys
- ControlPlaneCoordinator のtools/window共用generationとcancelLoadsStartedBeforeGeneration
- setCachedToolsListResult と MCPForwardingService.cacheableAsCanonical dead path
- guard sequencing専用test hooks/tests
- upstreamsBox、index countのmirror、router/health/debugへの手動topology append

## 6. Task B — lifecycle / protocol / observability

### 6.1 Shared client-session authority

新targetを作らず、XcodeMCPKit/Internal/ClientRuntime/MCPClientSessionAuthority.swift に package actor MCPClientSessionAuthority を置く。XcodeMCPProxyKit のstdio adapterはpackage accessで同じownerをcomposeする。

authorityだけがtransport factory/recipe、initialize context、connection identity/generation、HTTP session ID、SSE lifecycle、single-flight recovery、connection state subscribers、close task/reasonを所有する。

InitializedMCPClientSession はrequest ID、response correlation、request-scoped progress laneだけを所有する。StdioAdapter はframing/input/outputだけを所有し、HTTP session ID、recovery task、initialize taskを持たない。

### 6.2 Package operation boundary

authorityはraw Dataを無分類で受け取らない。shared single-message parserがMCPClientEnvelopeへ変換し、SDKとstdioの両方が同じoperation APIを使う。MCP stdio/HTTPの1 message契約に合わせ、array envelopeは入力boundaryでrejectする。

~~~swift
package struct MCPClientEnvelope: Sendable {
    package enum Kind: Sendable {
        case request(id: JSONRPC.ID, method: String)
        case notification(method: String)
        case response(id: JSONRPC.ID)
    }

    package let kind: Kind
    package let data: Data
}

package enum MCPClientInitializationMode: Sendable {
    case managed(MCPManagedInitializeContext)
    case forwarded
}

package struct MCPClientOperation: Sendable {
    package let envelope: MCPClientEnvelope
    package let deadline: Deadline?
    package let replayPolicy: MCPReplayPolicy
}

package enum MCPClientSessionEvent: Sendable {
    case message(connection: MCPConnectionID, envelope: MCPClientEnvelope)
    case connectionState(XcodeMCPConnectionSnapshot)
}

package actor MCPClientSessionAuthority {
    package nonisolated let events: AsyncStream<MCPClientSessionEvent>

    package static func startManaged(
        recipe: MCPTransportRecipe,
        initialize: MCPManagedInitializeContext,
        defaultTimeout: Duration?
    ) async throws -> MCPClientSessionAuthority

    package static func makeForwarded(
        recipe: MCPTransportRecipe,
        defaultTimeout: Duration?
    ) -> MCPClientSessionAuthority

    package func send(_ operation: MCPClientOperation) async throws
    package func reconnect(deadline: Deadline?) async throws
    package func connectionState() -> XcodeMCPConnectionSnapshot
    package func connectionStates() -> AsyncStream<XcodeMCPConnectionSnapshot>
    package func close() async
}
~~~

eventsはauthorityをcomposeする単一internal consumer（InitializedMCPClientSessionまたはStdioAdapter）向けで、message deliveryにだけ使う。connectionStates()は呼出しごとに独立continuationとbufferingNewest(1)を作り、connectionState()のsnapshot取得とsubscriber登録を同じactor turnで行って初回snapshotをyieldする。public XcodeMCP/adapterのstate APIはこのauthority APIをforwardし、別fan-outを所有しない。

fresh transport connection boundaryは次とする。HTTP-specific header/session factをここで型にし、文字列やstatusの再解析を上位へ漏らさない。

~~~swift
package struct MCPTransportRecipe: Sendable {
    package let makeConnection: @Sendable () async throws -> any MCPClientConnection
}

package struct MCPConnectionHeaders: Sendable {
    package let sessionID: String?
    package let protocolVersion: String?
}

package enum MCPConnectionEvent: Sendable {
    case message(
        connection: MCPConnectionID,
        envelope: MCPClientEnvelope,
        responseHeaders: MCPConnectionHeaders?
    )
    case closed(connection: MCPConnectionID, reason: String?)
    case eventStreamSessionExpired(connection: MCPConnectionID, sessionID: String)
}

package protocol MCPClientConnection: Sendable {
    var id: MCPConnectionID { get }
    var events: AsyncStream<MCPConnectionEvent> { get }

    func send(
        _ envelope: MCPClientEnvelope,
        headers: MCPConnectionHeaders,
        deadline: Deadline?
    ) async throws

    func startEventStream(headers: MCPConnectionHeaders) async
    func close() async
}

package enum MCPTransportFailure: Error, Sendable {
    case sessionExpired(
        connection: MCPConnectionID,
        sessionID: String,
        delivery: MCPDeliveryCertainty
    )
    case deliveryUnknown(connection: MCPConnectionID, reason: String)
    case unavailable(connection: MCPConnectionID, reason: String)
}
~~~

HTTP connectionは、実際にsession headerを付けたrequestの404だけをsessionExpired/rejectedBeforeProcessingにする。local process connectionはsession headersを無視する。connectionはnetwork/process Taskを機械的に所有するが、session ID、protocol version、recovery判断、connection stateは所有しない。

managed modeではauthorityがreserved internal IDでinitialize/initializedを完了してから返し、通常request IDを消費しない。InitializedMCPClientSessionはsend前にpending correlationを登録し、eventsのmessageをIDで完了する。

forwarded modeでは最初のdownstream initializeだけをsession IDなしで送る。そのresponseは元IDのままstdioへyieldし、成功したparams/resultをrecovery recipeとして保存する。downstream notifications/initializedを観測後にreadyへ遷移する。recovery時だけreserved string namespaceのhidden initializeをauthorityが発行・consumeし、stdioへyieldしない。downstream response envelope、cancel notification、古いserver requestへのresponseはreplayPolicy neverとする。

MCPTransportRecipeはfresh connectionを生成するimmutable factoryである。connectionはheadersを含む送達factとraw incoming envelopeをauthorityへ返し、HTTP session ID/protocol version/SSE taskを所有しない。authorityのconnection generationを付けたeventだけが上位へ届き、old connectionのlate eventはdiscardする。

### 6.3 Public SDK API

~~~swift
public struct XcodeMCPRequestOptions: Equatable, Sendable {
    public enum Timeout: Equatable, Sendable {
        case configurationDefault
        case disabled
        case after(Duration)
    }

    public enum ReplayPolicy: Equatable, Sendable {
        case never
        case onceWhenRejectedBeforeProcessing
    }

    public var timeout: Timeout
    public var replayPolicy: ReplayPolicy

    public init(
        timeout: Timeout = .configurationDefault,
        replayPolicy: ReplayPolicy = .onceWhenRejectedBeforeProcessing
    )
}

public enum XcodeMCPConnectionFailure: Equatable, Sendable {
    case transportUnavailable(String)
    case sessionRecoveryFailed(String)
    case protocolViolation(String)
}

public enum XcodeMCPCloseReason: Equatable, Sendable {
    case requested
}

public struct XcodeMCPConnectionSnapshot: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case initializing
        case ready
        case recovering
        case unavailable(XcodeMCPConnectionFailure)
        case closed(XcodeMCPCloseReason)
    }

    public let sequence: UInt64
    public let generation: UInt64
    public let phase: Phase
}

public actor XcodeMCP {
    public func connectionState() -> XcodeMCPConnectionSnapshot
    public func connectionStates() -> AsyncStream<XcodeMCPConnectionSnapshot>
    public func reconnect(options: XcodeMCPRequestOptions = .init()) async throws
    public func listTools(options: XcodeMCPRequestOptions = .init()) async throws -> [MCPTool]
    public func callTool(
        _ name: String,
        arguments: [String: MCPJSONValue] = [:],
        options: XcodeMCPRequestOptions = .init(),
        onProgress: (@Sendable (MCPProgress) async -> Void)? = nil
    ) async throws -> MCPToolResult
    public func request(
        _ method: String,
        params: MCPJSONValue? = nil,
        options: XcodeMCPRequestOptions = .init()
    ) async throws -> MCPJSONValue
    public func close() async
}
~~~

各 connectionStates() subscriberはcurrent snapshotを最初に受け、独立した bufferingNewest(1) を使う。sequence gapは中間stateのdropを示す。closedはterminalでstreamをfinishする。recovery失敗後はunavailableとなり、通常requestが無限のimplicit reconnectを行わず、reconnect()だけが再試行する。

explicit closeだけをasync resource completion contractとする。closeはevent reader、progress lane、recovery、notification taskをcancelして完了をawaitし、transportを閉じた後にclosedをpublishする。XcodeMCP自身のdeinitは別actorのstateへ触れず、async Taskも起動しない。session/authorityはそれぞれ自身のisolated deinitで所有Taskだけを同期cancelする。consumerがcloseを省略した場合にgraceful protocol shutdownが完了するとは約束しない。

### 6.4 Typed failure and recovery

session headerを実際に付けたPOST/GETの404だけを sessionExpired(connection, delivery: rejectedBeforeProcessing) にする。session IDなしinitializeの404、endpoint 404、network error、切断は同じcaseにしない。

- failed connection identityごとにrecoveryをsingle-flight化する。
- fresh transport/sessionへsession IDなしinitializeとnotifications/initializedを行う。
- logical request全体のreplayは最大1回。2回目のsession-expiredはtyped errorとしてsurfaceする。
- delivery unknownのoperationは自動replayしない。
- SSE GET 404は同じinvalidation/recoveryへ接続するが、元operationはない。
- stdio recoveryは成功済みdownstream initialize paramsを保存し、hidden internal request IDで再initializeする。そのresponseをstdoutへ出さない。initialize前のrecipeを推測しない。

### 6.5 One logical deadline

既存DeadlineをDuration対応へ拡張し、public operation開始時にabsolute monotonic deadlineを1回だけ発行する。初回send、recovery waiter、fresh initialize、initialized notification、one-shot replay、paginationはremaining budgetを共有する。recoveryやpageごとにtimeoutを再開始しない。

短いdeadlineのwaiterだけがtimeoutしても他waiterのshared recoveryをcancelしない。全waiterが離れた時だけ共有taskをcancelする。

### 6.6 Cancellation, progress, pagination

- timeoutとcaller cancellationでpending requestをterminalにした後、initialize以外のin-flight IDへnotifications/cancelledをbest-effort送信する。通知taskはauthorityが所有し、closeでcancel/awaitする。
- late responseはpending registryでdropする。
- requestごとにProgressLaneを持ち、final response時に新規progress受付を閉じ、既に受理したhandler chainをdrainしてからresultを返す。返却後callbackを禁止する。
- event readerはprogress handlerを直接awaitせず、handlerから同clientへreentrant requestしてもdeadlockしない。
- listTools はnextCursorがnilになるまで同じdeadline内で全pageを取得する。cursor cycleはfail fastし、途中failureでpartial catalogを返さない。
- pagination中にconnection generationが変わったら蓄積を捨て、同じlogical deadline/replay budgetでpage 1から再開する。
- raw request("tools/list", ...) は1pageのescape hatchとして残す。

### 6.7 Protocol-version fallback

明示versionがinvalid/unsupported/mismatchなら400を維持する。header欠如時はsessionに保存したnegotiated versionを使う。sessionにもversionがない場合だけ仕様既定の2025-03-26として評価し、serverがsupportしないなら400にする。POST/GET/DELETEを同じresolverに通す。

### 6.8 Batch contract cleanup

external HTTP batchは既にgatewayでrejectされ、単一objectから内部arrayを生成するproduction pathもない。互換的な内部batch normalize layerは追加しない。

1. empty/singleton/mixed arrayがgatewayで400、下流副作用ゼロであることを固定する。
2. executor/inspectorをtyped single JSON-RPC object契約へ変更する。
3. requestIsBatch、forceBatchArray、refresh remainder merge/reinjectionを削除する。
4. JSONRPCResponseRouter.pendingBatches/registerBatchPendingを削除する。
5. upstream array responseはupstream lifecycle boundaryのprotocol violationとする。実在が観測された場合だけ、その単一入力境界でordered messagesへ正規化する設計を再開する。

### 6.9 Observability and discovery

- notification buffer overflowはsessionごとのdropped counterを増やし、rate-limited warningを出す。
- 未処理server notificationのdebug logは既にあるため追加しない。
- discovery recordはURL hintとして読む。PID生存判定をtruthにせず、接続と標準initialize handshakeで確定する。
- discovery writeを要求したserver start()は、write成功までをstart成功条件にする。失敗時はlistener/runtimeをunwindしてthrowする。

### 6.10 Retain graph and completion contract

| Owner | Strong references while active | Explicit terminal operation | deinit backstop |
|---|---|---|---|
| XcodeMCP | InitializedMCPClientSession | close()がsession.close()をawait | cross-actor cancellationを行わず参照を解放。Task生成なし |
| InitializedMCPClientSession | authority、pending registry、requestごとのProgressLane | pendingをclosedで完了しlaneをcancel/await後、authority.close()をawait | isolated deinitで自分のpending/lane/event Taskだけを同期cancel |
| MCPClientSessionAuthority | current connection、event reader、recovery、cancel-notification tasks、subscriber continuations | state admission停止→owned tasks cancel/await→connection.close await→closed publish/streams finish | isolated deinitでTask handlesをcancelしcontinuation finish。async close Taskを生成しない |
| low-level HTTP/process connection | URLSession/network tasksまたはUpstreamSession、event continuation | close()がI/O停止とevent reader完了をawait | network/process task cancel signalだけ。graceful完了保証なし |
| XcodeMCPProxyStdioAdapter / internal StdioAdapter actor | wrapperはactorだけ、actorはauthority/read/event/request tasks/writer | stop()がinput admission停止と全task/authority完了をawait | wrapperは参照解放のみ。actorのisolated deinitが自分のTaskだけを同期cancel |
| XcodeMCPProxyServer | lifecycle state、ELG、listener/accepted channels、runtime、auto-approver | shutdown()がchannels/runtime/ELGを順にcloseして完了をawait | channels/taskを同期cancel。新しいTaskを生成しない |

Task closureはownerを無条件に強参照し続けない。ownerがTaskを保持する場合、closureはweak ownerまたはownerから切り離したimmutable dependenciesだけをcaptureする。AsyncStream continuationはonTerminationでsubscriber registryから外れ、closed時に必ずfinishする。close/stop/shutdown完了後のcallback、network send、process activityをcontract testで検出する。

## 7. Task C — breaking public API redesign

### 7.1 Proxy server

~~~swift
public struct XcodeMCPProxyServerConfiguration: Sendable {
    public enum Discovery: Equatable, Sendable {
        case disabled
        case defaultLocation
        case file(URL)
    }

    public var bindAddress: BindAddress
    public var upstream: Upstream
    public var maxBodyBytes: Int
    public var requestTimeout: Duration?
    public var configurationFileURL: URL?
    public var toolPolicy: ToolPolicy?
    public var initializeHandshake: InitializeHandshake?
    public var discovery: Discovery
    public var approvalPolicy: ApprovalPolicy
    public var featurePolicy: FeaturePolicy

    public init(
        bindAddress: BindAddress = .localhost(),
        upstream: Upstream = .defaultMCPBridge(),
        maxBodyBytes: Int = 1_048_576,
        requestTimeout: Duration? = .seconds(300),
        configurationFileURL: URL? = nil,
        toolPolicy: ToolPolicy? = nil,
        initializeHandshake: InitializeHandshake? = nil,
        discovery: Discovery = .defaultLocation,
        approvalPolicy: ApprovalPolicy = .manual,
        featurePolicy: FeaturePolicy = .default
    )
}

public final class XcodeMCPProxyServer: Sendable {
    public init(configuration: XcodeMCPProxyServerConfiguration = .init())
    public func start() async throws -> Endpoint
    public func snapshot() async -> Status
    public func waitUntilShutdown() async throws
    public func shutdown() async throws
    public static func run(
        arguments: [String],
        environment: [String: String],
        stdout: @escaping @Sendable (String) -> Void,
        stderr: @escaping @Sendable (String) -> Void
    ) async -> Int32
}
~~~

Configurationのpublic surfaceは次で確定する。既存nested typeの意味を維持し、表の型変更だけを行う。

| Property | Type / contract |
|---|---|
| bindAddress | BindAddress(host: String, port: Int)。port 0はephemeral |
| upstream | defaultMCPBridge(processesPerXcode: Int, sessionID: String?) または custom(command: String, arguments: [String], processesPerXcode: Int, sessionID: String?) |
| maxBodyBytes | Int、正数だけ |
| requestTimeout | Duration?、nilだけdisabled |
| configurationFileURL | URL?、明示URLのread/decode失敗はthrow |
| toolPolicy | ToolPolicy? |
| initializeHandshake | InitializeHandshake? |
| discovery | disabled / defaultLocation / file(URL) |
| approvalPolicy | manual / automatic |
| featurePolicy | FeaturePolicy |

Endpoint と Status は次の完全なread modelとする。

~~~swift
extension XcodeMCPProxyServer {
    public struct Endpoint: Equatable, Sendable {
        public let host: String
        public let port: Int
        public let url: URL
        public init(host: String, port: Int)
    }

    public struct Status: Equatable, Sendable {
        public enum Phase: Equatable, Sendable {
            case idle
            case running
            case stopping
            case stopped
        }

        public struct Upstream: Equatable, Sendable {
            public enum Health: Equatable, Sendable {
                case starting
                case healthy
                case degraded
                case quarantined
                case stopped
            }

            public let id: Int
            public let health: Health
            public let isInitialized: Bool
            public let activeRequestCount: Int
        }

        public let generatedAt: Date
        public let phase: Phase
        public let endpoint: Endpoint?
        public let proxyInitialized: Bool
        public let catalogAvailable: Bool
        public let queuedRequestCount: Int
        public let upstreams: [Upstream]
    }
}
~~~

serverはone-shot start、idempotent shutdownとする。shutdown完了時にはlistener/accepted channel/runtime/permission automation/event-loop taskがすべて終了している。terminal後の再startはtyped error。event loop groupはstart時にlazy作成し、未start instanceの破棄でthreadを作らない。

explicit shutdownだけをgraceful completion contractとする。started instanceのdeinitはchannel/taskを同期的にcancelするbackstopを実行し、新しいunowned Taskを作らない。

Status はsanitized aggregateだけを返す。lifecycle phase、endpoint、proxy initialized、catalog availability、queued request count、upstreamごとのindex/health/initialized/active countを含め、traffic payload、stderr、tool argumentsは含めない。consumer/ordering/resync契約のないserver public event streamは追加しない。

configでdiscoveryを要求した場合はstart()が書き、失敗時は全resourceをunwindしてthrowする。sync start()、startAndWriteDiscovery() wrapperは残さない。

### 7.2 Proxy adapter and CLI surface

public adapter surfaceは次で確定する。

~~~swift
public struct XcodeMCPProxyStdioAdapterConfiguration: Equatable, Sendable {
    public enum Endpoint: Equatable, Sendable {
        case url(URL)
        case discoveryFile(URL)
        case proxyDefault(environment: [String: String])
    }

    public var endpoint: Endpoint
    public var requestTimeout: Duration?

    public init(
        endpoint: Endpoint = .proxyDefault(environment: ProcessInfo.processInfo.environment),
        requestTimeout: Duration? = .seconds(300)
    )
}

public final class XcodeMCPProxyStdioAdapter: Sendable {
    public init(
        configuration: XcodeMCPProxyStdioAdapterConfiguration = .init(),
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput
    ) throws

    public func start() async throws
    public func connectionState() async -> XcodeMCPConnectionSnapshot
    public func waitUntilStopped() async
    public func stop() async
    public static func run(
        arguments: [String],
        environment: [String: String],
        stdout: @escaping @Sendable (String) -> Void,
        stderr: @escaping @Sendable (String) -> Void
    ) async -> Int32
}
~~~

startはone-shot、stopはidempotentで、stop完了時にread/request/event/progress/recovery taskとnetwork requestがすべて終了する。public wrapperのdeinitはinternal actor参照を解放するだけで、internal actorのisolated deinitが自身のtaskを同期cancelする。どちらも新しいTaskを作らない。

- public adapter configurationはendpoint policyとDuration? timeoutを持つ。nilだけをtimeout disabledとする。
- public resolver/launch-plan/parser metadataはpackage/internalへ降格する。
- canonical adapter CLI endpoint flagは--urlだけ。--stdio redirectとrewriteURLFlagToStdioを削除する。
- timeout 0はdisabledへ変換する。負数、NaN、infinity、非数値をrejectする。
- server/adapterのrun(arguments:environment:stdout:stderr:) facadeは残す。launch actionはpackage enumのassociated valueで表し、optional payloadのLaunchPlanとcan't-happen guardを削除する。
- configurationFilePath: String?をconfigurationFileURL: URL?へ変更し、明示configのread/decode失敗をresource取得前にthrowする。

installer implementationとProxyProductBuilderはpackage/executable ownershipへ移し、XcodeMCPProxyInstallerのpublic configuration/plan/install surfaceを削除する。installer executable behaviorとdry-runは維持する。

### 7.3 External consumer sketches

~~~swift
import XcodeMCPKit

let client = try await XcodeMCP(
    configuration: .init(transport: .streamableHTTPProxyDiscovery())
)
let state = await client.connectionState()
let tools = try await client.listTools(
    options: .init(timeout: .after(.seconds(30)))
)
await client.close()
~~~

~~~swift
import XcodeMCPProxyKit

let server = XcodeMCPProxyServer(
    configuration: .init(
        requestTimeout: .seconds(300),
        discovery: .defaultLocation
    )
)
let endpoint = try await server.start()
let status = await server.snapshot()

let adapter = try XcodeMCPProxyStdioAdapter(
    configuration: .init(endpoint: .url(endpoint.url))
)
try await adapter.start()
await adapter.stop()
try await server.shutdown()
~~~

### 7.4 Breaking impact inventory

| 旧surface / behavior | 新しい標準形 |
|---|---|
| server/adapter/installerのpublic LaunchAction、LaunchOptions、LaunchPlan、LaunchResolutionError | package launch actionのassociated value、外部consumerはrun()またはembedding APIを使用 |
| XcodeMCPProxyProductMetadata、PortInUseError | package diagnostics。public command結果はexit codeとstderrで観測 |
| XcodeMCPProxyInstallerConfigurationとpublic installer plan/install API | installer executableのみ |
| public adapter endpoint resolver/options/source types | adapter configurationのendpoint policy |
| sync server start()、startAndWriteDiscovery()、wait() | async start()、waitUntilShutdown()、shutdown() |
| configurationFilePath: String? | configurationFileURL: URL? |
| TimeInterval timeout | Duration?。nil/CLI 0だけdisabled |
| adapter --stdio / rewriteURLFlagToStdio | --urlのみ |
| MCPJSONValue.init(encoding:)、intValue | unlabeled Encodable init、integerValue |
| listToolsの先頭pageだけ | deadline内の完全catalog、partial resultなし |

wire上のJSON-RPC method/schemaとdiscovery record schemaは変更しない。HTTP batch rejectionは既存wire contractを狭めず、dead internal batch machineryだけを削除する。

### 7.5 SDK ergonomics

- XcodeMCPErrorをLocalizedErrorへ準拠させ、setup/configuration、proxy/transport unavailable、session expired/recovery failure、timeout、invalid response、server error、explicit closeをconsumerの次アクションで分ける。errorDescription: String?とrecoverySuggestion: String?を実装し、localized textをtestする。
- stale/missing discovery recordをinvalidRequestにせずproxy unavailableへ分類する。
- MCPContent.text(_:) factoryを追加する。
- MCPToolResult.textはtext contentを改行で連結し、non-text itemを無視する。
- MCPJSONValueにkey/index subscriptとinit<T: Encodable>(_ value: T) throwsを追加し、旧init(encoding:)と重複intValueを直接削除する。
- XcodeMCPTestRuntime.makeClient(configuration:)はnon-default transportをrejectし、transportをsilent ignoreしない。recordedToolCalls()を公開する。

## 8. Task D — hygiene and documentation

- external fixtureで、実在する非product test-support module（例: XcodeMCPProxyTestSupport）がpublic product clientからimport不能であることを検査する。存在しないXcodeMCPCore / XcodeMCPProcessRuntime名のtrivially-green検査は削除する。
- old surface fallback catch、generation-0 test-only catalog write、dead cacheable branchをowner移行と同時に削除する。
- Docs/architecture.mdへOrigin全route policy、missing-Origin policy、negotiated protocol fallback、single-message/batch rejection、SSE drop observabilityを記録する。
- Docs/maintainer-architecture.mdのexecutable dependency記述を実Package.swiftへ合わせる。
- root/module READMEを新public API、CLI flag、error/lifecycle contractへ更新する。
- breaking migration noteに削除/変更symbol、CLI flag、旧→新標準形を列挙する。

## 9. Access control plan

- public: consumer storyに現れるconfiguration、SDK models/options/state、server/adapter lifecycle、server/adapter run()だけ。
- package: cross-target lifecycle authority、CLI composition、installer、build metadata、test fixture integrationに必要な最小surface。
- internal/default: HTTP/runtime owners、transition/event/effect、parser、debug records。
- private/fileprivate: lease proof fields、mutable owner state、lock、task dictionaries。

外部 scratch packageは3 public productsのsupported storyだけをcompileする。@testable/package accessをpublic API verificationに使わない。

## 10. Variant-add tests

| 変動軸 | 追加時に編集してよい場所 | 合格条件 |
|---|---|---|
| catalog completion source | ProcessControlPlaneAuthority begin/complete transition | call siteにgeneration/route/attempt guardを追加しない |
| activation phase/resource | authorityのphase reducer/resource enum | 発行siteでregistration cleanupを追加しない |
| window owner query | authorityのwindow query enum | eligibility/conflict logicをcall siteへ追加しない |
| client transport recipe | session authority recipe factory | SDK/stdioにrecovery stateを追加しない |
| CLI launch action | package launch action enum + launcher switch | optional payload/guardを追加しない |
| public connection state | snapshot phase enum + exhaustive mapper | prose/substringからstateを復元しない |

## 11. Findings-to-design / deletion mapping

| Finding | canonical fix | 完了シグナル |
|---|---|---|
| F1 | catalog lease + atomic authority commit | proofなしcatalog write 0、route replacement TOCTOU test成功 |
| F2 | catalog/window/initialize epoch分離 | window更新中のtools/list成功 |
| F3 | attempt-owned resources/effects | N callbackがN+1を変更しない |
| F4 | owner transitions + snapshot tests | guard-order hooks削除、coordinatorはI/O/effect配線 |
| F5 | public launch plan/installer削除 | external surfaceがsupported storyだけ |
| F6 | async server lifecycle、lazy ELG、snapshot、discovery throw | unstarted thread 0、shutdown completion test成功 |
| F7 | shared session authority、typed 404、deadline/cancel/progress/pagination/error ergonomics | direct SDK/stdio restart E2E成功 |
| F8 | all-route Origin、version fallback、batch deletion、drop counter | route matrix / protocol / single-message tests成功 |
| F9 | dead API/test/docs cleanup | source inventoryとdocsが現HEADに一致 |

## 12. 採らない形

- call siteへn個目のgeneration/lease guardを追加する。
- route stateを旧storeへ残し、authorityへlease mirrorを作る。
- error文字列やCancellationErrorからrecovery reasonを推測する。
- recovery、pagination、retryごとにdeadlineを再開始する。
- delivery unknownのtool callを自動再送する。
- public API compatibilityのため旧launch plan/flag/sync start wrapperを残す。
- test/preview用にproduction pathへhook、fake row、mirror stateを置く。
- evidenceのないupstream batchを想定したnormalize/fallback layerを残す。
- public server event streamをconsumer/sequence/buffer/resync契約なしで追加する。

## 13. Migration and verification order

1. P0 Origin boundaryを独立commit。
2. Task A authorityを導入し、catalog → route/attempt/exposure/window → upstream registryの順にownerを移し、旧store/API/hookを削除。
3. Task B typed transport fact → shared authority direct SDK → stdio → cancel/progress/pagination → protocol/batch/observabilityの順に移行。
4. Task C public server/adapter/installer/SDK surfaceを直接置換。
5. Task D docs/fixture/source inventoryを実装後のsurfaceへ同期。
6. targeted tests、process/stdio integration、external product fixture、fast full suite、scripts/check.sh、git diff --check、codex-reviewを順に通す。

各migration sliceは旧ownerと新ownerを同時にtruthとして残さない。sliceのcommit内でconsumerを新ownerへ切り替え、旧state/write pathを削除する。

## 14. Required contract tests

### Task A

- load開始後のroute replacementで旧CatalogLease completionがdiscardされ、process/canonical snapshotが変わらない。
- catalog invalidationでは旧leaseをrejectし、initialize/window mutationではcatalog loadをcancelしない。
- attempt Nのtimeout/RPC/waiterがN+1開始時に自動失効し、Nのlate callbackがN+1資源を変更しない。
- accepted commit直後だけprocess surfaceとcanonical projectionが同じsnapshotに現れる。route retireは残存catalogを同transactionで再投影する。
- in-flight tools/list中のtab/window更新がclient errorやtimeoutにならない。
- source inventoryでauthority外のproduction catalog write、旧store、guard-order hookが0件。

### Task B/C

- session headerあり/なしPOST 404とGET 404をtypedに区別する。
- concurrent callerが1 recoveryを共有し、各operationのreplayは最大1回、短いwaiter timeoutが他waiterをcancelしない。
- direct SDKとstdio adapterがproxy restartから回復し、hidden initialize responseをstdioへ出さない。
- delivery unknownのtools/callをreplayしない。timeout/caller cancelはinitialize以外へ正しいrequest IDのcancel notificationを送る。
- result返却後progress callbackがなく、reentrant progress callbackがdeadlockしない。
- listTools multi-page、partial failure、cursor cycle、generation交換時page-1 restartを検査する。
- close/recovery競合とserver shutdownで、完了後にtask/channel/callback/network/process activityが残らない。
- serverをstartせず破棄してevent-loop threadを生成しない。discovery write失敗は全resourceをunwindしてthrowする。
- external scratch clientsが新public APIをcompile/linkし、削除surfaceを参照できない。

### HTTP / hygiene

- Origin route matrix、negotiated-version fallback、explicit mismatch、POST/GET/DELETEを検査する。
- empty/singleton/mixed batchはgatewayで400かつ下流副作用0。upstream arrayはprotocol violation。
- SSE notification overflowはdropped counterとrate-limited warningを1 ownerで更新する。
- 実在する非product test-support moduleがexternal product clientからimport不能である。
