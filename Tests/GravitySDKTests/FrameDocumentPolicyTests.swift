import XCTest
@testable import GravitySDK

final class FrameDocumentPolicyTests: XCTestCase {
    private let initial = URL(string: "https://engine.example/api/v1/ad/frame/reviewed")!
    private let documentHash = String(repeating: "a", count: 64)

    func testOnlyInitialShellDocumentAndReviewedImmutableChainAreAllowed() {
        var policy = FrameDocumentPolicy(initialURL: initial)
        XCTAssertFalse(policy.navigate(to: initial, initiatedByShell: false))
        XCTAssertTrue(policy.navigate(to: initial, initiatedByShell: true))
        XCTAssertFalse(policy.navigate(to: initial, initiatedByShell: true))
        let first = URL(string: "https://code.trygravity.ai/designer-units/prod/\(documentHash).html")!
        let second = URL(string: "https://code.trygravity.com/designer-units/prod/\(documentHash).html")!
        XCTAssertTrue(policy.receiveResponse(from: initial, status: 307))
        XCTAssertTrue(policy.navigate(to: first, initiatedByShell: false))
        XCTAssertTrue(policy.navigate(to: second, initiatedByShell: false))
        XCTAssertTrue(policy.receiveResponse(from: second, status: 200))
        XCTAssertFalse(policy.navigate(to: second, initiatedByShell: false))
        XCTAssertFalse(policy.navigate(to: initial, initiatedByShell: true))
    }

    func testUnsafeRedirectDestinationsAndContentChangesAreRejected() {
        let unsafe = [
            "http://code.trygravity.ai/designer-units/prod/\(documentHash).html",
            "https://code.trygravity.ai:444/designer-units/prod/\(documentHash).html",
            "https://code.trygravity.ai.evil.example/designer-units/prod/\(documentHash).html",
            "https://user@code.trygravity.ai/designer-units/prod/\(documentHash).html",
            "https://code.trygravity.ai/designer-units/prod/\(documentHash).html?next=tracker",
            "https://code.trygravity.ai/designer-units/prod/\(documentHash).html#fragment",
            "https://code.trygravity.ai/designer-units/staging/\(documentHash).html",
            "https://code.trygravity.ai/designer-units/prod/short.html",
            "https://code.trygravity.ai/designer-units/prod/\(documentHash.uppercased()).html",
            "https://engine.example/api/v1/ad/imp?p=not-a-document",
        ]
        for value in unsafe {
            var policy = FrameDocumentPolicy(initialURL: initial)
            XCTAssertTrue(policy.navigate(to: initial, initiatedByShell: true))
            XCTAssertFalse(policy.navigate(to: URL(string: value)!, initiatedByShell: false), value)
            XCTAssertFalse(policy.receiveResponse(from: URL(string: value)!, status: 200), value)
        }
        var policy = FrameDocumentPolicy(initialURL: initial)
        XCTAssertTrue(policy.navigate(to: initial, initiatedByShell: true))
        XCTAssertTrue(policy.navigate(to: URL(string: "https://code.trygravity.ai/designer-units/test/\(documentHash).html")!, initiatedByShell: false))
        XCTAssertFalse(policy.navigate(to: URL(string: "https://code.trygravity.ai/designer-units/prod/\(documentHash).html")!, initiatedByShell: false))
    }

    func testImmutableRedirectPreservesOnlyExactHostPinnedQuery() {
        let query = "theme=dark&layout=compact&variant=a%2Bb&tag=x&tag=y"
        let source = URL(string: "\(initial.absoluteString)?\(query)")!
        let target = "https://code.trygravity.ai/designer-units/test/\(documentHash).html"
        var valid = FrameDocumentPolicy(initialURL: source)
        XCTAssertTrue(valid.navigate(to: source, initiatedByShell: true))
        XCTAssertTrue(valid.navigate(to: URL(string: "\(target)?\(query)")!, initiatedByShell: false))
        XCTAssertTrue(valid.receiveResponse(from: URL(string: "\(target)?\(query)")!, status: 200))
        for changed in [nil, "theme=light&layout=compact", query + "&new=value", "layout=compact&theme=dark", query + "&tag=z"] as [String?] {
            let destination = URL(string: target + (changed.map { "?" + $0 } ?? ""))!
            var invalid = FrameDocumentPolicy(initialURL: source)
            XCTAssertTrue(invalid.navigate(to: source, initiatedByShell: true))
            XCTAssertFalse(invalid.navigate(to: destination, initiatedByShell: false))
            XCTAssertFalse(invalid.receiveResponse(from: destination, status: 200))
        }
    }

