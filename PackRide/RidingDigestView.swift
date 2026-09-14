import SwiftUI

// MARK: - Riding Digest (weekly/monthly recap)
// Aug 24, 2026 — ported from the shipped React Native digest feature. Pure
// computation over RideHistoryManager/LapHistoryManager's existing arrays,
// same as BadgesView and the Trends screens — nothing new is persisted here.

// MARK: - Digest Period
enum DigestPeriod: String, CaseIterable {
    case week = "Week"
    case month = "Month"
}

// MARK: - Streak Engine
// Shared by BadgesView (longest streak only) and RidingDigestView (current +
// longest + most-active-weekday). A "streak day" is any local calendar day
// with a road ride OR a track session — always computed over the rider's
// FULL history, never scoped to a selected period/window, so a streak
// spanning a period boundary can't reset just because a toggle flipped.
enum StreakEngine {
    static func activeDays(rides: [RideRecord], sessions: [LapRecord]) -> Set<Date> {
        let cal = Calendar.current
        var days = Set<Date>()
        for ride in rides { days.insert(cal.startOfDay(for: ride.date)) }
        for session in sessions { days.insert(cal.startOfDay(for: session.date)) }
        return days
    }

    static func longestStreak(activeDays: Set<Date>) -> Int {
        guard !activeDays.isEmpty else { return 0 }
        let cal = Calendar.current
        let sortedDays = activeDays.sorted()
        var longest = 1
        var current = 1
        for i in 1..<sortedDays.count {
            if let expected = cal.date(byAdding: .day, value: 1, to: sortedDays[i - 1]), expected == sortedDays[i] {
                current += 1
            } else {
                current = 1
            }
            longest = max(longest, current)
        }
        return longest
    }

    // "No ride/session yet today" is not treated as a broken streak — this
    // walks back from yesterday in that case, so the streak doesn't zero out
    // every morning before the rider's actually been out that day.
    static func currentStreak(activeDays: Set<Date>, now: Date = Date()) -> Int {
        guard !activeDays.isEmpty else { return 0 }
        let cal = Calendar.current
        var day = cal.startOfDay(for: now)
        if !activeDays.contains(day) {
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
            guard activeDays.contains(day) else { return 0 }
        }
        var streak = 0
        while activeDays.contains(day) {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return streak
    }

    static func mostActiveWeekday(activeDays: Set<Date>) -> String? {
        guard !activeDays.isEmpty else { return nil }
        let cal = Calendar.current
        var counts: [Int: Int] = [:]
        for day in activeDays {
            let weekday = cal.component(.weekday, from: day) // 1 = Sunday ... 7 = Saturday
            counts[weekday, default: 0] += 1
        }
        // Sorted (not max(by:)) for a deterministic tie-break — lowest
        // weekday number (earliest in the week) wins a tie.
        let ranked = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        guard let topWeekday = ranked.first?.key else { return nil }
        let symbols = DateFormatter().weekdaySymbols ?? [] // index 0 = Sunday, matches weekday - 1
        let index = topWeekday - 1
        guard symbols.indices.contains(index) else { return nil }
        return symbols[index]
    }
}

// MARK: - Riding Digest View
struct RidingDigestView: View {
    @StateObject private var historyManager = RideHistoryManager()
    @StateObject private var lapHistoryManager = LapHistoryManager()
    @State private var period: DigestPeriod = .week

    private let now = Date()
    private let cal = Calendar.current

    // MARK: - Period boundaries
    // "week" = most recent Sunday 00:00 local through now.
    private var startOfWeek: Date {
        let startOfToday = cal.startOfDay(for: now)
        let weekday = cal.component(.weekday, from: startOfToday) // 1 = Sunday
        return cal.date(byAdding: .day, value: -(weekday - 1), to: startOfToday) ?? startOfToday
    }

    // "month" = the 1st of the current calendar month 00:00 local through now.
    private var startOfMonth: Date {
        let comps = cal.dateComponents([.year, .month], from: now)
        return cal.date(from: comps) ?? cal.startOfDay(for: now)
    }

    private var periodStart: Date { period == .week ? startOfWeek : startOfMonth }

    // The previous FULLY COMPLETED week/month — a 7-day span (or full
    // calendar month) ending exactly where the current period begins, so the
    // percentage comparison is always like-for-like, never partial-to-partial.
    private var previousPeriodRange: (start: Date, end: Date) {
        if period == .week {
            let start = cal.date(byAdding: .day, value: -7, to: periodStart) ?? periodStart
            return (start, periodStart)
        } else {
            let start = cal.date(byAdding: .month, value: -1, to: periodStart) ?? periodStart
            return (start, periodStart)
        }
    }

