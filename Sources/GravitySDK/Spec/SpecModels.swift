import Foundation

/// Typed decoding + structural validation for a server-delivered
/// `renderer_spec` (PSP-1 profile). Pure Foundation — no UI dependency —
/// so it compiles and is testable on every platform, including Linux CI.
///
/// Security model (mirrors the web `SpecRenderer` / `validateSpec`):
///  - node `type` is a closed whitelist (`box|text|image|link`);
///  - depth ≤ 32, node count ≤ 400;
///  - image `src` / link `href` URLs restricted to `http/https/mailto`
///    (`data:` is deliberately not allowed on native);
///  - style values are parsed into typed primitives — anything that does
///    not match the PSP-1 grammar is ignored, never executed;
///  - size caps applied client-side: fontSize ≤ 20, spacing ≤ 32, image ≤ 64.
///
/// Parsing and validation never throw past `RendererSpec.parse` — a malformed
/// spec yields `nil`, which callers treat as "fall back to the built-in view".
public enum SpecConstants {
    public static let maxDepth = 32
    public static let maxNodes = 400
    public static let maxFontSizePx: Double = 20
    public static let maxSpacingPx: Double = 32
    public static let maxImagePx: Double = 64
    public static let allowedURLSchemes: Set<String> = ["http", "https", "mailto"]
    public static let nodeTypes: Set<String> = ["box", "text", "image", "link"]
    public static let bindableFields: Set<String> = [
        "adText", "title", "cta", "brandName", "url", "favicon",
    ]
    /// Semantic theme tokens usable as `$token[/alpha]` colors (PSP-1).
    public static let colorTokens: Set<String> = [
        "background", "foreground", "card", "card-foreground",
        "primary", "primary-foreground", "muted", "muted-foreground",
        "accent", "accent-foreground", "border",
    ]
}

/// A decoded `renderer_spec` payload.
public struct RendererSpec: Codable, Sendable {
    public let version: Int?
    public let name: String?
    public let root: SpecNode

    /// Decode a spec from the raw `[String: AnyCodable]` bag that
    /// ``AdResponse/rendererSpec`` carries. Returns `nil` on any failure.
    public static func parse(_ raw: [String: AnyCodable]?) -> RendererSpec? {
        guard let raw else { return nil }
        guard let data = try? JSONEncoder().encode(raw) else { return nil }
        return parse(data)
    }

    /// Decode a spec from raw JSON data. Returns `nil` on any failure.
    public static func parse(_ data: Data) -> RendererSpec? {
        try? JSONDecoder().decode(RendererSpec.self, from: data)
    }

    /// Parse + validate an ad's spec once and reuse it across SwiftUI
    /// re-renders. SwiftUI re-initializes view structs on every render pass,
    /// so an uncached parse would re-decode and re-walk the tree each redraw
    /// (scroll jank in feeds). Returns the spec only if it is both
    /// structurally valid and PSP-1 conformant — i.e. natively renderable —
    /// otherwise `nil` (fallback to the built-in view). Results (including
    /// negative ones) are memoized per ad identity.
    public static func renderableSpec(for ad: AdResponse) -> RendererSpec? {
        verdict(for: ad).spec
    }

    /// Whether the renderable spec for `ad` paints a perceivable disclosure
    /// label. Memoized alongside the spec so the per-frame SwiftUI render
    /// path never re-walks the tree.
    public static func rendersDisclosure(for ad: AdResponse) -> Bool {
        verdict(for: ad).hasDisclosure
    }

    private static func verdict(for ad: AdResponse) -> SpecVerdict {
        guard let raw = ad.rendererSpec else { return SpecVerdict(spec: nil, hasDisclosure: false) }
        guard let data = try? JSONEncoder().encode(raw) else {
            return SpecVerdict(spec: nil, hasDisclosure: false)
        }
        let key = cacheKey(for: ad, specData: data)
        if let key, let cached = cache.value(for: key) {
            return cached
        }
        let parsed = parse(data)
        let renderable: RendererSpec? =
            (parsed?.isStructurallyValid ?? false)
                && (parsed?.isPSP1Conformant ?? false)
                && (parsed?.hasVisibleContent(for: ad) ?? false)
                ? parsed : nil
        let verdict = SpecVerdict(
            spec: renderable,
            hasDisclosure: renderable?.hasDisclosure(rendering: ad) ?? false
        )
        if let key { cache.store(verdict, for: key) }
        return verdict
    }

    /// Cache identity for an ad's verdict. Tracking URLs alone are not
    /// unique — the engine stamps every test ad with the same placeholder
    /// (`https://trygravity.ai`) — and the verdict depends on both the ad's
    /// bindable field values (`hasVisibleContent` / `hasDisclosure` resolve
    /// `bind`/`showIf` against them) and the spec payload itself (two
    /// placements in one response can carry different optimizer arms). So
    /// the key combines the tracking URL, every bindable field, and an
    /// FNV-1a fingerprint of the encoded spec.
    private static func cacheKey(for ad: AdResponse, specData: Data) -> String? {
        guard let url = ad.impUrl ?? ad.clickUrl else { return nil }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in specData {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        let fields = SpecConstants.bindableFields.sorted().map {
            SpecBinding.fieldValue(ad, $0) ?? ""
        }
        return ([url, String(hash, radix: 16)] + fields).joined(separator: "\u{1F}")
    }

    private struct SpecVerdict: Sendable {
        let spec: RendererSpec?
        let hasDisclosure: Bool
    }

    /// Small thread-safe bounded cache of validated specs keyed by ad identity.
    private static let cache = SpecCache()

    private final class SpecCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: SpecVerdict] = [:]
        private var order: [String] = []
        private let capacity = 32

