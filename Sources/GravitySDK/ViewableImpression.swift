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
/// which SwiftUI's global frame does not. A clip it can't measure makes the
/// ad count as not viewable.
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

    var measurement: (fraction: Double, isMeasurable: Bool) {
        guard let window else { return (0, false) }
        var clips: [ViewClip] = []
        var ancestor: UIView? = self
        while let view = ancestor, view !== window {
            if view.clipsToBounds {
                let rect = view.convert(view.bounds, to: window)
                let radius = view.layer.cornerRadius
                if radius > 0 && view.layer.maskedCorners != [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner] {
                    clips.append(.unmeasurable)
                } else if radius > 0 {
                    let path = UIBezierPath(roundedRect: view.bounds, cornerRadius: radius)
                    clips.append(.shape(bounds: rect) { path.contains(view.convert($0, from: window)) })
                } else {
                    clips.append(.rect(rect))
                }
            }
            if let mask = view.layer.mask {
                let frame = mask.frame
                if frame.isEmpty || frame.isInfinite {
                    clips.append(.unmeasurable)
                } else if let shape = mask as? CAShapeLayer {
                    guard let path = shape.path else {
                        clips.append(.unmeasurable)
                        ancestor = view.superview
                        continue
                    }
                    let rule: CGPathFillRule = shape.fillRule == .evenOdd ? .evenOdd : .winding
                    clips.append(.shape(bounds: view.convert(frame, to: window)) {
                        let point = view.convert($0, from: window)
                        return path.contains(
                            CGPoint(x: point.x - frame.minX, y: point.y - frame.minY), using: rule
                        )
                    })
                } else if mask.contents == nil && mask.sublayers == nil && mask.cornerRadius == 0 {
                    clips.append(.rect(view.convert(frame, to: window)))
                } else {
                    clips.append(.unmeasurable)
                }
            }
            ancestor = view.superview
        }
        let fraction = ViewabilityTracker.visibleFraction(
            of: convert(bounds, to: window), in: window.bounds, clippedBy: clips
        )
        return (fraction, ViewabilityTracker.isMeasurable(clips))
    }
}

private final class AdProbeBox {
    weak var view: AdProbeView?
    var measuredKey: String?
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

private struct ViewabilityModifier: ViewModifier {
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
                    gravity.sendViewabilityBeacon(ad, event: .viewable)
                    isPolling = false
                }
                isPolling = ad.impUrl != nil && !tracker.fired
            }
            .task(id: scenePhase) { tracker.isActive = scenePhase == .active }
            .onAppear {
                tracker.isAttached = true
                sendMeasured()
            }
            .onDisappear { tracker.isAttached = false }
    }

    private func sendMeasured() {
        #if !os(watchOS)
        guard probe.view?.measurement.isMeasurable == true, probe.measuredKey != ad.impUrl else { return }
        probe.measuredKey = ad.impUrl
        #endif
        gravity.sendViewabilityBeacon(ad, event: .measured)
    }

    #if !os(watchOS)
    private func refreshVisibleFraction() {
        tracker.visibleFraction = probe.view?.measurement.fraction ?? 0
        sendMeasured()
    }
    #endif
}

extension View {
    /// Shadow-measures MRC viewability for `ad`: sends the `measured` beacon when
    /// the SDK can measure the ad, and `viewable` once at least 50% has been in
    /// view for 1 continuous second while the scene is active. It never affects
    /// the billed impression pixel.
    func trackViewability(of ad: AdResponse, gravity: Gravity) -> some View {
        modifier(ViewabilityModifier(ad: ad, gravity: gravity))
    }
}
#endif
