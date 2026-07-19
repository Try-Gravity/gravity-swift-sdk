import XCTest
@testable import GravitySDK

final class MessageTests: XCTestCase {
    func testValidRolesProduceDict() {
        for role in ["user", "assistant", "system", "developer", "model"] {
            let msg = Message(role: role, content: "hello")
            let dict = msg.toDict()
            XCTAssertNotNil(dict)
            XCTAssertEqual(dict?["role"], role)
            XCTAssertEqual(dict?["content"], "hello")
        }
    }

    func testInvalidRolesReturnNil() {
        for role in ["tool", "function", "ipython"] {
            let msg = Message(role: role, content: "data")
            XCTAssertNil(msg.toDict())
        }
    }
}
