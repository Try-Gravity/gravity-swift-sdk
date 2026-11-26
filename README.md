# gravity-ios

Swift SDK for requesting ads from the [Gravity](https://trygravity.ai) API. Transport supports iOS 15+, macOS 12+, tvOS 15+, and watchOS 8+. Frame/PSP-1 SwiftUI/UIKit rendering is available on iOS 15+ only; tvOS retains its basic native card.

The canonical source is this monorepo package. `VERSION` is the SDK version; the public Swift repository is the release mirror.

```swift
import GravitySDK

let gravity = Gravity(apiKey: "pub_...", production: true)

let result = await gravity.getAds(
    messages: messages,
    sessionId: "sess_123",
    userId: "user_456",
    placements: [.belowResponse()]
)
```

Zero third-party dependencies — uses Foundation, CryptoKit, and URLSession.

## Install

Add via Swift Package Manager in Xcode (**File → Add Package Dependencies**):

```
https://github.com/Try-Gravity/gravity-swift-sdk
```

Select the `GravitySDK` library product.

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Try-Gravity/gravity-swift-sdk", from: "1.0.0"),
]
```

Set `GRAVITY_API_KEY` in your environment or pass `apiKey:` directly.

## Integration

```swift
import GravitySDK

class ChatViewModel: ObservableObject {
    let gravity = Gravity(apiKey: "pub_...", production: true)
    @Published var ads: [AdResponse] = []

    func send(messages: [Message], sessionId: String, userId: String) async {
        // Fire ad request in parallel with your LLM call
        async let adResult = gravity.getAds(
            messages: messages,
            sessionId: sessionId,
            userId: userId,
            placements: [.belowResponse()]
        )

        // Stream your LLM response...

        let result = await adResult
        await MainActor.run { ads = result.ads }
    }
}
```

### SwiftUI

```swift
if let ad = ads.first {
    GravityAdView(ad: ad, gravity: gravity, sessionId: sessionId)
}
```

`GravityAdView` handles impression tracking, click handling, and feedback UI.

### App deeplinks

An ad whose buyer supplied an app deeplink arrives with `hasDeeplink: true`. `GravityAdView`, `GravityFrameView`, and `gravity.handleClick(ad)` then record the click with a short `GET` to `clickUrl` plus `resolve=1` instead of opening it in the browser. The server answers with the deeplink and an https fallback: the SDK opens the advertiser's app when one handles the link and otherwise opens the fallback website. If the server deliberately blocks the click, nothing opens; any other failure opens `clickUrl` as for every other ad. Ads without `hasDeeplink` behave as before.

The SDK opens the deeplink with `UIApplication.open(_:options:completionHandler:)` and never checks `canOpenURL` first, because `canOpenURL` returns `false` for any scheme the host app has not listed under `LSApplicationQueriesSchemes`, which would skip apps that are installed. You don't need to add advertiser schemes to your Info.plist.

### Advertising identifier (IDFA)

On iOS, ad requests carry the App Tracking Transparency status as `device.atts`. When the user has already authorized tracking, they also carry the IDFA as `device.ifa` with `device.lmt = 0`; otherwise `device.lmt = 1` and no IDFA is sent. The SDK never shows the ATT prompt and never calls `requestTrackingAuthorization`, so it reads the IDFA only if your app has obtained authorization itself. Your app owns `NSUserTrackingUsageDescription` and its App Store privacy declarations. Mac Catalyst, macOS, tvOS, and watchOS send none of these fields.

### Frames, native specs, and prompt insertion (iOS)

`GravityAdView` selects the server's iframe render envelope first, then a legacy iframe composition. A load or four-second handshake failure uses the native PSP-1 spec or card. `enableFrames: false` opts out in the view; use `Gravity(enableFrames: false)` to omit the request capability too. Only iOS advertises `psp1` and `supportsFrames`; other platforms remain transport clients.

Frames run inside an `allow-scripts`-only sandbox in a nonpersistent `WKWebView`. The host owns tracked navigation, including each carousel card's URL. It never sends the impression token, prompt, draft, or action ID to the creative. Impressions require at least 50% visibility while the app is active and reuse the existing process-wide URL dedupe. Auxiliary events use the token-bound frame event endpoint, never an extra click or impression beacon.

Engine-style document redirects are limited to immutable HTTPS documents on `code.trygravity.ai` or `code.trygravity.com`, under `/designer-units/{prod|test}/{64-lowercase-hex}.html`. The host validates observable redirect targets and the final response, pins the first observed immutable content path, and rejects a final hash or environment that differs. WebKit can hide intermediate same-origin server redirects, so the SDK does not promise a per-hop audit or its own hop count limit; the four-second handshake budget and WebKit's redirect limit still apply. After the document response is accepted, creative self-navigation and nested document loads remain blocked. Telemetry keeps the original engine origin, creative slug, and impression token; it never moves to the CDN origin.

Redirects must preserve the exact host-pinned query, including theme/layout and any existing parameters. Added, removed, reordered, or changed query values are rejected. For direct CDN frame URLs, the selected render/composition may provide `frameEventSource`; it must use `https://server.trygravity.ai` or `https://test-api.trygravity.ai` and `/api/v1/ad/frame/<slug>`. That source selects the original collector and slug while the impression token still comes from `impUrl`. An explicitly empty, malformed, or non-string source disables telemetry without disabling rendering. If the field is absent, the legacy frame-URL identity is retained.