        func value(for key: String) -> SpecVerdict? {
            lock.lock()
            defer { lock.unlock() }
            return entries[key]
        }

        func store(_ verdict: SpecVerdict, for key: String) {
            lock.lock()
            defer { lock.unlock() }
            if entries[key] == nil {
                order.append(key)
                if order.count > capacity {
                    entries.removeValue(forKey: order.removeFirst())
                }
            }
            entries[key] = verdict
        }
    }

    /// Static text labels that count as an advertising disclosure.
    public static let disclosureTexts: Set<String> = [
        "ad", "ads", "advertisement", "sponsored", "promoted", "paid",
    ]

    /// A node's own `opacity` declaration (1 when absent/invalid).
    /// Legibility floor shared by the disclosure and visible-content walks:
    /// effective opacity ≥ 0.5 through the ancestor chain and font ≥ 9px.
    private static func nodeOpacity(_ style: [String: SpecStyleValue]?) -> Double {
        guard let style, let raw = style["opacity"],
              let n = SpecPSP1.unitless(raw) else { return 1 }
        return n
    }

    /// Whether text painted with this style + effective (cascaded) color is
    /// imperceptible: transparent/zero-alpha color, a sub-legible font, or a
    /// color token equal to the effective (cascaded) background token — text
    /// painted in its background color is invisible (`disclosureLegible` in
    /// psp.ts).
    private static func illegibleText(
        _ style: [String: SpecStyleValue]?,
        effectiveColor: SpecColorRef?,
        effectiveBackgroundToken: String? = nil
    ) -> Bool {
        if let ref = effectiveColor, ref.isTransparent || ref.alpha == 0 {
            return true
        }
        if let size = style?["fontSize"], let px = size.pxValue, px < 9 {
            return true
        }
        if let ref = effectiveColor, !ref.isTransparent,
           let bg = effectiveBackgroundToken, ref.token == bg {
            return true
        }
        return false
    }

    /// The `$token` base of a style's `background`, or `nil` when absent or
    /// not a token color (mirror of `tokenBase` in psp.ts).
    private static func backgroundToken(_ style: [String: SpecStyleValue]?) -> String? {
        guard let raw = style?["background"],
              let ref = SpecColorRef.parse(raw), !ref.isTransparent else { return nil }
        return ref.token
    }

    /// Whether `text` normalizes to a disclosure label (`isDisclosureText`
    /// in psp.ts): lowercased, non-letter runs collapsed to single spaces,
    /// trimmed, and matched exactly against ``disclosureTexts``.
    static func isDisclosureText(_ text: String) -> Bool {
        var normalized = ""
        for scalar in text.lowercased().unicodeScalars {
            if scalar >= "a" && scalar <= "z" {
                normalized.unicodeScalars.append(scalar)
            } else if !normalized.hasSuffix(" ") {
                normalized.append(" ")
            }
        }
        let trimmed = normalized.trimmingCharacters(in: .whitespaces)
        return disclosureTexts.contains(trimmed)
    }

    /// True when the tree contains a static text node whose content is an
    /// advertising disclosure label (e.g. "AD", "[Sponsored]") AND that node
    /// would actually be rendered for `ad`. Label matching: text is
    /// lowercased, non-letter runs collapse to single spaces, and the trimmed
    /// result must equal one of ``disclosureTexts``. Only labels the renderer
    /// would show count: subtrees gated off by an empty `showIf` field are
    /// skipped, a `showIf`-gated label (or one inside a gated subtree) never
    /// counts even when the field is populated — a label that can silently
    /// disappear is no disclosure guarantee (PSP1.md / `specHasDisclosure`) —
    /// a node whose `bind` shadows its static `text` never counts,
    /// and the label must be perceivable — a node (or ancestor) styled
    /// `opacity: 0`, a `transparent`/zero-alpha text color, a sub-legible
    /// `fontSize`, or a color token matching the effective background token
    /// cannot satisfy the disclosure requirement.
    /// Respects the depth and node-count caps while walking.
    public func hasDisclosure(rendering ad: AdResponse) -> Bool {
        var seen = 0
        // The renderer cascades an ancestor's `color` into descendant text,
        // so perceivability must be judged against the effective (own or
        // inherited) color, not just the label node's own style.
        func walk(_ node: SpecNode, depth: Int, inheritedColor: SpecColorRef?, inheritedBackground: String?, opacity: Double, gated: Bool) -> Bool {
            seen += 1
            if seen > SpecConstants.maxNodes || depth > SpecConstants.maxDepth {
                return false
            }
            if let gate = node.showIf,
               (SpecBinding.fieldValue(ad, gate) ?? "").isEmpty {
                return false
            }
            // Conditional labels never count, even when the gate field is
            // currently populated: the same layout would be unlabeled for
            // ads where the field is empty.
            let nodeGated = gated || node.showIf != nil
            let effectiveOpacity = opacity * Self.nodeOpacity(node.style)
            if effectiveOpacity < 0.5 { return false }
            let effectiveColor = node.style?["color"].flatMap { SpecColorRef.parse($0) } ?? inheritedColor
            let effectiveBackground = Self.backgroundToken(node.style) ?? inheritedBackground
            // Match the text the renderer paints, not the raw template: a
            // static label like "{ad}" normalizes to "ad" pre-expansion but
            // resolves to an empty string on screen, so only the resolved
            // content can satisfy the disclosure requirement.
            if !nodeGated, node.type == "text", node.bind == nil,
               Self.isDisclosureText(SpecBinding.resolveText(node, ad: ad)),
               !Self.illegibleText(
                   node.style,
                   effectiveColor: effectiveColor,
                   effectiveBackgroundToken: effectiveBackground
               ) {
                return true
            }
            // Only container nodes paint their children (the renderer drops
            // children of text/image nodes), so only they can carry a
            // rendered disclosure deeper in the tree.
            guard node.type == "box" || node.type == "link" else { return false }
            for child in node.children ?? [] {
                if walk(child, depth: depth + 1, inheritedColor: effectiveColor, inheritedBackground: effectiveBackground, opacity: effectiveOpacity, gated: nodeGated) { return true }
            }
            return false
        }
        return walk(root, depth: 0, inheritedColor: nil, inheritedBackground: nil, opacity: 1, gated: false)
    }

    /// True when at least one node would paint *perceivable* content for
    /// `ad`, using the same resolution rules as the renderer: `showIf` gates
    /// subtrees, text is visible when its resolved content is non-empty and
    /// legible (effective opacity ≥ 0.5 through the ancestor chain, a
    /// non-transparent effective color, font ≥ 9px), and an image is visible
    /// when its URL survives sanitization and it isn't faded out. Static
    /// text must go beyond chrome (`specProducesContent` in psp.ts): it
    /// needs word content and must either resolve a `{field}` template or
    /// not be a disclosure label. A spec that resolves to nothing beyond
    /// chrome must not be shown — the slot would render a label-only unit
    /// while still counting an impression.
    public func hasVisibleContent(for ad: AdResponse) -> Bool {
        var seen = 0
        func walk(_ node: SpecNode, depth: Int, inheritedColor: SpecColorRef?, opacity: Double) -> Bool {
            seen += 1
            if seen > SpecConstants.maxNodes || depth > SpecConstants.maxDepth {
                return false
            }
            if let gate = node.showIf,
               (SpecBinding.fieldValue(ad, gate) ?? "").isEmpty {
                return false
            }
            let effectiveOpacity = opacity * Self.nodeOpacity(node.style)
            if effectiveOpacity < 0.5 { return false }
            let effectiveColor = node.style?["color"].flatMap { SpecColorRef.parse($0) } ?? inheritedColor
            switch node.type {
            case "text":
                if Self.illegibleText(node.style, effectiveColor: effectiveColor) {
                    return false
                }
                if node.bind != nil {
                    return !SpecBinding.resolveText(node, ad: ad).isEmpty
                }
                // Static text counts as ad content only if it goes beyond
                // chrome (`subtreePaintsContent(..., adContentOnly)` in
                // psp.ts): disclosure labels ("Sponsored", "AD") and
                // punctuation-only separators ("\u{B7}") must not keep a spec
                // alive when every bound ad field is empty — that would
                // ship a label-only unit.
                let (text, boundResolved) = SpecBinding.resolveTemplate(node.text, ad: ad)
                guard !text.isEmpty,
                      text.unicodeScalars.contains(where: {
                          CharacterSet.alphanumerics.contains($0)
                      })
                else { return false }
                return boundResolved || !Self.isDisclosureText(text)
            case "image":
                return SpecBinding.imageURL(node, ad: ad) != nil
            default:
                for child in node.children ?? [] {
                    if walk(child, depth: depth + 1, inheritedColor: effectiveColor, opacity: effectiveOpacity) { return true }
                }
                return false
            }
        }
        return walk(root, depth: 0, inheritedColor: nil, opacity: 1)
    }

    /// Structural contract check shared by every interpreter
    /// (mirrors `validateSpec` in `@gravity-ai/ui`): version 1, known node
    /// types, depth ≤ 32, node count ≤ 400. A spec that fails this must not
    /// be rendered — the caller falls back to the built-in ad view.
    public var isStructurallyValid: Bool {
        guard version == 1 else { return false }
        var count = 0
        func walk(_ node: SpecNode, depth: Int, insideLink: Bool) -> Bool {
            count += 1
            if count > SpecConstants.maxNodes { return false }
            if depth > SpecConstants.maxDepth { return false }
            guard let type = node.type, SpecConstants.nodeTypes.contains(type) else {
                return false
            }
            // Interactive elements never nest (invalid HTML on web, ambiguous
            // tap target on native) — a link inside a link fails the contract.
            if type == "link" && insideLink { return false }
            // bind/showIf must name a real ad field ($defs/adField).
            for field in [node.bind, node.showIf] {
                if let field, !SpecConstants.bindableFields.contains(field) {
                    return false
                }
            }
            // Literal URL values must be safe at the contract level
            // ($defs/safeUrl): absolute http/https/mailto only, with
            // obfuscated schemes (" javascript:", "java\nscript:")
            // rejected the way a WHATWG URL parser would normalize them.
            for value in [node.href, node.src] {
                if let value, !Self.isSafeURLValue(value) { return false }
            }
            for child in node.children ?? [] {
                if !walk(child, depth: depth + 1, insideLink: insideLink || type == "link") { return false }
            }
            return true
        }
        return walk(root, depth: 0, insideLink: false)
    }

    /// Contract-level URL check mirroring `urlViolation` in psp.ts: the value
    /// is normalized the way a WHATWG URL parser would (tab/newline removed
    /// anywhere, C0 controls and spaces trimmed at both ends) and then must
    /// carry an http/https/mailto scheme. Scheme-less values are relative
    /// URLs — they would resolve against the publisher's page, letting a
    /// spec point an ad (or fetch an asset) at an arbitrary path on the host
    /// origin — so they fail the contract too.
    static func isSafeURLValue(_ raw: String) -> Bool {
        var value = raw.unicodeScalars.filter {
            $0 != "\t" && $0 != "\n" && $0 != "\r"
        }
        while let first = value.first, first.value <= 0x20 {
            value.removeFirst()
        }
        while let last = value.last, last.value <= 0x20 {
            value.removeLast()
        }
        let normalized = String(value.map(Character.init))
        guard let colon = normalized.firstIndex(of: ":") else { return false }
        let scheme = String(normalized[..<colon])
        // A scheme is ASCII alpha followed by alphanumerics/+/-/.; anything
        // else means the colon is not a scheme separator (relative URL).
        guard let first = scheme.first, first.isLetter, first.isASCII,
              scheme.dropFirst().allSatisfy({
                  ($0.isLetter || $0.isNumber) && $0.isASCII
                      || $0 == "+" || $0 == "-" || $0 == "."
              })
        else { return false }
        return SpecConstants.allowedURLSchemes.contains(scheme.lowercased())
    }

    /// PSP-1 profile conformance (mirrors the `psp1` result of `validateSpec`
    /// in `sdk-js/packages/ui/src/psp.ts`): every style declaration must be a
    /// whitelisted PSP-1 property with an in-grammar value. Web-only (`web1`)
    /// specs — full-CSS layouts using `flexDirection`, `hsl(var(--...))`,
    /// `boxShadow`, etc. — fail this check; the native interpreter cannot
    /// paint them faithfully, so the caller falls back to the built-in view.
    public var isPSP1Conformant: Bool {
        func walk(_ node: SpecNode) -> Bool {
            // Literal image sources must live on Gravity-controlled hosts
            // (PSP1.md); bound sources come from the ad payload and are exempt.
            if node.type == "image", node.bind == nil, let src = node.src,
               !src.isEmpty, !SpecBinding.isAllowedImageSrc(src) {
                return false
            }
            for (prop, value) in node.style ?? [:] {
                if !SpecPSP1.isInProfile(prop, value, nodeType: node.type) {
                    return false
                }
            }
            for child in node.children ?? [] {
                if !walk(child) { return false }
            }
            return true
        }
        return walk(root)
    }
}

