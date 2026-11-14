#if canImport(SwiftUI) && canImport(UIKit) && (os(iOS) || os(tvOS))
import SwiftUI

private struct AdFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

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
            if view.isHidden || view.alpha <= 0.01 { clips.append(.rect(.null)) }
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

private struct ViewabilityModifier: ViewModifier {
    let ad: AdResponse
    let gravity: Gravity

    @State private var tracker = ViewabilityTracker()
    @State private var probe = AdProbeBox()
    @State private var isPolling = true
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: AdFrameKey.self, value: proxy.frame(in: .global))
                }
            )
            .background(AdProbe(box: probe, isPolling: isPolling, onRefresh: refreshVisibleFraction))
            .onPreferenceChange(AdFrameKey.self) { _ in refreshVisibleFraction() }
            .task(id: ad.impUrl) {
                tracker.setAd(key: ad.impUrl) { [ad, gravity] in
                    sendMeasuredIfPixelFired()
                    gravity.sendViewabilityBeacon(ad, event: .viewable)
                }
                isPolling = ad.impUrl != nil && !(tracker.fired && probe.measuredKey == ad.impUrl)
            }
            .task(id: scenePhase) { tracker.isActive = scenePhase == .active }
            .onAppear { tracker.isAttached = true }
            .onDisappear { tracker.isAttached = false }
    }

    // Once per ad per view, independent of the process-wide log, which evicts.
    private func sendMeasuredIfPixelFired() {
        guard probe.measuredKey != ad.impUrl, gravity.hasFiredImpression(ad) else { return }
        probe.measuredKey = ad.impUrl
        gravity.sendMeasuredBeaconIfPixelFired(ad)
    }

    // Keep sampling after `viewable` until `measured` has gone out, since the
    // billed pixel can land after the dwell completes (for example during a
    // drag). Until the pixel lands that wait is only a set lookup per tick, with
    // no view-tree walk. Once it has, one measurability check ends the polling;
    // a clip that becomes measurable later is picked up by the next preference
    // change or window move.
    private func refreshVisibleFraction() {
        if tracker.fired {
            guard gravity.hasFiredImpression(ad) else { return }
            if probe.view?.measurement.isMeasurable == true { sendMeasuredIfPixelFired() }
            isPolling = false
            return
        }
        let measurement = probe.view?.measurement
        tracker.visibleFraction = measurement?.fraction ?? 0
        if measurement?.isMeasurable == true { sendMeasuredIfPixelFired() }
    }
}

extension View {
    /// Shadow-measures MRC viewability for `ad`: sends the `measured` beacon once
    /// the billed pixel has fired and the ad's visibility is measurable, and
    /// `viewable` once at least 50% has been in view for 1 continuous second
    /// while the scene is active. It never changes when the pixel fires.
    func trackViewability(of ad: AdResponse, gravity: Gravity) -> some View {
        modifier(ViewabilityModifier(ad: ad, gravity: gravity))
    }
}
#endif
