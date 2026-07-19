#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// A SwiftUI view that renders a Gravity ad with automatic impression tracking.
///
/// ```swift
/// GravityAdView(ad: ad, gravity: gravity, sessionId: sessionId)
/// ```
///
/// Fires the impression pixel the first time it appears on screen
/// and routes clicks through the tracked `clickUrl`.
public struct GravityAdView: View {
    private let ad: AdResponse
    private let gravity: Gravity
    private let sessionId: String
    private let showFeedback: Bool

    @State private var impressionFired = false
    @State private var feedbackSent = false

    public init(
        ad: AdResponse,
        gravity: Gravity,
        sessionId: String,
        showFeedback: Bool = true
    ) {
        self.ad = ad
        self.gravity = gravity
        self.sessionId = sessionId
        self.showFeedback = showFeedback
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Brand row
            HStack(spacing: 6) {
                if let faviconURL = ad.favicon, let url = URL(string: faviconURL) {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fit)
                    } placeholder: {
                        Color.gray.opacity(0.2)
                    }
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                if let brand = ad.brandName {
                    Text(brand)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Ad")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let title = ad.title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }

            if let text = ad.adText {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack {
                if let cta = ad.cta {
                    Button {
                        gravity.handleClick(ad)
                    } label: {
                        Text(cta)
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                Spacer()

                if showFeedback && !feedbackSent {
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
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .onAppear {
            guard !impressionFired else { return }
            impressionFired = true
            gravity.trackImpression(ad)
        }
    }
}
#endif
