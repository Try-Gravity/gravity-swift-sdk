#if canImport(UIKit)
import UIKit
#endif
import Foundation

/// Collects device signals for the Gravity ad request.
struct DeviceContext: Sendable {
    let ua: String
    let os: String
    let deviceModel: String
    let screenWidth: Int
    let screenHeight: Int
    let timezone: String
    let locale: String
    let deviceType: String

    static func collect() -> DeviceContext {
        let ua = buildUserAgent()
        let os = currentOS()
        let model = deviceModel()
        let (w, h) = screenSize()
        let tz = TimeZone.current.identifier
        let locale = Locale.current.identifier

        let type: String
        #if os(iOS)
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: type = "mobile"
        case .pad:   type = "tablet"
        default:     type = "mobile"
        }
        #elseif os(tvOS)
        type = "tv"
        #elseif os(watchOS)
        type = "watch"
        #else
        type = "desktop"
        #endif

        return DeviceContext(
            ua: ua, os: os, deviceModel: model,
            screenWidth: w, screenHeight: h,
            timezone: tz, locale: locale, deviceType: type
        )
    }

    func toDict() -> [String: Any] {
        [
            "ua": ua,
            "os": os,
            "device_model": deviceModel,
            "screen_width": screenWidth,
            "screen_height": screenHeight,
            "timezone": timezone,
            "locale": locale,
            "device_type": deviceType,
        ]
    }

    private static func buildUserAgent() -> String {
        let info = Bundle.main.infoDictionary
        let appName = info?["CFBundleName"] as? String ?? "App"
        let appVersion = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let os = currentOS()
        let model = deviceModel()
        return "\(appName)/\(appVersion) (\(model); \(os)) GravitySDK/1.0"
    }

    private static func currentOS() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if os(iOS)
        return "iOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
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
