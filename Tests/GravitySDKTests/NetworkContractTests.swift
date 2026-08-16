import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import GravitySDK

final class NetworkContractTests: XCTestCase {
    func testSuccessfulAdArrayPreservesExistingBehavior() async {
        let body = Data(#"[{"adText":"A useful ad","title":"Example","impUrl":"https://ads.test/impression"}]"#.utf8)
        let (gravity, endpoint) = makeClient { stub in
            stub.respond(status: 200, body: body)
        }
        defer { StubURLProtocol.unregister(endpoint) }

        let result = await fetchAds(using: gravity)

        XCTAssertEqual(result.status, 200)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.ads.count, 1)
        XCTAssertEqual(result.ads.first?.title, "Example")
    }

    func testSuccessfulEmptyArrayRemainsValid() async {
        let (gravity, endpoint) = makeClient { stub in
            stub.respond(status: 200, body: Data("[]".utf8))
        }
        defer { StubURLProtocol.unregister(endpoint) }

        let result = await fetchAds(using: gravity)

        XCTAssertEqual(result.status, 200)
        XCTAssertNil(result.error)
        XCTAssertTrue(result.ads.isEmpty)
    }

    func testNoFillResponseRemainsAValidEmptyResult() async {
        let (gravity, endpoint) = makeClient { stub in
            stub.respond(status: 204, body: Data())
        }
        defer { StubURLProtocol.unregister(endpoint) }

        let result = await fetchAds(using: gravity)

        XCTAssertEqual(result.status, 204)
        XCTAssertNil(result.error)
        XCTAssertTrue(result.ads.isEmpty)
    }

    func testNonSuccessResponsesPreserveStatusAndServerText() async {
        let cases = [
            (401, "invalid API key"),
            (401, #"{"error":"invalid API key"}"#),
            (429, "too many requests"),
            (500, "upstream unavailable"),
        ]

        for (status, message) in cases {
            let (gravity, endpoint) = makeClient { stub in
                stub.respond(status: status, body: Data(message.utf8))
            }
            let result = await fetchAds(using: gravity)
            StubURLProtocol.unregister(endpoint)

            XCTAssertTrue(result.ads.isEmpty)
            XCTAssertEqual(result.status, status)
            XCTAssertEqual(result.error, "HTTP \(status): \(message)")
        }
    }

    func testRedirectResponseUsesTheGenericHTTPDiagnosticPath() async {
        let (gravity, endpoint) = makeClient { stub in
            stub.respond(status: 302, body: Data("moved".utf8))
        }
        defer { StubURLProtocol.unregister(endpoint) }

        let result = await fetchAds(using: gravity)

        XCTAssertTrue(result.ads.isEmpty)
        XCTAssertEqual(result.status, 302)
        XCTAssertEqual(result.error, "HTTP 302: moved")
    }

    func testHTTPFailureDiagnosticIsNormalizedAndBounded() async {
        let body = " \n first\tsecond \r\n" + String(repeating: "x", count: 1_000)
        let (gravity, endpoint) = makeClient { stub in
            stub.respond(status: 500, body: Data(body.utf8))
        }
        defer { StubURLProtocol.unregister(endpoint) }

        let result = await fetchAds(using: gravity)
        let diagnostic = result.error

        XCTAssertTrue(result.ads.isEmpty)
        XCTAssertEqual(result.status, 500)
        XCTAssertNotNil(diagnostic)
        XCTAssertTrue(diagnostic?.hasPrefix("HTTP 500: first second ") == true)
        XCTAssertEqual(diagnostic?.count, 512)
        XCTAssertTrue(diagnostic?.last == "…")
    }

    func testEmptyWhitespaceAndNonUTF8FailureBodiesUseGenericDiagnostic() async {
        let bodies = [
            Data(),
            Data(" \n\t".utf8),
            Data([0xff, 0xfe, 0xfd]),
        ]

        for body in bodies {
            let (gravity, endpoint) = makeClient { stub in
                stub.respond(status: 401, body: body)
            }
            let result = await fetchAds(using: gravity)
            StubURLProtocol.unregister(endpoint)

            XCTAssertTrue(result.ads.isEmpty)
            XCTAssertEqual(result.status, 401)
            XCTAssertEqual(result.error, "HTTP 401")
        }
    }

    func testMalformedSuccessfulResponsesPreserveHTTPStatus() async {
        let bodies = [
            Data(),
            Data("not json".utf8),
            Data("{}".utf8),
        ]

        for body in bodies {
            let (gravity, endpoint) = makeClient { stub in
                stub.respond(status: 200, body: body)
            }
            let result = await fetchAds(using: gravity)
            StubURLProtocol.unregister(endpoint)

            XCTAssertTrue(result.ads.isEmpty)
            XCTAssertEqual(result.status, 200)
            XCTAssertTrue(result.error?.localizedCaseInsensitiveContains("decode") == true)
        }
    }

    func testInvalidEndpointReturnsConfigurationFailureWithoutTransport() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        RecordingURLProtocol.reset()
        let gravity = Gravity(
            apiKey: "test",
            apiUrl: "not a URL",
            readCMPConsent: false,
            honorATT: false,
            session: URLSession(configuration: configuration)
        )

        let result = await fetchAds(using: gravity)

        XCTAssertTrue(result.ads.isEmpty)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.error, "Invalid ad endpoint URL")
        XCTAssertEqual(RecordingURLProtocol.startCount, 0)
    }

    func testNonHTTPResponseReturnsStatusZero() async {
        let (gravity, endpoint) = makeClient { stub in
            let response = URLResponse(
                url: stub.request.url!,
                mimeType: nil,
                expectedContentLength: 0,
                textEncodingName: nil
            )
            stub.respond(response: response, body: Data())
        }
        defer { StubURLProtocol.unregister(endpoint) }

        let result = await fetchAds(using: gravity)

        XCTAssertTrue(result.ads.isEmpty)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.error, "Received non-HTTP response")
    }

    func testRequestSerializationFailureReturnsStatusZero() async {
        let (gravity, endpoint) = makeClient { _ in
            XCTFail("serialization failure must happen before transport")
        }
        defer { StubURLProtocol.unregister(endpoint) }

        let result = await gravity.getAds(
            messages: [Message(role: "user", content: "hello")],
            sessionId: "session",
            placements: [.belowResponse()],
            extraDeviceFields: ["unsupported": Date()]
        )

        XCTAssertTrue(result.ads.isEmpty)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.error, "Request body could not be serialized")
    }

    func testInjectedTransportFailuresReturnStatusZero() async {
        let errors: [URLError] = [
            URLError(.timedOut),
            URLError(.notConnectedToInternet),
        ]

        for error in errors {
            let (gravity, endpoint) = makeClient { stub in
                stub.fail(error)
            }
            let result = await fetchAds(using: gravity)
            StubURLProtocol.unregister(endpoint)

            XCTAssertTrue(result.ads.isEmpty)
            XCTAssertEqual(result.status, 0)
            XCTAssertNotNil(result.error)
        }
    }

    func testCancellationAfterLoadingStartsReturnsPromptlyWithStatusZero() async {
        let started = expectation(description: "URLProtocol loading started")
        let finished = expectation(description: "cancelled request finished")
        let resultBox = AdResultBox()
        let (gravity, endpoint) = makeClient { _ in
            started.fulfill()
        }

        let requestTask = Task {
            let result = await fetchAds(using: gravity)
            await resultBox.store(result)
            finished.fulfill()
        }
        defer {
            requestTask.cancel()
            StubURLProtocol.unregister(endpoint)
        }
        await fulfillment(of: [started], timeout: 1)
        requestTask.cancel()
        await fulfillment(of: [finished], timeout: 1)

        guard let result = await resultBox.load() else {
            XCTFail("cancelled request completed without producing an AdResult")
            return
        }

        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.ads.isEmpty)
    }
}

