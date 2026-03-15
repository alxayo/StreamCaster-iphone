import XCTest
import SwiftUI
@testable import StreamCaster

@MainActor
final class StreamCasterStartupSmokeTests: XCTestCase {
    func testPermissionRequestViewLoads() {
        let host = UIHostingController(rootView: PermissionRequestView())

        host.loadViewIfNeeded()

        XCTAssertNotNil(host.view)
    }

    func testStreamViewLoads() {
        let host = UIHostingController(rootView: StreamView())

        host.loadViewIfNeeded()

        XCTAssertNotNil(host.view)
    }
}