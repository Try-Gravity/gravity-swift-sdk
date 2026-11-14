import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor
final class FrameTelemetry {
    typealias Transport = (URL, Data) -> Void
    private let endpoint: URL
    private let token: String
    private let slug: String
    private let transport: Transport
    private let clock: () -> TimeInterval
    private let start: TimeInterval
    private var visibleSince: TimeInterval?
    private var visibleMs: Double = 0
    private var events: [[String: Any]] = []
    private var taps = 0
    private var interacted = false
    private var timer: Timer?
    private var disposed = false
    private var ready = false
    private var closed = false
    private var foreground = true

    init?(frameURL: URL, impURL: String?, frameEventSource: AnyCodable? = nil,
          clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 * 1000 }, transport: @escaping Transport = FrameTelemetry.send) {
        let identity: URL
        if let frameEventSource {
            guard let value = frameEventSource.value as? String, let parts = URLComponents(string: value),
                  parts.scheme?.lowercased() == "https",
                  ["server.trygravity.ai", "test-api.trygravity.ai"].contains(parts.host?.lowercased() ?? ""),
                  parts.port == nil || parts.port == 443,
                  (parts.user ?? "").isEmpty, (parts.password ?? "").isEmpty,
                  parts.percentEncodedPath.range(of: "^/api/v1/ad/frame/[a-z0-9][a-z0-9_-]{0,63}$", options: .regularExpression) != nil,
                  let url = parts.url else { return nil }
            identity = url
        } else { identity = frameURL }
        guard let impURL, let parts = URLComponents(string: impURL),
              let token = parts.queryItems?.first(where: { $0.name == "p" })?.value, !token.isEmpty,
              identity.lastPathComponent.range(of: "^[a-z0-9][a-z0-9_-]{0,63}$", options: .regularExpression) != nil,
              var origin = URLComponents(url: identity, resolvingAgainstBaseURL: false) else { return nil }
        origin.path = "/api/v1/ad/frame/events"
        origin.query = nil
        origin.fragment = nil
        guard let endpoint = origin.url else { return nil }
        self.endpoint = endpoint
        self.token = token
        self.slug = identity.lastPathComponent
        self.transport = transport
        self.clock = clock
        self.start = clock()
    }

    nonisolated private static func send(_ url: URL, _ data: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        session.dataTask(with: request) { _, _, _ in session.finishTasksAndInvalidate() }.resume()
    }

    private func envelope(_ batch: [[String: Any]]) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["imp": token, "slug": slug, "now": clock(), "events": batch])
    }

    func push(_ name: String, data: Any? = nil, action: String? = nil) {
        guard !disposed, name.range(of: "^[a-z][a-z0-9_]{0,39}$", options: .regularExpression) != nil else { return }
        let event: [String: Any] = ["name": name, "ts": clock(), "t_ms": max(0, clock() - start),
                                    "data": data ?? NSNull(), "action": action.map { $0 as Any } ?? NSNull()]
        guard let encoded = envelope([event]), encoded.count <= 12000 else { return }
        if name == "frame_ready" { ready = true }
        if name == "frame_tap" { taps += 1 }
        if name == "click" || name == "frame_first_interaction" { interacted = true }
        events.append(event)
        if events.count >= 20 { flush() }
        else if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.flush() }
            }
        }
    }

    func setVisible(_ visible: Bool) {
        if visible { closed = false }
        let now = clock()
        if let since = visibleSince { visibleMs += max(0, now - since) }
        visibleSince = visible ? now : nil
    }

    func close(_ reason: String) {
        guard !closed else { flush(); return }
        closed = true
        setVisible(false)
        if ready {
            push("frame_close", data: ["reason": reason, "total_ms": max(0, clock() - start),
                                       "visible_ms": visibleMs, "taps": taps, "interacted": interacted])
        }
        flush()
    }

    func setForeground(_ active: Bool) {
        guard active != foreground else { return }
        foreground = active
        if active { closed = false } else { close("hidden") }
    }

    func flush() {
        timer?.invalidate()
        timer = nil
        while !events.isEmpty {
            var count = min(events.count, 50)
            while count > 1 && (envelope(Array(events.prefix(count)))?.count ?? Int.max) > 12000 { count = (count + 1) / 2 }
            let batch = Array(events.prefix(count))
            events.removeFirst(count)
            if let data = envelope(batch), data.count <= 12000 { transport(endpoint, data) }
        }
    }

    func dispose() {
        guard !disposed else { return }
        close("unmount")
        disposed = true
    }
}
