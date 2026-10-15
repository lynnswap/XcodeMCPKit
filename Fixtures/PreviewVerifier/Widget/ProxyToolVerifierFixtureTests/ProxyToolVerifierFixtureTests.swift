import XCTest
@testable import ProxyToolVerifierFixture

final class ProxyToolVerifierFixtureTests: XCTestCase {
    func testMessage() {
        XCTAssertEqual(VerifierCore.number(), 42)
    }
}