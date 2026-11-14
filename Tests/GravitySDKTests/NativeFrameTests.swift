#if os(iOS)
import XCTest
import WebKit
import SwiftUI
import Network
@testable import GravitySDK

@MainActor
final class NativeFrameTests: XCTestCase {
    func testNativeViewUpdateCancelsSameIdentityChangedPrompt() async throws {
        let old = try JSONDecoder().decode(AdResponse.self, from: Data(#"{"impUrl":"https://tracking.invalid/same","action":{"type":"prompt","id":"same","prompt":"Old prompt","openUrl":false}}"#.utf8))
        let replacement = try JSONDecoder().decode(AdResponse.self, from: Data(#"{"impUrl":"https://tracking.invalid/same","action":{"type":"prompt","id":"same","prompt":"Changed prompt","openUrl":true}}"#.utf8))
        XCTAssertEqual(old.id, replacement.id)
        XCTAssertEqual(old.promptAction?.id, replacement.promptAction?.id)
        let execution = PromptExecution()
        let started = expectation(description: "native consent suspended")
        let cancelled = expectation(description: "view update cancelled prior consent")
        var draft = ""
        let handler: PromptActionHandler = { action in
            started.fulfill()
            do { try await Task.sleep(nanoseconds: 60_000_000_000) }
            catch { cancelled.fulfill(); throw error }
            draft = action.prompt
            return .inserted
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeFixtureURLProtocol.self]
        let gravity = Gravity(apiKey: "fixture", readCMPConsent: false, honorATT: false,
                              session: URLSession(configuration: configuration))
        let controller = UIHostingController(rootView: GravityAdView(ad: old, gravity: gravity, sessionId: "same", onPrompt: handler, execution: execution))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        execution.activate(ad: old, handler: handler, frame: false,
                           open: { _ in XCTFail("Paste-only old action must not navigate"); return false },
                           completion: { _, _ in XCTFail("Stale action must not report") })
        await fulfillment(of: [started], timeout: 2)
        controller.rootView = GravityAdView(ad: replacement, gravity: gravity, sessionId: "same", onPrompt: handler, execution: execution)
        controller.view.layoutIfNeeded()
        await fulfillment(of: [cancelled], timeout: 5)
        XCTAssertEqual(draft, "")
    }

    func testActualHostFollowsEngineStyle307ImmutableRedirect() async throws {
        let server = try LocalFrameServer(redirect: true)
        defer { server.stop() }
        let listening = expectation(description: "redirect fixture listening")
        server.start { listening.fulfill() }
        await fulfillment(of: [listening], timeout: 5)
        let frameURL = try XCTUnwrap(server.url)
        let data = try JSONSerialization.data(withJSONObject: ["render": ["mode": "iframe", "frameUrl": frameURL.absoluteString + "?existing=kept&tag=x&tag=y",
                                                                                       "frameSize": ["height": 300, "compact": ["height": 120]]]])
        let ad = try JSONDecoder().decode(AdResponse.self, from: data)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let view = GravityFrameView(frame: CGRect(x: 15, y: 80, width: 360, height: 320))
        defer { view.dispose(); window.isHidden = true }
        controller.view.addSubview(view)
        let ready = expectation(description: "redirected creative handshakes")
        var didReady = false
        view.onHeightChange = { height in
            if height == 311 && !didReady { didReady = true; ready.fulfill() }
        }
        view.configure(ad: ad, gravity: Gravity(apiKey: "fixture", readCMPConsent: false, honorATT: false),
                       sessionId: "redirect-fixture", theme: "dark", frameLayout: .compact, allowLocalTestFrames: true)
        view.layoutIfNeeded()
        await fulfillment(of: [ready], timeout: 30)
        XCTAssertEqual(server.requests, 2)
        XCTAssertEqual(server.requestQueries, ["existing=kept&tag=x&tag=y&theme=dark&layout=compact", "existing=kept&tag=x&tag=y&theme=dark&layout=compact"])
        XCTAssertEqual(view.observedFrameRedirects, 1)
        XCTAssertTrue(view.hasActiveFrameResources)
        guard didReady, let web = view.subviews.compactMap({ $0 as? WKWebView }).first else { return }
        let sandbox = try await web.evaluateJavaScript("document.querySelector('iframe').getAttribute('sandbox')") as? String
        XCTAssertEqual(sandbox, "allow-scripts")
        let attachment = XCTAttachment(image: try await snapshot(web))
        attachment.name = "Actual GravityFrameView engine-style 307 redirect"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testActualHostValidatesHiddenRedirectChainFinalDocument() async throws {
        for change in [LocalFrameServer.FinalRedirectChange.none, .hash, .environment, .host, .query] {
            let benign = change == .none
            let server = try LocalFrameServer(redirect: true, redirectLimit: benign ? 5 : 3, finalChange: change)
            defer { server.stop() }
            let listening = expectation(description: "redirect chain listening: \(change)")
            server.start { listening.fulfill() }
            await fulfillment(of: [listening], timeout: 5)
            let data = try JSONSerialization.data(withJSONObject: ["title": "Redirect fallback", "render": [
                "mode": "iframe", "frameUrl": try XCTUnwrap(server.url).absoluteString
            ]])
            let ad = try JSONDecoder().decode(AdResponse.self, from: data)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            let controller = UIViewController()
            window.rootViewController = controller
            window.makeKeyAndVisible()
            let view = GravityFrameView(frame: CGRect(x: 15, y: 80, width: 360, height: 320))
            defer { view.dispose(); window.isHidden = true }
            controller.view.addSubview(view)
            let settled = expectation(description: "final response validated: \(change)")
            var completed = false
            var configured = false
            var creativeReady = false
            view.onHeightChange = { height in
                if height == 311 {
                    creativeReady = true
                    if benign && !completed { completed = true; settled.fulfill() }
                }
                if configured && !benign && !view.hasActiveFrameResources && !completed {
                    completed = true
                    settled.fulfill()
                }
            }
            view.configure(ad: ad, gravity: Gravity(apiKey: "fixture", readCMPConsent: false, honorATT: false),
                           sessionId: "redirect-chain-fixture", allowLocalTestFrames: true)
            configured = true
            view.layoutIfNeeded()
            await fulfillment(of: [settled], timeout: 20)
            XCTAssertEqual(creativeReady, benign, "Final document must not execute for \(change)")
            XCTAssertEqual(view.hasActiveFrameResources, benign)
            if benign {
                XCTAssertEqual(server.requests, 6)
                XCTAssertGreaterThanOrEqual(view.observedFrameRedirects, 1)
            } else if change == .host {
                XCTAssertEqual(server.requests, 3)
            } else {
                XCTAssertTrue((3...4).contains(server.requests), "Reject before fetching or before accepting the final document")
            }
        }
    }

    func testActualFrameHostKeepsDocumentOnLayoutUpdatesAndDisposesOnDetach() async throws {
        let server = try LocalFrameServer()
        defer { server.stop() }
        let listening = expectation(description: "local fixture server ready")
        server.start { listening.fulfill() }
        await fulfillment(of: [listening], timeout: 5)
        let frameURL = try XCTUnwrap(server.url)
        let data = try JSONSerialization.data(withJSONObject: ["brandName": "Local fixture", "render": [
            "mode": "iframe", "frameUrl": frameURL.absoluteString,
            "frameSize": ["height": 300, "compact": ["height": 120]]
        ]])
        let ad = try JSONDecoder().decode(AdResponse.self, from: data)
        let gravity = Gravity(apiKey: "fixture", readCMPConsent: false, honorATT: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let view = GravityFrameView(frame: CGRect(x: 15, y: 80, width: 360, height: 300))
        defer { view.dispose(); window.isHidden = true }
        controller.view.addSubview(view)
        let ready = expectation(description: "actual host accepts creative ready")
        let compact = expectation(description: "existing creative receives compact host resize")
        var didReady = false
        var didCompact = false
        view.onHeightChange = { height in
            view.frame.size.height = height
            if height == 311 && !didReady { didReady = true; ready.fulfill() }
            if height == 111 && !didCompact { didCompact = true; compact.fulfill() }
        }
        view.configure(ad: ad, gravity: gravity, sessionId: "fixture", frameLayout: .full, allowLocalTestFrames: true)
        view.layoutIfNeeded()
        let web = try XCTUnwrap(view.subviews.compactMap { $0 as? WKWebView }.first)
        await fulfillment(of: [ready], timeout: 30)
        XCTAssertEqual(server.requests, 1)
        guard didReady else { return }
        XCTAssertTrue(view.hasActiveFrameResources)
        view.configure(ad: ad, gravity: gravity, sessionId: "fixture", frameLayout: .compact,
                       frameSizeBudget: FrameSizeBudget(maxViewportRatio: 0.2), allowLocalTestFrames: true)
        XCTAssertTrue(view.subviews.contains { $0 === web })
        await fulfillment(of: [compact], timeout: 5)
        guard didCompact else { return }
        XCTAssertEqual(server.requests, 1)
        let image = try await snapshot(web)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Actual GravityFrameView compact local creative"
        attachment.lifetime = .keepAlways
        add(attachment)
        view.removeFromSuperview()
        XCTAssertFalse(view.hasActiveFrameResources)
        XCTAssertNil(web.navigationDelegate)
        XCTAssertNil(web.uiDelegate)
        XCTAssertTrue(view.subviews.isEmpty)
        let reattached = expectation(description: "detached host resumes without publisher configure")
        var didReattach = false
        view.onHeightChange = { height in
            view.frame.size.height = height
            if height == 311 && !didReattach { didReattach = true; reattached.fulfill() }
        }
        controller.view.addSubview(view)
        view.layoutIfNeeded()
        await fulfillment(of: [reattached], timeout: 30)
        XCTAssertTrue(view.hasActiveFrameResources)
        XCTAssertEqual(server.requests, 2)
        XCTAssertFalse(view.subviews.contains { $0 === web })
        view.dispose()
        XCTAssertFalse(view.hasActiveFrameResources)
        view.removeFromSuperview()
        controller.view.addSubview(view)
        XCTAssertFalse(view.hasActiveFrameResources)
        window.isHidden = true
    }

    final class Receiver: NSObject, WKScriptMessageHandler {
        var receive: ((WKScriptMessage) -> Void)?
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            receive?(message)
        }
    }

    func testRealWebKitOpaqueShellRendersAndRelaysHeightlessReady() async throws {
        let ready = expectation(description: "heightless ready through sandbox")
        let receiver = Receiver()
        var completed = false
        receiver.receive = { message in
            guard !completed, let text = message.body as? String,
                  let data = text.data(using: .utf8),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = body["message"] as? [String: Any], value["type"] as? String == "ready" else { return }
            XCTAssertTrue(message.frameInfo.isMainFrame)
            XCTAssertEqual(body["generation"] as? String, "fixture")
            XCTAssertNil(value["height"])
            completed = true
            ready.fulfill()
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(receiver, name: "gravityFrame")
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 360, height: 180), configuration: configuration)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(web)
        window.makeKeyAndVisible()
        let fixture = """
        <!doctype html><style>body{font:16px system-ui;background:#f5f5f5;padding:16px}button{padding:12px}</style>
        <small>Ad</small><h2>Native frame fixture</h2><button data-gravity-action="prompt">Explore options</button>
        <script>requestAnimationFrame(()=>requestAnimationFrame(()=>parent.postMessage({__gravity:1,protocol:'gfb-1',type:'ready'},'*')))</script>
        """
        let encoded = String(decoding: try JSONEncoder().encode(fixture), as: UTF8.self)
        let html = FrameShell.html(url: URL(string: "about:blank")!, generation: "fixture")
            .replacingOccurrences(of: "frame.src=config.src;", with: "frame.srcdoc=\(encoded);")
        web.loadHTMLString(html, baseURL: nil)
        await fulfillment(of: [ready], timeout: 10)
        let sandbox = try await web.evaluateJavaScript("document.querySelector('iframe').getAttribute('sandbox')") as? String
        XCTAssertEqual(sandbox, "allow-scripts")
        let image = try await snapshot(web)
        let attachment = XCTAttachment(image: image)
        attachment.name = "WebKit opaque frame fixture"
        attachment.lifetime = .keepAlways
        add(attachment)
        web.configuration.userContentController.removeScriptMessageHandler(forName: "gravityFrame")
        window.isHidden = true
    }

    private func snapshot(_ web: WKWebView) async throws -> UIImage {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        return try await withCheckedThrowingContinuation { continuation in
            web.takeSnapshot(with: configuration) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? URLError(.cannotDecodeContentData)) }
            }
        }
    }

    func testNativeCardAndUIKitAdapterCompileAndRender() async throws {
        let ad = try JSONDecoder().decode(AdResponse.self, from: Data(#"{"brandName":"Fixture","title":"A native card","adText":"Local fixture content.","cta":"Explore"}"#.utf8))
        let gravity = Gravity(apiKey: "fixture", readCMPConsent: false, honorATT: false)
        let controller = UIHostingController(rootView: GravityAdView(ad: ad, gravity: gravity, sessionId: "fixture"))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        controller.view.backgroundColor = .white
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image)
        attachment.name = "SwiftUI native fallback fixture"
        attachment.lifetime = .keepAlways
        add(attachment)
        let adapter = GravityFrameView(frame: controller.view.bounds)
        adapter.configure(ad: ad, gravity: gravity, sessionId: "fixture")
        XCTAssertEqual(adapter.subviews.count, 1)
        adapter.dispose()
        XCTAssertEqual(adapter.subviews.count, 0)
    }
}

private final class NativeFixtureURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class LocalFrameServer: @unchecked Sendable {
    enum FinalRedirectChange { case none, hash, environment, host, query }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "gravity.native-fixture")
    private let lock = NSLock()
    private var count = 0
    private var queries: [String?] = []
    private let redirect: Bool
    private let redirectLimit: Int
    private let finalChange: FinalRedirectChange
    var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
    var requestQueries: [String?] { lock.lock(); defer { lock.unlock() }; return queries }
    var url: URL? { listener.port.flatMap { URL(string: "http://127.0.0.1:\($0.rawValue)/frame/local-fixture") } }

    init(redirect: Bool = false, redirectLimit: Int = 1, finalChange: FinalRedirectChange = .none) throws {
        self.redirect = redirect
        self.redirectLimit = redirectLimit
        self.finalChange = finalChange
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start(ready: @escaping @Sendable () -> Void) {
        listener.stateUpdateHandler = { state in if case .ready = state { ready() } }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                guard let self else { connection.cancel(); return }
                let requestTarget = data.map { String(decoding: $0, as: UTF8.self).split(separator: " ", maxSplits: 2).dropFirst().first.map(String.init) ?? "" } ?? ""
                let query = requestTarget.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first.map(String.init)
                self.lock.lock(); self.count += 1; self.queries.append(query); let requestNumber = self.count; self.lock.unlock()
                if self.redirect && requestNumber <= self.redirectLimit {
                    let final = requestNumber == self.redirectLimit
                    let hash = String(repeating: final && self.finalChange == .hash ? "b" : "a", count: 64)
                    let environment = final && self.finalChange == .environment ? "prod" : "test"
                    let host = final && self.finalChange == .host ? "localhost." : "localhost"
                    var suffix = query.map { "?" + $0 } ?? ""
                    if final && self.finalChange == .query { suffix += query == nil ? "?unexpected=1" : "&unexpected=1" }
                    let location = "http://\(host):\(self.listener.port!.rawValue)/designer-units/\(environment)/\(hash).html\(suffix)"
                    let response = "HTTP/1.1 307 Temporary Redirect\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                let html = """
                <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
                <style>body{margin:0;padding:16px;font:16px system-ui;background:#f3f3f3;color:#222}h2{margin:6px 0}small{color:#555}</style>
                <small>Ad</small><h2>Actual native host fixture</h2><div id="layout">Full layout</div>
                <script>
                const send=height=>parent.postMessage({__gravity:1,protocol:'gfb-1',type:'resize',height},'*');
                if(new URLSearchParams(location.search).get('layout')==='compact')document.getElementById('layout').textContent='Compact layout';
                window.addEventListener('message',event=>{
                  if(event.source!==parent||event.data?.protocol!=='gfb-1')return;
                  if(['init','resize'].includes(event.data.type)){
                    const compact=event.data.layout==='compact';
                    document.getElementById('layout').textContent=compact?'Compact layout':'Full layout';
                    if(compact)requestAnimationFrame(()=>requestAnimationFrame(()=>send(111)));
                  }
                });
                parent.postMessage({__gravity:1,protocol:'gfb-1',type:'ready',height:311},'*');
                </script>
                """
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
    }

    func stop() { listener.cancel() }
}
#endif
