import XCTest
@testable import GravitySDK

final class ViewabilityTrackerTests: XCTestCase {
    private final class FakeClock {
        private var now = 0.0
        private var pending: [(id: Int, due: Double, action: () -> Void)] = []
        private var nextId = 0

        func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> () -> Void {
            let id = nextId
            nextId += 1
            pending.append((id, now + delay, action))
            return { [weak self] in self?.pending.removeAll { $0.id == id } }
        }

        func advance(ms: Double) {
            now += ms / 1000
            let due = pending.filter { $0.due <= now + 1e-9 }
            pending.removeAll { entry in due.contains { $0.id == entry.id } }
            due.forEach { $0.action() }
        }
    }

    private var clock: FakeClock!
    private var tracker: ViewabilityTracker!
    private var fired = 0

    override func setUp() {
        super.setUp()
        clock = FakeClock()
        fired = 0
        tracker = ViewabilityTracker(scheduler: { [clock] in clock!.schedule($0, $1) })
        tracker.isAttached = true
        tracker.isActive = true
        tracker.setAd(key: "https://imp/1") { [unowned self] in fired += 1 }
    }

    func testFiresAfterOneSecondAtHalfVisible() {
        tracker.visibleFraction = 0.5
        clock.advance(ms: 999)
        XCTAssertEqual(fired, 0)
        clock.advance(ms: 1)
        XCTAssertEqual(fired, 1)
    }

    func testDoesNotFireWhenBelowThresholdOrNeverInView() {
        tracker.visibleFraction = 0.49
        clock.advance(ms: 5000)
        XCTAssertEqual(fired, 0)
    }

    func testDropBelowHalfCancelsAndDwellRestartsFromZero() {
        tracker.visibleFraction = 1.0
        clock.advance(ms: 900)
        tracker.visibleFraction = 0.3
        clock.advance(ms: 500)
        XCTAssertEqual(fired, 0)

        tracker.visibleFraction = 0.8
        clock.advance(ms: 900)
        XCTAssertEqual(fired, 0)
        clock.advance(ms: 100)
        XCTAssertEqual(fired, 1)
    }

    func testBackgroundOrDetachCancelsTimer() {
        tracker.visibleFraction = 1.0
        clock.advance(ms: 900)
        tracker.isActive = false
        clock.advance(ms: 500)
        XCTAssertEqual(fired, 0)

        tracker.isActive = true
        clock.advance(ms: 900)
        tracker.isAttached = false
        clock.advance(ms: 500)
        XCTAssertEqual(fired, 0)

        tracker.isAttached = true
        clock.advance(ms: 1000)
        XCTAssertEqual(fired, 1)
    }

    func testFiresOnlyOnce() {
        tracker.visibleFraction = 1.0
        clock.advance(ms: 1000)
        clock.advance(ms: 5000)
        tracker.visibleFraction = 0.0
        tracker.visibleFraction = 1.0
        clock.advance(ms: 5000)
        XCTAssertEqual(fired, 1)
    }

    func testNewAdKeyResetsAndFiresAgain() {
        tracker.visibleFraction = 1.0
        clock.advance(ms: 1000)
        XCTAssertEqual(fired, 1)

        tracker.setAd(key: "https://imp/2") { [unowned self] in fired += 1 }
        clock.advance(ms: 999)
        XCTAssertEqual(fired, 1)
        clock.advance(ms: 1)
        XCTAssertEqual(fired, 2)
    }

    func testNewAdKeyDiscardsInFlightTimer() {
        tracker.visibleFraction = 1.0
        clock.advance(ms: 900)
        tracker.setAd(key: "https://imp/2") { [unowned self] in fired += 10 }
        clock.advance(ms: 100)
        XCTAssertEqual(fired, 0)
        clock.advance(ms: 900)
        XCTAssertEqual(fired, 10)
    }

    func testClipRectLimitsVisibleFraction() {
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 400)
        let ad = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(ViewabilityTracker.visibleFraction(of: ad, in: viewport), 1, accuracy: 1e-9)

