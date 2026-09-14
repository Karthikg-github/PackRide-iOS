import SwiftUI

// MARK: - Join Code Generator
// Shared by group ride codes (GroupRideView) and community IDs
// (CommunityManager) — a short, easy-to-read-aloud or text 4-character code,
// either all letters or all digits (never mixed), so it's simple to share
// verbally or via a quick SMS. Excludes visually-ambiguous characters
// (0/O, 1/I/L) the same way the app's older 6-character ride codes already did.
enum JoinCodeGenerator {
    static func generate() -> String {
        let letters = "ABCDEFGHJKLMNPQRSTUVWXYZ" // no I/O
        let digits = "23456789" // no 0/1
        let pool = Bool.random() ? letters : digits
        return String((0..<4).compactMap { _ in pool.randomElement() })
    }
}

// MARK: - Rider Initials
// Single source of truth for turning a rider's display name into the 2-letter
// initials shown in avatar circles across the app (Profile, Feed, Map pins,
// Group Ride, Community, etc). First letter of first name + first letter of
// last name for a full name; falls back to the first two characters for a
// single-word name, and "?" for an empty one.
extension String {
    var rideInitials: String {
        let parts = trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .filter { !$0.isEmpty }
        if parts.count >= 2, let first = parts.first?.first, let last = parts.last?.first {
            return String([first, last]).uppercased()
        } else if let only = parts.first {
            return String(only.prefix(2)).uppercased()
        } else {
            return "?"
        }
    }
}

// MARK: - App Colors
struct AppColors {
    // Base
    static let background = Color(red: 0.06, green: 0.06, blue: 0.08)
    static let cardBg = Color.white.opacity(0.05)
    static let fieldBg = Color.white.opacity(0.06)
    static let border = Color.white.opacity(0.08)
    static let borderLight = Color.white.opacity(0.12)

    // Text
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.5)
    static let tertiaryText = Color.white.opacity(0.3)
    static let label = Color.white.opacity(0.4)

    // Accents
    static let accent = Color.prCoral
    static let accentGradient = LinearGradient(
        colors: [Color.prCoral, Color(red: 0.92, green: 0.28, blue: 0.0)],
        startPoint: .leading, endPoint: .trailing
    )
    static let blue = Color(red: 0.25, green: 0.6, blue: 1.0)
    static let blueGradient = LinearGradient(
        colors: [Color(red: 0.25, green: 0.6, blue: 1.0), Color(red: 0.15, green: 0.4, blue: 0.85)],
        startPoint: .leading, endPoint: .trailing
    )
    static let green = Color.green
    static let greenGradient = LinearGradient(
        colors: [.green, Color(red: 0.0, green: 0.7, blue: 0.3)],
        startPoint: .leading, endPoint: .trailing
    )
    static let red = Color.red
    static let redGradient = LinearGradient(
        colors: [.red, Color(red: 0.7, green: 0.1, blue: 0.1)],
        startPoint: .leading, endPoint: .trailing
    )
    static let cyan = Color.cyan
    static let cyanGradient = LinearGradient(
        colors: [.cyan, Color(red: 0.0, green: 0.5, blue: 0.9)],
        startPoint: .leading, endPoint: .trailing
    )
    static let purple = Color.purple
}

// MARK: - App Fonts
struct AppFont {
    // Headers
    static func hero() -> Font { .system(size: 28, weight: .bold) }
    static func title() -> Font { .system(size: 22, weight: .bold) }
    static func heading() -> Font { .system(size: 18, weight: .semibold) }
    static func subheading() -> Font { .system(size: 16, weight: .semibold) }

    // Body
    static func body() -> Font { .system(size: 15, weight: .regular) }
    static func bodySmall() -> Font { .system(size: 14, weight: .regular) }
    static func caption() -> Font { .system(size: 12, weight: .medium) }
    static func micro() -> Font { .system(size: 10, weight: .medium) }

    // Special
    static func sectionHeader() -> Font { .system(size: 13, weight: .semibold) }
    static func monospaced() -> Font { .system(size: 14, weight: .semibold, design: .monospaced) }
    static func monoLarge() -> Font { .system(size: 16, weight: .semibold, design: .monospaced) }
    static func stat() -> Font { .system(size: 22, weight: .bold) }
    static func statLarge() -> Font { .system(size: 36, weight: .bold) }

    // Button
    static func button() -> Font { .system(size: 16, weight: .semibold) }
    static func buttonSmall() -> Font { .system(size: 14, weight: .semibold) }
}

// MARK: - Reusable View Modifiers
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 12
    func body(content: Content) -> some View {
        content
            .background(Color.prCardBg)
            .cornerRadius(cornerRadius)
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Color.prBorder, lineWidth: 1))
    }
}

struct GlassCardColored: ViewModifier {
    let color: Color
    var cornerRadius: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .background(color.opacity(0.06))
            .cornerRadius(cornerRadius)
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(color.opacity(0.2), lineWidth: 1))
    }
}

struct PrimaryButton: ViewModifier {
    var disabled: Bool = false
    func body(content: Content) -> some View {
        content
            .font(AppFont.button())
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(disabled ? LinearGradient(colors: [Color.gray.opacity(0.3)], startPoint: .leading, endPoint: .trailing) : AppColors.accentGradient)
            .cornerRadius(12)
            .shadow(color: disabled ? .clear : Color.prCoral.opacity(0.28), radius: 10, y: 4)
    }
}