```swift
let result = await gravity.getAds(
    messages: messages, sessionId: sessionId,
    placements: [.belowResponse(
        maxAdTextChars: 180, units: ["action", "text"],
        supportsPromptAction: true
    )],
    supportsPromptAction: true
)

// In a MainActor SwiftUI view with publisher-owned @State var draft = "":
if let ad = result.ads.first {
    GravityAdView(
        ad: ad, gravity: gravity, sessionId: sessionId,
        frameLayout: .auto,
        frameSizeBudget: FrameSizeBudget(maxViewportRatio: 0.30, minHeight: 160),
        onPrompt: { action in
            guard draft.isEmpty else { return .declined }
            draft = action.prompt
            return draft == action.prompt ? .inserted : .failed
        }
    )
}
```

Declare both placement `units: ["action", ...]` and `supportsPromptAction: true` only for slots with a working callback. The request-level Swift flag confirms the publisher has wired that callback; it is not an engine capability field. The callback may await publisher consent, must return after insertion, and must never submit automatically. Only validated parent `type: "prompt"` actions execute; unknown or malformed actions retain ordinary link behavior. `action.fields` preserves extra parent fields without interpreting them. Frame-supplied action content is ignored, and iframe prompt triggers require live user activation. WebKit versions without parent activation support fail closed for prompt insertion. Ordinary and carousel frame clicks require live user activation, or, when the activation API is unavailable, a native tap on the frame within the preceding second. Explicit inactive activation is always rejected. The native tap recognizer does not cancel WebKit touches and recognizes simultaneously with WebKit gestures. Concurrent insertions are suppressed; replacement/disposal suppresses stale SDK outcomes, but publishers must cancel their own asynchronous draft work.

`openUrl` defaults to true and attempts the existing tracked website URL once before awaiting insertion. Explicit false skips navigation for insertion or refusal. An iframe handler failure may attempt the tracked website fallback even with explicit false; native cards do not. No handler keeps ordinary tracked link behavior. Only insertion status and the accepted navigation-attempt flag return to the frame. The SDK adds no visible status or changing CTA labels.

Sizing honors validated responsive `frameSize` and optional compact declarations. Auto chooses compact only when full exceeds the viewport budget and compact fits; it never crops full content. `frameLayout: .full` or `.compact` overrides auto. Space is reserved before loading; host init/resize updates do not reload the creative. Heightless ready from a hidden slot keeps that reservation until a numeric correction. Overlay creatives use a trailing, maximum-420-point surface; put the ad in the publisher's bottom-trailing SwiftUI overlay or UIKit overlay container to anchor it to the viewport.

UIKit uses the same host and fallback:

```swift
let frame = GravityFrameView()
frame.onHeightChange = { height in heightConstraint.constant = height }
frame.configure(ad: ad, gravity: gravity, sessionId: sessionId, onPrompt: insertPrompt)
// Add frame to your view hierarchy with a constrained width and height.
// Before removal or reuse:
frame.dispose()
```

