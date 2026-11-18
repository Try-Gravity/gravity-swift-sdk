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
        XCTAssertTrue((device["ua"] as? String ?? "").hasSuffix("GravitySDK/\(ViewabilityBeacon.sdkVersion)"))
    }

    func testDeviceDictCarriesHostBundleIdentifierWhenPresent() {
        let device = DeviceContext.collect()
        XCTAssertEqual(device.bundle, Bundle.main.bundleIdentifier)
        XCTAssertEqual(device.toDict()["bundle"] as? String, Bundle.main.bundleIdentifier)
    }

    func testAuthorizedTrackingSendsIFAWithLimitOff() {
        let identity = AdvertisingIdentity.from(trackingStatus: 3) { "6D92078A-8246-4BA4-AE5B-76104861E7DC" }
        XCTAssertEqual(identity, AdvertisingIdentity(ifa: "6D92078A-8246-4BA4-AE5B-76104861E7DC", lmt: 0, atts: 3))
    }

    func testTrackingNotAuthorizedLimitsWithoutReadingIFA() {
        for status: UInt in [0, 1, 2] {
            let identity = AdvertisingIdentity.from(trackingStatus: status) {
                XCTFail("IDFA must not be read without ATT authorization")
                return "6D92078A-8246-4BA4-AE5B-76104861E7DC"
            }
            XCTAssertEqual(identity, AdvertisingIdentity(ifa: nil, lmt: 1, atts: Int(status)))
        }
    }

    func testZeroOrEmptyIFAIsNeverSent() {
        for zero in ["00000000-0000-0000-0000-000000000000", ""] {
            XCTAssertEqual(AdvertisingIdentity.from(trackingStatus: 3) { zero },
                           AdvertisingIdentity(ifa: nil, lmt: 1, atts: 3))
        }
    }

    func testDeviceDictCarriesInjectedAdvertisingIdentity() {
        let authorized = DeviceContext.collect {
            AdvertisingIdentity(ifa: "6D92078A-8246-4BA4-AE5B-76104861E7DC", lmt: 0, atts: 3)
        }.toDict()
        XCTAssertEqual(authorized["ifa"] as? String, "6D92078A-8246-4BA4-AE5B-76104861E7DC")
        XCTAssertEqual(authorized["lmt"] as? Int, 0)
        XCTAssertEqual(authorized["atts"] as? Int, 3)

        let denied = DeviceContext.collect { AdvertisingIdentity(lmt: 1, atts: 2) }.toDict()
        XCTAssertNil(denied["ifa"])
        XCTAssertEqual(denied["lmt"] as? Int, 1)
        XCTAssertEqual(denied["atts"] as? Int, 2)

        let unavailable = DeviceContext.collect { AdvertisingIdentity() }.toDict()
        for key in ["ifa", "lmt", "atts"] { XCTAssertNil(unavailable[key]) }
    }

    func testPlatformAdvertisingIdentityIsIOSOnly() {
        let identity = AdvertisingIdentity.current()
        #if os(iOS) && !targetEnvironment(macCatalyst)
        XCTAssertNotNil(identity.atts)
        XCTAssertEqual(identity.lmt, identity.ifa == nil ? 1 : 0)
        #else
        XCTAssertEqual(identity, AdvertisingIdentity())
        #endif
    }
}
