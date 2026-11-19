import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
#if canImport(UIKit) && canImport(WebKit) && os(iOS)
import UIKit
import WebKit
#endif
@testable import GravitySDK

final class ViewabilityBeaconTests: XCTestCase {
    func testBeaconURLKeepsExistingQueryAndAddsEvSdkSv() throws {
        let url = try XCTUnwrap(ViewabilityBeacon.url(
            impUrl: "https://ads.test/imp/abc?p=tok%2Bx&utm=a%20b", event: .viewable))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "ads.test")
        XCTAssertEqual(components.path, "/imp/abc")
        XCTAssertEqual(components.percentEncodedQueryItems, [
            URLQueryItem(name: "p", value: "tok%2Bx"),
            URLQueryItem(name: "utm", value: "a%20b"),
            URLQueryItem(name: "ev", value: "viewable"),
            URLQueryItem(name: "sdk", value: "ios"),
            URLQueryItem(name: "sv", value: ViewabilityBeacon.sdkVersion),
        ])
    }

    func testBeaconURLWithoutExistingQuery() throws {
        let url = try XCTUnwrap(ViewabilityBeacon.url(impUrl: "https://ads.test/imp/abc", event: .measured))
        XCTAssertEqual(url.absoluteString, "https://ads.test/imp/abc?ev=measured&sdk=ios&sv=\(ViewabilityBeacon.sdkVersion)")
    }

    func testBeaconURLRejectsUnparseableImpUrl() {
        XCTAssertNil(ViewabilityBeacon.url(impUrl: "not a url", event: .measured))
        XCTAssertNil(ViewabilityBeacon.url(impUrl: "", event: .viewable))
    }

    func testBeaconLogIsBoundedAndEvictsOldest() {
        let log = ViewabilityBeaconLog(capacity: 2)
        XCTAssertTrue(log.insert("a"))
        XCTAssertFalse(log.insert("a"))
        XCTAssertTrue(log.insert("b"))
        XCTAssertTrue(log.insert("c"))
        XCTAssertTrue(log.insert("a"))
        XCTAssertFalse(log.insert("c"))
    }
}

private final class BeaconRecordingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var recorded: [URL] = []

    static var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static func reset() {
        lock.lock()
        recorded = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url {
            Self.lock.lock()
            Self.recorded.append(url)
            Self.lock.unlock()
        }
        client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
    }

    override func stopLoading() {}
}