// MARK: - Test helpers

private extension NetworkContractTests {
    /// This function creates a client that uses a test `URLSession`. It keeps
    /// test requests separate from the global URL loading state.
    func makeClient(
        handler: @escaping StubURLProtocol.Handler
    ) -> (Gravity, URL) {
        let endpoint = URL(string: "https://gravity-sdk.test/\(UUID().uuidString)")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        StubURLProtocol.register(handler, for: endpoint)

        let gravity = Gravity(
            apiKey: "test",
            apiUrl: endpoint.absoluteString,
            timeoutSeconds: 1,
            readCMPConsent: false,
            honorATT: false,
            session: session
        )
        return (gravity, endpoint)
    }

    func fetchAds(using gravity: Gravity) async -> AdResult {
        await gravity.getAds(
            messages: [Message(role: "user", content: "hello")],
            sessionId: "session",
            placements: [.belowResponse()]
        )
    }
}

private final class StubURLProtocol: URLProtocol {
    typealias Handler = (StubURLProtocol) -> Void

    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]

    private let completionLock = NSLock()
    private var hasCompleted = false

    static func register(_ handler: @escaping Handler, for url: URL) {
        lock.lock()
        handlers[url.absoluteString] = handler
        lock.unlock()
    }

    static func unregister(_ url: URL) {
        lock.lock()
        handlers[url.absoluteString] = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let key = request.url?.absoluteString else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        Self.lock.lock()
        let handler = Self.handlers[key]
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        handler(self)
    }

    override func stopLoading() {
        fail(URLError(.cancelled))
    }

    func respond(status: Int, body: Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        respond(response: response, body: body)
    }

    func respond(response: URLResponse, body: Data) {
        guard markCompleted() else { return }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    func fail(_ error: Error) {
        guard markCompleted() else { return }
        client?.urlProtocol(self, didFailWithError: error)
    }

    private func markCompleted() -> Bool {
        completionLock.lock()
        defer { completionLock.unlock() }
        guard !hasCompleted else { return false }
        hasCompleted = true
        return true
    }
}

private final class RecordingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var starts = 0

    static var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    static func reset() {
        lock.lock()
        starts = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.starts += 1
        Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
    }

    override func stopLoading() {}
}

private actor AdResultBox {
    private var result: AdResult?

    func store(_ result: AdResult) {
        self.result = result
    }

    func load() -> AdResult? {
        result
    }
}
