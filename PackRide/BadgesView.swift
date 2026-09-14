import SwiftUI

// MARK: - Badges/Streaks
// Aug 24, 2026 — ported from the shipped React Native badges feature. Pure
// computation over the rider's existing ride/lap history (RideHistoryManager
// / LapHistoryManager), same as RideAnalyticsEngine and the Trends views —
// there's no new persisted "date earned" store. A badge is simply "earned"
// whenever the rider's current stats already clear its target, recomputed
// fresh every time this screen appears.

// MARK: - Badge Category
enum BadgeCategory: String, CaseIterable {
    case road = "Road"
    case track = "Track"
    case streaks = "Streaks"
}

// MARK: - Badge Value Kind
// Drives how a badge's progress readout is formatted ("320 / 500 mi" vs
// "82 / 95" vs "3 / 7 days" etc).
enum BadgeValueKind {
    case miles
    case score
    case degrees
    case count
    case days
}

// MARK: - Badge
struct Badge: Identifiable {
    let id: String
    let name: String
    let description: String
    let icon: String
    let category: BadgeCategory
    let kind: BadgeValueKind
    // Both already clamped to target by BadgeEngine below — an earned badge
    // shows a gold circle instead of a readout, so there's nothing to gain by
    // letting current run past target here.
    let current: Double
    let target: Double

    var isEarned: Bool { current >= target }
    var progressFraction: Double { target > 0 ? min(current / target, 1.0) : 0 }

    private static func numberString(_ value: Double) -> String {
        // Miles/degrees read fine as whole numbers for badge purposes; score/
        // count/day targets are always whole numbers already.
        String(Int(value.rounded()))
    }

    var readout: String {
        let cur = Badge.numberString(current)
        let tgt = Badge.numberString(target)
        switch kind {
        case .miles:
            if MeasurementUnits.current == .metric {
                return "\(Int((current * 1.609344).rounded())) / \(Int((target * 1.609344).rounded())) km"
            }
            return "\(cur) / \(tgt) mi"
        case .degrees: return "\(cur) / \(tgt)°"
        case .days: return "\(cur) / \(tgt) days"
        case .score, .count: return "\(cur) / \(tgt)"
        }
    }
}

// MARK: - Badge Engine
// "check whether RideAnalyticsEngine.swift is a good model for pure
// computation over history style" — yes: a stateless enum with one static
// entry point, mirroring RideAnalyticsEngine/LapAnalyticsEngine exactly.
enum BadgeEngine {
    static func computeBadges(rides: [RideRecord], sessions: [LapRecord]) -> [Badge] {
        // MARK: Road aggregates
        let totalRoadMiles = rides.reduce(0.0) { $0 + $1.distance }
        let totalRoadRides = rides.count
        let bestSingleRideMiles = rides.map { $0.distance }.max() ?? 0
        // Ride Score lives on RideRecord.analytics?.rideScore
        // (RideAnalyticsSummary.rideScore, defined in RideAnalyticsEngine.swift).
        let bestRideScore = rides.compactMap { $0.analytics?.rideScore }.max() ?? 0
        let hasNightRide = rides.contains { isNightRide($0.date) }
        // Road rides record their own max lean live during the ride, on
        // RideRecord.maxLeanAngle itself (not inside .analytics) — see
        // ActiveSoloRideView/SoloRideView.
        let bestRoadLean = rides.map { $0.maxLeanAngle }.max() ?? 0

        // MARK: Track aggregates
        let totalSessions = sessions.count
        // Consistency lives on LapRecord.analytics?.consistencyScore
        // (LapAnalyticsSummary.consistencyScore, defined in RideAnalyticsEngine.swift).
        let bestConsistency = sessions.compactMap { $0.analytics?.consistencyScore }.max() ?? 0
        // Unlike RideRecord, LapRecord has no top-level maxLeanAngle field —
        // a track session's max lean only exists inside its analytics
        // (LapAnalyticsSummary.maxLeanAngle, populated from the session's own
        // GPX/motion capture — see LapAnalyticsEngine.analyze).
        let bestTrackLean = sessions.compactMap { $0.analytics?.maxLeanAngle }.max() ?? 0
        let bestLean = max(bestRoadLean, bestTrackLean)

        // MARK: Streaks (full history, not scoped to any window)
        let activeDays = StreakEngine.activeDays(rides: rides, sessions: sessions)
        let longestStreak = StreakEngine.longestStreak(activeDays: activeDays)

        return [
            // MARK: Road
            Badge(id: "first_ride", name: "First Ride", description: "Complete your first road ride.",
                  icon: "flag.checkered", category: .road, kind: .count,
                  current: min(Double(totalRoadRides), 1), target: 1),
            Badge(id: "century_rider", name: "Century Rider", description: "Ride 100+ miles in a single ride.",
                  icon: "gauge.with.needle.fill", category: .road, kind: .miles,
                  current: min(bestSingleRideMiles, 100), target: 100),
            Badge(id: "500_mile_club", name: "500 Mile Club", description: "Rack up 500 cumulative road miles.",
                  icon: "road.lanes", category: .road, kind: .miles,
                  current: min(totalRoadMiles, 500), target: 500),
            Badge(id: "1000_mile_club", name: "1,000 Mile Club", description: "Rack up 1,000 cumulative road miles.",
                  icon: "map.fill", category: .road, kind: .miles,
                  current: min(totalRoadMiles, 1000), target: 1000),
            Badge(id: "smooth_operator", name: "Smooth Operator", description: "Score 95+ Ride Score on any single ride.",
                  icon: "wind", category: .road, kind: .score,
                  current: min(Double(bestRideScore), 95), target: 95),
            Badge(id: "night_rider", name: "Night Rider", description: "Complete a ride that starts between 9pm and 5am.",
                  icon: "moon.stars.fill", category: .road, kind: .count,
                  current: hasNightRide ? 1 : 0, target: 1),

            // MARK: Track
            Badge(id: "first_lap", name: "First Lap", description: "Complete your first Track Mode session.",
                  icon: "stopwatch.fill", category: .track, kind: .count,
                  current: min(Double(totalSessions), 1), target: 1),
            Badge(id: "track_regular", name: "Track Regular", description: "Complete 5+ Track Mode sessions.",
                  icon: "flag.2.crossed.fill", category: .track, kind: .count,
                  current: min(Double(totalSessions), 5), target: 5),
            Badge(id: "consistency_king", name: "Consistency King", description: "Score 90+ Consistency on any Track Mode session.",
                  icon: "chart.bar.fill", category: .track, kind: .score,
                  current: min(Double(bestConsistency), 90), target: 90),
            Badge(id: "lean_machine", name: "Lean Machine", description: "Record a 45°+ max lean angle, on the road or the track.",
                  icon: "angle", category: .track, kind: .degrees,
                  current: min(bestLean, 45), target: 45),

            // MARK: Streaks
            Badge(id: "week_warrior", name: "Week Warrior", description: "Ride or lap 7 days in a row.",
                  icon: "calendar.badge.clock", category: .streaks, kind: .days,
                  current: min(Double(longestStreak), 7), target: 7),
            Badge(id: "monthly_momentum", name: "Monthly Momentum", description: "Ride or lap 30 days in a row.",
                  icon: "flame.fill", category: .streaks, kind: .days,
                  current: min(Double(longestStreak), 30), target: 30),
        ]
    }