/// One node of the spec tree.
public struct SpecNode: Codable, Sendable {
    public let type: String?
    public let bind: String?
    public let showIf: String?
    public let text: String?
    public let src: String?
    public let href: String?
    public let style: [String: SpecStyleValue]?
    public let children: [SpecNode]?
}

/// A style value: string, number, or boolean. Unknown shapes decode as `nil`
/// via `decodeIfPresent` failure at the container level being tolerated by
/// the enum's throwing initializer only for the three known primitives.
public enum SpecStyleValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let d = try? c.decode(Double.self) {
            self = .number(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else {
            // Arrays/objects are outside the grammar; decode to a harmless
            // empty string so a single odd value never sinks the whole spec.
            self = .string("")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// Numeric value, accepting `12`, `12.5`, or `"12px"`.
    var pxValue: Double? {
        switch self {
        case .number(let d): return d
        case .string(let s): return SpecStyleValue.parsePx(s)
        case .bool: return nil
        }
    }

    static func parsePx(_ s: String) -> Double? {
        // Canonical grammar (PX_RE in psp.ts): /^\d+(\.\d+)?$/ after the
        // "px" suffix — no leading dot, no trailing dot, one dot at most.
        let trimmed = s.hasSuffix("px") ? String(s.dropLast(2)) : s
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              parts.allSatisfy({ part in
                  !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber }
              }) else { return nil }
        return Double(trimmed)
    }
}

// MARK: - PSP-1 profile conformance

/// Per-property value grammars for the PSP-1 portable style profile.
/// Mirrors `PSP1_STYLE_RULES` in `sdk-js/packages/ui/src/psp.ts` — the
/// contract source of truth. Used only as a render gate: a spec with any
/// out-of-profile declaration is painted by the built-in view instead.
enum SpecPSP1 {
    /// Strict px grammar: a non-negative number, or a string like `"12px"`.
    /// Negative sizes are rejected outright — they are never meaningful in
    /// the profile and would render overlapping or unreadable content.
    private static func px(_ value: SpecStyleValue) -> Double? {
        let n: Double?
        switch value {
        case .number(let d): n = d.isFinite ? d : nil
        case .string(let s):
            guard s.hasSuffix("px") else { return nil }
            n = SpecStyleValue.parsePx(s)
        case .bool: n = nil
        }
        guard let n, n >= 0 else { return nil }
        return n
    }

