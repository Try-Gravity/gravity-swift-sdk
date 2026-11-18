import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Click resolution for ads whose buyer sent an app deeplink (`hasDeeplink`).
///
/// The SDK asks the server to record the click and return the deeplink and
/// its https fallback as JSON instead of following the browser redirect.
/// Any unexpected answer opens the tracked `clickUrl` exactly as for other
/// ads; the server dedups the click, so a second record is harmless.
enum DeeplinkClick {
    enum Outcome: Equatable {
        /// Try `deeplink`; open `fallback` when no installed app handles it.
        case deeplink(URL, fallback: URL)
        /// Open the https fallback directly; the click is already recorded.
        case fallback(URL)
        /// Open the tracked `clickUrl` as for any other ad.
        case clickUrl
        /// The server deliberately blocked the click. Open nothing.
        case blocked
    }

    static let timeout: TimeInterval = 3

    private static let deniedSchemes: Set<String> = [
        "http", "https", "javascript", "data", "file", "vbscript", "about", "blob",
        "content", "intent", "filesystem", "ftp", "mailto", "tel", "sms",
    ]

    static func resolveRequest(for clickUrl: URL) -> URLRequest? {
        guard var components = URLComponents(url: clickUrl, resolvingAgainstBaseURL: false) else { return nil }
        let query = components.percentEncodedQuery ?? ""
        components.percentEncodedQuery = query.isEmpty ? "resolve=1" : query + "&resolve=1"
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func resolve(_ clickUrl: URL, session: URLSession) async -> Outcome {
        guard let request = resolveRequest(for: clickUrl),
              let result = try? await session.data(for: request) else { return .clickUrl }
        return outcome(status: (result.1 as? HTTPURLResponse)?.statusCode, body: result.0)
    }

    static func outcome(status: Int?, body: Data) -> Outcome {
        if status == 204 { return .blocked }
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let fallback = validFallback(json["fallback"]) else { return .clickUrl }
        guard let deeplink = validDeeplink(json["deeplink"]) else { return .fallback(fallback) }
        return .deeplink(deeplink, fallback: fallback)
    }

    static func validFallback(_ value: Any?) -> URL? {
        guard let string = value as? String, let url = URL(string: string),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    static func validDeeplink(_ value: Any?) -> URL? {
        guard let string = value as? String, let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme.range(of: "^[a-z][a-z0-9+.-]*$", options: .regularExpression) != nil,
              !deniedSchemes.contains(scheme) else { return nil }
        return url
    }
}
