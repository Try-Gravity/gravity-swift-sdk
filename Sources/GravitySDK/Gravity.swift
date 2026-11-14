import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Gravity SDK for fetching contextual ads from the Gravity engine.
///
/// ```swift
/// let gravity = Gravity(apiKey: "pub_...", production: true)
///
/// let result = await gravity.getAds(
///     messages: messages,
///     sessionId: "sess_123",
///     userId: "user_456",
///     placements: [.belowResponse()]
/// )
///
/// if let ad = result.ads.first {
///     // Render the ad in your UI
/// }
/// ```
///
/// `getAds` never throws. A failure before receiving an HTTP response has
/// status `0`; HTTP responses preserve their status code and include an
/// error when appropriate.
public final class Gravity: Sendable {
    public let apiKey: String
    public let apiUrl: String
    public let feedbackUrl: String
    public let timeoutSeconds: TimeInterval
    public let production: Bool
    public let relevancy: Double
    public let excludedTopics: [String]?
    public let readCMPConsent: Bool
    public let honorATT: Bool
    public let enableFrames: Bool

    private let session: URLSession

    /// - Parameters:
    ///   - apiKey: Your Gravity publisher API key. Falls back to the
    ///     `GRAVITY_API_KEY` environment variable.
    ///   - apiUrl: Gravity ad endpoint. Defaults to production.
    ///   - feedbackUrl: Gravity feedback endpoint. Defaults to production.
    ///   - timeoutSeconds: Request timeout. Default 4 s.
    ///   - production: `false` returns test ads (no billing). Default `false`.
    ///   - relevancy: Minimum relevancy threshold 0.0-1.0. Default `0.2`.
    ///   - excludedTopics: Topics to exclude from matching.
    ///   - readCMPConsent: When `true` (default), consent recorded by the
    ///     app's IAB-registered CMP (the standard `IABTCF_*` /
    ///     `IABUSPrivacy_String` UserDefaults keys) is forwarded with ad
    ///     requests so the server can honor it. Set `false` to never read
    ///     CMP storage; only an explicit `consent:` argument is sent then.
    ///   - honorATT: When `true` (default), the App Tracking Transparency
    ///     status is mapped to the consent signal: unless the user has
    ///     explicitly authorized tracking, requests carry `consent.gpc = true`
    ///     and the engine serves fully contextual ads with no cross-context
    ///     identifiers (denial, restriction, and never-asked all fail
    ///     closed, matching Apple's tracking policy). Set `false` only if
    ///     you forward the user's opt-out state yourself via `consent:`.
    ///   - enableFrames: Allow rich frame ads on platforms with a frame renderer.
    ///     Set `false` when using a custom renderer without frame support.
    public convenience init(
        apiKey: String? = nil,
        apiUrl: String = "https://server.trygravity.ai/api/v1/ad",
        feedbackUrl: String = "https://platform.trygravity.ai/ad-feedback",
        timeoutSeconds: TimeInterval = 4.0,
        production: Bool = false,
        relevancy: Double = 0.2,
        excludedTopics: [String]? = nil,
        readCMPConsent: Bool = true,
        honorATT: Bool = true,
        enableFrames: Bool = true
    ) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds + 2
        self.init(
            apiKey: apiKey,
            apiUrl: apiUrl,
            feedbackUrl: feedbackUrl,
            timeoutSeconds: timeoutSeconds,
            production: production,
            relevancy: relevancy,
            excludedTopics: excludedTopics,
            readCMPConsent: readCMPConsent,
            honorATT: honorATT,
            enableFrames: enableFrames,
            session: URLSession(configuration: config)
        )
    }

    internal init(
        apiKey: String? = nil,
        apiUrl: String = "https://server.trygravity.ai/api/v1/ad",
        feedbackUrl: String = "https://platform.trygravity.ai/ad-feedback",
        timeoutSeconds: TimeInterval = 4.0,
        production: Bool = false,
        relevancy: Double = 0.2,
        excludedTopics: [String]? = nil,
        readCMPConsent: Bool = true,
        honorATT: Bool = true,
        enableFrames: Bool = true,
        session: URLSession
    ) {
        self.apiKey = apiKey
            ?? ProcessInfo.processInfo.environment["GRAVITY_API_KEY"]
            ?? ""
        self.apiUrl = apiUrl
        self.feedbackUrl = feedbackUrl
        self.timeoutSeconds = timeoutSeconds
        self.production = production
        self.relevancy = relevancy
        self.excludedTopics = excludedTopics
        self.readCMPConsent = readCMPConsent
        self.honorATT = honorATT
        self.enableFrames = enableFrames
        self.session = session
    }

    // MARK: - Fetch ads

    /// Fetch contextual ads from the Gravity engine.
    ///
    /// This method never throws. Failures before an HTTP response return
    /// status `0`; HTTP responses preserve their status code.
    ///
    /// Unlike the server-side JS/Python SDKs, this client does not take a
    /// framework request object — it collects device signals (UA, OS, screen,
    /// timezone, locale) directly from the host device. Pass `userIP` if your
    /// app knows the end-user IP (e.g. from your backend).
    ///
    /// - Parameters:
    ///   - messages: Conversation history for contextual matching.
    ///   - sessionId: Session identifier for frequency capping and experiments.
    ///   - userId: Stable per-user identifier. Pass `"anonymous"` if unknown.
    ///   - placements: Ad slots to fill (1-10).
    ///   - userIP: End-user IP, sent as `device.ip` for geo targeting. Optional.
    ///   - hashedIdentity: Pre-hashed email/phone from ``hashPII(email:phone:)``.
    ///   - extraUserFields: Additional user context (gender, age, etc.).
    ///   - extraDeviceFields: Additional device fields to merge (e.g. `["ifa": idfa]`).
    ///   - production: Override the instance-level production flag.
    ///   - relevancy: Override the instance-level relevancy threshold.
    ///   - usage: Usage of the model response this ad request accompanies,
    ///     for model cost in your Gravity dashboard. See ``ModelUsage``.
    ///   - tags: Structured publisher cohort attributes, merged into `user.tags`.
    ///     Existing string-valued `extraUserFields` remain supported.
    ///   - units: Optional root-level unit selection.
    ///   - enableFrames: Override the instance-level frame capability.
    ///   - supportsPromptAction: Set `true` only when every opted-in placement
    ///     has a working `onPrompt` callback that inserts into the composer
    ///     without sending. The placement must also opt in to prompt actions.
    ///   - alwaysReturn: Request a fallback test ad on no-fill. Ignored in production.
    ///   - adLayout: Preview `image_left`, `image_right`, or `image_top` on test ads only.
    ///   - testAdFormat: Preview `action` on test ads, subject to placement opt-in.
    public func getAds(
        messages: [Message],
        sessionId: String,
        userId: String = "anonymous",
        placements: [Placement],
        userIP: String? = nil,
        hashedIdentity: HashedIdentity? = nil,
        extraUserFields: [String: String]? = nil,
        extraDeviceFields: [String: Any]? = nil,
        production: Bool? = nil,
        relevancy: Double? = nil,
        consent: ConsentSignal? = nil,
        usage: ModelUsage? = nil,
        tags: [String: Any]? = nil,
        units: [String]? = nil,
        enableFrames: Bool? = nil,
        supportsPromptAction: Bool = false,
        alwaysReturn: Bool = false,
        adLayout: String? = nil,
        testAdFormat: String? = nil
    ) async -> AdResult {
        let start = Date()
        do {
            let body = buildRequestBody(
                messages: messages,
                sessionId: sessionId,
                userId: userId,
                placements: placements,
                userIP: userIP,
                hashedIdentity: hashedIdentity,
                extraUserFields: extraUserFields,
                extraDeviceFields: extraDeviceFields,
                production: production,
                relevancy: relevancy,
                consent: consent,
                usage: usage,
                tags: tags,
                units: units,
                enableFrames: enableFrames,
                supportsPromptAction: supportsPromptAction,
                alwaysReturn: alwaysReturn,
                adLayout: adLayout,
                testAdFormat: testAdFormat
            )
            guard JSONSerialization.isValidJSONObject(body),
                  let data = try? JSONSerialization.data(withJSONObject: body)
            else {
                let elapsed = Int(-start.timeIntervalSinceNow * 1000)
                return AdResult(
                    ads: [],
                    status: 0,
                    elapsedMs: elapsed,
                    error: "Request body could not be serialized"
                )
            }

            guard let url = URL(string: apiUrl) else {
                let elapsed = Int(-start.timeIntervalSinceNow * 1000)
                return AdResult(
                    ads: [],
                    status: 0,
                    elapsedMs: elapsed,
                    error: "Invalid ad endpoint URL"
                )
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data

            let (responseData, response) = try await session.data(for: request)
            let elapsed = Int(-start.timeIntervalSinceNow * 1000)

            guard let httpResponse = response as? HTTPURLResponse else {
                return AdResult(
                    ads: [],
                    status: 0,
                    elapsedMs: elapsed,
                    error: "Received non-HTTP response"
                )
            }

            if httpResponse.statusCode == 204 {
                return AdResult(ads: [], status: 204, elapsedMs: elapsed, error: nil)
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                return AdResult(
                    ads: [],
                    status: httpResponse.statusCode,
                    elapsedMs: elapsed,
                    error: httpError(statusCode: httpResponse.statusCode, body: responseData)
                )
            }

            do {
                let ads = try JSONDecoder().decode([AdResponse].self, from: responseData)
                return AdResult(
                    ads: ads,
                    status: httpResponse.statusCode,
                    elapsedMs: elapsed,
                    error: nil
                )
            } catch {
                return AdResult(
                    ads: [],
                    status: httpResponse.statusCode,
                    elapsedMs: elapsed,
                    error: "Failed to decode ad response: \(error.localizedDescription)"
                )
            }
        } catch {
            let elapsed = Int(-start.timeIntervalSinceNow * 1000)
            return AdResult(ads: [], status: 0, elapsedMs: elapsed, error: error.localizedDescription)
        }
    }

    // MARK: - Impression tracking

    /// Fire the impression pixel. Call once when the ad becomes visible
    /// (at least 50% in viewport).
    ///
    /// Each impression URL fires at most once per process, so a view that a
    /// lazy list recreates cannot send the same impression again.
    ///
    /// Fire-and-forget — errors are silently ignored.
    public func trackImpression(_ ad: AdResponse) {
        guard let urlString = ad.impUrl, let url = URL(string: urlString) else { return }
        guard Self.firedImpressions.insert(urlString) else { return }
        Task { _ = try? await session.data(from: url) }
    }

    /// Whether the billed impression pixel for `ad` has already been sent.
    func hasFiredImpression(_ ad: AdResponse) -> Bool {
        ad.impUrl.map { Self.firedImpressions.contains($0) } ?? false
    }

    /// Send `measured` once the billed pixel for `ad` has fired, so the two go
    /// out together. Call only when the ad's visibility is measurable.
    func sendMeasuredBeaconIfPixelFired(_ ad: AdResponse) {
        guard hasFiredImpression(ad) else { return }
        sendViewabilityBeacon(ad, event: .measured)
    }

    /// Send a shadow viewability beacon for `ad`. At most once per event and
    /// impression URL per process. Fire-and-forget; never affects billing.
    func sendViewabilityBeacon(_ ad: AdResponse, event: ViewabilityBeacon.Event) {
        guard let impUrl = ad.impUrl,
              let url = ViewabilityBeacon.url(impUrl: impUrl, event: event),
              ViewabilityBeacon.sent.insert("\(event.rawValue)|\(impUrl)")
        else { return }
        Task { _ = try? await session.data(from: url) }
    }

    // MARK: - Click handling

    /// Open the ad's tracked click URL. Routes through Gravity tracking,
    /// then 302-redirects to the landing page.
    @MainActor
    public func handleClick(_ ad: AdResponse) {
        guard let urlString = ad.clickUrl, let url = URL(string: urlString) else { return }
        #if canImport(UIKit) && !os(watchOS)
        UIApplication.shared.open(url)
        #endif
    }

    // MARK: - Ad feedback

    /// Submit user feedback (thumbs up / thumbs down) on an ad.
    ///
    /// Fire-and-forget — errors are silently ignored.
    public func sendFeedback(
        sessionId: String,
        ad: AdResponse,
        sentiment: Sentiment,
        reasons: [String]? = nil,
        comment: String? = nil,
        userId: String? = nil
    ) {
        Task {
            do {
                var body: [String: Any] = [
                    "sessionId": sessionId,
                    "impUrl": ad.impUrl ?? "",
                    "sentiment": sentiment.rawValue,
                ]
                if let reasons { body["reasons"] = reasons }
                if let comment { body["comment"] = comment }
                if let userId { body["userId"] = userId }
                if let p = ad.placement { body["placement"] = p }
                if let pid = ad.placementId { body["placementId"] = pid }

                guard JSONSerialization.isValidJSONObject(body),
                      let data = try? JSONSerialization.data(withJSONObject: body),
                      let url = URL(string: feedbackUrl)
                else {
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = data

                _ = try await session.data(for: request)
            } catch {
                // fire-and-forget
            }
        }
    }

    public enum Sentiment: String, Sendable {
        case thumbsUp = "thumbs_up"
        case thumbsDown = "thumbs_down"
    }

    // MARK: - Private

    private static let firedImpressions = FiredImpressionLog(capacity: 1000)

    private func httpError(statusCode: Int, body: Data) -> String {
        guard let text = String(data: body, encoding: .utf8) else {
            return "HTTP \(statusCode)"
        }

        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty else {
            return "HTTP \(statusCode)"
        }

        let message = "HTTP \(statusCode): \(normalized)"
        guard message.count > 512 else {
            return message
        }
        return String(message.prefix(512))
    }

    func buildRequestBody(
        messages: [Message],
        sessionId: String,
        userId: String,
        placements: [Placement],
        userIP: String?,
        hashedIdentity: HashedIdentity?,
        extraUserFields: [String: String]?,
        extraDeviceFields: [String: Any]?,
        production: Bool?,
        relevancy: Double?,
        consent: ConsentSignal? = nil,
        usage: ModelUsage? = nil,
        tags: [String: Any]? = nil,
        units: [String]? = nil,
        enableFrames: Bool? = nil,
        supportsPromptAction: Bool = false,
        alwaysReturn: Bool = false,
        adLayout: String? = nil,
        testAdFormat: String? = nil
    ) -> [String: Any] {
        // Last 2 valid conversational messages
        let validMessages = messages
            .compactMap { $0.toDict() }
            .suffix(2)
            .map { $0 as Any }

        var user: [String: Any] = ["id": userId]
        if let hashed = hashedIdentity {
            if let eh = hashed.emailHash { user["hashed_email"] = eh }
            if let ph = hashed.hashedPhone { user["hashed_phone"] = ph }
        }
        if let extra = extraUserFields {
            for (k, v) in extra { user[k] = v }
        }
        if let tags { user["tags"] = tags }

        var device = DeviceContext.collect().toDict()
        if let ip = userIP { device["ip"] = ip }
        if let extra = extraDeviceFields {
            for (k, v) in extra { device[k] = v }
        }

        var body: [String: Any] = [
            "messages": Array(validMessages),
            "sessionId": sessionId,
            "placements": placements.map { $0.toDict(supportsPromptAction: supportsPromptAction) },
            "user": user,
            "device": device,
            "relevancy": relevancy ?? self.relevancy,
            "testAd": !(production ?? self.production),
        ]
        if let units { body["units"] = units }
        if !(production ?? self.production) {
            if alwaysReturn { body["alwaysReturn"] = true }
            if let adLayout, ["image_left", "image_right", "image_top"].contains(adLayout) {
                body["adLayout"] = adLayout
            }
            if testAdFormat == "action" { body["testAdFormat"] = "action" }
        }
        #if canImport(WebKit) && canImport(SwiftUI) && canImport(UIKit) && os(iOS)
        if enableFrames ?? self.enableFrames { body["supportsFrames"] = true }
        #endif
        // Capability profile only — never the legacy `supportsSpec: true`,
        // which the engine reads as "full web renderer" (web1) and would
        // attach full-CSS specs this interpreter can't paint. The engine's
        // profile gate matches psp1 clients with psp1-conformant specs.
        // Advertised only on platforms where the interpreter (SpecAdView)
        // actually compiles — tvOS/watchOS builds have no PSP-1 renderer,
        // so they must not ask for spec payloads they always discard.
        #if canImport(SwiftUI) && canImport(UIKit) && os(iOS)
        body["specCapabilities"] = "psp1"
        #endif
        if let topics = excludedTopics {
            body["excludedTopics"] = topics
        }
        // Consent: an explicit signal wins; otherwise (unless the publisher
        // opted out with `readCMPConsent: false`) auto-read the standard IAB
        // CMP keys the app's consent banner writes to UserDefaults.
        // Neither present → field omitted, request unchanged.
        // App Tracking Transparency: unless the user explicitly authorized
        // tracking, assert the opt-out (never unsets one already present).
        let signal = ConsentSignal.merging(
            consent ?? (readCMPConsent ? ConsentSignal.fromCMP() : nil),
            attOptsOut: honorATT ? ConsentSignal.attOptsOut() : nil
        )
        if let signal {
            let dict = signal.toDict()
            if !dict.isEmpty { body["consent"] = dict }
        }
        if let usage {
            let dict = usage.toDict()
            if !dict.isEmpty { body["usage"] = dict }
        }
        return body
    }
}

/// Bounded, thread-safe record of impression URLs already fired. The oldest
/// entry is evicted when the record is full.
internal final class FiredImpressionLog: @unchecked Sendable {
    private let capacity: Int
    private let lock = NSLock()
    private var fired: Set<String> = []
    private var order: [String] = []
    private var head = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func contains(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired.contains(key)
    }

    /// Returns `true` when `key` is new, and `false` when it was already recorded.
    func insert(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard fired.insert(key).inserted else { return false }
        order.append(key)
        if fired.count > capacity {
            fired.remove(order[head])
            head += 1
            if head >= capacity {
                order.removeFirst(head)
                head = 0
            }
        }
        return true
    }
}
