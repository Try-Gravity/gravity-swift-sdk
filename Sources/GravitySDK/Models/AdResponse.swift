import Foundation

/// A single ad returned by the Gravity engine.
public struct AdResponse: Codable, Sendable, Identifiable {
    /// Stable identity for SwiftUI diffing. Falls back to a UUID generated once at decode time.
    public let id: String

    public let adText: String?
    public let title: String?
    public let brandName: String?
    public let cta: String?
    public let url: String?
    public let favicon: String?
    public let clickUrl: String?
    public let impUrl: String?
    public let placement: String?
    public let placementId: String?
    public let campaignId: String?

    // Experiment fields
    public let variant: String?
    public let experimentId: String?
    public let compositionId: String?
    public let rendererKey: String?
    public let compositionMode: String?
    public let composition: [String: AnyCodable]?

    // Lead form
    public let leadForm: LeadFormConfig?

    // Server-rendered spec
    public let rendererSpec: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case adText, title, brandName, cta, url, favicon
        case clickUrl, impUrl, placement
        case placementId = "placement_id"
        case campaignId
        case variant
        case experimentId = "experiment_id"
        case compositionId = "composition_id"
        case rendererKey = "renderer_key"
        case compositionMode = "composition_mode"
        case composition
        case leadForm
        case rendererSpec = "renderer_spec"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        adText = try c.decodeIfPresent(String.self, forKey: .adText)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        brandName = try c.decodeIfPresent(String.self, forKey: .brandName)
        cta = try c.decodeIfPresent(String.self, forKey: .cta)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        favicon = try c.decodeIfPresent(String.self, forKey: .favicon)
        clickUrl = try c.decodeIfPresent(String.self, forKey: .clickUrl)
        impUrl = try c.decodeIfPresent(String.self, forKey: .impUrl)
        placement = try c.decodeIfPresent(String.self, forKey: .placement)
        placementId = try c.decodeIfPresent(String.self, forKey: .placementId)
        campaignId = try c.decodeIfPresent(String.self, forKey: .campaignId)
        variant = try c.decodeIfPresent(String.self, forKey: .variant)
        experimentId = try c.decodeIfPresent(String.self, forKey: .experimentId)
        compositionId = try c.decodeIfPresent(String.self, forKey: .compositionId)
        rendererKey = try c.decodeIfPresent(String.self, forKey: .rendererKey)
        compositionMode = try c.decodeIfPresent(String.self, forKey: .compositionMode)
        composition = try c.decodeIfPresent([String: AnyCodable].self, forKey: .composition)
        leadForm = try c.decodeIfPresent(LeadFormConfig.self, forKey: .leadForm)
        rendererSpec = try c.decodeIfPresent([String: AnyCodable].self, forKey: .rendererSpec)
        id = impUrl ?? UUID().uuidString
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(adText, forKey: .adText)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(brandName, forKey: .brandName)
        try c.encodeIfPresent(cta, forKey: .cta)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(favicon, forKey: .favicon)
        try c.encodeIfPresent(clickUrl, forKey: .clickUrl)
        try c.encodeIfPresent(impUrl, forKey: .impUrl)
        try c.encodeIfPresent(placement, forKey: .placement)
        try c.encodeIfPresent(placementId, forKey: .placementId)
        try c.encodeIfPresent(campaignId, forKey: .campaignId)
        try c.encodeIfPresent(variant, forKey: .variant)
        try c.encodeIfPresent(experimentId, forKey: .experimentId)
        try c.encodeIfPresent(compositionId, forKey: .compositionId)
        try c.encodeIfPresent(rendererKey, forKey: .rendererKey)
        try c.encodeIfPresent(compositionMode, forKey: .compositionMode)
        try c.encodeIfPresent(composition, forKey: .composition)
        try c.encodeIfPresent(leadForm, forKey: .leadForm)
        try c.encodeIfPresent(rendererSpec, forKey: .rendererSpec)
    }
}

/// Convenience wrapper around the ad fetch result.
public struct AdResult: Sendable {
    public let ads: [AdResponse]
    public let status: Int
    public let elapsedMs: Int
    public let error: String?

    public static let empty = AdResult(ads: [], status: 0, elapsedMs: 0, error: nil)
}

/// Lead-form configuration attached to an ad.
public struct LeadFormConfig: Codable, Sendable {
    public let fields: [LeadFormField]
    public let submitUrl: String
    public let headline: String?
    public let description: String?
    public let ctaText: String?
    public let successMessage: String?
    public let privacyText: String?
    public let consentText: String?
    public let successRedirectUrl: String?
    public let display: String?
    public let prefill: LeadFormPrefill?

    enum CodingKeys: String, CodingKey {
        case fields
        case submitUrl = "submit_url"
        case headline, description
        case ctaText = "cta_text"
        case successMessage = "success_message"
        case privacyText = "privacy_text"
        case consentText = "consent_text"
        case successRedirectUrl = "success_redirect_url"
        case display, prefill
    }
}

public struct LeadFormField: Codable, Sendable {
    public let name: String
    public let label: String
    public let type: String
    public let required: Bool
    public let placeholder: String?
    public let options: [String]?
}

public struct LeadFormPrefill: Codable, Sendable {
    public let email: Bool?
    public let phone: Bool?
}

/// Type-erased Codable for dynamic JSON values.
public struct AnyCodable: Codable, Sendable {
    public let value: Any

    public init(_ value: Any) { self.value = value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            value = NSNull()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}
