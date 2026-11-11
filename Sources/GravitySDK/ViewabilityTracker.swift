import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// MRC viewable-impression thresholds: at least 50% of the ad's pixels in view
/// for 1 continuous second.
enum Viewability {
    static let minVisibleFraction = 0.5
    static let dwell: TimeInterval = 1.0
    static let pollInterval: TimeInterval = 0.1
}

/// Decides when an ad counts as a viewable impression. Feed it the ad's
/// visible fraction and the foreground/attached state; it starts a
/// `Viewability.dwell` timer when the ad is in view, cancels it as soon as the
/// ad drops out of view, and calls `onViewable` once per ad key when the timer
/// completes. A new ad key resets everything. Use from the main thread.
final class ViewabilityTracker {
    typealias Scheduler = (_ delay: TimeInterval, _ action: @escaping () -> Void) -> () -> Void

    static let mainQueueScheduler: Scheduler = { delay, action in
        let item = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return item.cancel
    }

    var visibleFraction = 0.0 { didSet { evaluate() } }
    var isActive = false { didSet { evaluate() } }
    var isAttached = false { didSet { evaluate() } }

    private let scheduler: Scheduler
    private var adKey: String?
    private var onViewable: (() -> Void)?
    private var fired = false
    private var cancelTimer: (() -> Void)?

    init(scheduler: @escaping Scheduler = ViewabilityTracker.mainQueueScheduler) {
        self.scheduler = scheduler
    }

    func setAd(key: String?, onViewable: @escaping () -> Void) {
        self.onViewable = onViewable
        guard key != adKey else { return }
        cancelTimer?()
        cancelTimer = nil
        adKey = key
        fired = false
        evaluate()
    }

    static func visibleFraction(of frame: CGRect, in viewport: CGRect) -> Double {
        let area = frame.width * frame.height
        guard area > 0 else { return 0 }
        let visible = frame.intersection(viewport)
        guard !visible.isNull else { return 0 }
        return Double((visible.width * visible.height) / area)
    }

    private func evaluate() {
        let inView = adKey != nil && !fired && isAttached && isActive
            && visibleFraction >= Viewability.minVisibleFraction
        guard inView else {
            cancelTimer?()
            cancelTimer = nil
            return
        }
        guard cancelTimer == nil else { return }
        cancelTimer = scheduler(Viewability.dwell) { [weak self] in
            guard let self else { return }
            self.cancelTimer = nil
            self.fired = true
            self.onViewable?()
        }
    }
}
