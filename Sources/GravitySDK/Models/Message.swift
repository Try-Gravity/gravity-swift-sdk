import Foundation

/// A conversation message for contextual ad matching.
public struct Message: Sendable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }

    static let validRoles: Set<String> = [
        "user", "assistant", "system", "developer", "model",
    ]

    func toDict() -> [String: String]? {
        guard Self.validRoles.contains(role) else { return nil }
        return ["role": role, "content": content]
    }
}
