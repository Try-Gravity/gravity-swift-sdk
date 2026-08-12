// The iOS-13 semantic UIColor palette used for the default theme is
// unavailable on tvOS/watchOS; those platforms keep the built-in ad view.
#if canImport(SwiftUI) && canImport(UIKit) && !os(tvOS) && !os(watchOS)
import SwiftUI
import UIKit

/// Maps PSP-1 semantic `$tokens` to native colors. Defaults derive from the
/// system semantic palette so light/dark mode work with zero publisher
/// configuration; every slot can be overridden. Mirrors the JS `GravityTheme`.
public struct GravityTheme: Sendable {
    public var background: Color
    public var foreground: Color
    public var card: Color
    public var cardForeground: Color
    public var primary: Color
    public var primaryForeground: Color
    public var muted: Color
    public var mutedForeground: Color
    public var accent: Color
    public var accentForeground: Color
    public var border: Color
    /// Default corner radius used for `borderRadius: "$radius"` (px).
    public var radius: CGFloat

    public init(
        background: Color = Color(UIColor.systemBackground),
        foreground: Color = Color(UIColor.label),
        card: Color = Color(UIColor.secondarySystemBackground),
        cardForeground: Color = Color(UIColor.label),
        primary: Color = .accentColor,
        primaryForeground: Color = .white,
        muted: Color = Color(UIColor.secondarySystemFill),
        mutedForeground: Color = Color(UIColor.secondaryLabel),
        accent: Color = Color(UIColor.tertiarySystemFill),
        accentForeground: Color = Color(UIColor.label),
        border: Color = Color(UIColor.separator),
        radius: CGFloat = 10
    ) {
        self.background = background
        self.foreground = foreground
        self.card = card
        self.cardForeground = cardForeground
        self.primary = primary
        self.primaryForeground = primaryForeground
        self.muted = muted
        self.mutedForeground = mutedForeground
        self.accent = accent
        self.accentForeground = accentForeground
        self.border = border
        self.radius = radius
    }

    public static let `default` = GravityTheme()

    /// Resolve a parsed `$token[/alpha]` reference to a Color.
    /// Unknown tokens resolve to `nil` (the interpreter skips them).
    public func resolve(_ ref: SpecColorRef?) -> Color? {
        guard let ref else { return nil }
        if ref.isTransparent { return .clear }
        let base: Color?
        switch ref.token {
        case "background": base = background
        case "foreground": base = foreground
        case "card": base = card
        case "card-foreground": base = cardForeground
        case "primary": base = primary
        case "primary-foreground": base = primaryForeground
        case "muted": base = muted
        case "muted-foreground": base = mutedForeground
        case "accent": base = accent
        case "accent-foreground": base = accentForeground
        case "border": base = border
        default: base = nil
        }
        guard let base else { return nil }
        return ref.alpha < 1 ? base.opacity(ref.alpha) : base
    }
}
#endif
