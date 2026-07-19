import Foundation

/// An ad placement slot in your UI.
public struct Placement: Sendable {
    public let placement: String
    public let placementId: String

    public init(placement: String, placementId: String) {
        self.placement = placement
        self.placementId = placementId
    }

    /// Below the AI response — the most common slot.
    public static func belowResponse(id: String = "main") -> Placement {
        Placement(placement: "below_response", placementId: id)
    }

    public static func inlineResponse(id: String = "main") -> Placement {
        Placement(placement: "inline_response", placementId: id)
    }

    public static func aboveResponse(id: String = "main") -> Placement {
        Placement(placement: "above_response", placementId: id)
    }

    func toDict() -> [String: String] {
        ["placement": placement, "placement_id": placementId]
    }
}
