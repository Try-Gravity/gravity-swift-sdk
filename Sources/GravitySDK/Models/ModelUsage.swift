import Foundation

/// Usage of the model response an ad request accompanies, reported so your
/// Gravity dashboard can show model cost next to ad earnings. Never used for
/// ad targeting.
///
/// Report the usage of one model response per ad request: the reply the ad is
/// shown with, or the previous reply if the ad is requested before that reply
/// finishes. Invalid values are ignored; they never fail the ad request.
public struct ModelUsage: Sendable {
    /// Model that produced the response, e.g. `"gpt-4.1-mini"`.
    public let model: String?
    /// Input (prompt) tokens the response used.
    public let inputTokens: Int?
    /// Output (completion) tokens the response used.
    public let outputTokens: Int?
    /// What you paid for this model response in USD, if you know it. When
    /// present it is used instead of the list-price estimate. `0` is a free
    /// call, for example an on-device model; values outside 0 to 100 are
    /// ignored.
    public let cost: Double?
    public let cachedInputTokens: Int?

    public init(
        model: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cost: Double? = nil,
        cachedInputTokens: Int? = nil
    ) {
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cost = cost
        self.cachedInputTokens = cachedInputTokens
    }

    func toDict() -> [String: Any] {
        var dict: [String: Any] = [:]
        if let model { dict["model"] = model }
        if let inputTokens { dict["inputTokens"] = inputTokens }
        if let outputTokens { dict["outputTokens"] = outputTokens }
        if let cachedInputTokens { dict["cachedInputTokens"] = cachedInputTokens }
        // JSONSerialization rejects NaN and infinity, which would fail the
        // whole ad request instead of dropping the cost.
        if let cost, cost.isFinite { dict["cost"] = cost }
        return dict
    }
}
