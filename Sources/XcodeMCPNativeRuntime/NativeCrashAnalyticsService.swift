import ABIBridge
// Combine's cancellation handles lack Sendable annotations; the waiter transfers them under its mutex.
@unsafe @preconcurrency import Combine
import Foundation
import Synchronization

struct NativeCrashServiceQuery: Sendable {
    let adamIdentifier: String
    let bundleIdentifier: String
    let platformIdentifier: String
    let uploadPlatformIdentifier: String
    let appVersion: String?
    let isBeta: Bool?
    let timePeriod: String
    let pageIndex: Int
    let pageSize: Int
}

/// Calls the Organizer analytics services directly, without their MCP disk fallback.
@safe
final class NativeCrashAnalyticsService: Sendable {
    private let installation: NativeXcodeInstallation
    private let runtime = ABIRuntime.shared

    init(installation: NativeXcodeInstallation) { self.installation = installation }

    func fetchPage(_ query: NativeCrashServiceQuery) async throws -> Data {
        try await fetch(query, issueID: nil)
    }

    func fetchIssue(_ query: NativeCrashServiceQuery, issueID: String) async throws -> Data {
        try await fetch(query, issueID: issueID)
    }

    private func fetch(_ query: NativeCrashServiceQuery, issueID: String?) async throws -> Data {
        let responses = NativeCrashResponseWaiter()
        let worker = Task.detached { [self] in Data(try run(query, issueID: issueID, responses: responses).utf8) }
        return try await withTaskCancellationHandler {
            do {
                let response = try await worker.value
                try Task.checkCancellation()
                return response
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            worker.cancel()
            responses.cancel()
        }
    }

    private func run(_ query: NativeCrashServiceQuery, issueID: String?, responses: NativeCrashResponseWaiter) throws -> String {
        try Task.checkCancellation()
        let products = ImageSelector.path(installation.framework("DVTProducts", in: "SharedFrameworks"))
        let jobType = try runtime.resolveAndWait(
            .swift(.type("DVTProducts.AccountJob", genericArguments: [.type(String.self)])), in: products)
        let create = try jobType.resolveAndWait(.swift(.initializer(
            "init(userDescription: Swift.String, _: (__C.DVTServicesAccountBasedSession) throws -> A) -> DVTProducts.AccountJob<A>",
            as: ((String, NativeSwiftClosure<(NativeSwiftValue) throws -> String>) -> NativeSwiftValue).self,
            valueABIs: [jobType: .opaque(named: jobType.name)])))
        let work = try NativeSwiftClosure<(NativeSwiftValue) throws -> String> { [self] session in
            try session.withCopy { try perform(query, issueID: issueID, session: $0 as AnyObject, responses: responses) }
        }
        let job = try unsafe create.unsafeInvoke("Downloading crash analytics", work)
        guard let managerClass = NSClassFromString("DVTDeveloperAccountManager") else {
            throw NativeRuntimeError.unsupportedContract("Xcode's developer account manager is unavailable")
        }
        let manager = try runtime.object(managerClass as AnyObject).resolveAndWait(
            .objc(.method("sharedAccountManager", as: (() -> AnyObject).self)))
        let attempter = try runtime.resolveAndWait(
            .swift(.type("DVTProducts.AccountJobAttempter", genericArguments: [.type(String.self)])), in: products)
        let initialize = try attempter.resolveAndWait(.swift(.initializer(
            "init(accountManager: __C.DVTDeveloperAccountManager, _: DVTProducts.AccountJob<A>) -> DVTProducts.AccountJobAttempter<A>",
            as: ((AnyObject, NativeSwiftValue) -> AnyObject).self,
            valueABIs: [jobType: .opaque(named: jobType.name)])))
        let managerObject = try unsafe manager.unsafeInvoke()
        let owner = try unsafe initialize.unsafeInvoke(managerObject, job)
        let run = try runtime.object(owner).resolveAndWait(
            .swift(.method("run() throws -> A", as: (() throws -> String).self)))
        do { return try unsafe run.unsafeInvoke() }
        catch let failure as NativeSwiftError {
            try Task.checkCancellation()
            let noAccounts = failure.withUnderlyingError { Mirror(reflecting: $0).children.first?.label == "noAccounts" }
            guard noAccounts, let cause = try? keychainFailure(manager: managerObject) else { throw failure }
            let original = failure.withUnderlyingError { $0 as NSError }
            var information = original.userInfo
            information[NSLocalizedDescriptionKey] = original.localizedDescription
            if let reason = original.localizedFailureReason { information[NSLocalizedFailureReasonErrorKey] = reason }
            if let recovery = original.localizedRecoverySuggestion { information[NSLocalizedRecoverySuggestionErrorKey] = recovery }
            information[NSUnderlyingErrorKey] = cause
            throw NSError(domain: original.domain, code: original.code, userInfo: information)
        }
    }

    private func keychainFailure(manager: AnyObject) throws -> NSError? {
        let accounts = try runtime.object(manager).resolveAndWait(.objc(.method("allAccounts", as: (() -> NSOrderedSet).self)))
        guard try unsafe accounts.unsafeInvoke().count == 0 else { return nil }
        let identifiers = try runtime.object(manager).resolveAndWait(
            .objc(.method("_accountIdentifiersFromUserDefaults:", as: ((Bool) -> NSArray).self)))
        let configured = try unsafe identifiers.unsafeInvoke(false)
        guard let identifier = configured.compactMap({ ($0 as? NSDictionary)?["identifier"] as? String }).first,
              let clientClass = NSClassFromString("DVTKeychainServiceClient") else { return nil }
        let create = try runtime.object(clientClass as AnyObject).resolveAndWait(.objc(.method("new", as: (() -> AnyObject).self)))
        let client = try unsafe create.unsafeInvoke()
        let fetch = try unsafe runtime.object(client).resolveAndWait(.objc(.method(
            "fetchPasswordForUsername:service:keychain:error:",
            as: ((String, String, AnyObject?, UnsafeMutableRawPointer?) -> String?).self)))
        var errorAddress: UnsafeRawPointer?
        let available = try withUnsafeMutablePointer(to: &errorAddress) {
            try unsafe fetch.unsafeInvoke(identifier, "Xcode-Username", nil, UnsafeMutableRawPointer($0)) != nil
        }
        guard !available, let errorAddress = unsafe errorAddress else { return nil }
        return unsafe Unmanaged<NSError>.fromOpaque(errorAddress).takeUnretainedValue()
    }

    private func perform(_ query: NativeCrashServiceQuery, issueID: String?, session: AnyObject,
                         responses: NativeCrashResponseWaiter) throws -> String {
        try Task.checkCancellation()
        let analytics = ImageSelector.path(installation.framework("DVTAnalytics", in: "SharedFrameworks"))
        let services = ImageSelector.path(installation.framework("XCServices", in: "SharedFrameworks"))
        let kindType = try runtime.resolveAndWait(.swift(.type("DVTAnalytics.AnalyticsBackendKind")), in: analytics)
        let kindABI = try NativeType.opaque(named: kindType.name)
        let kind = try kindType.resolveAndWait(.swift(.staticGetter(
            "current.getter : DVTAnalytics.AnalyticsBackendKind", as: (() -> NativeSwiftValue).self,
            valueABIs: [kindType: kindABI])))
        let account = try runtime.object(session).resolveAndWait(.objc(.method("account", as: (() -> AnyObject).self)))
        let factory = try runtime.resolveAndWait(.swift(.type("DVTAnalytics.AnalyticsServiceBackendFactory")), in: analytics)
        let createBackend = try factory.resolveAndWait(.swift(.staticMethod(
            "liveBackend(kind: DVTAnalytics.AnalyticsBackendKind, credentials: DVTAnalytics.AnalyticsBackendCredentialsProvider) -> DVTAnalytics.AnalyticsServiceBackend",
            as: ((NativeSwiftValue, AnyObject) -> NativeSwiftValue).self, valueABIs: [kindType: kindABI])))
        let backend = try unsafe createBackend.unsafeInvoke(kind.unsafeInvoke(), account.unsafeInvoke())
        let aspect = try unsafe runtime.resolveAndWait(
            .c(.function("DVTAnalyticsLogAspect", as: (() -> UnsafeRawPointer).self)), in: analytics)
        let logAspect = try unsafe Unmanaged<AnyObject>.fromOpaque(aspect.unsafeInvoke()).takeUnretainedValue()
        let serviceName = issueID == nil ? "DVTCrashServiceListPoints" : "DVTCrashServiceDownloadPoint"
        let serviceType = try runtime.resolveAndWait(.swift(.type("DVTAnalytics." + serviceName)), in: analytics)
        let initialize = try serviceType.resolveAndWait(.swift(.initializer(
            "init(backend: DVTAnalytics.AnalyticsServiceBackend, log: __C.DVTLogAspect) -> DVTAnalytics." + serviceName,
            as: ((NativeSwiftValue, AnyObject) -> AnyObject).self)))
        let service = try unsafe initialize.unsafeInvoke(backend, logAspect)
        let request: NativeSwiftValue
        if let issueID { request = try detailRequest(query, issueID: issueID, analytics: analytics, services: services) }
        else { request = try listRequest(query, analytics: analytics, services: services) }
        let outputName = issueID == nil ? "DVTCrashServiceList" : "DVTCrashServiceDownloadedPoint"
        let outputType = try runtime.resolveAndWait(.swift(.type("DVTAnalytics." + outputName)), in: analytics)
        let publisherType = try runtime.resolveAndWait(.swift(.type("Combine.AnyPublisher",
            genericArguments: [.type(outputType), .type((any Error).self)])))
        let execute = try runtime.object(service).resolveAndWait(.swift(.method(
            "runPublisher(for: DVTAnalytics." + serviceName + ".Request) -> Combine.AnyPublisher<DVTAnalytics." + outputName + ", Swift.Error>",
            as: ((NativeSwiftValue) -> NativeSwiftValue).self,
            valueABIs: [request.type: .opaque(named: request.type.name), publisherType: .pointer])))
        let publisher = try unsafe execute.unsafeInvoke(request)
        return try publisher.withCopy { value in
            guard let value = value as? any Publisher else {
                throw NativeRuntimeError.unsupportedContract("The analytics service returned a non-publisher value")
            }
            return try responses.wait(value) { value in
                String(decoding: try JSONSerialization.data(withJSONObject: Self.json(value), options: [.sortedKeys]), as: UTF8.self)
            }
        }
    }

    private func listRequest(_ query: NativeCrashServiceQuery, analytics: ImageSelector,
                             services: ImageSelector) throws -> NativeSwiftValue {
        let period = try rawEnum("XCServices.AnalyticsWebServicesTimePeriod", rawValue: query.timePeriod, in: services)
        let platform = try rawEnum("XCServices.AnalyticsWebServicesPlatformIdentifier", rawValue: query.platformIdentifier, in: services)
        let upload = try rawEnum("XCServices.AnalyticsWebServicesPlatformIdentifier", rawValue: query.uploadPlatformIdentifier, in: services)
        let itemType = try runtime.resolveAndWait(.swift(.type("XCServices.QueryItem")), in: services)
        let createItem = try itemType.resolveAndWait(.swift(.initializer(
            "init(bundleIdentifier: Swift.String, isBeta: Swift.Bool?, appVersion: Swift.String?, appBuild: Swift.String?, platformIdentifier: XCServices.AnalyticsWebServicesPlatformIdentifier, uploadPlatformIdentifier: XCServices.AnalyticsWebServicesPlatformIdentifier) -> XCServices.QueryItem",
            as: ((String, NativeAnalyticsBoolean, String?, String?, NativeSwiftValue, NativeSwiftValue) -> NativeSwiftValue).self,
            valueABIs: [itemType: .opaque(named: itemType.name)])))
        let item = try unsafe createItem.unsafeInvoke(query.bundleIdentifier, NativeAnalyticsBoolean(value: query.isBeta),
                                                     query.appVersion, nil, platform, upload)
        let single = try runtime.resolveAndWait(.swift(.function(
            "XcodeMCPNativeRuntime.nativeCrashServiceArray<A>(A) -> [A]",
            as: ((NativeSwiftValue) -> NativeSwiftValue).self,
            genericArguments: [.type(itemType)], valueABIs: [itemType: .opaque(named: itemType.name)])))
        let items = try unsafe single.unsafeInvoke(item)
        let pageType = try runtime.resolveAndWait(.swift(.type("DVTAnalytics.PageInfo")), in: analytics)
        let pageABI = try NativeType.opaque(named: pageType.name)
        let createPage = try pageType.resolveAndWait(.swift(.initializer(
            "init(pageIndex: Swift.Int, pageSize: Swift.Int) -> DVTAnalytics.PageInfo",
            as: ((Int, Int) -> NativeSwiftValue).self, valueABIs: [pageType: pageABI])))
        let page = try unsafe createPage.unsafeInvoke(query.pageIndex, query.pageSize)
        let requestType = try runtime.resolveAndWait(.swift(.type("DVTAnalytics.DVTCrashServiceListPoints.Request")), in: analytics)
        let create = try requestType.resolveAndWait(.swift(.initializer(
            "init(timePeriod: XCServices.AnalyticsWebServicesTimePeriod, adamId: Swift.String, queryItems: [XCServices.QueryItem], pageInfo: DVTAnalytics.PageInfo) -> DVTAnalytics.DVTCrashServiceListPoints.Request",
            as: ((NativeSwiftValue, String, NativeSwiftValue, NativeSwiftValue) -> NativeSwiftValue).self,
            valueABIs: [requestType: .opaque(named: requestType.name), items.type: .pointer, pageType: pageABI])))
        return try unsafe create.unsafeInvoke(period, query.adamIdentifier, items, page)
    }

    private func detailRequest(_ query: NativeCrashServiceQuery, issueID: String, analytics: ImageSelector,
                               services: ImageSelector) throws -> NativeSwiftValue {
        let platform = try rawEnum("XCServices.AnalyticsWebServicesPlatformIdentifier", rawValue: query.platformIdentifier, in: services)
        let upload = try rawEnum("XCServices.AnalyticsWebServicesPlatformIdentifier", rawValue: query.uploadPlatformIdentifier, in: services)
        let point = try rawEnum("XCServices.AnalyticsWebServicesPointType", rawValue: "crashes", in: services)
        let type = try runtime.resolveAndWait(.swift(.type("DVTAnalytics.DVTCrashServiceDownloadPoint.Request")), in: analytics)
        let create = try type.resolveAndWait(.swift(.initializer(
            "init(pointId: Swift.String, pointType: XCServices.AnalyticsWebServicesPointType, adamId: Swift.String, bundleId: Swift.String, platform: XCServices.AnalyticsWebServicesPlatformIdentifier, uploadPlatform: XCServices.AnalyticsWebServicesPlatformIdentifier, logsMatchingAppVersion: Swift.String?, logsMatchingAppBuild: Swift.String?) -> DVTAnalytics.DVTCrashServiceDownloadPoint.Request",
            as: ((String, NativeSwiftValue, String, String, NativeSwiftValue, NativeSwiftValue, String?, String?) -> NativeSwiftValue).self,
            valueABIs: [type: .opaque(named: type.name)])))
        return try unsafe create.unsafeInvoke(issueID, point, query.adamIdentifier, query.bundleIdentifier,
                                              platform, upload, query.appVersion, nil)
    }

    private func rawEnum(_ name: String, rawValue: String, in image: ImageSelector) throws -> NativeSwiftValue {
        let rawValue = name == "XCServices.AnalyticsWebServicesPlatformIdentifier"
            ? ["com.apple.platform.iphoneos": "iOS", "com.apple.platform.macosx": "macOS",
               "com.apple.platform.appletvos": "tvOS", "com.apple.platform.watchos": "watchOS",
               "com.apple.platform.xros": "xrOS"][rawValue] ?? rawValue : rawValue
        let type = try runtime.resolveAndWait(.swift(.type(name)), in: image)
        let initialize = try type.resolveAndWait(.swift(.initializer(
            "init(rawValue: Swift.String) -> " + name + "?", as: ((String) -> NativeSwiftValue).self)))
        let optional = try unsafe initialize.unsafeInvoke(rawValue)
        guard let value = try optional.copyEnumPayloadAndWait(forCase: "some") else {
            throw NativeRuntimeError.invalidRequest("Unsupported analytics value '\(rawValue)' for \(name)")
        }
        return value
    }

    private static func json(_ value: Any) throws -> Any {
        if let value = value as? String { return value }
        if let value = value as? Bool { return value }
        if let value = value as? Int { return value }
        if let value = value as? UInt { return value }
        if let value = value as? Double { return value }
        if let value = value as? Date { return ISO8601DateFormatter().string(from: value) }
        if let value = value as? URL { return value.absoluteString }
        if let value = value as? Data { return value.base64EncodedString() }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional { return try mirror.children.first.map { try json($0.value) } ?? NSNull() }
        if let value = value as? any RawRepresentable { return try json(value.rawValue) }
        if mirror.displayStyle == .collection || mirror.displayStyle == .set { return try mirror.children.map { try json($0.value) } }
        if mirror.displayStyle == .dictionary {
            var object: [String: Any] = [:]
            for item in mirror.children {
                let pair = Array(Mirror(reflecting: item.value).children)
                guard pair.count == 2, let key = pair[0].value as? String else {
                    throw NativeRuntimeError.unsupportedContract("An analytics dictionary has a non-string key")
                }
                object[key] = try json(pair[1].value)
            }
            return object
        }
        guard mirror.displayStyle == .struct || mirror.displayStyle == .class else {
            throw NativeRuntimeError.unsupportedContract("Unsupported analytics value \(String(reflecting: type(of: value)))")
        }
        return try Dictionary(uniqueKeysWithValues: mirror.children.map { child in
            guard let name = child.label else { throw NativeRuntimeError.unsupportedContract("An analytics value has an unnamed field") }
            return (name, try json(child.value))
        })
    }
}

/// Owns one request's cancellation across the native account job's sequential attempts.
@safe
final class NativeCrashResponseWaiter: Sendable {
    private struct Attempt {
        let identifier: UUID
        let completed: DispatchSemaphore
        var result: Result<String, any Error>?
        var subscription: AnyCancellable?
    }