    private static func pxCapped(_ value: SpecStyleValue, _ cap: Double) -> Bool {
        guard let n = px(value) else { return false }
        return n <= cap
    }

    /// 1–4 space-separated px values (CSS shorthand), or a bare number.
    private static func pxList(_ value: SpecStyleValue, _ cap: Double) -> Bool {
        if case .number(let n) = value { return n.isFinite && n >= 0 && n <= cap }
        guard let s = value.stringValue else { return false }
        // Single spaces only (PX_LIST_RE in psp.ts) — empty runs are
        // out of grammar, not silently collapsed.
        let parts = s.split(separator: " ", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return false }
        for part in parts {
            guard part.hasSuffix("px"), let n = SpecStyleValue.parsePx(String(part)),
                  n <= cap else { return false }
        }
        return true
    }

    private static func color(_ value: SpecStyleValue) -> Bool {
        guard let s = value.stringValue else { return false }
        if s == "transparent" { return true }
        guard let ref = SpecColorRef.parse(value), !ref.isTransparent else { return false }
        return SpecConstants.colorTokens.contains(ref.token)
    }

    private static func isEnum(_ value: SpecStyleValue, _ allowed: [String]) -> Bool {
        guard let s = value.stringValue else { return false }
        return allowed.contains(s)
    }

