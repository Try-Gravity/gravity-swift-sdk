import XCTest
@testable import GravitySDK

final class FrameEventSourceTests: XCTestCase {
    private let cdn = URL(string: "https://code.trygravity.ai/designer-units/test/\(String(repeating: "a", count: 64)).html")!
    private let impURL = "https://server.trygravity.ai/imp?p=original-token"

    @MainActor
    func testExplicitEngineSourceBindsDirectCDNEventsToOriginalIdentity() async throws {
        for host in ["server.trygravity.ai", "test-api.trygravity.ai"] {
            var requests: [(URL, Data)] = []
            let source = AnyCodable("https://\(host):443/api/v1/ad/frame/reviewed-unit?theme=dark#section")
            let sink = try XCTUnwrap(FrameTelemetry(frameURL: cdn, impURL: impURL, frameEventSource: source,
                                                   transport: { requests.append(($0, $1)) }))
            sink.push("frame_ready", data: ["height": 160])
            sink.flush()
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests[0].0.scheme, "https")
            XCTAssertEqual(requests[0].0.host, host)
            XCTAssertEqual(requests[0].0.path, "/api/v1/ad/frame/events")
            XCTAssertNil(requests[0].0.query)
            XCTAssertNil(requests[0].0.fragment)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[0].1) as? [String: Any])
            XCTAssertEqual(body["slug"] as? String, "reviewed-unit")
            XCTAssertEqual(body["imp"] as? String, "original-token")
            sink.dispose()
        }
    }

    @MainActor
    func testInvalidOrEmptyExplicitSourceDisablesTelemetryWithoutLegacyFallback() async throws {
        let legacy = URL(string: "https://frames.example/frame/legacy")!
        let values: [Any] = [
            "", "not a URL", NSNull(), false, 42, [],
            "http://server.trygravity.ai/api/v1/ad/frame/reviewed",
            "https://server.trygravity.ai:444/api/v1/ad/frame/reviewed",
            "https://server.trygravity.ai.evil.example/api/v1/ad/frame/reviewed",
            "https://code.trygravity.ai/api/v1/ad/frame/reviewed",
            "https://user@server.trygravity.ai/api/v1/ad/frame/reviewed",
            "https://server.trygravity.ai/api/v1/ad/frame/UPPER",
            "https://server.trygravity.ai/api/v1/ad/frame/reviewed/",
            "https://server.trygravity.ai/api/v1/ad/frame/reviewed%2Fextra",
            "https://server.trygravity.ai/api/v1/ad/frame/" + String(repeating: "a", count: 65),
        ]
        var sent = 0
        for value in values {
            let sink = FrameTelemetry(frameURL: legacy, impURL: impURL, frameEventSource: AnyCodable(value), transport: { _, _ in sent += 1 })
            XCTAssertNil(sink)
        }
        XCTAssertEqual(sent, 0)
    }

    @MainActor
    func testAbsentSourceRetainsLegacyURLFallbackAndCDNWithoutSourceStaysDisabled() async throws {
        var delivered: [(URL, Data)] = []
        let legacy = URL(string: "https://legacy.example/frame/existing")!
        let sink = try XCTUnwrap(FrameTelemetry(frameURL: legacy, impURL: impURL, transport: { delivered.append(($0, $1)) }))
        sink.push("frame_ready")
        sink.flush()
        XCTAssertEqual(delivered[0].0.host, "legacy.example")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: delivered[0].1) as? [String: Any])
        XCTAssertEqual(body["slug"] as? String, "existing")
        sink.dispose()
        XCTAssertNil(FrameTelemetry(frameURL: cdn, impURL: impURL, transport: { _, _ in XCTFail("CDN is not a collector") }))
    }

    func testSourceSelectionMatchesSelectedRenderAndPreservesExplicitInvalidValues() throws {
        let source = "https://server.trygravity.ai/api/v1/ad/frame/reviewed"
        let frameURL = cdn.absoluteString
        func selection(render: [String: Any]?, composition: [String: Any]?) throws -> FrameSelection {
            var value: [String: Any] = [:]
            value["render"] = render
            value["composition"] = composition
            let data = try JSONSerialization.data(withJSONObject: value)
            let ad = try JSONDecoder().decode(AdResponse.self, from: data)
            let encoded = try JSONEncoder().encode(ad)
            let roundTrip = try JSONDecoder().decode(AdResponse.self, from: encoded)
            return try XCTUnwrap(FrameSelection.select(roundTrip))
        }
        let legacy: [String: Any] = ["mode": "iframe", "frameUrl": frameURL, "frameEventSource": source]
        XCTAssertEqual(try selection(render: nil, composition: legacy).eventSource?.value as? String, source)
        XCTAssertNil(try selection(render: ["mode": "iframe", "frameUrl": frameURL], composition: legacy).eventSource)
        XCTAssertEqual(try selection(render: ["mode": "iframe", "frameUrl": frameURL, "frameEventSource": ""], composition: legacy).eventSource?.value as? String, "")
        XCTAssertTrue(try selection(render: ["mode": "iframe", "frameUrl": frameURL, "frameEventSource": NSNull()], composition: legacy).eventSource?.value is NSNull)
    }
}