    private struct State {
        var cancelled = false
        var attempt: Attempt?
    }

    private let state = Mutex(State())

    func cancel() {
        let completion = state.withLock { state -> (AnyCancellable?, DispatchSemaphore?) in
            state.cancelled = true
            guard var attempt = state.attempt, attempt.result == nil else { return (nil, nil) }
            attempt.result = .failure(CancellationError())
            let subscription = attempt.subscription
            attempt.subscription = nil
            state.attempt = attempt
            return (subscription, attempt.completed)
        }
        completion.0?.cancel()
        completion.1?.signal()
    }

    func wait<Response: Publisher>(_ publisher: Response,
                                  transform: @escaping @Sendable (Response.Output) throws -> String) throws -> String {
        try Task.checkCancellation()
        let identifier = UUID()
        let completed = DispatchSemaphore(value: 0)
        try state.withLock { state in
            if state.cancelled { throw CancellationError() }
            state.attempt = Attempt(identifier: identifier, completed: completed)
        }
        defer {
            let subscription = state.withLock { state -> AnyCancellable? in
                guard state.attempt?.identifier == identifier else { return nil }
                let subscription = state.attempt?.subscription
                state.attempt = nil
                return subscription
            }
            subscription?.cancel()
        }
        let subscription = publisher.first().sink { completion in
            self.complete(identifier) {
                switch completion {
                case .failure(let error): .failure(error)
                case .finished: .failure(NativeRuntimeError.unsupportedContract("The analytics publisher completed without a response"))
                }
            }
        } receiveValue: { value in
            self.complete(identifier) { Result { try transform(value) } }
        }
        let installed = state.withLock { state in
            guard state.attempt?.identifier == identifier, state.attempt?.result == nil else { return false }
            state.attempt?.subscription = subscription
            return true
        }
        if !installed { subscription.cancel() }
        if completed.wait(timeout: .now() + 60) == .timedOut {
            complete(identifier) { .failure(URLError(.timedOut)) }
            completed.wait()
        }
        try Task.checkCancellation()
        return try state.withLock { state in
            guard let result = state.attempt?.result else {
                throw NativeRuntimeError.unsupportedContract("The analytics publisher completed without a response")
            }
            return try result.get()
        }
    }

    private func complete(_ identifier: UUID, result: () -> Result<String, any Error>) {
        let completion = state.withLock { state -> (AnyCancellable?, DispatchSemaphore?) in
            guard var attempt = state.attempt, attempt.identifier == identifier, attempt.result == nil else { return (nil, nil) }
            // Keep value conversion inside the lock so cancellation waits for an active native value's use.
            attempt.result = result()
            let subscription = attempt.subscription
            attempt.subscription = nil
            state.attempt = attempt
            return (subscription, attempt.completed)
        }
        completion.0?.cancel()
        completion.1?.signal()
    }
}

package func nativeCrashServiceArray<Value>(_ value: Value) -> [Value] { [value] }
