#if canImport(SwiftUI) && canImport(UIKit) && (os(iOS) || os(tvOS))
import SwiftUI
import UIKit

/// A SwiftUI view that renders a Gravity ad with automatic impression tracking.
///
/// ```swift
/// GravityAdView(ad: ad, gravity: gravity, sessionId: sessionId)
/// ```
///
/// Fires the impression pixel the first time it appears on screen
/// and routes clicks through the tracked `clickUrl`.
@MainActor
public struct GravityAdView: View {
    private let ad: AdResponse
    private let gravity: Gravity
    private let sessionId: String
    private let showFeedback: Bool
    private let enableFrames: Bool
    private let frameLayout: FrameLayout
    private let frameSizeBudget: FrameSizeBudget
    private let onPrompt: PromptActionHandler?
    @Environment(\.colorScheme) private var colorScheme
    @State private var frameHeight: CGFloat = 160
    @State private var execution = PromptExecution()

    @State private var feedbackSent = false

    public init(
        ad: AdResponse,
        gravity: Gravity,
        sessionId: String,
        showFeedback: Bool = true,
        enableFrames: Bool = true,
        frameLayout: FrameLayout = .auto,
        frameSizeBudget: FrameSizeBudget = FrameSizeBudget(),
        onPrompt: PromptActionHandler? = nil
    ) {
        self.ad = ad
        self.gravity = gravity
        self.sessionId = sessionId
        self.showFeedback = showFeedback
        self.enableFrames = enableFrames
        self.frameLayout = frameLayout
        self.frameSizeBudget = frameSizeBudget
        self.onPrompt = onPrompt
        if let frame = FrameSelection.select(ad) {
            let reserved = frame.size?.resolve(width: 0, viewport: Double(UIScreen.main.bounds.height), budget: frameSizeBudget, override: frameLayout).height ?? frame.height
            _frameHeight = State(initialValue: CGFloat(reserved))
        }
    }

    init(ad: AdResponse, gravity: Gravity, sessionId: String,
         onPrompt: PromptActionHandler?, execution: PromptExecution) {
        self.init(ad: ad, gravity: gravity, sessionId: sessionId, onPrompt: onPrompt)
        _execution = State(initialValue: execution)
    }

    private var actionIdentity: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var identity = (try? encoder.encode([ad.id, ad.clickUrl ?? ""])) ?? Data()
        if let action = ad.action { identity.append((try? encoder.encode(action)) ?? Data()) }
        return identity
    }

    public var body: some View {
        Group {
            #if os(iOS)
            if enableFrames, let frame = FrameSelection.select(ad) {
                FrameAdapter(ad: ad, gravity: gravity, sessionId: sessionId,
                             theme: colorScheme == .dark ? "dark" : "light", layout: frameLayout,
                             budget: frameSizeBudget, onPrompt: onPrompt, height: $frameHeight)
                    .frame(maxWidth: frame.overlay ? 420 : .infinity)
                    .frame(height: frameHeight)
                    .frame(maxWidth: .infinity, alignment: frame.overlay ? .trailing : .leading)
            } else if ad.promptAction != nil && onPrompt != nil {
                nativeCard
            } else if RendererSpec.renderableSpec(for: ad) != nil {
                SpecAdView(ad: ad, gravity: gravity, sessionId: sessionId, showFeedback: showFeedback)
            } else {
                nativeCard
            }
            #else
            nativeCard
            #endif
        }
        .id(ad.id)
        .onChange(of: actionIdentity) { _ in execution.invalidate() }
        .onDisappear { execution.invalidate() }
        .trackViewability(of: ad, gravity: gravity)
    }

    private func activate() {
        execution.activate(ad: ad, handler: onPrompt, frame: false, open: { url in
            guard UIApplication.shared.canOpenURL(url) else { return false }
            UIApplication.shared.open(url)
            return true
        }, completion: { _, _ in })
    }

    private var nativeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Brand row
            HStack(spacing: 6) {
                if let faviconURL = ad.favicon, let url = URL(string: faviconURL) {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fit)
                    } placeholder: {
                        Color.gray.opacity(0.2)
                    }
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                if let brand = ad.brandName {
                    Text(brand)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Ad")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let title = ad.title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let text = ad.adText {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if let cta = ad.cta {
                    Button {
                        activate()
                    } label: {
                        Text(cta)
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                Spacer()

                if showFeedback && !feedbackSent {
                    HStack(spacing: 12) {
                        Button {
                            feedbackSent = true
                            gravity.sendFeedback(
                                sessionId: sessionId, ad: ad,
                                sentiment: .thumbsUp
                            )
                        } label: {
                            Image(systemName: "hand.thumbsup")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)

                        Button {
                            feedbackSent = true
                            gravity.sendFeedback(
                                sessionId: sessionId, ad: ad,
                                sentiment: .thumbsDown,
                                reasons: ["not_interested"]
                            )
                        } label: {
                            Image(systemName: "hand.thumbsdown")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {
            activate()
        }
        .background(NativeImpressionProbe(ad: ad, gravity: gravity).allowsHitTesting(false))
    }
}

@MainActor
struct NativeImpressionProbe: UIViewRepresentable {
    let ad: AdResponse
    let gravity: Gravity

    final class Probe: UIView {
        var timer: Timer?
        var visible: (() -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            timer?.invalidate()
            guard window != nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.check() }
            }
            check()
        }
        func check() {
            guard let window, UIApplication.shared.applicationState == .active, bounds.width > 0, bounds.height > 0 else { return }
            var rect = convert(bounds, to: window).intersection(window.bounds)
            var ancestor: UIView? = self
            while let view = ancestor {
                if view.isHidden || view.alpha <= 0.01 { return }
                if view.clipsToBounds { rect = rect.intersection(view.convert(view.bounds, to: window)) }
                ancestor = view.superview
            }
            if !rect.isNull && rect.width * rect.height >= bounds.width * bounds.height * 0.5 { visible?() }
        }
    }
    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.visible = { gravity.trackImpression(ad) }
        return view
    }
    func updateUIView(_ view: Probe, context: Context) { view.visible = { gravity.trackImpression(ad) } }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.timer?.invalidate(); view.visible = nil }
}
#endif
