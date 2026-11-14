import Foundation

public struct PromptAction: Codable, Sendable {
    public let type: String
    public let id: String
    public let prompt: String
    public let openUrl: Bool?
    public let fields: [String: AnyCodable]

    public init(from decoder: Decoder) throws {
        fields = try [String: AnyCodable](from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        id = try values.decode(String.self, forKey: .id)
        prompt = try values.decode(String.self, forKey: .prompt)
        openUrl = fields["openUrl"] == nil ? nil : try values.decode(Bool.self, forKey: .openUrl)
    }

    public func encode(to encoder: Encoder) throws { try fields.encode(to: encoder) }

    private enum CodingKeys: String, CodingKey { case type, id, prompt, openUrl }

    public var usable: Bool {
        type == "prompt" && !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum PromptInsertionResult: String, Sendable {
    case inserted, declined, failed
}

public typealias PromptActionHandler = @MainActor (PromptAction) async throws -> PromptInsertionResult

public struct FrameSizeBudget: Sendable {
    public let maxViewportRatio: Double
    public let minHeight: Double

    public init(maxViewportRatio: Double = 0.30, minHeight: Double = 160) {
        self.maxViewportRatio = maxViewportRatio.isFinite && maxViewportRatio > 0 && maxViewportRatio <= 1 ? maxViewportRatio : 0.30
        self.minHeight = minHeight.isFinite && (40...1200).contains(minHeight) ? minHeight : 160
    }

    func maximum(_ viewportHeight: Double) -> Double {
        min(1200, max(minHeight, floor(viewportHeight * maxViewportRatio)))
    }
}

public enum FrameLayout: String, Sendable { case auto, full, compact }

struct FrameDeclaration {
    let height: Int
    let breakpoints: [(Int, Int)]
    let compact: Layout?

    struct Layout {
        let height: Int
        let breakpoints: [(Int, Int)]
        func at(_ width: Double) -> Double {
            Double(breakpoints.filter { Double($0.0) <= width }.max { $0.0 < $1.0 }?.1 ?? height)
        }
    }

    static func parse(_ value: Any?) -> FrameDeclaration? {
        guard let raw = value as? [String: Any], let full = layout(raw) else { return nil }
        var compact: Layout?
        if let value = raw["compact"] {
            guard let dict = value as? [String: Any], dict["compact"] == nil, let parsed = layout(dict) else { return nil }
            compact = parsed
        }
        return FrameDeclaration(height: full.height, breakpoints: full.breakpoints, compact: compact)
    }

    private static func integer(_ value: Any?, range: ClosedRange<Int>) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue,
              range.contains(n.intValue) else { return nil }
        return n.intValue
    }

    private static func layout(_ raw: [String: Any]) -> Layout? {
        guard let height = integer(raw["height"], range: 40...1200) else { return nil }
        var points: [(Int, Int)] = []
        if let value = raw["breakpoints"] {
            guard let list = value as? [[String: Any]], list.count <= 16 else { return nil }
            for point in list {
                guard let width = integer(point["minWidth"], range: 0...10000),
                      let h = integer(point["height"], range: 40...1200),
                      !points.contains(where: { $0.0 == width }) else { return nil }
                points.append((width, h))
            }
        }
        return Layout(height: height, breakpoints: points)
    }

    func resolve(width: Double, viewport: Double, budget: FrameSizeBudget, override: FrameLayout) -> (height: Double, layout: FrameLayout) {
        let full = Layout(height: height, breakpoints: breakpoints).at(width)
        let small = compact?.at(width)
        let useCompact = override == .compact || (override == .auto && full > budget.maximum(viewport) && (small ?? .infinity) <= budget.maximum(viewport))
        return useCompact && small != nil ? (small!, .compact) : (full, .full)
    }
}

import CoreFoundation

struct FrameSelection {
    let url: URL
    let height: Double
    let size: FrameDeclaration?
    let overlay: Bool
    let eventSource: AnyCodable?

    static func select(_ ad: AdResponse, allowLocalFixtures: Bool = false) -> FrameSelection? {
        let render = ad.render?.mapValues(\.value) ?? [:]
        let composition = ad.composition?.mapValues(\.value) ?? [:]
        let raw = render["mode"] as? String == "iframe" ? render : composition
        guard raw["mode"] as? String == "iframe", let href = raw["frameUrl"] as? String,
              let url = safeURL(href, local: allowLocalFixtures) else { return nil }
        let number = (raw["frameHeight"] ?? composition["frameHeight"]) as? NSNumber
        let height = number.flatMap { CFGetTypeID($0) != CFBooleanGetTypeID() ? $0.doubleValue : nil } ?? 160
        return FrameSelection(url: url, height: height.isFinite ? min(1200, max(40, height)) : 160,
                              size: FrameDeclaration.parse(raw["frameSize"]),
                              overlay: (raw["framePlacement"] ?? composition["framePlacement"]) as? String == "overlay",
                              eventSource: raw["frameEventSource"].map(AnyCodable.init))
    }

    static func safeURL(_ value: String?, local: Bool = false) -> URL? {
        guard let value, let url = URL(string: value), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              url.scheme == "https" || (local && url.scheme == "http" && ["localhost", "127.0.0.1"].contains(host)) else { return nil }
        return url
    }

    static func clickURL(_ ad: AdResponse, action: String?) -> URL? {
        if let action, action.hasPrefix("card:"), let index = Int(action.dropFirst(5)), index >= 0,
           let items = ad.render?["items"]?.value as? [[String: Any]], index < items.count,
           let url = safeURL(items[index]["clickUrl"] as? String) { return url }
        return safeURL(ad.clickUrl)
    }
}

struct FrameHandshake {
    private(set) var ready = false
    private(set) var height: Double
    init(height: Double) { self.height = height }
    mutating func reserve(_ height: Double) { self.height = height }

    mutating func receive(_ message: [String: Any]) -> Bool {
        guard message["__gravity"] as? Int == 1, message["protocol"] as? String == "gfb-1",
              let type = message["type"] as? String, ["ready", "resize"].contains(type) else { return false }
        if let value = message["height"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return false }
            height = min(1200, max(40, number.doubleValue.rounded()))
        } else if type != "ready" { return false }
        ready = true
        return true
    }
}