    private static func numberIn(_ value: SpecStyleValue, _ range: ClosedRange<Double>) -> Bool {
        guard case .number(let n) = value, n.isFinite else { return false }
        return range.contains(n)
    }

    /// A unitless number, as a JSON number or a numeric string like `"1.35"`
    /// (parity with `ruleLineHeight`/`ruleOpacity`/`ruleMaxLines` in psp.ts,
    /// which accept string-encoded numbers).
    static func unitless(_ value: SpecStyleValue) -> Double? {
        switch value {
        case .number(let n): return n.isFinite ? n : nil
        case .string(let s):
            let parts = s.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count),
                  parts.allSatisfy({ part in
                      !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber }
                  }) else { return nil }
            return Double(s)
        case .bool: return nil
        }
    }

    static func isInProfile(_ prop: String, _ value: SpecStyleValue, nodeType: String?) -> Bool {
        let spacing = SpecConstants.maxSpacingPx
        switch prop {
        case "direction": return isEnum(value, ["row", "column"])
        case "gap": return pxCapped(value, spacing)
        case "align": return isEnum(value, ["start", "center", "end", "baseline"])
        case "justify": return isEnum(value, ["start", "center", "end", "space-between"])
        case "grow", "shrink": return numberIn(value, 0...1) && (value.pxValue == 0 || value.pxValue == 1)
        case "spacerBefore", "nowrap": return value.boolValue != nil
        case "padding", "margin": return pxList(value, spacing)
        case "paddingTop", "paddingRight", "paddingBottom", "paddingLeft",
             "marginTop", "marginRight", "marginBottom", "marginLeft":
            return pxCapped(value, spacing)
        case "width", "height":
            // `ruleDimension` in psp.ts: "100%" or px, with only image
            // nodes capped (non-image dimensions are uncapped — the host
            // slot constrains the unit).
            if value.stringValue == "100%" { return true }
            guard let n = px(value) else { return false }
            return nodeType != "image" || n <= SpecConstants.maxImagePx
        case "maxWidth": return px(value) != nil
        case "minWidth":
            if case .number(let n) = value, n == 0 { return true }
            if value.stringValue == "0" { return true }
            return px(value) != nil
        case "background", "color": return color(value)
        case "border":
            // Canonical grammar requires a $token color (ruleBorder in
            // psp.ts: /^1px solid (\$\S+)$/) — "1px solid transparent" is
            // out of profile.
            guard let s = value.stringValue, s.hasPrefix("1px solid $") else { return false }
            return color(.string(String(s.dropFirst("1px solid ".count))))
        case "borderRadius":
            if let s = value.stringValue, s == "full" || s == "$radius" { return true }
            return px(value) != nil
        case "elevation": return isEnum(value, ["none", "sm", "md"])
        case "opacity":
            guard let n = unitless(value) else { return false }
            return n >= 0 && n <= 1
        case "fontSize": return pxCapped(value, SpecConstants.maxFontSizePx)
        case "fontWeight":
            guard case .number(let n) = value, n.isFinite else { return false }
            return [400.0, 500, 600, 700, 800].contains(n)
        case "lineHeight":
            guard let n = unitless(value) else { return false }
            return n >= 1 && n <= 2
        case "letterSpacing":
            // Canonical grammar: /^-?\d+(\.\d+)?em$/ (EM_RE in psp.ts).
            guard let s = value.stringValue, s.hasSuffix("em") else { return false }
            let body = s.hasPrefix("-") ? String(s.dropFirst().dropLast(2)) : String(s.dropLast(2))
            let parts = body.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count) else { return false }
            return parts.allSatisfy { part in
                !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber }
            }
        case "textTransform": return isEnum(value, ["none", "uppercase"])
        case "textDecoration": return isEnum(value, ["none", "underline"])
        case "textAlign": return isEnum(value, ["left", "center", "right"])
        case "maxLines":
            // ruleMaxLines in psp.ts: numbers must be integers in [1, 10];
            // strings must match /^\d+$/ — "2.0" is out of grammar.
            switch value {
            case .number(let n):
                return n.isFinite && n == n.rounded() && n >= 1 && n <= 10
            case .string(let s):
                guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let n = Int(s) else { return false }
                return n >= 1 && n <= 10
            case .bool: return false
            }
        case "fit": return isEnum(value, ["contain", "cover"])
        default: return false
        }
    }
}

