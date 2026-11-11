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

private extension ViewabilityTracker {
    static var viewport: CGRect {
        #if os(watchOS)
        return WKInterfaceDevice.current().screenBounds
        #else
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows.first { $0.isKeyWindow }?.bounds ?? .zero
        #endif
    }
}

private struct ViewableImpressionModifier: ViewModifier {
    let ad: AdResponse
    let gravity: Gravity

    @State private var tracker = ViewabilityTracker()
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: AdFrameKey.self, value: proxy.frame(in: .global))
                }
            )
            .onPreferenceChange(AdFrameKey.self) { frame in
                tracker.visibleFraction = ViewabilityTracker.visibleFraction(
                    of: frame, in: ViewabilityTracker.viewport
                )
            }
            .task(id: ad.impUrl) {
                tracker.setAd(key: ad.impUrl) { [ad, gravity] in gravity.trackImpression(ad) }
            }
            .task(id: scenePhase) { tracker.isActive = scenePhase == .active }
            .onAppear { tracker.isAttached = true }
            .onDisappear { tracker.isAttached = false }
    }
}

extension View {
    /// Fires `gravity.trackImpression(ad)` once the ad has been at least 50%
    /// visible for 1 continuous second while the scene is active (MRC viewable).
    func trackViewableImpression(of ad: AdResponse, gravity: Gravity) -> some View {
        modifier(ViewableImpressionModifier(ad: ad, gravity: gravity))
    }
}
#endif
