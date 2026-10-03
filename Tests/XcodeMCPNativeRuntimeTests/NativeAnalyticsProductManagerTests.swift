import ABIBridge
import Foundation
import ObjectiveC
import Testing
@testable import XcodeMCPNativeRuntime

@Suite
@MainActor
struct NativeAnalyticsProductManagerTests {
    @Test func filtersOnlyTheRequestedBundleAndPreservesProductIdentityAndOrder() throws {
        let fixture = AnalyticsProductFixture()
        let view = NativeAnalyticsProductManager(manager: fixture.manager, bundleIdentifier: "SharedApp", familyIdentifier: "iphoneos")
        let products = try #require(view.products as? [AnalyticsProduct])
        #expect(products.map(\.name) == ["Other Mac app", "iOS app", "iOS extension"])
        #expect(products[0] === fixture.other)
        #expect(products[1] === fixture.ios)
        #expect(products[2] === fixture.extensionProduct)
        #expect((fixture.manager.products as? [AnalyticsProduct])?.map(\.name) == ["Mac app", "Other Mac app", "iOS app", "iOS extension"])
        try view.checkFailure()
    }

    @Test func concurrentRequestsKeepTheirOwnPlatformWithoutTaskLocalState() async throws {
        let fixture = AnalyticsProductFixture()
        let ios = Task { @MainActor in
            let view = NativeAnalyticsProductManager(manager: fixture.manager, bundleIdentifier: "SharedApp", familyIdentifier: "iphoneos")
            await Task.yield()
            try view.checkFailure()
            return try #require(view.products as? [AnalyticsProduct]).map(\.name)
        }
        let mac = Task { @MainActor in
            let view = NativeAnalyticsProductManager(manager: fixture.manager, bundleIdentifier: "SharedApp", familyIdentifier: "macosx")
            await Task.yield()
            try view.checkFailure()
            return try #require(view.products as? [AnalyticsProduct]).map(\.name)
        }
        #expect(try await ios.value == ["Other Mac app", "iOS app", "iOS extension"])
        #expect(try await mac.value == ["Mac app", "Other Mac app"])
        #expect(fixture.manager.products.count == 4)
    }

    @Test func aMissingPlatformDoesNotFallBackToAnotherPlatform() throws {
        let fixture = AnalyticsProductFixture()
        let view = NativeAnalyticsProductManager(manager: fixture.manager, bundleIdentifier: "SharedApp", familyIdentifier: "watchos")
        #expect((view.products as? [AnalyticsProduct])?.map(\.name) == ["Other Mac app"])
        try view.checkFailure()
    }

    @Test func productContractFailuresRemainAvailableToTheAsyncCaller() throws {
        let manager = AnalyticsProductManager(products: NSArray(object: NSObject()))
        let view = NativeAnalyticsProductManager(manager: manager, bundleIdentifier: "SharedApp", familyIdentifier: "iphoneos")
        #expect(view.products.count == 0)
        #expect(throws: (any Error).self) { try view.checkFailure() }
        #expect(manager.products.count == 1)
    }

    @Test func nativeManagerOperationsAreForwardedToTheirOriginalOwner() throws {
        let fixture = AnalyticsProductFixture()
        let view = NativeAnalyticsProductManager(manager: fixture.manager, bundleIdentifier: "SharedApp", familyIdentifier: "iphoneos")
        _ = unsafe class_addProtocol(NativeAnalyticsProductManager.self, AnalyticsManagerOperations.self)
        let receiver = try #require(view as? any AnalyticsManagerOperations)
        receiver.load()
        #expect(fixture.manager.loadCount == 1)
        #expect(view.responds(to: #selector(AnalyticsManagerOperations.load)))
    }
}

@objc
private protocol AnalyticsManagerOperations {
    func load()
}

private final class AnalyticsProductFixture {
    let mac = AnalyticsProduct(name: "Mac app", bundle: "SharedApp", family: "macosx")
    let other = AnalyticsProduct(name: "Other Mac app", bundle: "OtherApp", family: "macosx")
    let ios = AnalyticsProduct(name: "iOS app", bundle: "SharedApp", family: "iphoneos")
    let extensionProduct = AnalyticsProduct(name: "iOS extension", bundle: "SharedApp", family: "iphoneos")
    lazy var manager = AnalyticsProductManager(products: NSArray(array: [mac, other, ios, extensionProduct]))
}

private final class AnalyticsProductManager: NSObject {
    @objc let products: NSArray
    private(set) var loadCount = 0
    init(products: NSArray) { self.products = products }
    @objc func load() { loadCount += 1 }
}

private final class AnalyticsProduct: NSObject {
    let name: String
    @objc let identifier: AnalyticsProductIdentifier
    init(name: String, bundle: String, family: String) {
        self.name = name
        identifier = AnalyticsProductIdentifier(bundle: bundle, family: family)
    }
}

private final class AnalyticsProductIdentifier: NSObject {
    @objc let bundleIdentifier: String
    @objc let productCategory: AnalyticsProductCategory
    init(bundle: String, family: String) {
        bundleIdentifier = bundle
        productCategory = AnalyticsProductCategory(family: family)
    }
}

private final class AnalyticsProductCategory: NSObject {
    @objc let platform: AnalyticsPlatform
    init(family: String) { platform = AnalyticsPlatform(family: family) }
}

private final class AnalyticsPlatform: NSObject {
    @objc let family: AnalyticsPlatformFamily
    init(family: String) { self.family = AnalyticsPlatformFamily(identifier: family) }
}

private final class AnalyticsPlatformFamily: NSObject {
    @objc let identifier: String
    init(identifier: String) { self.identifier = identifier }
}