Changing `frameLayout` or `frameSizeBudget` through `configure` keeps the existing document and posts host resize. A different ad, document theme, or session starts a new lifecycle. Detaching a previously attached UIKit view disposes its WebView, timers, telemetry, and listeners automatically. Reattaching resumes from its latest configuration without relying on SwiftUI to call `updateUIView`. Explicit `dispose` is idempotent and disables that automatic resume until the next `configure`. Isolated loopback fixtures may opt in to `allowLocalTestFrames: true`; it allows HTTP only on `localhost` or `127.0.0.1`, not other hosts.

Replacement and disposal cancel the pending insertion task before allowing another action. Publisher callbacks must cooperate with Swift task cancellation: use cancellable awaits or check `Task.checkCancellation()` after asynchronous consent and before changing the composer. The SDK cannot undo a draft mutation performed by a callback that ignores cancellation.

Structured user tags use `tags: ["interests": ["travel", "music"]]`; existing `extraUserFields: [String: String]` remains compatible. Root `units` chooses normal units independently of placement action gating. Test requests accept `alwaysReturn`, `adLayout` (`image_left`, `image_right`, `image_top`), and `testAdFormat: "action"`; production requests omit all three. Existing CMP, ATT, identity hashing, two-turn context, timeout, model usage, feedback, and impression dedupe behavior remains in place.

### Viewability beacon (shadow)

Billing is unchanged: the impression pixel (`impUrl`) fires exactly as described above. Alongside it the SDK sends a separate, measurement-only viewability beacon to `impUrl` with `ev`, `sdk=ios` and `sv` added: `ev=measured` when the pixel fires and the SDK can measure the ad's visibility, and `ev=viewable` once at least 50% of the ad has been in view for 1 continuous second while the app is active (MRC viewable). Each is sent once per `impUrl`, and neither is sent when visibility can't be measured.

### Custom rendering

```swift
// Fire impression once when the ad becomes visible
gravity.trackImpression(ad)

// Open clicks through the SDK so deeplink ads open the advertiser's app
gravity.handleClick(ad)
```

If you open `ad.clickUrl` yourself instead, the click is still recorded and lands on the website, but `hasDeeplink` ads won't open the advertiser's app.

### PII hashing

```swift
let hashed = hashPII(email: user.email, phone: user.phone)
let result = await gravity.getAds(..., hashedIdentity: hashed)
```

SHA-256 with normalization matching the Gravity pixel — email: `strip().lowercased()`, phone: digits only.

## Constructor

```swift
Gravity(
    apiKey: String? = nil,
    timeoutSeconds: TimeInterval = 4.0,
    production: Bool = false,
    relevancy: Double = 0.2,
    excludedTopics: [String]? = nil,
    readCMPConsent: Bool = true
)
```

`getAds()` never throws. Failures before an HTTP response return status `0`; HTTP responses preserve their status code.

### Privacy / consent

If your app uses an IAB-registered CMP (OneTrust, Sourcepoint, Usercentrics, …),
the SDK automatically forwards the user's recorded decision — the standard
`IABTCF_TCString`, `IABTCF_gdprApplies`, `IABUSPrivacy_String`,
`IABGPP_HDR_GppString`, and `IABGPP_GppSID` UserDefaults keys — with each ad request so Gravity's serving can take it into account as
consent enforcement rolls out server-side. No CMP keys present → no
consent data is sent. To disable the automatic read, initialize with
`readCMPConsent: false`; you can still pass an explicit `consent:` signal to
`getAds()`, for example
`ConsentSignal(gpc: true, gpp: gppString, gppSid: [7])`. An explicit signal
replaces the CMP values.

## Development

```bash
cd sdk-ios
swift build
swift test
```

The native CI job also builds and tests on an iOS simulator, retaining WebKit/card fixture render attachments in `sdk-ios-native-tests`. Linux/macOS policy tests alone do not verify native rendering, real user activation, or a publisher's composer.

## Docs

Full documentation: [docs.trygravity.ai/sdks/ios](https://docs.trygravity.ai/sdks/ios)

## License

MIT
