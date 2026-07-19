import XCTest
@testable import GravitySDK

final class PIITests: XCTestCase {
    func testEmailHashing() {
        let result = hashPII(email: "  TEST@Example.Com  ")
        XCTAssertNotNil(result.emailHash)
        // sha256("test@example.com")
        XCTAssertEqual(
            result.emailHash,
            "973dfe463ec85785f5f95af5ba3906eedb2d931c24e69824a89ea65dba4e813b"
        )
        XCTAssertNil(result.hashedPhone)
    }

    func testPhoneHashing() {
        let result = hashPII(phone: "+1 (555) 123-4567")
        XCTAssertNotNil(result.hashedPhone)
        // sha256("15551234567")
        XCTAssertEqual(
            result.hashedPhone,
            "d6736136ea896c1bfdc553e0e86e702c70d060d805696ca3e4e9e0961353860a"
        )
        XCTAssertNil(result.emailHash)
    }

    func testBothFields() {
        let result = hashPII(email: "user@test.com", phone: "5551234567")
        XCTAssertNotNil(result.emailHash)
        XCTAssertNotNil(result.hashedPhone)
    }

    func testEmptyInputs() {
        let result = hashPII(email: "", phone: "")
        XCTAssertNil(result.emailHash)
        XCTAssertNil(result.hashedPhone)
    }

    func testNilInputs() {
        let result = hashPII()
        XCTAssertNil(result.emailHash)
        XCTAssertNil(result.hashedPhone)
    }
}
