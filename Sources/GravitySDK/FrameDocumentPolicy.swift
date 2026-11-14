import Foundation

struct FrameDocumentPolicy {
    private let initialURL: URL
    private let localFixtures: Bool
    private var started = false
    private var documentReceived = false
    private(set) var observedRedirects = 0
    private var immutablePath: String?

    init(initialURL: URL, localFixtures: Bool = false) {
        self.initialURL = initialURL
        self.localFixtures = localFixtures
    }

    mutating func navigate(to url: URL, initiatedByShell: Bool) -> Bool {
        guard !documentReceived else { return false }
        if !started {
            guard initiatedByShell, url == initialURL else { return false }
            started = true
            return true
        }
        guard validImmutableDestination(url),
              immutablePath == nil || immutablePath == url.path else { return false }
        immutablePath = url.path
        observedRedirects += 1
        return true
    }

    mutating func receiveResponse(from url: URL, status: Int) -> Bool {
        guard started, !documentReceived,
              (url == initialURL && immutablePath == nil) ||
                (validImmutableDestination(url) && (immutablePath == nil || immutablePath == url.path)) else { return false }
        if (300..<400).contains(status) { return true }
        guard (200..<300).contains(status) else { return false }
        if url != initialURL { immutablePath = url.path }
        documentReceived = true
        return true
    }

    private func validImmutableDestination(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.percentEncodedQuery == URLComponents(url: initialURL, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
              parts.percentEncodedPath == url.path,
              url.path.range(of: "^/designer-units/(prod|test)/[0-9a-f]{64}\\.html$", options: .regularExpression) != nil else { return false }
        if url.scheme == "https", ["code.trygravity.ai", "code.trygravity.com"].contains(url.host ?? ""),
           url.port == nil || url.port == 443 { return true }
        return localFixtures && initialURL.scheme == "http" && url.scheme == "http" &&
            ["127.0.0.1", "localhost"].contains(initialURL.host ?? "") &&
            ["127.0.0.1", "localhost"].contains(url.host ?? "") && url.port == initialURL.port
    }
}