// MARK: - Field binding / templating

public enum SpecBinding {
    /// Resolve a bindable ad field by name.
    public static func fieldValue(_ ad: AdResponse, _ field: String) -> String? {
        guard SpecConstants.bindableFields.contains(field) else { return nil }
        switch field {
        case "adText": return ad.adText
        case "title": return ad.title
        case "cta": return ad.cta
        case "brandName": return ad.brandName
        case "url": return ad.url
        case "favicon": return ad.favicon
        default: return nil
        }
    }

    /// Resolve an image node's sanitized source URL. `bind` takes strict
    /// precedence over a literal `src` (web parity): when `bind` is present
    /// but the field is empty or unbindable, the node shows nothing rather
    /// than falling back to the hardcoded picture.
    public static func imageURL(_ node: SpecNode, ad: AdResponse) -> URL? {
        // Literal sources must live on Gravity-controlled hosts (PSP1.md);
        // bound sources come from the ad payload and are exempt.
        if node.bind == nil, let src = node.src, !src.isEmpty,
           !isAllowedImageSrc(src) {
            return nil
        }
        let raw = node.bind != nil
            ? node.bind.flatMap { fieldValue(ad, $0) }
            : node.src
        // Image fetches are https-only (bound sources included): an image
        // node makes the end-user device issue a network request, and a
        // plaintext src would both downgrade transport and open the same
        // tracking-pixel vector the literal host rule closes.
        guard let url = sanitizeUrl(raw),
              url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    /// Literal image sources must be `https` on `*.trygravity.ai` — end-user
    /// devices never fetch ad assets straight from third-party hosts.
    public static func isAllowedImageSrc(_ src: String) -> Bool {
        isGravityHTTPS(src)
    }

    /// `https` on `trygravity.ai` or a subdomain — the host policy shared by
    /// literal image sources and literal link destinations.
    public static func isGravityHTTPS(_ raw: String) -> Bool {
        guard let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased()
        else { return false }
        return host == "trygravity.ai" || host.hasSuffix(".trygravity.ai")
    }

    /// Resolve a `text` node's content, expanding `{field}` placeholders.
    public static func resolveText(_ node: SpecNode, ad: AdResponse) -> String {
        if let bind = node.bind {
            return fieldValue(ad, bind) ?? ""
        }
        return resolveTemplate(node.text, ad: ad).text
    }

    /// Expand `{field}` placeholders in a static text template, also
    /// reporting whether any placeholder resolved to a non-empty ad field
    /// (`boundResolved` in psp.ts's `subtreePaintsContent`).
    static func resolveTemplate(_ template: String?, ad: AdResponse) -> (text: String, boundResolved: Bool) {
        guard let template else { return ("", false) }
        var boundResolved = false
        var result = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            let afterOpen = rest.index(after: open)
            if let close = rest[afterOpen...].firstIndex(of: "}"),
               afterOpen < close,
               rest[afterOpen..<close].allSatisfy({
                   $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_")
               }) {
                let value = fieldValue(ad, String(rest[afterOpen..<close])) ?? ""
                if !value.isEmpty { boundResolved = true }
                result += value
                rest = rest[rest.index(after: close)...]
            } else {
                // Not a `{word}` placeholder — emit the brace literally and
                // rescan from the next character, matching the web
                // SpecRenderer's `\{(\w+)\}` rule (which still finds a
                // placeholder after a stray `{`, e.g. "Save {50% off {title}").
                result += "{"
                rest = rest[afterOpen...]
            }
        }
        result += rest
        return (result, boundResolved)
    }

