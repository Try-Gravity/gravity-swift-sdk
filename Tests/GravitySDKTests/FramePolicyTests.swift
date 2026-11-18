import XCTest
@testable import GravitySDK

final class FramePolicyTests: XCTestCase {
    func ad(_ json: String) throws -> AdResponse { try JSONDecoder().decode(AdResponse.self, from: Data(json.utf8)) }

    func testSelectedRenderPrecedesLegacyCompositionAndRoutesCardURLs() throws {
        let value = try ad(#"{"clickUrl":"https://track.example/primary","render":{"mode":"iframe","frameUrl":"https://frames.example/frame/new","frameHeight":250,"items":[{"clickUrl":"https://track.example/card"}]},"composition":{"mode":"iframe","frameUrl":"https://frames.example/frame/old"}}"#)
        XCTAssertEqual(FrameSelection.select(value)?.url.lastPathComponent, "new")
        XCTAssertEqual(FrameSelection.select(value)?.height, 250)
        XCTAssertEqual(FrameSelection.clickURL(value, action: "card:0")?.path, "/card")
        XCTAssertEqual(FrameSelection.clickURL(value, action: "card:4")?.path, "/primary")
        XCTAssertEqual(FrameSelection.clickURL(value, action: "card:-1")?.path, "/primary")
    }

    func testHTTPSOnlyAndExplicitLocalFixturePolicy() {
        XCTAssertNil(FrameSelection.safeURL("file:///private/file"))
        XCTAssertNil(FrameSelection.safeURL("javascript:alert(1)"))
        XCTAssertNil(FrameSelection.safeURL("http://localhost/frame"))
        XCTAssertNotNil(FrameSelection.safeURL("http://localhost/frame", local: true))
        XCTAssertNil(FrameSelection.safeURL("http://elsewhere/frame", local: true))
        XCTAssertNil(FrameSelection.safeURL("https://user:password@example.com/frame"))
    }

    func testModernRenderKeepsLegacyOverlayPlacement() throws {
        let value = try ad(#"{"render":{"mode":"iframe","frameUrl":"https://frames.example/frame/new"},"composition":{"mode":"iframe","framePlacement":"overlay","frameHeight":220}}"#)
        XCTAssertEqual(FrameSelection.select(value)?.overlay, true)
        XCTAssertEqual(FrameSelection.select(value)?.height, 220)
        let inline = try ad(#"{"render":{"mode":"iframe","frameUrl":"https://frames.example/frame/new","framePlacement":"inline"},"composition":{"mode":"iframe","framePlacement":"overlay"}}"#)
        XCTAssertEqual(FrameSelection.select(inline)?.overlay, false)
    }

    func testResponsiveCompactBudgetAndNoClipping() throws {
        let raw: [String: Any] = ["height": 420, "breakpoints": [["minWidth": 560, "height": 252]],
                                  "compact": ["height": 156, "breakpoints": [["minWidth": 560, "height": 136]]]]
        let size = try XCTUnwrap(FrameDeclaration.parse(raw))
        XCTAssertEqual(size.resolve(width: 320, viewport: 800, budget: FrameSizeBudget(), override: .auto).height, 156)
        XCTAssertEqual(size.resolve(width: 600, viewport: 1000, budget: FrameSizeBudget(), override: .auto).height, 252)
        XCTAssertEqual(size.resolve(width: 320, viewport: 800, budget: FrameSizeBudget(), override: .full).height, 420)
        let full = try XCTUnwrap(FrameDeclaration.parse(["height": 900]))
        XCTAssertEqual(full.resolve(width: 320, viewport: 200, budget: FrameSizeBudget(), override: .auto).height, 900)
        XCTAssertEqual(FrameSizeBudget(maxViewportRatio: .nan, minHeight: 20).maximum(800), 240)
        XCTAssertEqual(FrameSizeBudget().maximum(10000), 1200)
    }

    func testInvalidDeclarationsFallBack() {
        for raw: [String: Any] in [
            ["height": true], ["height": 39], ["height": 1201], ["height": 40.5],
            ["height": 160, "breakpoints": [["minWidth": 1, "height": 160], ["minWidth": 1, "height": 200]]],
            ["height": 160, "compact": ["height": 80, "compact": ["height": 40]]],
            ["height": 160, "breakpoints": (0...16).map { ["minWidth": $0, "height": 160] }]
        ] { XCTAssertNil(FrameDeclaration.parse(raw)) }
    }

    func testHiddenSlotReadyAcknowledgesWithoutOverwritingReservedHeight() {
        var state = FrameHandshake(height: 420)
        XCTAssertTrue(state.receive(["__gravity": 1, "protocol": "gfb-1", "type": "ready"]))
        XCTAssertTrue(state.ready)
        XCTAssertEqual(state.height, 420)
        state.reserve(252)
        XCTAssertTrue(state.ready)
        XCTAssertTrue(state.receive(["__gravity": 1, "protocol": "gfb-1", "type": "resize", "height": 180]))
        XCTAssertEqual(state.height, 180)
        XCTAssertFalse(state.receive(["__gravity": 1, "protocol": "gfb-1", "type": "resize"]))
        XCTAssertFalse(state.receive(["__gravity": 1, "protocol": "gfb-1", "type": "resize", "height": true]))
        XCTAssertFalse(state.receive(["__gravity": 1, "protocol": "wrong", "type": "ready"]))
        XCTAssertTrue(state.receive(["__gravity": 1, "protocol": "gfb-1", "type": "resize", "height": 2000]))
        XCTAssertEqual(state.height, 1200)
    }

    func testShellKeepsOpaqueSandboxAndNeverEmbedsTrackingToken() throws {
        let shell = FrameShell.html(url: URL(string: "https://frames.example/frame/card?theme=dark")!, generation: "generation")
        XCTAssertTrue(shell.contains("sandbox=\"allow-scripts\""))
        XCTAssertFalse(shell.contains("allow-same-origin"))
        XCTAssertFalse(shell.contains("allow-popups"))
        XCTAssertTrue(shell.contains("event.source!==frame.contentWindow"))
        XCTAssertTrue(shell.contains("navigator.userActivation?.isActive===true"))
        XCTAssertFalse(shell.contains("impUrl"))
        XCTAssertFalse(shell.contains("prompt:"))
    }

    @MainActor
    func testTelemetryTokenBindingVisibilityAndBounds() async throws {
        var now = 1000.0
        var captured: [(URL, Data)] = []
        let sink = try XCTUnwrap(FrameTelemetry(frameURL: URL(string: "https://frames.example:443/frame/spotify-play?theme=dark")!,
                                               impURL: "https://tracking.example/imp?p=encrypted", clock: { now },
                                               transport: { captured.append(($0, $1)) }))
        sink.push("frame_ready", data: ["height": 160])
        sink.setVisible(true)
        now += 300
        sink.setVisible(false)
        now += 700
        sink.push("BAD-NAME")
        sink.push("frame_tap")
        sink.push("click", action: "card:0")
        sink.push("large", data: String(repeating: "x", count: 13000))
        sink.dispose()
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0].0.path, "/api/v1/ad/frame/events")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: captured[0].1) as? [String: Any])
        XCTAssertEqual(body["imp"] as? String, "encrypted")
        XCTAssertEqual(body["slug"] as? String, "spotify-play")
        let events = try XCTUnwrap(body["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 4)
        let close = try XCTUnwrap(events.last?["data"] as? [String: Any])
        XCTAssertEqual(close["visible_ms"] as? Double, 300)
        XCTAssertEqual(close["taps"] as? Int, 1)
        XCTAssertEqual(close["interacted"] as? Bool, true)
        XCTAssertLessThanOrEqual(captured[0].1.count, 12000)
        sink.push("after_dispose")
        sink.flush()
        XCTAssertEqual(captured.count, 1)
    }

    @MainActor
    func testTelemetryFlushSplitsUTF8BatchesAndMissingTokenDisables() async throws {
        var batches: [Data] = []
        let sink = try XCTUnwrap(FrameTelemetry(frameURL: URL(string: "https://frames.example/frame/card")!, impURL: "https://t.example?p=t", transport: { _, data in batches.append(data) }))
        for _ in 0..<40 { sink.push("interaction", data: String(repeating: "海", count: 1000)) }
        sink.dispose()
        XCTAssertGreaterThan(batches.count, 10)
        XCTAssertTrue(batches.allSatisfy { $0.count <= 12000 })
        XCTAssertNil(FrameTelemetry(frameURL: URL(string: "https://frames.example/frame/card")!, impURL: nil))
    }

    @MainActor
    func testPromptInsertionNavigationAndFailureFallback() async throws {
        for status in [PromptInsertionResult.inserted, .declined, .failed] {
            let value = try ad(#"{"clickUrl":"https://track.example/click","action":{"type":"prompt","id":"reviewed","prompt":"Insert this","openUrl":false}}"#)
            let runner = PromptExecution()
            let done = expectation(description: status.rawValue)
            var opens = 0
            runner.activate(ad: value, handler: { action in
                XCTAssertEqual(action.prompt, "Insert this")
                return status
            }, frame: true, open: { _ in opens += 1; return true }, completion: { result, opened in
                XCTAssertEqual(result, status)
                XCTAssertEqual(opened, status == .failed)
                done.fulfill()
            })
            await fulfillment(of: [done], timeout: 2)
            XCTAssertEqual(opens, status == .failed ? 1 : 0)
        }
    }

    @MainActor
    func testInvalidationBeforeTaskStartsNeverCallsPublisher() async throws {
        let value = try ad(#"{"action":{"type":"prompt","id":"reviewed","prompt":"Insert this","openUrl":false}}"#)
        let runner = PromptExecution()
        var calls = 0
        runner.activate(ad: value, handler: { _ in calls += 1; return .inserted }, frame: true,
                        open: { _ in XCTFail("Paste-only action must not navigate"); return false },
                        completion: { _, _ in XCTFail("Stale action must not report") })
        runner.invalidate()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testReplacementCancelsConsentBeforeDraftMutation() async throws {
        let oldAd = try ad(#"{"clickUrl":"https://track.example/old","action":{"type":"prompt","id":"old","prompt":"Old prompt","openUrl":false}}"#)
        let newAd = try ad(#"{"action":{"type":"prompt","id":"new","prompt":"New prompt","openUrl":false}}"#)
        let runner = PromptExecution()
        let started = expectation(description: "consent suspended")
        let cancelled = expectation(description: "old consent cancelled")
        let inserted = expectation(description: "replacement inserted")
        var draft = ""
        var opens = 0
        runner.activate(ad: oldAd, handler: { action in
            started.fulfill()
            do { try await Task.sleep(nanoseconds: 60_000_000_000) }
            catch { cancelled.fulfill(); throw error }
            draft = action.prompt
            return .inserted
        }, frame: true, open: { _ in opens += 1; return true },
                        completion: { _, _ in XCTFail("Old action must not report") })
        await fulfillment(of: [started], timeout: 2)
        runner.invalidate()
        runner.activate(ad: newAd, handler: { action in
            draft = action.prompt
            return .inserted
        }, frame: true, open: { _ in opens += 1; return true }, completion: { status, _ in
            XCTAssertEqual(status, .inserted)
            inserted.fulfill()
        })
        await fulfillment(of: [cancelled, inserted], timeout: 2)
        XCTAssertEqual(draft, "New prompt")
        XCTAssertEqual(opens, 0)
    }

    @MainActor
    func testConcurrentPromptSuppressionAndStaleCompletion() async throws {
        let value = try ad(#"{"clickUrl":"https://track.example/click","action":{"type":"prompt","id":"reviewed","prompt":"Insert this"}}"#)
        let runner = PromptExecution()
        var finish: CheckedContinuation<PromptInsertionResult, Never>?
        var calls = 0
        var opens = 0
        var completions = 0
        let started = expectation(description: "started")
        let handler: PromptActionHandler = { _ in
            calls += 1
            started.fulfill()
            return await withCheckedContinuation { finish = $0 }
        }
        runner.activate(ad: value, handler: handler, frame: true, open: { _ in opens += 1; return true }, completion: { _, _ in completions += 1 })
        runner.activate(ad: value, handler: handler, frame: true, open: { _ in opens += 1; return true }, completion: { _, _ in completions += 1 })
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(opens, 1)
        runner.invalidate()
        finish?.resume(returning: .inserted)
        await Task.yield()
        XCTAssertEqual(completions, 0)
    }
}