    func testDirectDocumentResponseClosesNavigationBeforeReady() {
        var policy = FrameDocumentPolicy(initialURL: initial)
        XCTAssertTrue(policy.navigate(to: initial, initiatedByShell: true))
        XCTAssertTrue(policy.receiveResponse(from: initial, status: 200))
        XCTAssertFalse(policy.navigate(to: URL(string: "https://code.trygravity.ai/designer-units/test/\(documentHash).html")!, initiatedByShell: false))
    }

    func testFinalResponseRejectsUnobservedContentChanges() {
        let pinned = URL(string: "https://code.trygravity.ai/designer-units/test/\(documentHash).html")!
        let otherHash = String(repeating: "b", count: 64)
        for target in [
            "https://code.trygravity.ai/designer-units/test/\(otherHash).html",
            "https://code.trygravity.ai/designer-units/prod/\(documentHash).html",
            "https://untrusted.example/designer-units/test/\(documentHash).html",
            initial.absoluteString,
        ] {
            var policy = FrameDocumentPolicy(initialURL: initial)
            XCTAssertTrue(policy.navigate(to: initial, initiatedByShell: true))
            XCTAssertTrue(policy.navigate(to: pinned, initiatedByShell: false))
            XCTAssertFalse(policy.receiveResponse(from: URL(string: target)!, status: 200))
        }
        var policy = FrameDocumentPolicy(initialURL: initial)
        XCTAssertTrue(policy.navigate(to: initial, initiatedByShell: true))
        XCTAssertTrue(policy.navigate(to: pinned, initiatedByShell: false))
        XCTAssertTrue(policy.receiveResponse(from: pinned, status: 200))
        XCTAssertFalse(policy.navigate(to: pinned, initiatedByShell: false))
    }

    func testLoopbackRedirectRequiresExplicitFixtureOptInAndSamePort() {
        let local = URL(string: "http://127.0.0.1:8765/frame/reviewed")!
        let target = URL(string: "http://localhost:8765/designer-units/test/\(documentHash).html")!
        var production = FrameDocumentPolicy(initialURL: local)
        XCTAssertTrue(production.navigate(to: local, initiatedByShell: true))
        XCTAssertFalse(production.navigate(to: target, initiatedByShell: false))
        var fixture = FrameDocumentPolicy(initialURL: local, localFixtures: true)
        XCTAssertTrue(fixture.navigate(to: local, initiatedByShell: true))
        XCTAssertFalse(fixture.navigate(to: URL(string: "http://localhost:8766/designer-units/test/\(documentHash).html")!, initiatedByShell: false))
        XCTAssertTrue(fixture.navigate(to: target, initiatedByShell: false))
        XCTAssertTrue(fixture.receiveResponse(from: target, status: 200))
    }

    @MainActor
    func testRedirectKeepsOriginalCollectorSlugAndToken() async throws {
        var delivered: [(URL, Data)] = []
        let sink = try XCTUnwrap(FrameTelemetry(frameURL: initial, impURL: "https://engine.example/imp?p=encrypted-token",
                                               transport: { delivered.append(($0, $1)) }))
        var policy = FrameDocumentPolicy(initialURL: initial)
        let target = URL(string: "https://code.trygravity.ai/designer-units/prod/\(documentHash).html")!
        XCTAssertTrue(policy.navigate(to: initial, initiatedByShell: true))
        XCTAssertTrue(policy.navigate(to: target, initiatedByShell: false))
        XCTAssertTrue(policy.receiveResponse(from: target, status: 200))
        sink.push("frame_ready")
        sink.flush()
        XCTAssertEqual(delivered.first?.0.host, "engine.example")
        XCTAssertEqual(delivered.first?.0.path, "/api/v1/ad/frame/events")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: delivered[0].1) as? [String: Any])
        XCTAssertEqual(body["slug"] as? String, "reviewed")
        XCTAssertEqual(body["imp"] as? String, "encrypted-token")
        sink.dispose()
    }
}
