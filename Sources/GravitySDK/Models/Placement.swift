import Foundation

/// An ad placement slot in your UI.
public struct Placement: Sendable {
    public let placement: String
    public let placementId: String
    public let maxAdTextChars: Int?
    public let units: [String]?
    public let supportsPromptAction: Bool?

    public init(
        placement: String,
        placementId: String,
        maxAdTextChars: Int? = nil,
        units: [String]? = nil,
        supportsPromptAction: Bool? = nil
    ) {
        self.placement = placement
        self.placementId = placementId
        self.maxAdTextChars = maxAdTextChars
        self.units = units
        self.supportsPromptAction = supportsPromptAction
    }

    /// Below the AI response — the most common slot.
    public static func belowResponse(
        id: String = "main",
        maxAdTextChars: Int? = nil,
        units: [String]? = nil,
        supportsPromptAction: Bool? = nil
    ) -> Placement {
        Placement(placement: "below_response", placementId: id, maxAdTextChars: maxAdTextChars,
                  units: units, supportsPromptAction: supportsPromptAction)
    }

    public static func inlineResponse(
        id: String = "main",
        maxAdTextChars: Int? = nil,
        units: [String]? = nil,
        supportsPromptAction: Bool? = nil
    ) -> Placement {
        Placement(placement: "inline_response", placementId: id, maxAdTextChars: maxAdTextChars,
                  units: units, supportsPromptAction: supportsPromptAction)
    }

    public static func aboveResponse(
        id: String = "main",
        maxAdTextChars: Int? = nil,
        units: [String]? = nil,
        supportsPromptAction: Bool? = nil
    ) -> Placement {
        Placement(placement: "above_response", placementId: id, maxAdTextChars: maxAdTextChars,
                  units: units, supportsPromptAction: supportsPromptAction)
    }

    func toDict(supportsPromptAction publisherSupportsPromptAction: Bool = false) -> [String: Any] {
        var dict: [String: Any] = ["placement": placement, "placement_id": placementId]
        if let maxAdTextChars { dict["max_ad_text_chars"] = maxAdTextChars }
        if let units { dict["units"] = units }
        if publisherSupportsPromptAction && supportsPromptAction == true {
            dict["supportsPromptAction"] = true
        }
        return dict
    }
}