    /// The direct-open destination for a link node, if any. Bound links
    /// (e.g. `bind: "url"`) always return `nil` so the tap routes through the
    /// tracked `clickUrl` — never the raw landing URL — keeping attribution.
    /// A literal `href` opens directly only when it is `https` on a
    /// Gravity-controlled host (same policy as literal image sources); any
    /// other literal destination routes through the tracked `clickUrl`, so a
    /// spec can never send a tap straight to an arbitrary third-party site.
    public static func explicitHref(_ node: SpecNode) -> URL? {
        guard node.bind == nil,
              let href = node.href,
              isGravityHTTPS(href)
        else { return nil }
        return sanitizeUrl(href)
    }

    /// Allow only `http`, `https`, and `mailto` URLs; reject everything else
    /// (including `data:` and `javascript:`).
    public static func sanitizeUrl(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              SpecConstants.allowedURLSchemes.contains(scheme),
              let url = components.url
        else { return nil }
        return url
    }
}

// MARK: - Resolved PSP-1 style

/// Edge values parsed from a 1–4 px list (CSS shorthand order).
public struct SpecEdges: Sendable, Equatable {
    public var top: Double = 0
    public var right: Double = 0
    public var bottom: Double = 0
    public var left: Double = 0

    static func parse(_ value: SpecStyleValue, cap: Double) -> SpecEdges? {
        if let n = value.pxValue {
            let v = min(n, cap)
            return SpecEdges(top: v, right: v, bottom: v, left: v)
        }
        guard let s = value.stringValue else { return nil }
        let parts = s.split(separator: " ").compactMap { SpecStyleValue.parsePx(String($0)) }
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        let capped = parts.map { min($0, cap) }
        switch capped.count {
        case 1: return SpecEdges(top: capped[0], right: capped[0], bottom: capped[0], left: capped[0])
        case 2: return SpecEdges(top: capped[0], right: capped[1], bottom: capped[0], left: capped[1])
        case 3: return SpecEdges(top: capped[0], right: capped[1], bottom: capped[2], left: capped[1])
        default: return SpecEdges(top: capped[0], right: capped[1], bottom: capped[2], left: capped[3])
        }
    }
}

/// A `$token[/alpha]` color reference.
public struct SpecColorRef: Sendable, Equatable {
    public let token: String
    /// 0…1 alpha multiplier.
    public let alpha: Double
    public let isTransparent: Bool

    static let transparent = SpecColorRef(token: "", alpha: 0, isTransparent: true)

    static func parse(_ value: SpecStyleValue) -> SpecColorRef? {
        guard let s = value.stringValue else { return nil }
        if s == "transparent" { return .transparent }
        guard s.hasPrefix("$") else { return nil }
        let body = s.dropFirst()
        let parts = body.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let token = parts.first.map(String.init), !token.isEmpty else { return nil }
        var alpha = 1.0
        if parts.count == 2 {
            // Canonical grammar (TOKEN_RE in psp.ts / colorToken in
            // renderer-spec.schema.json): the percent is exactly `100` or
            // `[1-9]?[0-9]` — plain decimal digits, no sign, no leading zeros
            // ("045"), no empty suffix ("$muted/").
            let suffix = parts[1]
            let isCanonicalPercent =
                suffix.allSatisfy { $0.isASCII && $0.isNumber }
                    && (suffix == "100"
                        || (1...2).contains(suffix.count) && !(suffix.count == 2 && suffix.first == "0"))
            guard isCanonicalPercent, let pct = Int(suffix) else { return nil }
            alpha = Double(pct) / 100
        }
        return SpecColorRef(token: token, alpha: alpha, isTransparent: false)
    }
}

/// Corner radius: px, "full", or "$radius" (theme radius).
public enum SpecRadius: Sendable, Equatable {
    case px(Double)
    case full
    case themeRadius

    static func parse(_ value: SpecStyleValue) -> SpecRadius? {
        if let s = value.stringValue {
            if s == "full" { return .full }
            if s == "$radius" { return .themeRadius }
        }
        if let n = value.pxValue { return .px(n) }
        return nil
    }
}

/// A dimension: px or "100%".
public enum SpecDimension: Sendable, Equatable {
    case px(Double)
    case fill

    static func parse(_ value: SpecStyleValue, cap: Double = .infinity) -> SpecDimension? {
        if value.stringValue == "100%" { return .fill }
        if let n = value.pxValue { return .px(min(n, cap)) }
        return nil
    }
}

/// The PSP-1 style bag parsed into typed, clamped values. Unknown properties
/// and out-of-grammar values are silently dropped (skip-not-crash).
public struct SpecStyle: Sendable {
    // Layout
    public var direction: String?      // row | column
    public var gap: Double?
    public var align: String?          // start | center | end | baseline
    public var justify: String?        // start | center | end | space-between
    public var grow: Bool = false
    /// `shrink: 0` — the node must keep its intrinsic size under width
    /// pressure (portable replacement for CSS `flexShrink: 0`).
    public var noShrink: Bool = false
    public var spacerBefore: Bool = false
    // Box
    public var padding = SpecEdges()
    public var margin = SpecEdges()
    public var width: SpecDimension?
    public var height: SpecDimension?
    public var maxWidth: Double?
    // Surface
    public var background: SpecColorRef?
    public var borderColor: SpecColorRef?
    public var borderRadius: SpecRadius?
    public var elevation: String?      // none | sm | md
    public var opacity: Double?
    // Text
    public var fontSize: Double?
    public var fontWeight: Int?
    public var lineHeight: Double?
    public var letterSpacingEm: Double?
    public var color: SpecColorRef?
    public var uppercase: Bool = false
    public var underline: Bool = false
    public var textAlign: String?      // left | center | right
    public var maxLines: Int?
    public var nowrap: Bool = false
    // Image
    public var fit: String?            // contain | cover
    /// Whether this style belongs to an `image` node. Non-image nodes treat an
    /// explicit `height` as a minimum so ad copy is never clipped by a frame.
    public var isImage: Bool = false

