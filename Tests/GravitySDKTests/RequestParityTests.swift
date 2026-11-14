import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import GravitySDK

final class RequestParityTests: XCTestCase {
    func testGetAdsForwardsNewOptionsThroughTransport() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ParityRequestURLProtocol.self]
        let gravity = Gravity(apiKey: "test", apiUrl: "https://sdk.test/ad", readCMPConsent: false,
                              honorATT: false, session: URLSession(configuration: configuration))
        for production in [false, true] {
            let result = await gravity.getAds(
                messages: [Message(role: "user", content: "hello")], sessionId: "session",
                placements: [.belowResponse(maxAdTextChars: 240, units: ["action"], supportsPromptAction: true)],
                production: production, tags: ["plan": "pro", "paid": true], units: ["image"],
                enableFrames: false, supportsPromptAction: true,
                alwaysReturn: true, adLayout: "image_top", testAdFormat: "action"
            )
            XCTAssertEqual(result.status, 200)
            XCTAssertNil(result.error)
            XCTAssertEqual(result.ads.first?.title, "Transport response")
        }
    }

    func testDefaultRequestOmitsOptionalMetadataAndNeverClaimsWebRenderer() {
        let request = body()
        let placement = (request["placements"] as? [[String: Any]])?.first
        XCTAssertEqual(placement?["placement"] as? String, "below_response")
        XCTAssertEqual(placement?["placement_id"] as? String, "main")
        XCTAssertEqual(placement?.count, 2)
        for key in ["units", "alwaysReturn", "adLayout", "testAdFormat", "supportsPromptAction", "enableFrames"] {
            XCTAssertNil(request[key])
        }
        XCTAssertNil((request["user"] as? [String: Any])?["tags"])
        XCTAssertNil(request["supportsSpec"])
        XCTAssertNotEqual(request["specCapabilities"] as? String, "web1")
        #if canImport(SwiftUI) && canImport(UIKit) && os(iOS)
        XCTAssertEqual(request["specCapabilities"] as? String, "psp1")
        #else
        XCTAssertNil(request["specCapabilities"])
        #endif
    }

    func testPlacementMetadataRequiresExplicitPublisherPromptCapability() {
        let placement = Placement.belowResponse(
            id: "answer", maxAdTextChars: 240, units: ["action"], supportsPromptAction: true
        )
        let unsupported = body(placements: [placement])
        let unsupportedSlot = (unsupported["placements"] as? [[String: Any]])?.first
        XCTAssertNil(unsupportedSlot?["supportsPromptAction"])

        let supported = body(placements: [placement], units: ["text", "image"], supportsPromptAction: true)
        let slot = (supported["placements"] as? [[String: Any]])?.first
        XCTAssertEqual(slot?["placement_id"] as? String, "answer")
        XCTAssertEqual(slot?["max_ad_text_chars"] as? Int, 240)
        XCTAssertEqual(slot?["units"] as? [String], ["action"])
        XCTAssertEqual(slot?["supportsPromptAction"] as? Bool, true)
        XCTAssertEqual(supported["units"] as? [String], ["text", "image"])
        XCTAssertNil(supported["supportsPromptAction"])

        let optedOut = body(placements: [.aboveResponse(supportsPromptAction: false), .inlineResponse()],
                            supportsPromptAction: true)
        for slot in optedOut["placements"] as? [[String: Any]] ?? [] {
            XCTAssertNil(slot["supportsPromptAction"])
        }
    }

    func testStructuredTagsPreserveLegacyFieldsConsentIdentityAndTwoTurns() {
        let gravity = Gravity(apiKey: "test", readCMPConsent: false, honorATT: false)
        let request = gravity.buildRequestBody(
            messages: [Message(role: "user", content: "old"), Message(role: "assistant", content: "answer"),
                       Message(role: "user", content: "new")],
            sessionId: "session", userId: "user", placements: [.belowResponse()],
            userIP: "203.0.113.7", hashedIdentity: HashedIdentity(emailHash: "hashed", hashedPhone: nil),
            extraUserFields: ["age": "25-34", "tags": "legacy"], extraDeviceFields: nil,
            production: nil, relevancy: nil, consent: ConsentSignal(gpc: true),
            usage: ModelUsage(model: "m", inputTokens: 10),
            tags: ["plan": "pro", "visits": 3, "subscribed": true]
        )
        let user = request["user"] as? [String: Any]
        let tags = user?["tags"] as? [String: Any]
        XCTAssertEqual(user?["age"] as? String, "25-34")
        XCTAssertEqual(user?["hashed_email"] as? String, "hashed")
        XCTAssertEqual(tags?["plan"] as? String, "pro")
        XCTAssertEqual(tags?["visits"] as? Int, 3)
        XCTAssertEqual(tags?["subscribed"] as? Bool, true)
        XCTAssertEqual((request["consent"] as? [String: Any])?["gpc"] as? Bool, true)
        XCTAssertEqual((request["usage"] as? [String: Any])?["inputTokens"] as? Int, 10)
        XCTAssertEqual((request["device"] as? [String: Any])?["ip"] as? String, "203.0.113.7")
        XCTAssertEqual((request["messages"] as? [[String: String]])?.map { $0["content"] ?? "" }, ["answer", "new"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(request))
    }

    func testTestOverridesNeverReachProductionAndHonorPerCallFlag() {
        for instanceProduction in [true, false] {
            for override in [nil, true, false] as [Bool?] {
                let request = body(production: override, instanceProduction: instanceProduction,
                                   alwaysReturn: true, adLayout: "image_left", testAdFormat: "action")
                let testAd = !(override ?? instanceProduction)
                XCTAssertEqual(request["testAd"] as? Bool, testAd)
                XCTAssertEqual(request["alwaysReturn"] as? Bool, testAd ? true : nil)
                XCTAssertEqual(request["adLayout"] as? String, testAd ? "image_left" : nil)
                XCTAssertEqual(request["testAdFormat"] as? String, testAd ? "action" : nil)
            }
        }
        let invalid = body(adLayout: "unknown", testAdFormat: "lead_form")
        XCTAssertNil(invalid["adLayout"])
        XCTAssertNil(invalid["testAdFormat"])
    }

    func testFrameCapabilityMatchesPlatformAndOptOut() {
        let request = body()
        #if canImport(WebKit) && canImport(SwiftUI) && canImport(UIKit) && os(iOS)
        XCTAssertEqual(request["supportsFrames"] as? Bool, true)
        XCTAssertEqual(body(enableFrames: true, instanceFrames: false)["supportsFrames"] as? Bool, true)
        #else
        XCTAssertNil(request["supportsFrames"])
        XCTAssertNil(body(enableFrames: true)["supportsFrames"])
        #endif
        XCTAssertNil(body(enableFrames: false)["supportsFrames"])
        XCTAssertNil(body(instanceFrames: false)["supportsFrames"])
    }

    private func body(
        placements: [Placement] = [.belowResponse()],
        production: Bool? = nil,
        instanceProduction: Bool = false,
        units: [String]? = nil,
        enableFrames: Bool? = nil,
        instanceFrames: Bool = true,
        supportsPromptAction: Bool = false,
        alwaysReturn: Bool = false,
        adLayout: String? = nil,
        testAdFormat: String? = nil
    ) -> [String: Any] {
        Gravity(apiKey: "test", production: instanceProduction, readCMPConsent: false,
                honorATT: false, enableFrames: instanceFrames).buildRequestBody(
            messages: [Message(role: "user", content: "hello")], sessionId: "session", userId: "user",
            placements: placements, userIP: nil, hashedIdentity: nil, extraUserFields: nil,
            extraDeviceFields: nil, production: production, relevancy: nil,
            units: units, enableFrames: enableFrames, supportsPromptAction: supportsPromptAction,
            alwaysReturn: alwaysReturn, adLayout: adLayout, testAdFormat: testAdFormat
        )
    }
}

