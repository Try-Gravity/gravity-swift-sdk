import Foundation
import XCTest
@testable import GravitySDK

final class DeviceContextTests: XCTestCase {
    #if targetEnvironment(macCatalyst) || os(macOS)
    func testMacReportsDesktopAndMacOSUserAgent() {
        let device = DeviceContext.collect()

        XCTAssertEqual(device.deviceType, "desktop")
        XCTAssertEqual(device.os, "macos")
        XCTAssertTrue(device.ua.contains("; macOS \(device.osVersion))"))
        XCTAssertEqual(device.toDict()["device_type"] as? String, "desktop")
    }
    #endif
    func testDeclaresDeviceCategories() {
        let device = DeviceContext.collect().toDict()
        #if targetEnvironment(macCatalyst) || os(macOS)
        XCTAssertEqual(device["os"] as? String, "macos")
        XCTAssertEqual(device["device_type"] as? String, "desktop")
        #elseif os(iOS)
        XCTAssertEqual(device["os"] as? String, "ios")
        #endif
        XCTAssertFalse((device["os_version"] as? String ?? "").isEmpty)
        XCTAssertTrue((device["ua"] as? String ?? "").contains("GravitySDK/"))
    }
}
