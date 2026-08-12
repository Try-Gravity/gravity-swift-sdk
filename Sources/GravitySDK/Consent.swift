import Foundation
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif

/// End-user privacy/consent signal sent with ad and feedback requests.
///
/// When not supplied explicitly, the SDK auto-reads the app's CMP output:
/// IAB-registered consent SDKs (OneTrust, Sourcepoint, Usercentrics, …)
/// are required to write the user's decision to standard `UserDefaults`
/// keys (`IABTCF_TCString`, `IABTCF_gdprApplies`, `IABUSPrivacy_String`),
/// so consent collected by the publisher's existing banner is forwarded
/// with zero publisher code. No CMP keys present → no consent field, and
/// requests are unchanged.
public struct ConsentSignal: Sendable, Equatable {
    /// Whether GDPR applies to this end user.
    public var gdprApplies: Bool?
    /// IAB TCF v2 consent string collected by the app's CMP.
    public var tcfString: String?
    /// IAB US Privacy (CCPA) string, e.g. `"1YNN"`.
    public var usPrivacy: String?
    /// Opt-out of sale/share (Global Privacy Control semantics). Set to
    /// `true` when the end user has opted out of cross-context tracking —
    /// e.g. denied the App Tracking Transparency prompt. The engine then
    /// serves fully contextual ads and processes no pseudonymous
    /// identifiers.
    public var gpc: Bool?

    public init(
        gdprApplies: Bool? = nil,
        tcfString: String? = nil,
        usPrivacy: String? = nil,
        gpc: Bool? = nil
    ) {
        self.gdprApplies = gdprApplies
        self.tcfString = tcfString
        self.usPrivacy = usPrivacy
        self.gpc = gpc
    }

    /// Read the standard IAB CMP keys from `UserDefaults`.
    /// Returns `nil` when no CMP has written a decision.
    public static func fromCMP(_ defaults: UserDefaults = .standard) -> ConsentSignal? {
        var consent = ConsentSignal()

        // Per the TCF in-app spec, IABTCF_gdprApplies is 0 or 1; absent
        // means undetermined.
        if defaults.object(forKey: "IABTCF_gdprApplies") is Int {
            consent.gdprApplies = defaults.integer(forKey: "IABTCF_gdprApplies") == 1
        }
        if let tc = defaults.string(forKey: "IABTCF_TCString"), !tc.isEmpty {
            consent.tcfString = tc
        }
        if let usp = defaults.string(forKey: "IABUSPrivacy_String"), !usp.isEmpty {
            consent.usPrivacy = usp
        }

        if consent.gdprApplies == nil, consent.tcfString == nil, consent.usPrivacy == nil {
            return nil
        }
        return consent
    }

    /// Whether App Tracking Transparency forbids cross-context tracking of
    /// this user. Apple only permits tracking when the user has explicitly
    /// tapped "Allow" on the ATT prompt, so anything other than
    /// `.authorized` — denied, restricted, or never asked — is treated as an
    /// opt-out of sale/share (fail closed). Returns `nil` on platforms
    /// without ATT, where no device-level signal exists.
    static func attOptsOut() -> Bool? {
        #if canImport(AppTrackingTransparency)
        if #available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, *) {
            switch ATTrackingManager.trackingAuthorizationStatus {
            case .authorized:
                return false
            case .denied, .restricted, .notDetermined:
                return true
            @unknown default:
                return true
            }
        }
        #endif
        return nil
    }

    /// Merge a device-level tracking opt-out into a (possibly absent)
    /// consent signal. Asserting only — never unsets an opt-out already
    /// present, and `false`/`nil` leaves the signal untouched.
    static func merging(_ signal: ConsentSignal?, attOptsOut: Bool?) -> ConsentSignal? {
        guard attOptsOut == true else { return signal }
        var merged = signal ?? ConsentSignal()
        merged.gpc = true
        return merged
    }

    func toDict() -> [String: Any] {
        var dict: [String: Any] = [:]
        if let gdprApplies { dict["gdprApplies"] = gdprApplies }
        if let tcfString { dict["tcfString"] = tcfString }
        if let usPrivacy { dict["usPrivacy"] = usPrivacy }
        if let gpc { dict["gpc"] = gpc }
        return dict
    }
}
