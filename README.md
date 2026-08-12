# gravity-ios

Swift SDK for requesting ads from the [Gravity](https://trygravity.ai) API. iOS 15+, macOS 12+.

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
https://github.com/Try-Gravity/gravity
```

Select the `GravitySDK` library product.

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Try-Gravity/gravity", from: "1.0.0"),
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

### Custom rendering

```swift
// Fire impression once when the ad becomes visible
gravity.trackImpression(ad)

// Always use clickUrl for links
if let clickUrl = ad.clickUrl, let url = URL(string: clickUrl) {
    UIApplication.shared.open(url)
}
```

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
    timeoutSeconds: TimeInterval = 3.0,
    production: Bool = false,
    relevancy: Double = 0.2,
    excludedTopics: [String]? = nil,
    readCMPConsent: Bool = true
)
```

`getAds()` never throws — returns `AdResult.empty` on any failure.

### Privacy / consent

If your app uses an IAB-registered CMP (OneTrust, Sourcepoint, Usercentrics, …),
the SDK automatically forwards the user's recorded decision — the standard
`IABTCF_TCString`, `IABTCF_gdprApplies`, and `IABUSPrivacy_String` UserDefaults
keys — with each ad request so Gravity's serving can take it into account as
consent enforcement rolls out server-side. No CMP keys present → no
consent data is sent. To disable the automatic read, initialize with
`readCMPConsent: false`; you can still pass an explicit `consent:` signal to
`getAds()`.

## Development

```bash
cd sdk-ios
swift build
swift test
```

## Docs

Full documentation: [docs.trygravity.ai/sdks/ios](https://docs.trygravity.ai/sdks/ios)

## License

MIT