// MARK: - View Extensions
extension View {
    func glassCard(cornerRadius: CGFloat = 20) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius))
    }

    func glassCardColored(_ color: Color, cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassCardColored(color: color, cornerRadius: cornerRadius))
    }

    func primaryButton(disabled: Bool = false) -> some View {
        modifier(PrimaryButton(disabled: disabled))
    }

    func sectionHeader() -> some View {
        self.font(AppFont.sectionHeader())
            .foregroundColor(AppColors.tertiaryText)
            .tracking(2)
    }

    func appBackground() -> some View {
        self.background(AppColors.background.ignoresSafeArea())
    }
}

// MARK: - Reusable Components
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).sectionHeader()
    }
}

struct GlowDot: View {
    let color: Color
    var size: CGFloat = 8
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .shadow(color: color.opacity(0.6), radius: 4)
    }
}

// MARK: - Speed Limit Badge (US road-sign style)
// currentSpeed is optional — pass it in to tint the badge red when the rider
// is over the posted limit. Speed limit data comes from OpenStreetMap and may
// not be available on every road; the caller should only show this when
// `limitMph` is non-nil.
struct SpeedLimitBadge: View {
    let limitMph: Int
    var currentSpeed: Double? = nil

    private var isOverLimit: Bool {
        guard let currentSpeed else { return false }
        return currentSpeed > Double(limitMph) + 3 // small buffer for GPS noise
    }

    var body: some View {
        VStack(spacing: 1) {
            Text("SPEED").font(.system(size: 8, weight: .heavy, design: .rounded)).tracking(0.5)
            Text("LIMIT").font(.system(size: 8, weight: .heavy, design: .rounded)).tracking(0.5)
            Text("\(limitMph)").font(.system(size: 26, weight: .heavy, design: .rounded))
                .padding(.vertical, 1)
        }
        .foregroundColor(.black)
        .frame(width: 56, height: 64)
        .background(Color.prCardBg)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isOverLimit ? Color(red: 0.827, green: 0.231, blue: 0.173) : Color.black, lineWidth: isOverLimit ? 3 : 2.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
    }
}

// MARK: - Road Name Pill
struct RoadNamePill: View {
    let roadName: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "signpost.right.fill").font(.system(size: 11))
            Text(roadName).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.black.opacity(0.5))
        .cornerRadius(12)
    }
}

struct AvatarCircle: View {
    let initials: String
    let size: CGFloat
    var gradient: [Color] = [Color.prCoral, Color(red: 1.0, green: 0.32, blue: 0.0)]
    var showOnline: Bool = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .shadow(color: gradient[0].opacity(0.3), radius: 4)
            Text(initials)
                .font(.system(size: size * 0.32, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: size, height: size)
            if showOnline {
                Circle().fill(Color.green).frame(width: size * 0.27, height: size * 0.27)
                    .overlay(Circle().stroke(AppColors.background, lineWidth: 2))
                    .offset(x: 2, y: 2)
            }
        }
    }
}

// MARK: - REVER-style building blocks
struct FilterChip: View {
    let title: String
    let selected: Bool
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(selected ? .white : .prInk)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(selected ? Color.prCoral : Color.prFieldBg)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct SectionNavHeader: View {
    let title: String
    var trailing: String? = nil
    var body: some View {
        HStack {
            Text(title).font(.system(size: 18, weight: .semibold)).foregroundColor(.prInk)
            Spacer()
            if let trailing {
                Text(trailing).font(.system(size: 13)).foregroundColor(.prMuted)
            }
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(.prMuted)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }
}

/// Two-column stat row with a centered icon — matches REVER ride-detail stats.
struct ReverStatRow: View {
    let leftLabel: String
    let leftValue: String
    let icon: String
    let rightLabel: String
    let rightValue: String
    var body: some View {
        HStack(spacing: 0) {
            HStack {
                Text("\(leftLabel):").foregroundColor(.prMuted)
                Text(leftValue).foregroundColor(.prInk).fontWeight(.medium)
                Spacer()
            }
            .font(.system(size: 15))
            Image(systemName: icon)
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(.prInk)
                .frame(width: 44)
            HStack {
                Spacer()
                Text("\(rightLabel):").foregroundColor(.prMuted)
                Text(rightValue).foregroundColor(.prInk).fontWeight(.medium)
            }
            .font(.system(size: 15))
        }
        .padding(.horizontal, 16).padding(.vertical, 16)
        .background(Color.prFieldBg)
    }
}

struct RideActivityChart: View {
    let points: [(label: String, value: Double)]
    var body: some View {
        GeometryReader { geo in
            let maxV = max(points.map(\.value).max() ?? 1, 1)
            let w = geo.size.width
            let h = geo.size.height
            let step = points.count > 1 ? w / CGFloat(points.count - 1) : w
            let coords: [CGPoint] = points.enumerated().map { i, p in
                CGPoint(x: CGFloat(i) * step, y: h - CGFloat(p.value / maxV) * (h - 8) - 4)
            }
            Path { path in
                guard let first = coords.first else { return }
                path.move(to: first)
                for pt in coords.dropFirst() { path.addLine(to: pt) }
            }
            .stroke(Color.prCoral, style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
            Path { path in
                guard let first = coords.first, let last = coords.last else { return }
                path.move(to: CGPoint(x: first.x, y: h))
                path.addLine(to: first)
                for pt in coords.dropFirst() { path.addLine(to: pt) }
                path.addLine(to: CGPoint(x: last.x, y: h))
                path.closeSubpath()
            }
            .fill(LinearGradient(colors: [Color.prCoral.opacity(0.35), Color.prCoral.opacity(0.02)], startPoint: .top, endPoint: .bottom))
        }
    }
}