    // MARK: - Scoped ride/session sets
    private var roadRidesThisPeriod: [RideRecord] {
        historyManager.rides.filter { $0.date >= periodStart && $0.date <= now }
    }

    private var roadRidesPreviousPeriod: [RideRecord] {
        let range = previousPeriodRange
        return historyManager.rides.filter { $0.date >= range.start && $0.date < range.end }
    }

    private var lapSessionsThisPeriod: [LapRecord] {
        lapHistoryManager.sessions.filter { $0.date >= periodStart && $0.date <= now }
    }

    // MARK: - Hero stat
    private var totalMilesThisPeriod: Double { roadRidesThisPeriod.reduce(0) { $0 + $1.distance } }
    private var totalMilesPreviousPeriod: Double { roadRidesPreviousPeriod.reduce(0) { $0 + $1.distance } }

    // nil when there's no completed-period baseline to compare against
    // (e.g. this is the rider's first week/month ever) — nothing honest to
    // show as a percentage in that case.
    private var percentChange: Double? {
        guard totalMilesPreviousPeriod > 0 else { return nil }
        return ((totalMilesThisPeriod - totalMilesPreviousPeriod) / totalMilesPreviousPeriod) * 100
    }

    // MARK: - Streaks (full history, independent of the period toggle)
    private var activeDays: Set<Date> { StreakEngine.activeDays(rides: historyManager.rides, sessions: lapHistoryManager.sessions) }
    private var currentStreak: Int { StreakEngine.currentStreak(activeDays: activeDays, now: now) }
    private var longestStreak: Int { StreakEngine.longestStreak(activeDays: activeDays) }
    private var mostActiveWeekday: String? { StreakEngine.mostActiveWeekday(activeDays: activeDays) }

    // MARK: - Road Riding card (scoped to period)
    private var roadRideCount: Int { roadRidesThisPeriod.count }
    private var topMph: Double { roadRidesThisPeriod.map { $0.maxSpeed }.max() ?? 0 }
    private var roadRideScores: [Int] { roadRidesThisPeriod.compactMap { $0.analytics?.rideScore } }
    private var avgRideScore: Int? {
        roadRideScores.isEmpty ? nil : Int((Double(roadRideScores.reduce(0, +)) / Double(roadRideScores.count)).rounded())
    }
    private var bestRideScore: Int? { roadRideScores.max() }

    // MARK: - Track Riding card (scoped to period, hidden entirely with zero
    // track sessions ever — not just zero this period)
    private var hasAnyTrackSessionEver: Bool { !lapHistoryManager.sessions.isEmpty }
    private var trackSessionCount: Int { lapSessionsThisPeriod.count }
    private var lapCountThisPeriod: Int { lapSessionsThisPeriod.reduce(0) { $0 + $1.laps.count } }
    private var bestLapThisPeriod: Double? {
        lapSessionsThisPeriod.compactMap { $0.bestLapTime > 0 ? $0.bestLapTime : nil }.min()
    }
    // RideRecord has no destination/road-name field to build a "favorite
    // road" stat from — deliberately not invented here. LapRecord.trackName
    // is real, so "favorite track" (most-visited this period) is legitimate.
    private var favoriteTrack: String? {
        var counts: [String: Int] = [:]
        for session in lapSessionsThisPeriod where !session.trackName.isEmpty {
            counts[session.trackName, default: 0] += 1
        }
        let ranked = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        return ranked.first?.key
    }

    private var hasAnyActivityEver: Bool { !historyManager.rides.isEmpty || !lapHistoryManager.sessions.isEmpty }

    var body: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        PRWebPageHeader(
                            eyebrow: "Digest",
                            title: "Riding Digest",
                            subtitle: hasAnyActivityEver
                                ? (period == .week ? "Your week in review" : "Your month in review")
                                : "Track your riding over time"
                        )

                        if !hasAnyActivityEver {
                            emptyState
                                .padding(.top, 20)
                                .padding(.bottom, 40)
                        } else {
                            VStack(spacing: 20) {
                                periodToggle

                                heroCard

                                streaksCard

                                roadRidingCard

                                if hasAnyTrackSessionEver {
                                    trackRidingCard
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                            .padding(.bottom, 30)
                        }
                    }
                }

