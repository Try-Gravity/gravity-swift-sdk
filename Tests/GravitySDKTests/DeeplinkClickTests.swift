import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import GravitySDK

final class DeeplinkClickTests: XCTestCase {
    private let deeplink = "zmaticoo://product/42?ref=gravity"
    private let fallback = "https://shop.example/product/42"

    func testResolveRequestAppendsResolveKeepingQueryAndAcceptsJSON() throws {
        let click = try XCTUnwrap(URL(string: "https://server.test/api/v1/click?c=abc%2Fdef&p=1"))
        let request = try XCTUnwrap(DeeplinkClick.resolveRequest(for: click))
        XCTAssertEqual(request.url?.absoluteString, "https://server.test/api/v1/click?c=abc%2Fdef&p=1&resolve=1")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 3)

        let bare = try XCTUnwrap(DeeplinkClick.resolveRequest(for: XCTUnwrap(URL(string: "https://server.test/click"))))
        XCTAssertEqual(bare.url?.absoluteString, "https://server.test/click?resolve=1")
    }

    @MainActor
    func testValidDeeplinkOpensAppAfterRecordingClick() async throws {
        let (gravity, opener, click) = makeClient(status: 200, body: ["deeplink": deeplink, "fallback": fallback])
        await gravity.resolveDeeplinkClick(click)
        XCTAssertEqual(opener.opened, [deeplink])
        XCTAssertEqual(ResolveStub.requests(for: click).map(\.url?.query), ["c=1&resolve=1"])
        XCTAssertEqual(ResolveStub.requests(for: click).first?.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    @MainActor
    func testUnhandledDeeplinkOpensFallback() async throws {
        let (gravity, opener, click) = makeClient(status: 200, body: ["deeplink": deeplink, "fallback": fallback])
        opener.refuse = ["zmaticoo"]
        await gravity.resolveDeeplinkClick(click)
        XCTAssertEqual(opener.opened, [deeplink, fallback])
    }

    @MainActor
    func testMissingInvalidOrDeniedDeeplinkOpensFallbackOnly() async throws {
        let deeplinks: [Any?] = [
            nil, NSNull(), 42, "", "not a url", "1app://x", "https://evil.example", "HTTP://x", "javascript:alert(1)",
            "data:text/html,x", "file:///etc/passwd", "vbscript:x", "about:blank", "blob:x", "content://x",
            "INTENT://x#Intent;end", "filesystem:x", "ftp://x", "mailto:a@b.c", "tel:123", "sms:123",
        ]
        for value in deeplinks {
            var body: [String: Any] = ["fallback": fallback]
            body["deeplink"] = value
            let (gravity, opener, click) = makeClient(status: 200, body: body)
            await gravity.resolveDeeplinkClick(click)
            XCTAssertEqual(opener.opened, [fallback], "deeplink \(String(describing: value))")
        }
    }

    @MainActor
    func testInvalidFallbackOpensClickUrl() async throws {
        for value: Any in [NSNull(), 42, "", "ftp://shop.example", "https://", "javascript:alert(1)", "shop.example/x"] {
            let (gravity, opener, click) = makeClient(status: 200, body: ["deeplink": deeplink, "fallback": value])
            await gravity.resolveDeeplinkClick(click)
            XCTAssertEqual(opener.opened, [click.absoluteString], "fallback \(value)")
        }
        let (gravity, opener, click) = makeClient(status: 200, body: ["deeplink": deeplink])
        await gravity.resolveDeeplinkClick(click)
        XCTAssertEqual(opener.opened, [click.absoluteString])
    }

    @MainActor
    func testBlockedClickOpensNothing() async {
        let (gravity, opener, click) = makeClient(status: 204, body: nil)
        await gravity.resolveDeeplinkClick(click)
        XCTAssertEqual(opener.opened, [])
        XCTAssertEqual(ResolveStub.requests(for: click).count, 1)
    }

    @MainActor
    func testServerErrorUnparseableBodyOrNetworkFailureOpensClickUrl() async {
        for status in [500, 302, 404] {
            let (gravity, opener, click) = makeClient(status: status, body: ["deeplink": deeplink, "fallback": fallback])
            await gravity.resolveDeeplinkClick(click)
            XCTAssertEqual(opener.opened, [click.absoluteString], "status \(status)")
        }
        let (unparseable, unparseableOpener, unparseableClick) = makeClient(status: 200, raw: Data("<html>".utf8))
        await unparseable.resolveDeeplinkClick(unparseableClick)
        XCTAssertEqual(unparseableOpener.opened, [unparseableClick.absoluteString])

        for error in [URLError(.timedOut), URLError(.notConnectedToInternet)] {
            let (gravity, opener, click) = makeClient(failure: error)
            await gravity.resolveDeeplinkClick(click)
            XCTAssertEqual(opener.opened, [click.absoluteString])
        }
    }

    @MainActor
    func testOnlyDeeplinkAdsMainClickUrlUsesResolveFlow() async throws {
        let (gravity, opener, click) = makeClient(status: 200, body: ["deeplink": deeplink, "fallback": fallback])
        let plain = try ad(click: click, hasDeeplink: nil)
        let disabled = try ad(click: click, hasDeeplink: false)
        let deeplinkAd = try ad(click: click, hasDeeplink: true)

        XCTAssertFalse(gravity.handleDeeplinkClick(plain, url: click))
        XCTAssertFalse(gravity.handleDeeplinkClick(disabled, url: click))
        XCTAssertFalse(gravity.handleDeeplinkClick(deeplinkAd, url: try XCTUnwrap(URL(string: "https://server.test/card/1"))))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(ResolveStub.requests(for: click).count, 0)
        XCTAssertEqual(opener.opened, [])

        XCTAssertTrue(gravity.handleDeeplinkClick(deeplinkAd, url: click))
        for _ in 0..<100 where opener.opened.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(opener.opened, [deeplink])
        XCTAssertEqual(ResolveStub.requests(for: click).count, 1)
    }

    private func ad(click: URL, hasDeeplink: Bool?) throws -> AdResponse {
        var json: [String: Any] = ["adText": "Ad", "clickUrl": click.absoluteString]
        if let hasDeeplink { json["hasDeeplink"] = hasDeeplink }
        return try JSONDecoder().decode(AdResponse.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @MainActor
    private func makeClient(status: Int = 200, body: [String: Any]? = nil, raw: Data? = nil,
                            failure: URLError? = nil) -> (Gravity, RecordingOpener, URL) {
        let click = URL(string: "https://server.test/click/\(UUID().uuidString)?c=1")!
        let data = raw ?? body.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        ResolveStub.register(click, response: failure.map { .failure($0) } ?? .success((status, data)))
        addTeardownBlock { ResolveStub.unregister(click) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResolveStub.self]
        let opener = RecordingOpener()
        let gravity = Gravity(apiKey: "test", session: URLSession(configuration: configuration),
                              openURL: { url in opener.open(url) })
        return (gravity, opener, click)
    }
}

@MainActor
private final class RecordingOpener {
    var opened: [String] = []
    var refuse: Set<String> = []

    func open(_ url: URL) -> Bool {
        opened.append(url.absoluteString)
        return !refuse.contains(url.scheme ?? "")
    }
}

private final class ResolveStub: URLProtocol {
    private static let lock = NSLock()
    private static var responses: [String: Result<(Int, Data), URLError>] = [:]
    private static var seen: [String: [URLRequest]] = [:]

    static func register(_ url: URL, response: Result<(Int, Data), URLError>) {
        lock.lock()
        defer { lock.unlock() }
        responses[url.path] = response
        seen[url.path] = []
    }

    static func unregister(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        responses[url.path] = nil
        seen[url.path] = nil
    }

    static func requests(for url: URL) -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return seen[url.path] ?? []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.lock()
        let response = Self.responses[path]
        Self.seen[path, default: []].append(request)
        Self.lock.unlock()
        switch response {
        case .success((let status, let body))?:
            let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error)?:
            client?.urlProtocol(self, didFailWithError: error)
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
        }
    }

    override func stopLoading() {}
}
