#if canImport(UIKit) && canImport(WebKit) && canImport(SwiftUI) && os(iOS)
import UIKit
import WebKit
import SwiftUI

@MainActor
private final class WeakFrameHandler: NSObject, WKScriptMessageHandler {
    weak var owner: GravityFrameView?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message)
    }
}

/// An isolated GFB-1 frame surface for UIKit. It falls back to the native PSP-1/card renderer.
@MainActor
public final class GravityFrameView: UIView, WKNavigationDelegate, WKUIDelegate {
    public var onHeightChange: ((CGFloat) -> Void)?
    public var onActionResult: ((String, PromptInsertionResult) -> Void)?
    private var webView: WKWebView?
    private var fallback: UIHostingController<AnyView>?
    private var ad: AdResponse?
    private var gravity: Gravity?
    private var sessionId = ""
    private var onPrompt: PromptActionHandler?
    private var selection: FrameSelection?
    private var handshake = FrameHandshake(height: 160)
    private var generation = UUID().uuidString
    private var loaded = false
    private var failed = false
    private var sourcePinned = false
    private var timeout: Timer?
    private var visibilityTimer: Timer?
    private var notifications: [NSObjectProtocol] = []
    private var telemetry: FrameTelemetry?
    private let execution = PromptExecution()
    private var budget = FrameSizeBudget()
    private var layout: FrameLayout = .auto
    private var hostSize: [String: Any] = [:]
    private var theme = "light"
    private var lastConfiguration: Data?
    private var documentPolicy: FrameDocumentPolicy?
    private var localFixtures = false
    private var attachedToWindow = false
    private var resumeConfiguration: (() -> Void)?

    var hasActiveFrameResources: Bool {
        webView != nil || timeout != nil || visibilityTimer != nil || !notifications.isEmpty || telemetry != nil
    }

    var observedFrameRedirects: Int { documentPolicy?.observedRedirects ?? 0 }

    public override init(frame: CGRect) { super.init(frame: frame) }
    public required init?(coder: NSCoder) { super.init(coder: coder) }

