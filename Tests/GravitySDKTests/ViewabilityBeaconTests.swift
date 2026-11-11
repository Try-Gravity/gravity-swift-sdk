import XCTest
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

    func testAdWithoutImpUrlSendsNothing() async throws {
        let gravity = makeGravity()
        gravity.sendViewabilityBeacon(try makeAd(impUrl: nil), event: .measured)
        gravity.sendViewabilityBeacon(try makeAd(impUrl: nil), event: .viewable)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(BeaconRecordingURLProtocol.urls.isEmpty)
    }
}
