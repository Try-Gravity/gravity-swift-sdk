import Foundation
import XCTest
@testable import GravitySDK

final class AdResponseParityTests: XCTestCase {
    func testRenderActionSizingAndCarouselMetadataSurviveRoundTrip() throws {
        let json = #"""
        {
          "adText":"A useful ad",
          "brandImage":"https://assets.test/brand.png",
          "impUrl":"https://ads.test/imp?p=token",
          "render":{"mode":"iframe","frameUrl":"https://ads.test/f/demo","frameSize":{"width":320,"height":180},"frameHeight":180,"fallback":"spec"},
          "action":{"type":"prompt","id":"action-1","prompt":"Compare options","openUrl":false,"future":{"enabled":true}},
          "renderer_spec":{"version":1,"root":{"type":"box"}},
          "composition":{"renderer":"carousel","items":[{"title":"First","clickUrl":"https://ads.test/card/1","impUrl":"https://ads.test/card-imp/1"}],"height":180}
        }
        """#
        let ad = try decode(json)

        XCTAssertEqual(ad.id, "https://ads.test/imp?p=token")
        XCTAssertEqual(ad.brandImage, "https://assets.test/brand.png")
        XCTAssertEqual(ad.render?["mode"]?.value as? String, "iframe")
        XCTAssertEqual(ad.promptAction?.id, "action-1")
        XCTAssertEqual(ad.promptAction?.prompt, "Compare options")
        XCTAssertEqual(ad.promptAction?.openUrl, false)
        XCTAssertEqual((ad.promptAction?.fields["future"]?.value as? [String: Any])?["enabled"] as? Bool, true)
        XCTAssertEqual(ad.rendererSpec?["version"]?.value as? Int, 1)

        let encoded = try JSONEncoder().encode(ad)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
        let roundTrip = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
        XCTAssertEqual(roundTrip, original)
    }

    func testRendererSpecAcceptsJSONEncodedObject() throws {
        let spec = #"{"version":1,"root":{"type":"text","text":"Hello"}}"#
        let data = try JSONSerialization.data(withJSONObject: ["renderer_spec": spec, "title": "Kept"])
        let ad = try JSONDecoder().decode(AdResponse.self, from: data)

        XCTAssertEqual(ad.title, "Kept")
        XCTAssertEqual(ad.rendererSpec?["version"]?.value as? Int, 1)
        let roundTrip = try JSONDecoder().decode(AdResponse.self, from: JSONEncoder().encode(ad))
        XCTAssertEqual(roundTrip.rendererSpec?["version"]?.value as? Int, 1)
    }

    func testMalformedRendererSpecFallsBackWithoutDroppingAd() throws {
        let specs: [Any] = ["not json", "[]", "null", "42", "{", [], 42, true, NSNull()]
        for spec in specs {
            let data = try JSONSerialization.data(withJSONObject: ["renderer_spec": spec, "adText": "Kept"])
            let ad = try JSONDecoder().decode(AdResponse.self, from: data)
            XCTAssertEqual(ad.adText, "Kept")
            XCTAssertNil(ad.rendererSpec)
        }
    }

    func testUnknownAndMalformedActionObjectsArePreservedButNotExecutable() throws {
        let actions: [[String: Any]] = [
            ["type": "future", "id": "a", "prompt": "Not executable", "extra": ["v": 1]],
            ["type": "prompt", "id": "a"],
            ["type": "prompt", "id": "", "prompt": "Invalid"],
            ["type": "prompt", "id": "a", "prompt": "   "],
            ["type": "prompt", "id": "a", "prompt": "Invalid", "openUrl": "false"],
            ["type": "prompt", "id": "a", "prompt": "Invalid", "openUrl": NSNull()],
        ]
        for action in actions {
            let data = try JSONSerialization.data(withJSONObject: ["action": action, "title": "Kept"])
            let ad = try JSONDecoder().decode(AdResponse.self, from: data)
            XCTAssertEqual(ad.title, "Kept")
            XCTAssertNil(ad.promptAction)
            let encoded = try JSONEncoder().encode(ad)
            let roundTrip = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(roundTrip["action"] as? NSDictionary, action as NSDictionary)
        }
    }

    func testNonObjectOptionalMetadataDoesNotDropAd() throws {
        let ad = try decode(#"{"title":"Kept","render":false,"action":"invalid","brandImage":42}"#)
        XCTAssertEqual(ad.title, "Kept")
        XCTAssertNil(ad.render)
        XCTAssertNil(ad.action)
        XCTAssertNil(ad.promptAction)
        XCTAssertNil(ad.brandImage)
    }

    func testLegacyAdWithoutNewMetadataStillDecodes() throws {
        let ad = try decode(#"{"adText":"Legacy","clickUrl":"https://ads.test/click"}"#)
        XCTAssertEqual(ad.adText, "Legacy")
        XCTAssertNil(ad.render)
        XCTAssertNil(ad.action)
        XCTAssertNil(ad.brandImage)
        XCTAssertNil(ad.rendererSpec)
        XCTAssertFalse(ad.id.isEmpty)
    }

    private func decode(_ json: String) throws -> AdResponse {
        try JSONDecoder().decode(AdResponse.self, from: Data(json.utf8))
    }
}
