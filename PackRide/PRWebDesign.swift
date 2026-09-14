import SwiftUI

// MARK: - PackRide web-style presentation primitives
// Shared by the redesigned feature screens. These deliberately follow
// ContentView.swift's full-bleed, editorial/list treatment instead of
// turning every section into a floating card.

struct PRWebPageHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    var accent: Color = .prCoral
    var trailing: AnyView? = nil
    // Aug 27, 2026 — every pushed sub-screen built on this header
    // (Garage, Digest, Trends, Badges, scheduled-ride detail, Communities)
    // had .navigationBarHidden(true) with no back button at all, so there
    // was no way back to the screen you came from short of an undiscoverable
    // edge swipe. Defaulted on here so every current and future screen using
    // this header gets a working back button for free. The two fullScreenCover
    // weather screens (WeatherView.swift) already have their own trailing
    // X-close button, so they pass showBackButton: false to avoid showing
    // two dismiss controls on one header.
    var showBackButton: Bool = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            if showBackButton {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.prInk)
                        .frame(width: 32, height: 32)
                        .background(Color.prCardBg)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.prBorder, lineWidth: 1))
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(eyebrow.uppercased())
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(2.6)
                    .foregroundColor(accent)
                Text(title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundColor(.prInk)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.prMuted)
            }
            Spacer(minLength: 0)
            if let trailing {
                trailing
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PRWebSectionLabel: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .heavy))
                .tracking(2)
                .foregroundColor(.prMuted)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.prMuted.opacity(0.72))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
}

struct PRWebSurface<Content: View>: View {
    let content: Content
    var cornerRadius: CGFloat = 18
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.prCardBg)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.prBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    init(cornerRadius: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }
}

struct PRWebDivider: View {
    var inset: CGFloat = 56
    var body: some View {
        Rectangle()
            .fill(Color.prBorder)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

struct PRWebMetricStrip: View {
    let metrics: [(String, String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(metrics.enumerated()), id: \.offset) { index, metric in
                VStack(spacing: 3) {
                    Text(metric.0)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundColor(.prInk)
                        .lineLimit(1)
                    Text(metric.1.uppercased())
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundColor(.prMuted)
                        .tracking(1.1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)

                if index < metrics.count - 1 {
                    Rectangle()
                        .fill(Color.prBorder)
                        .frame(width: 1, height: 34)
                }
            }
        }
        .background(Color.prCardBg)
        .overlay(Rectangle().fill(Color.prBorder).frame(height: 1), alignment: .top)
        .overlay(Rectangle().fill(Color.prBorder).frame(height: 1), alignment: .bottom)
    }
}

struct PRWebLivePill: View {
    let label: String
    var accent: Color = Color(red: 0.180, green: 0.620, blue: 0.357)

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(accent)
                .frame(width: 7, height: 7)
                .shadow(color: accent.opacity(0.55), radius: 4)
            Text(label.uppercased())
                .font(.system(size: 10, weight: .heavy))
                .tracking(1.8)
                .foregroundColor(accent)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(accent.opacity(0.08))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(accent.opacity(0.2), lineWidth: 1))
    }
}
