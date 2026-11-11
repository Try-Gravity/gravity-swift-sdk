#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
#if os(watchOS)
import WatchKit
#endif

private struct AdFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

#if !os(watchOS)
/// UIKit twin of the ad's frame: it knows its hosting window and the clips
/// above it (clipping views such as scroll views, and layer masks, which is
/// how SwiftUI's `.clipped()`/`.clipShape` reach a hosted platform view),
/// which SwiftUI's global frame does not.
private final class AdProbeView: UIView {
    var onRefresh: (() -> Void)?
    var isPolling = true { didSet { updatePollTimer() } }
    private var pollTimer: Timer?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updatePollTimer()
        onRefresh?()
    }

    // Ancestors can resize or clip without moving the ad, which SwiftUI
    // reports nothing for, so sample while the ad is in a window and has not
    // yet counted.
    private func updatePollTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
        if window != nil && isPolling {
            let timer = Timer(timeInterval: Viewability.pollInterval, repeats: true) { [weak self] _ in
                self?.onRefresh?()
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        }
    }

    deinit { pollTimer?.invalidate() }

    var visibleFraction: Double {
        guard let window else { return 0 }
        var clips: [ViewClip] = []
        var ancestor: UIView? = self
        while let view = ancestor, view !== window {
            if view.clipsToBounds { clips.append(.rect(view.convert(view.bounds, to: window))) }
            if let mask = view.layer.mask {
                let frame = mask.frame
                clips.append(frame.isEmpty || frame.isInfinite ? .unmeasurable : .rect(view.convert(frame, to: window)))
            }
            ancestor = view.superview
        }
        return ViewabilityTracker.visibleFraction(
            of: convert(bounds, to: window), in: window.bounds, clippedBy: clips
        )
    }
}

private final class AdProbeBox {
    weak var view: AdProbeView?
}

private struct AdProbe: UIViewRepresentable {
    let box: AdProbeBox
    let isPolling: Bool
    let onRefresh: () -> Void

    func makeUIView(context: Context) -> AdProbeView {
        let view = AdProbeView()
        view.isUserInteractionEnabled = false
        box.view = view
        return view
    }

    func updateUIView(_ view: AdProbeView, context: Context) {
        view.onRefresh = onRefresh
        view.isPolling = isPolling
    }
}
#endif

private struct ViewableImpressionModifier: ViewModifier {
    let ad: AdResponse
    let gravity: Gravity

    @State private var tracker = ViewabilityTracker()
    #if !os(watchOS)
    @State private var probe = AdProbeBox()
    #endif
    @State private var isPolling = true
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: AdFrameKey.self, value: proxy.frame(in: .global))
                }
            )
            #if !os(watchOS)
            .background(AdProbe(box: probe, isPolling: isPolling, onRefresh: refreshVisibleFraction))
            #endif
            .onPreferenceChange(AdFrameKey.self) { frame in
                #if os(watchOS)
                tracker.visibleFraction = ViewabilityTracker.visibleFraction(
                    of: frame, in: WKInterfaceDevice.current().screenBounds
                )
                #else
                refreshVisibleFraction()
                #endif
            }
            .task(id: ad.impUrl) {
                tracker.setAd(key: ad.impUrl) { [ad, gravity] in
                    gravity.trackImpression(ad)
                    isPolling = false
                }
                isPolling = ad.impUrl != nil && !tracker.fired
            }
            .task(id: scenePhase) { tracker.isActive = scenePhase == .active }
            .onAppear { tracker.isAttached = true }
            .onDisappear { tracker.isAttached = false }
    }

    #if !os(watchOS)
    private func refreshVisibleFraction() {
        tracker.visibleFraction = probe.view?.visibleFraction ?? 0
    }
    #endif
}

extension View {
    /// Fires `gravity.trackImpression(ad)` once the ad has been at least 50%
    /// visible for 1 continuous second while the scene is active (MRC viewable).
    /// Visibility is measured against the ad's own window and its clipping
    /// ancestors (iOS/tvOS), or the screen (watchOS).
    func trackViewableImpression(of ad: AdResponse, gravity: Gravity) -> some View {
        modifier(ViewableImpressionModifier(ad: ad, gravity: gravity))
    }
}
#endif