private final class ParityRequestURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            var requestBody = request.httpBody
            if requestBody == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count == 0 { break }
                    guard count > 0 else { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
                    data.append(contentsOf: buffer.prefix(count))
                }
                requestBody = data
            }
            let data = try XCTUnwrap(requestBody)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(body["units"] as? [String], ["image"])
            XCTAssertNil(body["supportsFrames"])
            XCTAssertNil(body["enableFrames"])
            XCTAssertNil(body["supportsPromptAction"])
            let tags = (body["user"] as? [String: Any])?["tags"] as? [String: Any]
            XCTAssertEqual(tags?["plan"] as? String, "pro")
            XCTAssertEqual(tags?["paid"] as? Bool, true)
            let placement = (body["placements"] as? [[String: Any]])?.first
            XCTAssertEqual(placement?["units"] as? [String], ["action"])
            XCTAssertEqual(placement?["max_ad_text_chars"] as? Int, 240)
            XCTAssertEqual(placement?["supportsPromptAction"] as? Bool, true)
            let testAd = try XCTUnwrap(body["testAd"] as? Bool)
            XCTAssertEqual(body["alwaysReturn"] as? Bool, testAd ? true : nil)
            XCTAssertEqual(body["adLayout"] as? String, testAd ? "image_top" : nil)
            XCTAssertEqual(body["testAdFormat"] as? String, testAd ? "action" : nil)
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200,
                                                       httpVersion: nil, headerFields: nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"[{"title":"Transport response"}]"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