    public func configure(ad: AdResponse, gravity: Gravity, sessionId: String,
                          theme: String = "light", frameLayout: FrameLayout = .auto,
                          frameSizeBudget: FrameSizeBudget = FrameSizeBudget(),
                          onPrompt: PromptActionHandler? = nil,
                          allowLocalTestFrames: Bool = false) {
        let resume: () -> Void = { [weak self] in
            self?.configure(ad: ad, gravity: gravity, sessionId: sessionId, theme: theme,
                            frameLayout: frameLayout, frameSizeBudget: frameSizeBudget,
                            onPrompt: onPrompt, allowLocalTestFrames: allowLocalTestFrames)
        }
        resumeConfiguration = resume
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var fingerprint = (try? encoder.encode(ad)) ?? Data()
        fingerprint.append(Data("\(ad.id)|\(sessionId)|\(theme)|\(allowLocalTestFrames)".utf8))
        self.onPrompt = onPrompt
        self.layout = frameLayout
        self.budget = frameSizeBudget
        if lastConfiguration == fingerprint && self.gravity === gravity {
            reserveAndLoad()
            return
        }
        dispose()
        resumeConfiguration = resume
        lastConfiguration = fingerprint
        self.ad = ad
        self.gravity = gravity
        self.sessionId = sessionId
        self.onPrompt = onPrompt
        self.theme = theme == "dark" ? "dark" : "light"
        self.layout = frameLayout
        self.budget = frameSizeBudget
        self.selection = FrameSelection.select(ad, allowLocalFixtures: allowLocalTestFrames)
        failed = false
        sourcePinned = false
        documentPolicy = nil
        localFixtures = allowLocalTestFrames
        loaded = false
        guard let selection else { showFallback(); return }
        handshake = FrameHandshake(height: selection.height)
        invalidateIntrinsicContentSize()
        onHeightChange?(CGFloat(selection.height))
        let handler = WeakFrameHandler()
        handler.owner = self
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(handler, name: "gravityFrame")
        let web = WKWebView(frame: bounds, configuration: configuration)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.allowsBackForwardNavigationGestures = false
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        web.accessibilityLabel = ad.brandName.map { "Ad: \($0)" } ?? "Ad"
        webView = web
        addSubview(web)
        telemetry = FrameTelemetry(frameURL: selection.url, impURL: ad.impUrl, frameEventSource: selection.eventSource)
        visibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.measureVisibility() }
        }
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willEnterForegroundNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.measureVisibility() }
            })
        }
        setNeedsLayout()
    }

    public override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: CGFloat(handshake.height)) }

    public override func layoutSubviews() {
        super.layoutSubviews()
        webView?.frame = bounds
        fallback?.view.frame = bounds
        if let fallback, bounds.width > 0 {
            let size = fallback.view.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
            if size.height.isFinite && size.height > 0 { setHeight(Double(size.height)) }
        }
        reserveAndLoad()
        measureVisibility()
    }

    private func reserveAndLoad() {
        guard !failed, let selection, let web = webView else { return }
        let width = min(100000, Double(max(0, bounds.width)))
        let viewport = min(100000, max(1, Double(window?.bounds.height ?? UIScreen.main.bounds.height)))
        let resolved = selection.size?.resolve(width: width, viewport: viewport, budget: budget, override: layout)
        let height = resolved?.height ?? selection.height
        let chosenLayout = resolved?.layout ?? .full
        let next: [String: Any] = ["width": width, "viewportHeight": viewport,
                                   "maxHeight": budget.maximum(viewport), "layout": chosenLayout.rawValue]
        let changed = !NSDictionary(dictionary: hostSize).isEqual(to: next)
        if !sourcePinned || (changed && selection.size != nil) { setHeight(height) }
        hostSize = next
        if !sourcePinned {
            sourcePinned = true
            var components = URLComponents(url: selection.url, resolvingAgainstBaseURL: false)!
            var query = components.queryItems ?? []
            query.removeAll { $0.name == "theme" || (selection.size?.compact != nil && $0.name == "layout") }
            query.append(URLQueryItem(name: "theme", value: theme))
            if selection.size?.compact != nil { query.append(URLQueryItem(name: "layout", value: chosenLayout.rawValue)) }
            components.queryItems = query
            documentPolicy = FrameDocumentPolicy(initialURL: components.url!, localFixtures: localFixtures)
            web.loadHTMLString(FrameShell.html(url: components.url!, generation: generation), baseURL: nil)
        } else if changed && loaded { postSize("resize") }
    }

    private func beginHandshakeTimeout() {
        guard !handshake.ready else { return }
        timeout?.invalidate()
        timeout = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.handshake.ready else { return }
                self.showFallback()
            }
        }
    }

    private func setHeight(_ height: Double) {
        guard handshake.height != height else { return }
        handshake.reserve(height)
        invalidateIntrinsicContentSize()
        onHeightChange?(CGFloat(height))
    }

    private func measureVisibility() {
        telemetry?.setForeground(UIApplication.shared.applicationState == .active)
        guard !failed, let window, bounds.width > 0, bounds.height > 0,
              UIApplication.shared.applicationState == .active else {
            telemetry?.setVisible(false)
            return
        }
        var visible = convert(bounds, to: window).intersection(window.bounds)
        var ancestor: UIView? = self
        while let view = ancestor {
            if view.isHidden || view.alpha <= 0.01 { visible = .null; break }
            if view.clipsToBounds { visible = visible.intersection(view.convert(view.bounds, to: window)) }
            ancestor = view.superview
        }
        let isVisible = !visible.isNull && visible.width * visible.height >= bounds.width * bounds.height * 0.5
        telemetry?.setVisible(isVisible)
        if isVisible, let ad { gravity?.trackImpression(ad) }
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard !failed, message.frameInfo.isMainFrame, message.webView === webView,
              let text = message.body as? String, text.utf8.count <= 16000,
              let data = text.data(using: .utf8), let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              body["generation"] as? String == generation,
              let value = body["message"] as? [String: Any], value["__gravity"] as? Int == 1,
              value["protocol"] as? String == "gfb-1", let type = value["type"] as? String else { return }
        if type == "ready" || type == "resize" {
            let wasReady = handshake.ready
            guard handshake.receive(value) else { return }
            timeout?.invalidate()
            post(["type": "ack"])
            if !wasReady {
                postSize("init")
                telemetry?.push("frame_ready", data: ["height": handshake.height])
            }
            invalidateIntrinsicContentSize()
            onHeightChange?(CGFloat(handshake.height))
        } else if type == "click" {
            guard value["action"] == nil || value["action"] is NSNull || value["action"] is String, let ad else { return }
            let action = value["action"] as? String
            if action == "prompt", ad.promptAction != nil, onPrompt != nil {
                guard body["activated"] as? Bool == true else { return }
                let current = generation
                execution.activate(ad: ad, handler: onPrompt, frame: true, open: Self.open) { [weak self] status, opened in
                    guard let self, self.generation == current else { return }
                    self.post(["type": "action_result", "action": "prompt", "status": status.rawValue, "opened": opened])
                    if let id = ad.promptAction?.id { self.onActionResult?(id, status) }
                }
            } else {
                telemetry?.push("click", action: action)
                if let url = FrameSelection.clickURL(ad, action: action) { _ = Self.open(url) }
            }
        } else if type == "event", let name = value["name"] as? String {
            telemetry?.push(name, data: value["data"])
        }
    }

    private static func open(_ url: URL) -> Bool {
        guard UIApplication.shared.canOpenURL(url) else { return false }
        UIApplication.shared.open(url)
        return true
    }

    private func postSize(_ type: String) { var value = hostSize; value["type"] = type; post(value) }

    private func post(_ value: [String: Any]) {
        var message = value
        message["__gravity"] = 1
        message["protocol"] = "gfb-1"
        guard let data = try? JSONSerialization.data(withJSONObject: message), let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.gravityHostPost(\(json))", completionHandler: nil)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        loaded = true
        postSize("init")
        if timeout == nil { beginHandshakeTimeout() }
    }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView { showFallback() }
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView { showFallback() }
    }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === self.webView { showFallback() }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard webView === self.webView else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame == true {
            decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" && !loaded ? .allow : .cancel)
        } else {
            let allowed = navigationAction.targetFrame != nil && navigationAction.navigationType == .other &&
                navigationAction.request.url.map { documentPolicy?.navigate(to: $0, initiatedByShell: navigationAction.sourceFrame.isMainFrame) == true } == true
            if allowed {
                if timeout == nil { beginHandshakeTimeout() }
            }
            decisionHandler(allowed ? .allow : .cancel)
        }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard webView === self.webView else { decisionHandler(.cancel); return }
        if navigationResponse.isForMainFrame {
            decisionHandler(navigationResponse.response.url?.absoluteString == "about:blank" && !loaded ? .allow : .cancel)
            return
        }
        guard let response = navigationResponse.response as? HTTPURLResponse, let url = response.url,
              documentPolicy?.receiveResponse(from: url, status: response.statusCode) == true else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    private func showFallback() {
        guard !failed, let ad, let gravity else { return }
        failed = true
        stopFrame()
        let view = GravityAdView(ad: ad, gravity: gravity, sessionId: sessionId, enableFrames: false, onPrompt: onPrompt)
        let host = UIHostingController(rootView: AnyView(view))
        host.view.backgroundColor = .clear
        host.view.frame = bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(host.view)
        fallback = host
        attachFallbackController()
        let size = host.view.sizeThatFits(CGSize(width: max(1, bounds.width), height: .greatestFiniteMagnitude))
        if size.height.isFinite && size.height > 0 { setHeight(Double(size.height)) }
    }

    private func attachFallbackController() {
        guard let fallback, fallback.parent == nil else { return }
        var responder: UIResponder? = next
        while let current = responder {
            if let controller = current as? UIViewController {
                controller.addChild(fallback)
                fallback.didMove(toParent: controller)
                return
            }
            responder = current.next
        }
    }

    private func stopFrame() {
        generation = UUID().uuidString
        execution.invalidate()
        timeout?.invalidate(); timeout = nil
        visibilityTimer?.invalidate(); visibilityTimer = nil
        for observer in notifications { NotificationCenter.default.removeObserver(observer) }
        notifications.removeAll()
        telemetry?.dispose(); telemetry = nil
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "gravityFrame")
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
    }

    /// Dispose before removing this UIKit view or reusing it for another ad.
    public func dispose() {
        resumeConfiguration = nil
        stopFrame()
        lastConfiguration = nil
        fallback?.willMove(toParent: nil)
        fallback?.view.removeFromSuperview()
        fallback?.removeFromParent()
        fallback = nil
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            attachedToWindow = true
            if !hasActiveFrameResources && fallback == nil { resumeConfiguration?() }
        }
        else if attachedToWindow {
            attachedToWindow = false
            let resume = resumeConfiguration
            dispose()
            resumeConfiguration = resume
        }
        attachFallbackController()
    }
}

@MainActor
struct FrameAdapter: UIViewRepresentable {
    let ad: AdResponse
    let gravity: Gravity
    let sessionId: String
    let theme: String
    let layout: FrameLayout
    let budget: FrameSizeBudget
    let onPrompt: PromptActionHandler?
    @Binding var height: CGFloat

    func makeUIView(context: Context) -> GravityFrameView {
        let view = GravityFrameView()
        view.onHeightChange = { value in DispatchQueue.main.async { height = value } }
        view.configure(ad: ad, gravity: gravity, sessionId: sessionId, theme: theme, frameLayout: layout, frameSizeBudget: budget, onPrompt: onPrompt)
        return view
    }

    func updateUIView(_ view: GravityFrameView, context: Context) {
        view.configure(ad: ad, gravity: gravity, sessionId: sessionId, theme: theme, frameLayout: layout, frameSizeBudget: budget, onPrompt: onPrompt)
    }
    static func dismantleUIView(_ view: GravityFrameView, coordinator: ()) { view.dispose() }
}
#endif
