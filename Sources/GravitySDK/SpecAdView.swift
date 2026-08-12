// Spec rendering depends on GravityTheme's semantic palette, which is
// unavailable on tvOS/watchOS; those platforms keep the built-in ad view.
#if canImport(SwiftUI) && canImport(UIKit) && !os(tvOS) && !os(watchOS)
import SwiftUI
import UIKit

/// Renders a server-delivered PSP-1 `renderer_spec` as a native SwiftUI tree.
///
/// Fallback ladder: if the ad carries no spec, or the spec fails to parse or
/// violates the structural contract (unknown node types, depth > 32,
/// nodes > 400, version ≠ 1), the SDK's built-in ``GravityAdView`` renders
/// instead — an invalid spec can never crash or blank the host app.
///
/// Tracking parity with ``GravityAdView``: fires the impression pixel once on
/// first appearance, and routes link taps through `gravity.handleClick`
/// (the tracked `clickUrl`). Bound links (e.g. `bind: "url"`) always use the
/// tracked clickUrl; only a literal `href` on a Gravity-controlled `https`
/// host opens directly — any other destination routes through the clickUrl.
///
/// ```swift
/// SpecAdView(ad: ad, gravity: gravity, sessionId: sessionId)
/// ```
public struct SpecAdView: View {
    private let ad: AdResponse
    private let gravity: Gravity
    private let sessionId: String
    private let theme: GravityTheme
    private let showFeedback: Bool
    private let spec: RendererSpec?
    private let specHasDisclosure: Bool

    @State private var impressionFired = false
    @State private var feedbackSent = false

    public init(
        ad: AdResponse,
        gravity: Gravity,
        sessionId: String,
        theme: GravityTheme = .default,
        showFeedback: Bool = true
    ) {
        self.ad = ad
        self.gravity = gravity
        self.sessionId = sessionId
        self.theme = theme
        self.showFeedback = showFeedback
        // Memoized: SwiftUI re-runs this init on every render pass, so the
        // parse + validation is cached per ad rather than repeated each redraw.
        self.spec = RendererSpec.renderableSpec(for: ad)
        self.specHasDisclosure = RendererSpec.rendersDisclosure(for: ad)
    }