                AdBannerFooter()
            }
        }
        .navigationBarHidden(true)
    }

    // MARK: - Period Toggle
    // Same two-option segmented-pill pattern as LoginView's Log In/Sign Up
    // toggle.
    private var periodToggle: some View {
        HStack(spacing: 0) {
            ForEach(DigestPeriod.allCases, id: \.self) { option in
                let isSelected = period == option
                Button(action: { withAnimation { period = option } }) {
                    Text(option.rawValue)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(isSelected ? .prInk : .prMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(isSelected ? Color.prCardBg : Color.clear)
                        .cornerRadius(11)
                }
            }
        }
        .padding(4)
        .background(Color.prFieldBg)
        .cornerRadius(14)
    }

    // MARK: - Hero Card
    private var heroCard: some View {
        VStack(spacing: 8) {
            Text(period == .week ? "MILES THIS WEEK" : "MILES THIS MONTH")
                .font(.system(size: 11, weight: .heavy)).foregroundColor(.prMuted).tracking(2)
            Text(String(format: "%.0f", totalMilesThisPeriod))
                .font(.system(size: 40, weight: .bold, design: .monospaced))
                .foregroundColor(.prInk)

            if let percentChange {
                HStack(spacing: 5) {
                    Image(systemName: percentChange >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 11, weight: .bold))
                    Text("\(percentChange >= 0 ? "+" : "")\(Int(percentChange.rounded()))% vs last \(period == .week ? "week" : "month")")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(percentChange >= 0 ? Color(red: 0.180, green: 0.620, blue: 0.357) : .prMuted)
            } else {
                Text(period == .week ? "No completed week yet to compare against" : "No completed month yet to compare against")
                    .font(.system(size: 12)).foregroundColor(.prMuted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(Color.prCardBg)
        .cornerRadius(20)
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.prBorder, lineWidth: 1))
    }

    // MARK: - Streaks Card
    private var streaksCard: some View {
        VStack(spacing: 14) {
            Text("STREAKS").font(.system(size: 11, weight: .heavy)).foregroundColor(.prMuted).tracking(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                AllTimeCard(icon: "flame.fill", value: "\(currentStreak)", label: "Current Streak", color: .prCoral)
                AllTimeCard(icon: "trophy.fill", value: "\(longestStreak)", label: "Longest Streak", color: Color(red: 0.788, green: 0.565, blue: 0.180))
                AllTimeCard(icon: "calendar", value: mostActiveWeekday ?? "--", label: "Most Active Day", color: .prTeal)
            }
        }
    }

    // MARK: - Road Riding Card
    private var roadRidingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "flag.checkered").font(.system(size: 13)).foregroundColor(.prCoral)
                Text("ROAD RIDING").font(.system(size: 11, weight: .heavy)).foregroundColor(.prMuted).tracking(2)
            }

            HStack(spacing: 0) {
                DetailStat(label: "Rides", value: "\(roadRideCount)")
                DetailStat(label: "Miles", value: String(format: "%.0f", totalMilesThisPeriod))
                DetailStat(label: "Top MPH", value: String(format: "%.0f", topMph))
            }

            Divider().background(Color.prBorder)

            HStack(spacing: 0) {
                DetailStat(label: "Avg Ride Score", value: avgRideScore.map { "\($0)" } ?? "--")
                DetailStat(label: "Best Ride Score", value: bestRideScore.map { "\($0)" } ?? "--")
            }
        }
        .padding(16)
        .background(Color.prCardBg)
        .cornerRadius(18)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.prBorder, lineWidth: 1))
    }

    // MARK: - Track Riding Card
    private var trackRidingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "stopwatch.fill").font(.system(size: 13)).foregroundColor(.prTeal)
                Text("TRACK RIDING").font(.system(size: 11, weight: .heavy)).foregroundColor(.prMuted).tracking(2)
            }

            HStack(spacing: 0) {
                DetailStat(label: "Sessions", value: "\(trackSessionCount)")
                DetailStat(label: "Laps", value: "\(lapCountThisPeriod)")
                DetailStat(label: "Best Lap", value: bestLapThisPeriod.map { LapEngine.formatLapTime($0) } ?? "--:--")
            }

            if let favoriteTrack {
                Divider().background(Color.prBorder)
                HStack(spacing: 8) {
                    Image(systemName: "mappin.circle.fill").font(.system(size: 13)).foregroundColor(.prTeal)
                    Text("Favorite track: \(favoriteTrack)")
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(.prInk)
                    Spacer()
                }
            }
        }
        .padding(16)
        .background(Color.prCardBg)
        .cornerRadius(18)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.prBorder, lineWidth: 1))
    }

    // MARK: - Empty State
    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.prCoralSoft).frame(width: 80, height: 80)
                Image(systemName: "calendar.badge.clock").font(.system(size: 30)).foregroundColor(.prCoral)
            }
            Text("No riding yet").font(.system(size: 16, weight: .bold)).foregroundColor(.prInk)
            Text("Complete a ride or Track Mode session to see your Digest here.")
                .font(.system(size: 13)).foregroundColor(.prMuted)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    NavigationView { RidingDigestView() }
}