        let clippedToTop40 = ViewClip.rect(CGRect(x: 0, y: 0, width: 100, height: 40))
        let fraction = ViewabilityTracker.visibleFraction(of: ad, in: viewport, clippedBy: [clippedToTop40])
        XCTAssertEqual(fraction, 0.4, accuracy: 1e-9)

        tracker.visibleFraction = fraction
        clock.advance(ms: 5000)
        XCTAssertEqual(fired, 0)
    }

    func testClipsCombineAndDisjointClipHidesAd() {
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 400)
        let ad = CGRect(x: 0, y: 0, width: 100, height: 100)
        let topHalf = ViewClip.rect(CGRect(x: 0, y: 0, width: 100, height: 50))
        let leftHalf = ViewClip.rect(CGRect(x: 0, y: 0, width: 50, height: 100))
        XCTAssertEqual(
            ViewabilityTracker.visibleFraction(of: ad, in: viewport, clippedBy: [topHalf, leftHalf]), 0.25, accuracy: 1e-9)
        XCTAssertEqual(
            ViewabilityTracker.visibleFraction(of: ad, in: viewport, clippedBy: [.rect(CGRect(x: 0, y: 200, width: 100, height: 100))]), 0)
    }

    func testShapedClipUsesTheShapeNotItsBoundingBox() {
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 400)
        let ad = CGRect(x: 0, y: 0, width: 200, height: 30)
        let container = CGRect(x: 0, y: 0, width: 200, height: 200)
        let circle = ViewClip.shape(bounds: container) { point in
            let dx = Double(point.x - 100), dy = Double(point.y - 100)
            return dx * dx + dy * dy <= 100 * 100
        }
        let boundingBoxOnly = ViewabilityTracker.visibleFraction(of: ad, in: viewport, clippedBy: [.rect(container)])
        XCTAssertEqual(boundingBoxOnly, 1, accuracy: 1e-9)

        let fraction = ViewabilityTracker.visibleFraction(of: ad, in: viewport, clippedBy: [circle])
        XCTAssertEqual(fraction, 0.49, accuracy: 0.05)
        XCTAssertLessThan(fraction, Viewability.minVisibleFraction)

        tracker.visibleFraction = fraction
        clock.advance(ms: 5000)
        XCTAssertEqual(fired, 0)
    }

    func testShapedClipThatCoversTheAdKeepsItViewable() {
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 400)
        let ad = CGRect(x: 80, y: 80, width: 40, height: 40)
        let circle = ViewClip.shape(bounds: CGRect(x: 0, y: 0, width: 200, height: 200)) { point in
            let dx = Double(point.x - 100), dy = Double(point.y - 100)
            return dx * dx + dy * dy <= 100 * 100
        }
        XCTAssertEqual(ViewabilityTracker.visibleFraction(of: ad, in: viewport, clippedBy: [circle]), 1, accuracy: 1e-9)
    }

    func testUnmeasurableClipIsNotViewable() {
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 400)
        let ad = CGRect(x: 0, y: 0, width: 100, height: 100)
        let fraction = ViewabilityTracker.visibleFraction(
            of: ad, in: viewport, clippedBy: [.rect(viewport), .unmeasurable])
        XCTAssertEqual(fraction, 0)
        XCTAssertTrue(ViewabilityTracker.isMeasurable([.rect(viewport)]))
        XCTAssertFalse(ViewabilityTracker.isMeasurable([.rect(viewport), .unmeasurable]))

        tracker.visibleFraction = fraction
        clock.advance(ms: 5000)
        XCTAssertEqual(fired, 0)
    }

    func testVisibleFractionOfFrameInViewport() {
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(
            ViewabilityTracker.visibleFraction(of: CGRect(x: 0, y: 50, width: 100, height: 100), in: viewport), 0.5, accuracy: 1e-9)
        XCTAssertEqual(
            ViewabilityTracker.visibleFraction(of: CGRect(x: 10, y: 10, width: 20, height: 20), in: viewport), 1, accuracy: 1e-9)
        XCTAssertEqual(
            ViewabilityTracker.visibleFraction(of: CGRect(x: 0, y: 200, width: 50, height: 50), in: viewport), 0)
        XCTAssertEqual(
            ViewabilityTracker.visibleFraction(of: .zero, in: viewport), 0)
    }
}
