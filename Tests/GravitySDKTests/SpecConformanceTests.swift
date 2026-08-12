import XCTest
@testable import GravitySDK

/// PSP-1 conformance suite.
///
/// The golden fixtures in `SpecFixtures/` are a copy of the canonical set in
/// `sdk-js/spec-fixtures/` (the cross-platform source of truth — keep them in
/// sync when the contract changes). Each fixture declares
/// `expect.structureValid`; specs that fail the structural contract must
/// trigger the fallback ladder (built-in `GravityAdView`) without throwing.
final class SpecConformanceTests: XCTestCase {
    struct Fixture: Decodable {
        struct Expect: Decodable {
            let structureValid: Bool
            let psp1: Bool
        }
        let name: String
        let expect: Expect
    }

    static func fixtureURLs() throws -> [URL] {
        guard let dir = Bundle.module.url(forResource: "SpecFixtures", withExtension: nil) else {
            throw XCTSkip("SpecFixtures resource directory missing")
        }
        return try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func specData(from fixtureData: Data) throws -> Data {
        let obj = try JSONSerialization.jsonObject(with: fixtureData) as? [String: Any]
        let spec = try XCTUnwrap(obj?["spec"])
        return try JSONSerialization.data(withJSONObject: spec)
    }

    /// Every golden fixture decodes without throwing, and structural
    /// validity matches the fixture's `expect.structureValid` — the exact
    /// signal the interpreter uses to choose spec rendering vs fallback.
    func testFixturesMatchStructuralExpectations() throws {
        let urls = try Self.fixtureURLs()
        XCTAssertGreaterThanOrEqual(urls.count, 20, "fixture set incomplete")
        for url in urls {
            let data = try Data(contentsOf: url)
            let fixture = try JSONDecoder().decode(Fixture.self, from: data)
            let spec = RendererSpec.parse(try Self.specData(from: data))
            let structureValid = spec?.isStructurallyValid ?? false
            XCTAssertEqual(
                structureValid,
                fixture.expect.structureValid,
                "\(fixture.name): structureValid=\(structureValid), expected \(fixture.expect.structureValid)"
            )
            // The native render gate: structure AND PSP-1 profile conformance.
            // Web-only (web1) specs must fall back to the built-in view.
            let renderable = structureValid && (spec?.isPSP1Conformant ?? false)
            XCTAssertEqual(
                renderable,
                fixture.expect.psp1,
                "\(fixture.name): psp1=\(renderable), expected \(fixture.expect.psp1)"
            )
        }
    }

    /// Adversarial fixtures never throw during decode or validation and
    /// never mark an invalid spec renderable.
    func testAdversarialFixturesFallBackSafely() throws {
        for url in try Self.fixtureURLs() where url.lastPathComponent.hasPrefix("adversarial") {
            let data = try Data(contentsOf: url)
            let fixture = try JSONDecoder().decode(Fixture.self, from: data)
            // Must not crash regardless of content.
            let spec = RendererSpec.parse(try Self.specData(from: data))
            if !fixture.expect.structureValid {
                XCTAssertFalse(
                    spec?.isStructurallyValid ?? false,
                    "\(fixture.name): invalid spec must not be renderable"
                )
            }
        }
    }

    /// Every structurally valid fixture resolves to a fully typed node tree —
    /// the input the SwiftUI interpreter walks — and style parsing never
    /// throws on any fixture, including adversarial style bags.
    func testValidFixturesProduceTypedNodeTree() throws {
        for url in try Self.fixtureURLs() {
            let data = try Data(contentsOf: url)
            let fixture = try JSONDecoder().decode(Fixture.self, from: data)
            guard let spec = RendererSpec.parse(try Self.specData(from: data)) else { continue }
            var nodes = 0
            func walk(_ node: SpecNode) {
                nodes += 1
                _ = SpecStyle(node.style, nodeType: node.type)
                (node.children ?? []).forEach(walk)
            }
            walk(spec.root)
            if fixture.expect.structureValid {
                XCTAssertGreaterThan(nodes, 0, "\(fixture.name): empty tree")
            }
        }
    }

    // MARK: - Safety rails

    func testURLSanitizationAllowsOnlySafeSchemes() {
        XCTAssertNotNil(SpecBinding.sanitizeUrl("https://example.com/x"))
        XCTAssertNotNil(SpecBinding.sanitizeUrl("http://example.com"))
        XCTAssertNotNil(SpecBinding.sanitizeUrl("mailto:ads@example.com"))
        XCTAssertNil(SpecBinding.sanitizeUrl("javascript:alert(1)"))
        XCTAssertNil(SpecBinding.sanitizeUrl("data:text/html,<script>alert(1)</script>"))
        XCTAssertNil(SpecBinding.sanitizeUrl("file:///etc/passwd"))
        XCTAssertNil(SpecBinding.sanitizeUrl(""))
        XCTAssertNil(SpecBinding.sanitizeUrl(nil))
    }

    func testDangerousStyleValuesAreDropped() {
        let style = SpecStyle(
            [
                "background": .string("url(javascript:alert(1))"),
                "behavior": .string("expression(alert(1))"),
                "color": .string("#ff0000"),
                "fontSize": .string("120px"),
                "gap": .string("500px"),
                "width": .string("9999px"),
            ],
            nodeType: "image"
        )
        XCTAssertNil(style.background, "non-$token background must be dropped")
        XCTAssertNil(style.color, "literal hex color must be dropped")
        XCTAssertEqual(style.fontSize, SpecConstants.maxFontSizePx)
        XCTAssertEqual(style.gap, SpecConstants.maxSpacingPx)
        XCTAssertEqual(style.width, .px(SpecConstants.maxImagePx))
    }

    func testOutOfRangeNumbersNeverTrap() {
        for extreme in [1e19, -1e19, Double.infinity, -Double.infinity, Double.nan] {
            let style = SpecStyle(
                [
                    "fontWeight": .number(extreme),
                    "maxLines": .number(extreme),
                    "opacity": .number(extreme),
                    "lineHeight": .number(extreme),
                ],
                nodeType: "text"
            )
            XCTAssertNil(style.fontWeight)
            XCTAssertNil(style.maxLines)
            XCTAssertNil(style.opacity)
            XCTAssertNil(style.lineHeight)
        }
    }

    func testColorTokenParsing() {
        XCTAssertEqual(
            SpecColorRef.parse(.string("$muted/45")),
            SpecColorRef(token: "muted", alpha: 0.45, isTransparent: false)
        )
        XCTAssertEqual(SpecColorRef.parse(.string("transparent")), .transparent)
        XCTAssertNil(SpecColorRef.parse(.string("red")))
        XCTAssertNil(SpecColorRef.parse(.string("$muted/999")))
        // Canonical alpha grammar is exactly 100|[1-9]?[0-9] (TOKEN_RE in
        // psp.ts): no leading zeros, no sign, no empty/fractional suffix.
        XCTAssertNil(SpecColorRef.parse(.string("$muted/")))
        XCTAssertNil(SpecColorRef.parse(.string("$muted/045")))
        XCTAssertNil(SpecColorRef.parse(.string("$muted/07")))
        XCTAssertNil(SpecColorRef.parse(.string("$muted/+45")))
        XCTAssertNil(SpecColorRef.parse(.string("$muted/4.5")))
        XCTAssertEqual(
            SpecColorRef.parse(.string("$muted/0")),
            SpecColorRef(token: "muted", alpha: 0, isTransparent: false)
        )
        XCTAssertEqual(
            SpecColorRef.parse(.string("$muted/100")),
            SpecColorRef(token: "muted", alpha: 1, isTransparent: false)
        )
    }

    /// `border` requires a `$token` color (ruleBorder in psp.ts) and
    /// `maxLines` strings must be plain integers (ruleMaxLines in psp.ts).
    func testBorderAndMaxLinesGrammarParity() {
        XCTAssertTrue(SpecPSP1.isInProfile("border", .string("1px solid $border"), nodeType: "box"))
        XCTAssertFalse(SpecPSP1.isInProfile("border", .string("1px solid transparent"), nodeType: "box"))
        XCTAssertFalse(SpecPSP1.isInProfile("border", .string("1px solid red"), nodeType: "box"))
        XCTAssertTrue(SpecPSP1.isInProfile("maxLines", .string("2"), nodeType: "text"))
        XCTAssertTrue(SpecPSP1.isInProfile("maxLines", .number(2), nodeType: "text"))
        XCTAssertFalse(SpecPSP1.isInProfile("maxLines", .string("2.0"), nodeType: "text"))
        XCTAssertFalse(SpecPSP1.isInProfile("maxLines", .string("0"), nodeType: "text"))
        XCTAssertFalse(SpecPSP1.isInProfile("maxLines", .number(2.5), nodeType: "text"))
    }

    func testEdgeShorthandParsing() {
        XCTAssertEqual(
            SpecEdges.parse(.string("15px 16px 16px 16px"), cap: 32),
            SpecEdges(top: 15, right: 16, bottom: 16, left: 16)
        )
        XCTAssertEqual(
            SpecEdges.parse(.string("3px 7px"), cap: 32),
            SpecEdges(top: 3, right: 7, bottom: 3, left: 7)
        )
        XCTAssertEqual(
            SpecEdges.parse(.number(40), cap: 32),
            SpecEdges(top: 32, right: 32, bottom: 32, left: 32)
        )
        XCTAssertNil(SpecEdges.parse(.string("calc(1px)"), cap: 32))
    }

    // MARK: - Binding / templating

    func testTextBindingAndTemplating() throws {
        let ad = try Self.decodeAd([
            "title": "Great Shoes",
            "brandName": "Acme",
            "cta": "Shop now",
        ])
        let bound = SpecNode(
            type: "text", bind: "title", showIf: nil, text: nil,
            src: nil, href: nil, style: nil, children: nil
        )
        XCTAssertEqual(SpecBinding.resolveText(bound, ad: ad), "Great Shoes")

        let template = SpecNode(
            type: "text", bind: nil, showIf: nil, text: "{brandName} — {cta}",
            src: nil, href: nil, style: nil, children: nil
        )
        XCTAssertEqual(SpecBinding.resolveText(template, ad: ad), "Acme — Shop now")

        let unknownField = SpecNode(
            type: "text", bind: nil, showIf: nil, text: "{clickUrl}{nope}ok",
            src: nil, href: nil, style: nil, children: nil
        )
        XCTAssertEqual(SpecBinding.resolveText(unknownField, ad: ad), "ok")

        // Non-`{word}` brace runs stay literal (parity with the web
        // SpecRenderer's `\{(\w+)\}` rule).
        let literalBraces = SpecNode(
            type: "text", bind: nil, showIf: nil, text: "Save {50% off} now a{}b {title}",
            src: nil, href: nil, style: nil, children: nil
        )
        XCTAssertEqual(
            SpecBinding.resolveText(literalBraces, ad: ad),
            "Save {50% off} now a{}b Great Shoes"
        )

        // A stray `{` before a real placeholder must not swallow it
        // (`/\{(\w+)\}/g` still matches `{title}` in this input).
        let unbalanced = SpecNode(
            type: "text", bind: nil, showIf: nil, text: "Save {50% off {title}",
            src: nil, href: nil, style: nil, children: nil
        )
        XCTAssertEqual(
            SpecBinding.resolveText(unbalanced, ad: ad),
            "Save {50% off Great Shoes"
        )

        // JS `\w` is ASCII-only: non-ASCII brace runs stay literal.
        let nonAscii = SpecNode(
            type: "text", bind: nil, showIf: nil, text: "{café} {title}",
            src: nil, href: nil, style: nil, children: nil
        )
        XCTAssertEqual(
            SpecBinding.resolveText(nonAscii, ad: ad),
            "{café} Great Shoes"
        )
    }

    /// Disclosure detection (mirrors `specHasDisclosure` in
    /// `sdk-js/packages/ui/src/psp.ts`): a spec WITH a disclosure text node
    /// needs no overlay badge; one WITHOUT gets the built-in "Ad" badge.
    /// Punctuation/case variants count as disclosure.
    func testSpecDisclosureDetection() throws {
        func spec(_ rootJSON: String) throws -> RendererSpec {
            try XCTUnwrap(RendererSpec.parse(Data(
                #"{"version": 1, "root": \#(rootJSON)}"#.utf8
            )))
        }
        let ad = try Self.decodeAd(["adText": "copy", "title": "Great Shoes"])

        // WITH disclosure → no overlay needed.
        let disclosed = try spec(
            #"{"type": "box", "children": [{"type": "text", "text": "AD"}, {"type": "text", "bind": "title"}]}"#
        )
        XCTAssertTrue(disclosed.hasDisclosure(rendering: ad))

        // Punctuation/case variants still count.
        for variant in ["[Sponsored]", "AD.", " promoted ", "Paid!", "ADVERTISEMENT"] {
            let node = #"{"type": "text", "text": "\#(variant)"}"#
            XCTAssertTrue(try spec(node).hasDisclosure(rendering: ad), variant)
        }

        // WITHOUT disclosure → overlay badge required.
        let undisclosed = try spec(
            #"{"type": "box", "children": [{"type": "text", "text": "Great Shoes"}, {"type": "text", "bind": "adText"}]}"#
        )
        XCTAssertFalse(undisclosed.hasDisclosure(rendering: ad))

        // Words merely containing a label don't count.
        for nonDisclosure in ["adding", "prepaid plans", "sponsored content here"] {
            let node = #"{"type": "text", "text": "\#(nonDisclosure)"}"#
            XCTAssertFalse(try spec(node).hasDisclosure(rendering: ad), nonDisclosure)
        }

        // Bound (non-static) text nodes never count as disclosure.
        let boundOnly = try spec(#"{"type": "text", "bind": "adText"}"#)
        XCTAssertFalse(boundOnly.hasDisclosure(rendering: ad))

        // A bind shadows static text at render time, so it never counts.
        let shadowed = try spec(#"{"type": "text", "bind": "adText", "text": "AD"}"#)
        XCTAssertFalse(shadowed.hasDisclosure(rendering: ad))

        // Disclosure matches the rendered (template-expanded) text: "{ad}"
        // normalizes to "ad" pre-expansion but paints an empty string, so it
        // never counts; a template resolving to a label does.
        for placeholder in ["{ad}", "{sponsored}", "{paid}"] {
            let node = #"{"type": "text", "text": "\#(placeholder)"}"#
            XCTAssertFalse(try spec(node).hasDisclosure(rendering: ad), placeholder)
        }
        let resolvedLabel = try spec(#"{"type": "text", "text": "{{}Sponsored{}}"}"#)
        XCTAssertTrue(resolvedLabel.hasDisclosure(rendering: ad))

        // A showIf-gated label never counts — even when the gate field is
        // populated — because the same layout would be unlabeled for ads
        // where the field is empty (PSP1.md / specHasDisclosure).
        let gated = try spec(
            #"{"type": "box", "children": [{"type": "text", "text": "Sponsored", "showIf": "brandName"}]}"#
        )
        XCTAssertFalse(gated.hasDisclosure(rendering: ad))
        let branded = try Self.decodeAd(["adText": "copy", "brandName": "Acme"])
        XCTAssertFalse(gated.hasDisclosure(rendering: branded))
        // Same for a label inside a gated subtree.
        let gatedSubtree = try spec(
            #"{"type": "box", "showIf": "brandName", "children": [{"type": "text", "text": "Sponsored"}]}"#
        )
        XCTAssertFalse(gatedSubtree.hasDisclosure(rendering: branded))

        // An imperceptible label must not suppress the badge: opacity 0
        // (on the node or an ancestor), transparent/zero-alpha color, or a
        // sub-legible font size.
        let invisibleVariants = [
            #"{"type": "text", "text": "AD", "style": {"opacity": 0}}"#,
            #"{"type": "box", "style": {"opacity": 0}, "children": [{"type": "text", "text": "AD"}]}"#,
            #"{"type": "text", "text": "AD", "style": {"color": "transparent"}}"#,
            #"{"type": "text", "text": "AD", "style": {"color": "$muted/0"}}"#,
            #"{"type": "text", "text": "AD", "style": {"fontSize": 1}}"#,
            // Legibility floor: effective opacity < 0.5 through the ancestor
            // chain, or font below 9px, is not a perceivable disclosure.
            #"{"type": "text", "text": "AD", "style": {"opacity": 0.3}}"#,
            #"{"type": "box", "style": {"opacity": 0.7}, "children": [{"type": "text", "text": "AD", "style": {"opacity": 0.7}}]}"#,
            #"{"type": "text", "text": "AD", "style": {"fontSize": 8}}"#,
        ]
        for variant in invisibleVariants {
            XCTAssertFalse(try spec(variant).hasDisclosure(rendering: ad), variant)
        }
        let legible = try spec(
            #"{"type": "text", "text": "AD", "style": {"opacity": 0.6, "color": "$muted/45", "fontSize": 11}}"#
        )
        XCTAssertTrue(legible.hasDisclosure(rendering: ad))
    }

    /// A disclosure label only counts where the renderer would paint it:
    /// a `text` node's own content — never children of text/image nodes
    /// (which are dropped) or a container's unrendered static `text`.
    func testDisclosureOnlyCountsRenderedTextNodes() throws {
        let ad = try Self.decodeAd(["adText": "copy"])
        func spec(_ root: String) throws -> RendererSpec {
            try XCTUnwrap(RendererSpec.parse(Data(#"{"version": 1, "root": \#(root)}"#.utf8)))
        }
        let underText = #"{"type": "text", "text": "body", "children": [{"type": "text", "text": "AD"}]}"#
        XCTAssertFalse(try spec(underText).hasDisclosure(rendering: ad))
        let underImage = #"{"type": "image", "src": "https://a.example/i.png", "children": [{"type": "text", "text": "AD"}]}"#
        XCTAssertFalse(try spec(underImage).hasDisclosure(rendering: ad))
        let onBox = #"{"type": "box", "text": "AD", "children": [{"type": "text", "text": "body"}]}"#
        XCTAssertFalse(try spec(onBox).hasDisclosure(rendering: ad))
        let underBox = #"{"type": "box", "children": [{"type": "text", "text": "AD"}]}"#
        XCTAssertTrue(try spec(underBox).hasDisclosure(rendering: ad))
    }

    /// An ancestor's cascaded transparent/zero-alpha color makes a descendant
    /// disclosure label imperceptible, so it must not suppress the badge.
    func testInheritedTransparentColorDisclosureDoesNotCount() throws {
        let ad = try Self.decodeAd(["adText": "copy"])
        func spec(_ rootColor: String) throws -> RendererSpec {
            let json = """
            {"version": 1, "root": {"type": "box", "style": {"color": "\(rootColor)"},
             "children": [{"type": "box", "children": [{"type": "text", "text": "AD"}]}]}}
            """
            return try XCTUnwrap(RendererSpec.parse(Data(json.utf8)))
        }
        XCTAssertFalse(try spec("transparent").hasDisclosure(rendering: ad))
        XCTAssertFalse(try spec("$muted/0").hasDisclosure(rendering: ad))
        XCTAssertTrue(try spec("$muted-foreground").hasDisclosure(rendering: ad))

        // A label's own visible color overrides a transparent ancestor.
        let ownColor = """
        {"version": 1, "root": {"type": "box", "style": {"color": "transparent"},
         "children": [{"type": "text", "text": "AD", "style": {"color": "$foreground"}}]}}
        """
        XCTAssertTrue(try XCTUnwrap(RendererSpec.parse(Data(ownColor.utf8))).hasDisclosure(rendering: ad))
    }

    /// A label painted in the same color token as its effective (cascaded)
    /// background is invisible, so it must not suppress the badge
    /// (`disclosureLegible` in psp.ts / "legible" rule in PSP1.md).
    func testDisclosureColorMatchingBackgroundDoesNotCount() throws {
        let ad = try Self.decodeAd(["adText": "copy"])
        func spec(_ root: String) throws -> RendererSpec {
            try XCTUnwrap(RendererSpec.parse(Data(#"{"version": 1, "root": \#(root)}"#.utf8)))
        }
        // Label color == ancestor background token → invisible.
        let camouflaged = #"{"type": "box", "style": {"background": "$card"}, "children": [{"type": "text", "text": "AD", "style": {"color": "$card"}}]}"#
        XCTAssertFalse(try spec(camouflaged).hasDisclosure(rendering: ad))
        // Alpha variants share the token base, so they still match.
        let alphaMatch = #"{"type": "box", "style": {"background": "$card"}, "children": [{"type": "text", "text": "AD", "style": {"color": "$card/80"}}]}"#
        XCTAssertFalse(try spec(alphaMatch).hasDisclosure(rendering: ad))
        // A node's own background overrides the ancestor's for the comparison.
        let ownBackground = #"{"type": "box", "style": {"background": "$card"}, "children": [{"type": "text", "text": "AD", "style": {"color": "$card", "background": "$primary"}}]}"#
        XCTAssertTrue(try spec(ownBackground).hasDisclosure(rendering: ad))
        // A contrasting color token on the same background stays a disclosure.
        let contrasting = #"{"type": "box", "style": {"background": "$card"}, "children": [{"type": "text", "text": "AD", "style": {"color": "$muted-foreground"}}]}"#
        XCTAssertTrue(try spec(contrasting).hasDisclosure(rendering: ad))
    }

    /// Shorthand `padding`/`margin` apply before per-side overrides regardless
    /// of dictionary iteration order (CSS-deterministic resolution).
    func testShorthandThenLonghandSpacingIsDeterministic() throws {
        let json = #"{"padding": "8px", "paddingTop": "0px", "margin": "4px", "marginLeft": "12px"}"#
        let raw = try JSONDecoder().decode([String: SpecStyleValue].self, from: Data(json.utf8))
        for _ in 0..<20 {
            let style = SpecStyle(raw, nodeType: "box")
            XCTAssertEqual(style.padding, SpecEdges(top: 0, right: 8, bottom: 8, left: 8))
            XCTAssertEqual(style.margin, SpecEdges(top: 4, right: 4, bottom: 4, left: 12))
        }
    }

    /// `bind` takes strict precedence over a literal `src` (web parity): a
    /// bound image whose field is empty shows nothing, never the hardcoded
    /// fallback picture.
    func testBoundImageDoesNotFallBackToLiteralSrc() throws {
        let json = #"{"type": "image", "bind": "favicon", "src": "https://cdn.example/fallback.png"}"#
        let node = try JSONDecoder().decode(SpecNode.self, from: Data(json.utf8))
        let noFavicon = try Self.decodeAd(["adText": "copy"])
        XCTAssertNil(SpecBinding.imageURL(node, ad: noFavicon))
        let withFavicon = try Self.decodeAd(["adText": "copy", "favicon": "https://cdn.example/brand.png"])
        XCTAssertEqual(SpecBinding.imageURL(node, ad: withFavicon)?.absoluteString,
                       "https://cdn.example/brand.png")
        // Literal sources must live on Gravity-controlled hosts; foreign
        // hosts and non-https literals resolve to nothing.
        let literal = try JSONDecoder().decode(
            SpecNode.self,
            from: Data(#"{"type": "image", "src": "https://cdn.trygravity.ai/fallback.png"}"#.utf8)
        )
        XCTAssertEqual(SpecBinding.imageURL(literal, ad: noFavicon)?.absoluteString,
                       "https://cdn.trygravity.ai/fallback.png")
        let foreign = try JSONDecoder().decode(
            SpecNode.self,
            from: Data(#"{"type": "image", "src": "https://cdn.example/fallback.png"}"#.utf8)
        )
        XCTAssertNil(SpecBinding.imageURL(foreign, ad: noFavicon))
        let insecure = try JSONDecoder().decode(
            SpecNode.self,
            from: Data(#"{"type": "image", "src": "http://cdn.trygravity.ai/fallback.png"}"#.utf8)
        )
        XCTAssertNil(SpecBinding.imageURL(insecure, ad: noFavicon))
    }

    /// The disclosure verdict is memoized with the renderable spec so the
    /// SwiftUI render path never re-walks the tree per frame.
    func testDisclosureVerdictMemoized() throws {
        let json = """
        {"adText": "x", "impUrl": "https://t.example/i?k=disc-\(UUID().uuidString)",
         "renderer_spec": {"version": 1, "root": {"type": "box", "children": [
            {"type": "text", "text": "AD"}, {"type": "text", "bind": "adText"}]}}}
        """
        let ad = try JSONDecoder().decode(AdResponse.self, from: Data(json.utf8))
        XCTAssertNotNil(RendererSpec.renderableSpec(for: ad))
        XCTAssertTrue(RendererSpec.rendersDisclosure(for: ad))
        XCTAssertTrue(RendererSpec.rendersDisclosure(for: ad))
    }

    /// A structurally valid spec whose every leaf resolves to nothing for the
    /// served ad (empty binds, gated subtrees) must not render — the slot
    /// would be blank while still counting an impression — so the memoized
    /// entry point falls back to the built-in view.
    func testSpecResolvingToNoVisibleContentFallsBack() throws {
        let json = """
        {"adText": "copy here", "impUrl": "https://t.example/i?k=blank-\(UUID().uuidString)",
         "renderer_spec": {"version": 1, "root": {"type": "box", "children": [
            {"type": "text", "bind": "cta", "showIf": "cta"},
            {"type": "image", "bind": "favicon", "showIf": "favicon"}]}}}
        """
        let ad = try JSONDecoder().decode(AdResponse.self, from: Data(json.utf8))
        XCTAssertNil(RendererSpec.renderableSpec(for: ad))

        let visibleJson = """
        {"adText": "copy here", "impUrl": "https://t.example/i?k=vis-\(UUID().uuidString)",
         "renderer_spec": {"version": 1, "root": {"type": "box", "children": [
            {"type": "text", "bind": "adText"}]}}}
        """
        let visibleAd = try JSONDecoder().decode(AdResponse.self, from: Data(visibleJson.utf8))
        XCTAssertNotNil(RendererSpec.renderableSpec(for: visibleAd))
    }

    /// Static chrome — disclosure labels, punctuation separators — must not
    /// keep an otherwise-empty spec alive (`specProducesContent` in psp.ts):
    /// an ad whose every bound field is empty would otherwise ship as a
    /// bare "Sponsored" unit while the impression pixel fires.
    func testChromeOnlySpecFallsBack() throws {
        let json = """
        {"impUrl": "https://t.example/i?k=chrome-\(UUID().uuidString)",
         "renderer_spec": {"version": 1, "root": {"type": "box", "children": [
            {"type": "text", "text": "Sponsored"},
            {"type": "text", "text": "\u{B7}"},
            {"type": "text", "bind": "adText"}]}}}
        """
        let ad = try JSONDecoder().decode(AdResponse.self, from: Data(json.utf8))
        XCTAssertNil(RendererSpec.renderableSpec(for: ad))

        // A resolved {field} template is ad content, not chrome.
        let templateJson = """
        {"brandName": "Acme", "impUrl": "https://t.example/i?k=tmpl-\(UUID().uuidString)",
         "renderer_spec": {"version": 1, "root": {"type": "box", "children": [
            {"type": "text", "text": "By {brandName}"}]}}}
        """
        let templated = try JSONDecoder().decode(AdResponse.self, from: Data(templateJson.utf8))
        XCTAssertNotNil(RendererSpec.renderableSpec(for: templated))
    }

    /// Scheme-less (relative) literal URLs fail the structural contract
    /// (`urlViolation` in psp.ts): they would resolve against the
    /// publisher's page, pointing an ad at an arbitrary host-origin path.
    func testRelativeURLsFailStructuralValidation() throws {
        let spec = try XCTUnwrap(RendererSpec.parse(Data("""
        {"version": 1, "root": {"type": "link", "href": "/promo",
            "children": [{"type": "text", "bind": "cta"}]}}
        """.utf8)))
        XCTAssertFalse(spec.isStructurallyValid)
    }

    /// Non-image dimensions are uncapped (`ruleDimension` in psp.ts caps
    /// only image nodes) — a wide card stays PSP-1 conformant.
    func testWideNonImageDimensionsStayConformant() throws {
        let spec = try XCTUnwrap(RendererSpec.parse(Data("""
        {"version": 1, "root": {"type": "box",
            "style": {"width": "800px", "maxWidth": "720px", "minWidth": "680px"},
            "children": [{"type": "text", "bind": "adText"}]}}
        """.utf8)))
        XCTAssertTrue(spec.isPSP1Conformant)
    }

    /// An in-profile but imperceptible spec — everything faded out with
    /// `opacity: 0` or painted `transparent` — must fall back: the slot would
    /// look blank while the impression pixel still fires.
    func testImperceptibleSpecFallsBack() throws {
        for style in [#""opacity": 0"#, #""color": "transparent""#, #""color": "$muted/0""#] {
            let json = """
            {"adText": "copy here", "impUrl": "https://t.example/i?k=ghost-\(UUID().uuidString)",
             "renderer_spec": {"version": 1, "root": {"type": "box", "style": {\(style)},
                "children": [{"type": "text", "bind": "adText"}]}}}
            """
            let ad = try JSONDecoder().decode(AdResponse.self, from: Data(json.utf8))
            XCTAssertNil(RendererSpec.renderableSpec(for: ad), style)
        }
        // A node's own opacity: 0 hides only that subtree — a sibling keeps
        // the spec renderable.
        let json = """
        {"adText": "copy here", "impUrl": "https://t.example/i?k=ghost-\(UUID().uuidString)",
         "renderer_spec": {"version": 1, "root": {"type": "box", "children": [
            {"type": "text", "bind": "adText", "style": {"opacity": 0}},
            {"type": "text", "bind": "adText"}]}}}
        """
        let ad = try JSONDecoder().decode(AdResponse.self, from: Data(json.utf8))
        XCTAssertNotNil(RendererSpec.renderableSpec(for: ad))
    }

    /// Negative sizes are outside the PSP-1 grammar — a spec carrying them
    /// must fall back rather than render overlapping/unreadable content.
    func testNegativeSizesAreRejected() {
        XCTAssertFalse(SpecPSP1.isInProfile("gap", .number(-40), nodeType: "box"))
        XCTAssertFalse(SpecPSP1.isInProfile("fontSize", .number(-12), nodeType: "text"))
        XCTAssertFalse(SpecPSP1.isInProfile("padding", .number(-20), nodeType: "box"))
        XCTAssertFalse(SpecPSP1.isInProfile("padding", .string("-8px 4px"), nodeType: "box"))
        XCTAssertFalse(SpecPSP1.isInProfile("width", .number(-64), nodeType: "image"))
        XCTAssertTrue(SpecPSP1.isInProfile("gap", .number(8), nodeType: "box"))
        // letterSpacing keeps its own grammar and may be negative.
        XCTAssertTrue(SpecPSP1.isInProfile("letterSpacing", .string("-0.01em"), nodeType: "text"))
    }

    /// psp.ts accepts string-encoded numbers for lineHeight/opacity/maxLines
    /// (ruleLineHeight/ruleOpacity/ruleMaxLines) — the native gate and style
    /// parser must too, or pipeline-authored specs silently fall back on iOS.
    func testStringEncodedUnitlessNumbersAccepted() {
        XCTAssertTrue(SpecPSP1.isInProfile("lineHeight", .string("1.35"), nodeType: "text"))
        XCTAssertTrue(SpecPSP1.isInProfile("opacity", .string("0.8"), nodeType: "box"))
        XCTAssertTrue(SpecPSP1.isInProfile("maxLines", .string("2"), nodeType: "text"))
        XCTAssertFalse(SpecPSP1.isInProfile("lineHeight", .string("1.5.2"), nodeType: "text"))
        XCTAssertFalse(SpecPSP1.isInProfile("lineHeight", .string("3"), nodeType: "text"))
        XCTAssertFalse(SpecPSP1.isInProfile("maxLines", .string("2.5"), nodeType: "text"))
        XCTAssertFalse(SpecPSP1.isInProfile("opacity", .string(""), nodeType: "box"))

        let style = SpecStyle(
            [
                "lineHeight": .string("1.35"),
                "opacity": .string("0.8"),
                "maxLines": .string("2"),
            ],
            nodeType: "text"
        )
        XCTAssertEqual(style.lineHeight, 1.35)
        XCTAssertEqual(style.opacity, 0.8)
        XCTAssertEqual(style.maxLines, 2)
    }

    /// The px grammar is the canonical PX_RE/PX_LIST_RE from psp.ts:
    /// `\d+(\.\d+)?px`, single spaces between shorthand values. Forms the
    /// source-of-truth validator rejects must not render natively.
    func testPxStringGrammarMatchesCanonicalValidator() {
        XCTAssertTrue(SpecPSP1.isInProfile("gap", .string("8px"), nodeType: "box"))
        XCTAssertTrue(SpecPSP1.isInProfile("gap", .string("8.5px"), nodeType: "box"))
        XCTAssertTrue(SpecPSP1.isInProfile("padding", .string("4px 8px"), nodeType: "box"))
        XCTAssertFalse(SpecPSP1.isInProfile("gap", .string(".5px"), nodeType: "box"))
        XCTAssertFalse(SpecPSP1.isInProfile("gap", .string("5.px"), nodeType: "box"))
        XCTAssertFalse(SpecPSP1.isInProfile("gap", .string("1.2.3px"), nodeType: "box"))
        XCTAssertFalse(SpecPSP1.isInProfile("padding", .string("4px  8px"), nodeType: "box"))
        XCTAssertFalse(SpecPSP1.isInProfile("padding", .string(" 4px"), nodeType: "box"))
    }

    /// The canonical psp1-card fixture already carries an "AD" chip, so it
    /// renders without the overlay badge.
    func testPsp1CardFixtureHasDisclosure() throws {
        let url = try XCTUnwrap(
            Self.fixtureURLs().first { $0.lastPathComponent == "psp1-card.json" }
        )
        let data = try Data(contentsOf: url)
        let spec = try XCTUnwrap(RendererSpec.parse(Self.specData(from: data)))
        let ad = try Self.decodeAd(["adText": "copy"])
        XCTAssertTrue(spec.hasDisclosure(rendering: ad))
    }

    /// The memoized per-ad entry point returns a spec only when it is
    /// natively renderable, and returns the same verdict on repeat calls
    /// (cache hit path).
    func testRenderableSpecMemoizedPerAd() throws {
        let json = """
        {"adText": "x", "impUrl": "https://t.example/i?k=memo-\(UUID().uuidString)",
         "renderer_spec": {"version": 1, "root": {"type": "text", "text": "hi"}}}
        """
        let ad = try JSONDecoder().decode(AdResponse.self, from: Data(json.utf8))
        XCTAssertNotNil(RendererSpec.renderableSpec(for: ad))
        XCTAssertNotNil(RendererSpec.renderableSpec(for: ad))

        let badJson = """
        {"adText": "x", "impUrl": "https://t.example/i?k=memo-\(UUID().uuidString)",
         "renderer_spec": {"version": 99, "root": {"type": "script"}}}
        """
        let badAd = try JSONDecoder().decode(AdResponse.self, from: Data(badJson.utf8))
        XCTAssertNil(RendererSpec.renderableSpec(for: badAd))
        XCTAssertNil(RendererSpec.renderableSpec(for: badAd))
    }

    /// The engine stamps every test ad with the same placeholder tracking
    /// URL (`https://trygravity.ai`), so two distinct ads can share it. The
    /// memoized verdict must not leak between them: an ad whose fields
    /// resolve to content renders, while a sibling with the same impUrl but
    /// empty fields still falls back (and vice versa on repeat lookups).
    func testMemoizedVerdictNotSharedAcrossAdsWithSameTrackingUrl() throws {
        let spec = """
        "renderer_spec": {"version": 1, "root": {"type": "box", "children": [
            {"type": "text", "bind": "adText", "showIf": "adText"}]}}
        """
        let visibleJson = """
        {"adText": "real copy", "impUrl": "https://trygravity.ai", \(spec)}
        """
        let blankJson = """
        {"impUrl": "https://trygravity.ai", \(spec)}
        """
        let visibleAd = try JSONDecoder().decode(AdResponse.self, from: Data(visibleJson.utf8))
        let blankAd = try JSONDecoder().decode(AdResponse.self, from: Data(blankJson.utf8))
        XCTAssertNotNil(RendererSpec.renderableSpec(for: visibleAd))
        XCTAssertNil(RendererSpec.renderableSpec(for: blankAd))
        XCTAssertNotNil(RendererSpec.renderableSpec(for: visibleAd))

        // Same tracking URL AND identical copy, but different spec arms
        // (multi-placement responses): the layout — and its disclosure
        // verdict — must not leak from one ad to the other.
        let withDisclosureJson = """
        {"adText": "same copy", "impUrl": "https://trygravity.ai",
         "renderer_spec": {"version": 1, "root": {"type": "box", "children": [
            {"type": "text", "text": "AD"}, {"type": "text", "bind": "adText"}]}}}
        """
        let withoutDisclosureJson = """
        {"adText": "same copy", "impUrl": "https://trygravity.ai",
         "renderer_spec": {"version": 1, "root": {"type": "box", "children": [
            {"type": "text", "bind": "adText"}]}}}
        """
        let labeled = try JSONDecoder().decode(AdResponse.self, from: Data(withDisclosureJson.utf8))
        let unlabeled = try JSONDecoder().decode(AdResponse.self, from: Data(withoutDisclosureJson.utf8))
        XCTAssertTrue(RendererSpec.rendersDisclosure(for: labeled))
        XCTAssertFalse(RendererSpec.rendersDisclosure(for: unlabeled))
        XCTAssertEqual(RendererSpec.renderableSpec(for: labeled)?.root.children?.count, 2)
        XCTAssertEqual(RendererSpec.renderableSpec(for: unlabeled)?.root.children?.count, 1)
    }

    /// Click routing: `bind:"url"` links must route through the tracked
    /// clickUrl (explicitHref == nil), never open the raw landing URL.
    /// Only a literal `https` href on a Gravity-controlled host opens
    /// directly; every other literal destination also routes through the
    /// tracked clickUrl.
    func testBoundLinksRouteThroughTrackedClickUrl() {
        let bound = SpecNode(
            type: "link", bind: "url", showIf: nil, text: nil,
            src: nil, href: nil, style: nil, children: nil
        )
        XCTAssertNil(SpecBinding.explicitHref(bound), "bind:\"url\" must use tracked clickUrl")

        let boundWithHref = SpecNode(
            type: "link", bind: "url", showIf: nil, text: nil,
            src: nil, href: "https://landing.example.com", style: nil, children: nil
        )
        XCTAssertNil(SpecBinding.explicitHref(boundWithHref), "bind wins: still tracked")

        let gravityHosted = SpecNode(
            type: "link", bind: nil, showIf: nil, text: nil,
            src: nil, href: "https://docs.trygravity.ai/help", style: nil, children: nil
        )
        XCTAssertEqual(
            SpecBinding.explicitHref(gravityHosted)?.absoluteString,
            "https://docs.trygravity.ai/help"
        )

        // A literal href on a third-party host must not open directly —
        // the tap routes through the tracked clickUrl instead.
        let foreign = SpecNode(
            type: "link", bind: nil, showIf: nil, text: nil,
            src: nil, href: "https://docs.example.com/help", style: nil, children: nil
        )
        XCTAssertNil(SpecBinding.explicitHref(foreign), "foreign host: tracked clickUrl")

        let insecure = SpecNode(
            type: "link", bind: nil, showIf: nil, text: nil,
            src: nil, href: "http://trygravity.ai/help", style: nil, children: nil
        )
        XCTAssertNil(SpecBinding.explicitHref(insecure), "https only")

        let lookalike = SpecNode(
            type: "link", bind: nil, showIf: nil, text: nil,
            src: nil, href: "https://eviltrygravity.ai/x", style: nil, children: nil
        )
        XCTAssertNil(SpecBinding.explicitHref(lookalike), "suffix must be a subdomain")

        let unsafe = SpecNode(
            type: "link", bind: nil, showIf: nil, text: nil,
            src: nil, href: "javascript:alert(1)", style: nil, children: nil
        )
        XCTAssertNil(SpecBinding.explicitHref(unsafe))
    }

    /// An ad whose renderer_spec is adversarial parses end-to-end from the
    /// wire format and lands on the fallback path (nil / not renderable)
    /// without throwing.
    func testAdResponseWithAdversarialSpecFallsBack() throws {
        for url in try Self.fixtureURLs() where url.lastPathComponent.hasPrefix("adversarial") {
            let data = try Data(contentsOf: url)
            let fixture = try JSONDecoder().decode(Fixture.self, from: data)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let ad = try Self.decodeAd([
                "title": "T", "adText": "A", "brandName": "B", "cta": "C",
                "clickUrl": "https://server.trygravity.ai/c?x=1",
                "renderer_spec": try XCTUnwrap(obj?["spec"]),
            ])
            let spec = RendererSpec.parse(ad.rendererSpec)
            let renderable = spec?.isStructurallyValid ?? false
            XCTAssertEqual(renderable, fixture.expect.structureValid, fixture.name)
        }
    }

    static func decodeAd(_ dict: [String: Any]) throws -> AdResponse {
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(AdResponse.self, from: data)
    }
}
