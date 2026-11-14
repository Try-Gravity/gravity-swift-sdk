import Foundation
import XCTest
@testable import GravitySDK

final class ModelUsageTests: XCTestCase {
    private func body(usage: ModelUsage?) -> [String: Any] {
        Gravity(apiKey: "k", readCMPConsent: false, honorATT: false).buildRequestBody(
            messages: [Message(role: "user", content: "hi")],
            sessionId: "s", userId: "u", placements: [.belowResponse()],
            userIP: nil, hashedIdentity: nil, extraUserFields: nil,
            extraDeviceFields: nil, production: nil, relevancy: nil,
            usage: usage
        )
    }

    func testUsageSentWhenGiven() {
        let usage = body(usage: ModelUsage(
            model: "gpt-4.1-mini", inputTokens: 1830, outputTokens: 412, cost: 0.0012
        ))["usage"] as? [String: Any]
        XCTAssertEqual(usage?["model"] as? String, "gpt-4.1-mini")
        XCTAssertEqual(usage?["inputTokens"] as? Int, 1830)
        XCTAssertEqual(usage?["outputTokens"] as? Int, 412)
        XCTAssertEqual(usage?["cost"] as? Double, 0.0012)
    }

    func testUsageOmittedWhenAbsentOrEmpty() {
        XCTAssertNil(body(usage: nil)["usage"])
        XCTAssertNil(body(usage: ModelUsage())["usage"])
    }

    func testCachedInputTokensAreForwardedWithFreeReportedCost() {
        let usage = body(usage: ModelUsage(
            model: "m", inputTokens: 100, cost: 0, cachedInputTokens: 80
        ))["usage"] as? [String: Any]
        XCTAssertEqual(usage?["inputTokens"] as? Int, 100)
        XCTAssertEqual(usage?["cachedInputTokens"] as? Int, 80)
        XCTAssertEqual(usage?["cost"] as? Double, 0)
    }

    /// A NaN or infinite cost would make the whole body unserializable.
    func testUserIPSentOnlyAsDeviceIP() {
        let request = Gravity(apiKey: "k", readCMPConsent: false, honorATT: false).buildRequestBody(
            messages: [Message(role: "user", content: "hi")],
            sessionId: "s", userId: "u", placements: [.belowResponse()],
            userIP: "203.0.113.7", hashedIdentity: HashedIdentity(emailHash: "abc", hashedPhone: nil),
            extraUserFields: nil, extraDeviceFields: nil, production: nil, relevancy: nil
        )
        let user = request["user"] as? [String: Any]
        let device = request["device"] as? [String: Any]
        XCTAssertNil(user?["ip"])
        XCTAssertEqual(device?["ip"] as? String, "203.0.113.7")
        XCTAssertEqual(user?["hashed_email"] as? String, "abc")
        XCTAssertNil(user?["email_hash"])
    }

    func testNonFiniteCostDroppedAndBodyStaysSerializable() {
        for cost in [Double.nan, .infinity] {
            let request = body(usage: ModelUsage(model: "gpt-4o", cost: cost))
            XCTAssertNil((request["usage"] as? [String: Any])?["cost"])
            XCTAssertTrue(JSONSerialization.isValidJSONObject(request))
        }
    }
}