final class ViewabilityBeaconSendTests: XCTestCase {
    #if canImport(UIKit) && canImport(WebKit) && os(iOS)
    @MainActor
    func testUIKitFrameInstallsSharedProbeAndDisposesItWithoutBilling() throws {
        let gravity = makeGravity()
        let ad = try JSONDecoder().decode(AdResponse.self, from: Data(
            #"{"impUrl":"https://ads.test/imp/\#(UUID().uuidString)?p=1","render":{"mode":"iframe","frameUrl":"https://frames.example/frame/test"}}"#.utf8
        ))
        let frame = GravityFrameView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        frame.configure(ad: ad, gravity: gravity, sessionId: "test")
        let web = try XCTUnwrap(frame.subviews.compactMap { $0 as? WKWebView }.first)
        let probe = try XCTUnwrap(frame.subviews.compactMap { $0 as? AdProbeView }.first)
        XCTAssertFalse(probe.isOpaque)
        XCTAssertEqual(probe.backgroundColor, .clear)
        XCTAssertLessThan(try XCTUnwrap(frame.subviews.firstIndex(of: probe)),
                          try XCTUnwrap(frame.subviews.firstIndex(of: web)))
        let tap = try XCTUnwrap(web.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer }
            .first { $0.delegate === frame })
        XCTAssertFalse(tap.cancelsTouchesInView)
        XCTAssertFalse(tap.delaysTouchesEnded)
        XCTAssertTrue(frame.gestureRecognizer(tap, shouldRecognizeSimultaneouslyWith: web.scrollView.panGestureRecognizer))
        XCTAssertFalse(probe.isUserInteractionEnabled)
        XCTAssertNotNil(probe.onRefresh)
        probe.onRefresh?()
        XCTAssertFalse(gravity.hasFiredImpression(ad))
        XCTAssertTrue(BeaconRecordingURLProtocol.urls.isEmpty)
        frame.dispose()
        XCTAssertNil(probe.superview)
        XCTAssertNil(probe.onRefresh)
        XCTAssertFalse(frame.hasActiveFrameResources)
    }
    #endif

    func testSharedFrameObservationWaitsForPixelAndDeduplicatesWithSwiftUI() async throws {
        let gravity = makeGravity()
        let ad = try makeAd(impUrl: "https://ads.test/imp/\(UUID().uuidString)?p=1")
        var dwellActions: [() -> Void] = []
        let observations = (0..<2).map { _ in
            ViewabilityObservation(tracker: ViewabilityTracker(scheduler: { delay, action in
                XCTAssertEqual(delay, 1)
                dwellActions.append(action)
                return {}
            }))
        }
        for observation in observations {
            observation.setAd(ad, gravity: gravity)
            observation.tracker.isAttached = true
            observation.tracker.isActive = true
            XCTAssertTrue(observation.refresh { (0.49, true) })
        }
        XCTAssertTrue(dwellActions.isEmpty)
        XCTAssertTrue(BeaconRecordingURLProtocol.urls.isEmpty)
        for observation in observations {
            XCTAssertTrue(observation.refresh { (0.5, true) })
        }
        XCTAssertEqual(dwellActions.count, 2)
        dwellActions.forEach { $0() }
        try await waitForBeacons(1)
        XCTAssertEqual(BeaconRecordingURLProtocol.urls.count, 1)
        XCTAssertTrue(BeaconRecordingURLProtocol.urls[0].absoluteString.contains("ev=viewable"))
        for observation in observations {
            XCTAssertTrue(observation.refresh { XCTFail("Wait for the pixel without measuring"); return nil })
        }
        gravity.trackImpression(ad)
        for observation in observations {
            XCTAssertFalse(observation.refresh { (0.5, true) })
        }
        try await waitForBeacons(3)
        let urls = BeaconRecordingURLProtocol.urls
        XCTAssertEqual(urls.count, 3)
        XCTAssertEqual(urls.filter { $0.absoluteString == ad.impUrl }.count, 1)
        XCTAssertEqual(urls.filter { $0.absoluteString.contains("ev=measured") }.count, 1)
        XCTAssertEqual(urls.filter { $0.absoluteString.contains("ev=viewable") }.count, 1)
    }

    func testSharedObservationWithoutImpressionOrMeasurementSendsNothing() async throws {
        let gravity = makeGravity()
        let observation = ViewabilityObservation()
        observation.setAd(try makeAd(impUrl: nil), gravity: gravity)
        observation.tracker.isAttached = true
        observation.tracker.isActive = true
        XCTAssertFalse(observation.refresh { nil })
        XCTAssertTrue(BeaconRecordingURLProtocol.urls.isEmpty)
        let ad = try makeAd(impUrl: "https://ads.test/imp/\(UUID().uuidString)?p=1")
        observation.setAd(ad, gravity: gravity)
        XCTAssertTrue(observation.refresh { (0, false) })
        XCTAssertFalse(observation.tracker.fired)
        XCTAssertTrue(BeaconRecordingURLProtocol.urls.isEmpty)
    }

    private func makeGravity() -> Gravity {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BeaconRecordingURLProtocol.self]
        BeaconRecordingURLProtocol.reset()
        return Gravity(apiKey: "test", session: URLSession(configuration: configuration))
    }

    private func makeAd(impUrl: String?) throws -> AdResponse {
        let imp = impUrl.map { #","impUrl":"\#($0)""# } ?? ""
        let json = #"{"adText":"Ad","title":"Example"\#(imp)}"#
        return try JSONDecoder().decode(AdResponse.self, from: Data(json.utf8))
    }

    private func waitForBeacons(_ count: Int) async throws {
        for _ in 0..<100 where BeaconRecordingURLProtocol.urls.count < count {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testEachEventFiresOncePerImpUrlAndLeavesThePixelAlone() async throws {
        let impUrl = "https://ads.test/imp/\(UUID().uuidString)?p=1"
        let gravity = makeGravity()
        let ad = try makeAd(impUrl: impUrl)

        gravity.sendViewabilityBeacon(ad, event: .measured)
        gravity.sendViewabilityBeacon(ad, event: .measured)
        gravity.sendViewabilityBeacon(ad, event: .viewable)
        gravity.sendViewabilityBeacon(ad, event: .viewable)
        try await waitForBeacons(2)
        try await Task.sleep(nanoseconds: 200_000_000)

        let urls = BeaconRecordingURLProtocol.urls
        XCTAssertEqual(urls.count, 2)
        let events = urls.compactMap { url in
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ev" }?.value
        }
        XCTAssertEqual(Set(events), ["measured", "viewable"])
        XCTAssertTrue(urls.allSatisfy { $0.absoluteString.contains("p=1") && $0.absoluteString.contains("sdk=ios") })
    }

    func testMeasuredGoesOutWithThePixelAndNotBefore() async throws {
        let impUrl = "https://ads.test/imp/\(UUID().uuidString)?p=1"
        let gravity = makeGravity()
        let ad = try makeAd(impUrl: impUrl)

        gravity.sendMeasuredBeaconIfPixelFired(ad)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(BeaconRecordingURLProtocol.urls.isEmpty)

        gravity.trackImpression(ad)
        gravity.sendMeasuredBeaconIfPixelFired(ad)
        gravity.sendMeasuredBeaconIfPixelFired(ad)
        try await waitForBeacons(2)
        try await Task.sleep(nanoseconds: 200_000_000)

        let urls = BeaconRecordingURLProtocol.urls
        XCTAssertEqual(urls.count, 2)
        let pixel = urls.filter { $0.absoluteString == impUrl }
        let measured = urls.filter { $0.absoluteString.contains("ev=measured") }
        XCTAssertEqual(pixel.count, 1)
        XCTAssertEqual(measured.count, 1)
    }

    func testSdkVersionMatchesTheVersionFile() throws {
        let versionFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VERSION")
        let version = try String(contentsOf: versionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(ViewabilityBeacon.sdkVersion, version)
    }

    func testAdWithoutImpUrlSendsNothing() async throws {
        let gravity = makeGravity()
        gravity.sendViewabilityBeacon(try makeAd(impUrl: nil), event: .measured)
        gravity.sendViewabilityBeacon(try makeAd(impUrl: nil), event: .viewable)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(BeaconRecordingURLProtocol.urls.isEmpty)
    }
}
