#if canImport(UIKit)
import UIKit
#endif
#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(AppTrackingTransparency) && canImport(AdSupport)
import AppTrackingTransparency
import AdSupport
#endif
import Foundation

/// The advertising identifier fields of the request's `device` object:
/// `ifa` (IDFA), `lmt` (limit ad tracking), and `atts` (ATT status raw value).
/// Nil fields are omitted.
struct AdvertisingIdentity: Sendable, Equatable {
    var ifa: String?
    var lmt: Int?
    var atts: Int?

    /// Map an `ATTrackingManager.AuthorizationStatus` raw value to the
    /// request fields. `idfa` is read only when tracking is authorized, and
    /// an all-zero identifier is never sent.
    static func from(trackingStatus: UInt, idfa: () -> String) -> AdvertisingIdentity {
        let atts = Int(trackingStatus)
        guard trackingStatus == 3 else { return AdvertisingIdentity(lmt: 1, atts: atts) }
        let ifa = idfa()
        guard !ifa.isEmpty, ifa != "00000000-0000-0000-0000-000000000000" else {
            return AdvertisingIdentity(lmt: 1, atts: atts)
        }
        return AdvertisingIdentity(ifa: ifa, lmt: 0, atts: atts)
    }

    /// Read the app's current ATT status and, only when the user has
    /// authorized tracking, the IDFA. Never requests authorization. Empty on
    /// every platform but iOS.
    static func current() -> AdvertisingIdentity {
        #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(AppTrackingTransparency) && canImport(AdSupport)
        return from(trackingStatus: ATTrackingManager.trackingAuthorizationStatus.rawValue) {
            ASIdentifierManager.shared().advertisingIdentifier.uuidString
        }
        #else
        return AdvertisingIdentity()
        #endif
    }
}

/// Collects device signals for the Gravity ad request.
struct DeviceContext: Sendable {
    let ua: String
    let os: String
    let osVersion: String
    let deviceModel: String
    let screenWidth: Int
    let screenHeight: Int
    let timezone: String
    let locale: String
    let deviceType: String
    let bundle: String?
    let advertising: AdvertisingIdentity

    static func collect(advertising: () -> AdvertisingIdentity = AdvertisingIdentity.current) -> DeviceContext {
        let ua = buildUserAgent()
        let os = osCategory()
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        let model = deviceModel()
        let (w, h) = screenSize()
        let tz = TimeZone.current.identifier
        let locale = Locale.current.identifier

        let type: String
        #if os(iOS)
        if ProcessInfo.processInfo.isMacCatalystApp {
            type = "desktop"
        } else {
            switch UIDevice.current.userInterfaceIdiom {
            case .phone: type = "mobile"
            case .pad:   type = "tablet"
            case .mac:   type = "desktop"
            default:     type = "mobile"
            }
        }
        #elseif os(tvOS)
        type = "tv"
        #elseif os(watchOS)
        type = "watch"
        #else
        type = "desktop"
        #endif

        return DeviceContext(
            ua: ua, os: os, osVersion: osVersion, deviceModel: model,
            screenWidth: w, screenHeight: h,
            timezone: tz, locale: locale, deviceType: type,
            bundle: Bundle.main.bundleIdentifier,
            advertising: advertising()
        )
    }

    func toDict() -> [String: Any] {
        var dict: [String: Any] = [
            "ua": ua,
            "os": os,
            "os_version": osVersion,
            "device_model": deviceModel,
            "screen_width": screenWidth,
            "screen_height": screenHeight,
            "timezone": timezone,
            "locale": locale,
            "device_type": deviceType,
        ]
        if let bundle, !bundle.isEmpty { dict["bundle"] = bundle }
        if let ifa = advertising.ifa { dict["ifa"] = ifa }
        if let lmt = advertising.lmt { dict["lmt"] = lmt }
        if let atts = advertising.atts { dict["atts"] = atts }
        return dict
    }

    private static func buildUserAgent() -> String {
        let info = Bundle.main.infoDictionary
        let appName = info?["CFBundleName"] as? String ?? "App"
        let appVersion = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let os = currentOS()
        let model = deviceModel()
        return "\(appName)/\(appVersion) (\(model); \(os)) GravitySDK/\(ViewabilityBeacon.sdkVersion)"
    }

    private static func currentOS() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if os(iOS)
        let name = ProcessInfo.processInfo.isMacCatalystApp ? "macOS" : "iOS"
        return "\(name) \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #elseif os(macOS)
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #elseif os(tvOS)
        return "tvOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #elseif os(watchOS)
        return "watchOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #else
        return "unknown"
        #endif
    }

    private static func osCategory() -> String {
        #if os(macOS)
        return "macos"
        #elseif os(iOS)
        return ProcessInfo.processInfo.isMacCatalystApp ? "macos" : "ios"
        #else
        return "other"
        #endif
    }

    private static func deviceModel() -> String {
        #if canImport(Darwin)
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
        #else
        return "unknown"
        #endif
    }

    private static func screenSize() -> (Int, Int) {
        #if canImport(UIKit) && !os(watchOS)
        let screen = UIScreen.main.bounds
        let scale = UIScreen.main.scale
        return (Int(screen.width * scale), Int(screen.height * scale))
        #else
        return (0, 0)
        #endif
    }
}