    public var body: some View {
        if let spec {
            VStack(alignment: .leading, spacing: 4) {
                // The whole card is always the tap target, whatever the
                // design says. A root `link` node is already a full-card
                // button; for any other root, tapping anywhere outside a
                // nested button opens the tracked destination.
                SpecNodeView(node: spec.root, ad: ad, gravity: gravity, theme: theme)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard spec.root.type != "link" else { return }
                        gravity.handleClick(ad)
                    }
                    .overlay(alignment: .topTrailing) {
                        // Compliance: an unlabeled ad must never reach the end
                        // user — if the spec carries no disclosure text node,
                        // overlay the SDK's built-in "Ad" badge.
                        if !specHasDisclosure {
                            Text("Ad")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.regularMaterial, in: Capsule())
                                .padding(6)
                                .allowsHitTesting(false)
                        }
                    }

                // Feedback chrome sits outside the portable spec tree, so
                // spec-rendered inventory reports the same thumbs signal as
                // the built-in renderer.
                if showFeedback && !feedbackSent {
                    HStack {
                        Spacer()
                        HStack(spacing: 12) {
                            Button {
                                feedbackSent = true
                                gravity.sendFeedback(
                                    sessionId: sessionId, ad: ad,
                                    sentiment: .thumbsUp
                                )
                            } label: {
                                Image(systemName: "hand.thumbsup")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)

                            Button {
                                feedbackSent = true
                                gravity.sendFeedback(
                                    sessionId: sessionId, ad: ad,
                                    sentiment: .thumbsDown,
                                    reasons: ["not_interested"]
                                )
                            } label: {
                                Image(systemName: "hand.thumbsdown")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .onAppear {
                guard !impressionFired else { return }
                impressionFired = true
                gravity.trackImpression(ad)
            }
        } else {
            // GravityAdView fires its own impression pixel on appear and
            // owns the feedback chrome on the fallback path.
            GravityAdView(ad: ad, gravity: gravity, sessionId: sessionId, showFeedback: showFeedback)
        }
    }
}

/// One node of the spec tree. Unknown node types render as nothing
/// (skip-not-crash); `showIf` gates a subtree on a non-empty ad field.
@MainActor
struct SpecNodeView: View {
    let node: SpecNode
    let ad: AdResponse
    let gravity: Gravity
    let theme: GravityTheme

    var body: some View {
        if let gate = node.showIf,
           (SpecBinding.fieldValue(ad, gate) ?? "").isEmpty {
            EmptyView()
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        let style = SpecStyle(node.style, nodeType: node.type)
        switch node.type {
        case "text":
            let text = SpecBinding.resolveText(node, ad: ad)
            if text.isEmpty {
                EmptyView()
            } else {
                styledText(text, style: style)
                    .modifier(SpecContainerModifier(style: style, theme: theme))
            }
        case "image":
            if let url = SpecBinding.imageURL(node, ad: ad) {
                specImage(url: url, style: style)
                    .modifier(SpecContainerModifier(style: style, theme: theme))
            } else {
                EmptyView()
            }
        case "link":
            Button {
                handleTap()
            } label: {
                childStack(style: style)
                    .modifier(SpecContainerModifier(style: style, theme: theme))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case "box":
            childStack(style: style)
                .modifier(SpecContainerModifier(style: style, theme: theme))
        default:
            EmptyView()
        }
    }

    @MainActor
    private func handleTap() {
        // A `bind` (e.g. bind:"url") means "the ad's destination" — that must
        // go through the tracked clickUrl, never the raw landing URL, so the
        // click is attributed. Only a literal `href` on a Gravity-controlled
        // https host opens directly; anything else falls through to the
        // tracked clickUrl so a spec can never steer a tap to an arbitrary
        // third-party site.
        #if !os(watchOS)
        if let explicit = SpecBinding.explicitHref(node) {
            UIApplication.shared.open(explicit)
            return
        }
        #endif
        gravity.handleClick(ad)
    }

    /// Whether a child will paint anything for this ad, mirroring the
    /// gating in `body`/`content`. Children that render `EmptyView()` must
    /// not contribute spacers, or hidden pieces would leave phantom
    /// flexible space that shoves visible siblings around.
    private func willRender(_ node: SpecNode) -> Bool {
        if let gate = node.showIf,
           (SpecBinding.fieldValue(ad, gate) ?? "").isEmpty {
            return false
        }
        switch node.type {
        case "text":
            return !SpecBinding.resolveText(node, ad: ad).isEmpty
        case "image":
            return SpecBinding.imageURL(node, ad: ad) != nil
        case "box", "link":
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private func childStack(style: SpecStyle) -> some View {
        let children = (node.children ?? []).filter(willRender)
        // An omitted `direction` defaults to "row" — the contract-pinned
        // default (PSP1.md), matching the CSS flexbox default. Every
        // interpreter must stack the same way for the same spec.
        if style.direction == "column" {
            VStack(alignment: horizontalAlignment(style), spacing: CGFloat(style.gap ?? 0)) {
                childViews(children, style: style)
            }
        } else {
            HStack(alignment: verticalAlignment(style), spacing: CGFloat(style.gap ?? 0)) {
                childViews(children, style: style)
            }
        }
    }

    @ViewBuilder
    private func childViews(_ children: [SpecNode], style: SpecStyle) -> some View {
        // Main-axis distribution: space-between inserts a Spacer between each
        // pair of children; center/end pack the run with flexible edge Spacers
        // (leading+trailing for center, leading only for end). start is the
        // stack's natural packing.
        let spaceBetween = style.justify == "space-between"
        if style.justify == "center" || style.justify == "end" {
            Spacer(minLength: 0)
        }
        ForEach(Array(children.enumerated()), id: \.offset) { index, child in
            let childStyle = SpecStyle(child.style, nodeType: child.type)
            if childStyle.spacerBefore || (spaceBetween && index > 0) {
                Spacer(minLength: 0)
            }
            // `grow`/`shrink` act on the container's main axis, like CSS
            // flex-grow/flex-shrink: horizontal in a row, vertical in a
            // column. A cross-axis fixedSize would pin text to its unwrapped
            // intrinsic width and clip copy.
            if childStyle.grow {
                SpecNodeView(node: child, ad: ad, gravity: gravity, theme: theme)
                    .frame(
                        maxWidth: style.direction == "column" ? nil : .infinity,
                        maxHeight: style.direction == "column" ? .infinity : nil,
                        alignment: .leading
                    )
            } else if childStyle.noShrink {
                // `shrink: 0` — keep the intrinsic size on the main axis;
                // flexible siblings absorb any compression instead.
                SpecNodeView(node: child, ad: ad, gravity: gravity, theme: theme)
                    .fixedSize(
                        horizontal: style.direction != "column",
                        vertical: style.direction == "column"
                    )
                    .layoutPriority(1)
            } else {
                SpecNodeView(node: child, ad: ad, gravity: gravity, theme: theme)
            }
        }
        if style.justify == "center" {
            Spacer(minLength: 0)
        }
    }

    private func horizontalAlignment(_ style: SpecStyle) -> HorizontalAlignment {
        switch style.align {
        case "center": return .center
        case "end": return .trailing
        default: return .leading
        }
    }

    private func verticalAlignment(_ style: SpecStyle) -> VerticalAlignment {
        switch style.align {
        case "start": return .top
        case "end": return .bottom
        case "baseline": return .firstTextBaseline
        default: return .center
        }
    }

    private func styledText(_ content: String, style: SpecStyle) -> some View {
        let size = CGFloat(style.fontSize ?? 14)
        var text = Text(style.uppercase ? content.uppercased() : content)
            .font(.system(size: size, weight: fontWeight(style.fontWeight)))
        if style.underline {
            text = text.underline()
        }
        if let em = style.letterSpacingEm {
            text = text.tracking(CGFloat(em) * size)
        }
        // Copy is never cut client-side: `maxLines` stays valid in the
        // profile for spec compatibility but is never applied as a line
        // limit — ad copy must always be fully visible. Length is controlled
        // server-side (sentence-boundary-aware max_ad_text_chars). `nowrap`
        // keeps single-line labels (CTA pills, badges) on one line, matching
        // the web's `white-space: nowrap`.
        // A nil explicit color falls through to the environment foreground,
        // so a `color` declared on an ancestor box/link cascades like CSS.
        return text
            .foregroundColor(theme.resolve(style.color))
            .lineLimit(style.nowrap ? 1 : nil)
            .fixedSize(horizontal: false, vertical: true)
            .lineSpacing(style.lineHeight.map { CGFloat(($0 - 1) * (style.fontSize ?? 14)) } ?? 0)
            .multilineTextAlignment(textAlignment(style.textAlign))
    }

    private func fontWeight(_ weight: Int?) -> Font.Weight {
        switch weight {
        case 500: return .medium
        case 600: return .semibold
        case 700: return .bold
        case 800: return .heavy
        default: return .regular
        }
    }

    private func textAlignment(_ align: String?) -> TextAlignment {
        switch align {
        case "center": return .center
        case "right": return .trailing
        default: return .leading
        }
    }

    private func specImage(url: URL, style: SpecStyle) -> some View {
        let width: CGFloat? = {
            if case .px(let n) = style.width { return CGFloat(n) }
            return nil
        }()
        let height: CGFloat? = {
            if case .px(let n) = style.height { return CGFloat(n) }
            return nil
        }()
        let fillsWidth = style.width == .fill
        // A "100%" height would otherwise leave the resizable image
        // unconstrained (a stack proposes unbounded height), so a fill
        // height clamps to the profile's image cap. Width fill is safe:
        // the host slot bounds it.
        let fillHeight: CGFloat? = style.height == .fill ? CGFloat(SpecConstants.maxImagePx) : nil
        // A small default applies only when the spec gives no sizing at all;
        // a single specified axis lets aspect-fit derive the other, and a
        // "100%" width stretches to the available width.
        let unsized = width == nil && height == nil && !fillsWidth && fillHeight == nil
        return AsyncImage(url: url) { image in
            image
                .resizable()
                .aspectRatio(contentMode: style.fit == "cover" ? .fill : .fit)
        } placeholder: {
            Color.gray.opacity(0.2)
        }
        .frame(width: unsized ? 20 : width, height: unsized ? 20 : (height ?? fillHeight))
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
        .clipShape(RoundedRectangle(
            cornerRadius: SpecStyle.cornerRadius(style.borderRadius, theme: theme),
            style: .continuous
        ))
    }
}

extension SpecStyle {
    /// Resolve a PSP-1 `borderRadius` to points, shared by container shaping
    /// and image clipping so both round corners identically.
    static func cornerRadius(_ radius: SpecRadius?, theme: GravityTheme) -> CGFloat {
        switch radius {
        case .px(let n): return CGFloat(n)
        case .full: return 999
        case .themeRadius: return theme.radius
        case nil: return 0
        }
    }
}

/// Applies the PSP-1 container styles (padding, background, border, corner
/// radius, elevation shadow, opacity, sizing, margin) in the same visual
/// order as the web interpreter.
struct SpecContainerModifier: ViewModifier {
    let style: SpecStyle
    let theme: GravityTheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if let cascade = theme.resolve(style.color) {
            // `color` on a container cascades to descendant text (CSS parity):
            // text nodes without their own color inherit this via the
            // SwiftUI foreground environment.
            styled(content).foregroundColor(cascade)
        } else {
            styled(content)
        }
    }

    private func styled(_ content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // Images own their exact frame inside `specImage`; re-applying it
        // here after padding would report a smaller size to the parent than
        // the padded content occupies (overflow into siblings).
        return content
            .padding(EdgeInsets(
                top: CGFloat(style.padding.top),
                leading: CGFloat(style.padding.left),
                bottom: CGFloat(style.padding.bottom),
                trailing: CGFloat(style.padding.right)
            ))
            // Explicit .leading/.topLeading: SwiftUI frames center by
            // default, but a sized CSS flex container packs content at the
            // top-leading edge.
            .frame(width: style.isImage ? nil : fixedWidth, alignment: .leading)
            .frame(minHeight: style.isImage ? nil : fixedHeight, alignment: .topLeading)
            .frame(maxWidth: flexibleMaxWidth, alignment: .leading)
            .background(theme.resolve(style.background) ?? .clear, in: shape)
            .overlay {
                if let borderColor = theme.resolve(style.borderColor) {
                    shape.strokeBorder(borderColor, lineWidth: 1)
                }
            }
            .shadow(
                color: .black.opacity(shadowOpacity),
                radius: shadowRadius,
                x: 0,
                y: shadowRadius / 2
            )
            .opacity(style.opacity ?? 1)
            .padding(EdgeInsets(
                top: CGFloat(style.margin.top),
                leading: CGFloat(style.margin.left),
                bottom: CGFloat(style.margin.bottom),
                trailing: CGFloat(style.margin.right)
            ))
    }

    private var cornerRadius: CGFloat {
        SpecStyle.cornerRadius(style.borderRadius, theme: theme)
    }

    private var flexibleMaxWidth: CGFloat? {
        // `width: "100%"` fills the slot but still honors a declared
        // `maxWidth` cap (CSS: width:100%; max-width:Npx).
        if style.width == .fill { return style.maxWidth.map { CGFloat($0) } ?? .infinity }
        return style.maxWidth.map { CGFloat($0) }
    }

    private var fixedWidth: CGFloat? {
        if case .px(let n) = style.width { return CGFloat(n) }
        return nil
    }

    private var fixedHeight: CGFloat? {
        if case .px(let n) = style.height { return CGFloat(n) }
        return nil
    }

    private var shadowRadius: CGFloat {
        switch style.elevation {
        case "sm": return 3
        case "md": return 8
        default: return 0
        }
    }

    private var shadowOpacity: Double {
        switch style.elevation {
        case "sm": return 0.08
        case "md": return 0.14
        default: return 0
        }
    }
}
#endif