    // 9pm through 5am local, inclusive of 9pm, exclusive of 5am.
    private static func isNightRide(_ date: Date) -> Bool {
        let hour = Calendar.current.component(.hour, from: date)
        return hour >= 21 || hour < 5
    }
}

// MARK: - Badges View
struct BadgesView: View {
    @StateObject private var historyManager = RideHistoryManager()
    @StateObject private var lapHistoryManager = LapHistoryManager()

    private var badges: [Badge] {
        BadgeEngine.computeBadges(rides: historyManager.rides, sessions: lapHistoryManager.sessions)
    }

    private var earnedCount: Int { badges.filter { $0.isEarned }.count }

    private func badges(in category: BadgeCategory) -> [Badge] {
        badges.filter { $0.category == category }
    }

    private func earnedCount(in category: BadgeCategory) -> Int {
        badges(in: category).filter { $0.isEarned }.count
    }

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        PRWebPageHeader(
                            eyebrow: "Badges",
                            title: "Your Achievements",
                            subtitle: "\(earnedCount) of \(badges.count) badges earned",
                            accent: Color(red: 0.788, green: 0.565, blue: 0.180)
                        )

                        PRWebMetricStrip(metrics: BadgeCategory.allCases.map { category in
                            ("\(earnedCount(in: category))/\(badges(in: category).count)", category.rawValue)
                        })

                        VStack(spacing: 24) {
                            ForEach(BadgeCategory.allCases, id: \.self) { category in
                                VStack(alignment: .leading, spacing: 0) {
                                    PRWebSectionLabel(title: category.rawValue)

                                    LazyVGrid(columns: columns, spacing: 12) {
                                        ForEach(badges(in: category)) { badge in
                                            BadgeCard(badge: badge)
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                }
                            }
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 30)
                    }
                }

                AdBannerFooter()
            }
        }
        .navigationBarHidden(true)
    }
}

// MARK: - Badge Card
struct BadgeCard: View {
    let badge: Badge

    // Fixed literal — matches the app's established pattern of non-adaptive
    // color literals for status/grading colors (see MaintenanceRow's
    // statusColor in GarageView.swift, or RideScoreCard's scoreColor) rather
    // than adding a new adaptive pr* token for something that should read as
    // "gold" the same way in both light and dark mode.
    private var goldColor: Color { Color(red: 0.788, green: 0.565, blue: 0.180) } // #C9902E

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(badge.isEarned ? goldColor : Color.prBorder, lineWidth: badge.isEarned ? 2 : 1)
                    .frame(width: 52, height: 52)
                Circle()
                    .fill(badge.isEarned ? goldColor.opacity(0.15) : Color.prFieldBg)
                    .frame(width: 44, height: 44)
                Image(systemName: badge.icon)
                    .font(.system(size: 18))
                    .foregroundColor(badge.isEarned ? goldColor : .prMuted)
            }

            VStack(spacing: 3) {
                Text(badge.name)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.prInk)
                    .multilineTextAlignment(.center)
                Text(badge.description)
                    .font(.system(size: 10))
                    .foregroundColor(.prMuted)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            if badge.isEarned {
                Text("EARNED")
                    .font(.system(size: 9, weight: .heavy)).tracking(1)
                    .foregroundColor(goldColor)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(goldColor.opacity(0.15))
                    .cornerRadius(6)
            } else {
                VStack(spacing: 5) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.prBorder).frame(height: 5)
                            Capsule().fill(Color.prCoral)
                                .frame(width: geo.size.width * badge.progressFraction, height: 5)
                        }
                    }
                    .frame(height: 5)
                    Text(badge.readout)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.prMuted)
                }
            }
        }
        .padding(.vertical, 16).padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .background(Color.prCardBg)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(badge.isEarned ? goldColor.opacity(0.4) : Color.prBorder, lineWidth: 1))
    }
}

#Preview {
    NavigationView { BadgesView() }
}