    public init(_ raw: [String: SpecStyleValue]?, nodeType: String?) {
        isImage = nodeType == "image"
        guard let raw else { return }
        let spacingCap = SpecConstants.maxSpacingPx
        let dimensionCap = nodeType == "image" ? SpecConstants.maxImagePx : Double.infinity

        // Shorthand before longhand, like CSS: `padding`/`margin` replace the
        // whole edge set, then per-side properties override individual edges.
        // Dictionary iteration order is unspecified, so this must be explicit.
        if let value = raw["padding"], let e = SpecEdges.parse(value, cap: spacingCap) {
            padding = e
        }
        if let value = raw["margin"], let e = SpecEdges.parse(value, cap: spacingCap) {
            margin = e
        }

        for (prop, value) in raw {
            switch prop {
            case "direction":
                if let s = value.stringValue, s == "row" || s == "column" { direction = s }
            case "gap":
                if let n = value.pxValue { gap = min(n, spacingCap) }
            case "align":
                if let s = value.stringValue,
                   ["start", "center", "end", "baseline"].contains(s) { align = s }
            case "justify":
                if let s = value.stringValue,
                   ["start", "center", "end", "space-between"].contains(s) { justify = s }
            case "grow":
                if value.pxValue == 1 { grow = true }
            case "shrink":
                if value.pxValue == 0 { noShrink = true }
            case "spacerBefore":
                if value.boolValue == true { spacerBefore = true }
            case "padding", "margin":
                break // consumed above, before the per-side overrides
            case "paddingTop":
                if let n = value.pxValue { padding.top = min(n, spacingCap) }
            case "paddingRight":
                if let n = value.pxValue { padding.right = min(n, spacingCap) }
            case "paddingBottom":
                if let n = value.pxValue { padding.bottom = min(n, spacingCap) }
            case "paddingLeft":
                if let n = value.pxValue { padding.left = min(n, spacingCap) }
            case "marginTop":
                if let n = value.pxValue { margin.top = min(n, spacingCap) }
            case "marginRight":
                if let n = value.pxValue { margin.right = min(n, spacingCap) }
            case "marginBottom":
                if let n = value.pxValue { margin.bottom = min(n, spacingCap) }
            case "marginLeft":
                if let n = value.pxValue { margin.left = min(n, spacingCap) }
            case "width":
                width = SpecDimension.parse(value, cap: dimensionCap)
            case "height":
                height = SpecDimension.parse(value, cap: dimensionCap)
            case "maxWidth":
                if let n = value.pxValue { maxWidth = n }
            case "background":
                background = SpecColorRef.parse(value)
            case "border":
                if let s = value.stringValue, s.hasPrefix("1px solid ") {
                    borderColor = SpecColorRef.parse(.string(String(s.dropFirst("1px solid ".count))))
                }
            case "borderRadius":
                borderRadius = SpecRadius.parse(value)
            case "elevation":
                if let s = value.stringValue, ["none", "sm", "md"].contains(s) { elevation = s }
            case "opacity":
                if let n = SpecPSP1.unitless(value), n >= 0, n <= 1 { opacity = n }
            case "fontSize":
                if let n = value.pxValue { fontSize = min(n, SpecConstants.maxFontSizePx) }
            case "fontWeight":
                if case .number(let n) = value, n >= 400, n <= 800,
                   [400, 500, 600, 700, 800].contains(Int(n)) {
                    fontWeight = Int(n)
                }
            case "lineHeight":
                if let n = SpecPSP1.unitless(value), n >= 1, n <= 2 { lineHeight = n }
            case "letterSpacing":
                if let s = value.stringValue, s.hasSuffix("em"),
                   let n = Double(s.dropLast(2)) { letterSpacingEm = n }
            case "color":
                color = SpecColorRef.parse(value)
            case "textTransform":
                if value.stringValue == "uppercase" { uppercase = true }
            case "textDecoration":
                if value.stringValue == "underline" { underline = true }
            case "textAlign":
                if let s = value.stringValue, ["left", "center", "right"].contains(s) { textAlign = s }
            case "maxLines":
                if let n = SpecPSP1.unitless(value), n == n.rounded(), n >= 1, n <= 10 {
                    maxLines = Int(n)
                }
            case "nowrap":
                if value.boolValue == true { nowrap = true }
            case "fit":
                if let s = value.stringValue, s == "contain" || s == "cover" { fit = s }
            default:
                break // unknown property — skip, never fail
            }
        }
    }
}
