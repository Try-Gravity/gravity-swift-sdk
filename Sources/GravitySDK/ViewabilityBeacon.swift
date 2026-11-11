import Foundation

/// Shadow measurement of MRC viewability, sent alongside (never instead of)
/// the billed impression pixel: `measured` when the SDK can measure this ad's
/// visibility, `viewable` once 50% has been in view for 1 continuous second.
enum ViewabilityBeacon {
    enum Event: String {
        case measured
        case viewable
    }

    static let sdkName = "ios"
    static let sdkVersion = "1.0.0"
    static let sent = ViewabilityBeaconLog(capacity: 1000)

    /// The impression URL with `ev`, `sdk` and `sv` appended; every existing
    /// query item is kept as is.
    static func url(impUrl: String, event: Event) -> URL? {
        guard var components = URLComponents(string: impUrl),
              components.scheme != nil, components.host != nil
        else { return nil }
        components.percentEncodedQueryItems = (components.percentEncodedQueryItems ?? []) + [
            URLQueryItem(name: "ev", value: event.rawValue),
            URLQueryItem(name: "sdk", value: sdkName),
            URLQueryItem(name: "sv", value: sdkVersion),
        ]
        return components.url
    }
}

/// Bounded, thread-safe record of beacons already sent. The oldest entry is
/// evicted when the record is full.
final class ViewabilityBeaconLog: @unchecked Sendable {
    private let capacity: Int
    private let lock = NSLock()
    private var sent: Set<String> = []
    private var order: [String] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// Returns `true` when `key` is new, and `false` when it was already recorded.
    func insert(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard sent.insert(key).inserted else { return false }
        order.append(key)
        if order.count > capacity {
            sent.remove(order.removeFirst())
        }
        return true
    }
}
