import SwiftUI
import Charts

// MARK: - Lap Trends View
// Track Mode's equivalent of RideTrendsView — but scoped to a single track at
// a time, since raw lap times from different tracks aren't comparable to each
// other (a 45-second parking lot loop and a 3-minute road course are both
// valid "best laps," just not on the same chart). Track Score IS comparable
// across tracks (it's normalized 0-100), so that one's shown for the
// selected track same as the others, not pooled across all of them — mixing
// tracks into one trend would hide whether you're actually improving at any
// specific one.
struct LapTrendsView: View {
    let sessions: [LapRecord]
    @Environment(\.dismiss) var dismiss
    @State private var selectedTrack: String = ""
    // Aug 24, 2026 — Lap Compare. This screen already has exactly the
    // per-track context Compare Laps wants to be pre-filtered to, so the
    // link lives here rather than needing its own separate entry point.
    @State private var showCompareLaps = false

    private var trackNames: [String] {
        // Most-recent-first order, so a rider's current track naturally
        // sorts to the top of the picker.
        var seen = Set<String>()
        var ordered: [String] = []
        for session in sessions.sorted(by: { $0.date > $1.date }) {
            let name = session.trackName.isEmpty ? "Track Session" : session.trackName
            if !seen.contains(name) {
                seen.insert(name)
                ordered.append(name)
            }
        }
        return ordered
    }

    // Oldest-to-newest, most recent 15 sessions at the selected track — reads
    // left-to-right as "getting more recent," same convention as solo rides.
    private var trendSessions: [LapRecord] {
        sessions
            .filter { ($0.trackName.isEmpty ? "Track Session" : $0.trackName) == selectedTrack }
            .sorted { $0.date < $1.date }
            .suffix(15)
            .map { $0 }
    }

    private var bestLapEver: Double {
        trendSessions.compactMap { $0.bestLapTime > 0 ? $0.bestLapTime : nil }.min() ?? 0
    }

    private var averageTrackScore: Int {
        let scores = trendSessions.compactMap { $0.analytics?.trackScore }
        guard !scores.isEmpty else { return 0 }
        return scores.reduce(0, +) / scores.count
    }

    var body: some View {
            ZStack {
                Color.prBg.ignoresSafeArea()
                if trackNames.isEmpty {
                    VStack(spacing: 12) {
                        Text("TRACK TRENDS").font(.system(size: 10, weight: .heavy)).tracking(2.5).foregroundColor(.prCoral)
                        Text("Not enough data yet").font(.system(size: 24, weight: .bold, design: .rounded)).foregroundColor(.prInk)
                        Text("Record a few Track Mode sessions and your progress will appear here.")
                            .font(.system(size: 13, weight: .medium)).foregroundColor(.prMuted)
                            .multilineTextAlignment(.center).padding(.horizontal, 44)
                    }
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            PRWebPageHeader(
                                eyebrow: "TRACK ANALYTICS",
                                title: "Progress over time",
                                subtitle: "Compare consistency, pace and score"
                            )

                            trackPicker
                                .padding(.bottom, 6)

                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(selectedTrack.uppercased()).font(.system(size: 10, weight: .heavy)).tracking(1.8).foregroundColor(.prCoral)
                                    Text("Your last \(trendSessions.count) sessions")
                                        .font(.system(size: 16, weight: .bold, design: .rounded)).foregroundColor(.prInk)
                                }
                                Spacer()
                                Button(action: { showCompareLaps = true }) {
                                    Image(systemName: "chart.xyaxis.line")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(.prInk)
                                        .frame(width: 38, height: 38)
                                        .background(.ultraThinMaterial)
                                        .clipShape(Circle())
                                        .overlay(Circle().stroke(Color.prBorder, lineWidth: 1))
                                }
                                .accessibilityLabel("Compare laps")
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 10)
                            .padding(.bottom, 16)

                            if trendSessions.count < 2 {
                                PRWebSurface(cornerRadius: 20) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Need another run")
                                            .font(.system(size: 17, weight: .bold))
                                            .foregroundColor(.prInk)
                                        Text("Trends compare the same track across sessions. Run this track again to unlock the graphs.")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(.prMuted)
                                    }
                                    .padding(20)
                                }
                                .padding(.horizontal, 20)
                            } else {
                                PRWebMetricStrip(metrics: [
                                    ("\(averageTrackScore)", "Avg Score"),
                                    (bestLapEver > 0 ? LapEngine.formatLapTime(bestLapEver) : "--:--", "Best Lap"),
                                    ("\(trendSessions.count)", "Sessions")
                                ])
                                .padding(.bottom, 18)

                                PRWebSectionLabel(title: "Pace", detail: "Lower is faster")
                                TrendChartCard(title: "Best Lap Trend", subtitle: "your best lap from each session") {
                                    Chart(Array(trendSessions.enumerated()), id: \.offset) { index, session in
                                        if session.bestLapTime > 0 {
                                            LineMark(x: .value("Session", index), y: .value("Best Lap", session.bestLapTime))
                                                .foregroundStyle(Color.prCoral)
                                                .symbol(Circle())
                                                .interpolationMethod(.catmullRom)
                                        }
                                    }
                                }

                                PRWebSectionLabel(title: "Performance", detail: "0–100")
                                TrendChartCard(title: "Track Score", subtitle: "consistency + smoothness combined") {
                                    Chart(Array(trendSessions.enumerated()), id: \.offset) { index, session in
                                        if let score = session.analytics?.trackScore {
                                            LineMark(x: .value("Session", index), y: .value("Score", score))
                                                .foregroundStyle(Color.prTeal)
                                                .symbol(Circle())
                                                .interpolationMethod(.catmullRom)
                                        }
                                    }
                                    .chartYScale(domain: 0...100)
                                }

                                PRWebSectionLabel(title: "Consistency", detail: "0–100")
                                TrendChartCard(title: "Lap Consistency", subtitle: "how tightly your laps clustered") {
                                    Chart(Array(trendSessions.enumerated()), id: \.offset) { index, session in
                                        if let consistency = session.analytics?.consistencyScore {
                                            BarMark(x: .value("Session", index), y: .value("Consistency", consistency))
                                                .foregroundStyle(Color(red: 0.18, green: 0.62, blue: 0.36))
                                        }
                                    }
                                    .chartYScale(domain: 0...100)
                                }

                                Text("Oldest session is on the left; most recent is on the right. Sessions with only 0–1 completed laps do not receive a Track Score.")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.prMuted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 20)
                                    .padding(.top, 8)
                            }
                        }
                        .padding(.bottom, 30)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .topTrailing) {
                Button("Done") { dismiss() }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.prInk)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.prBorder, lineWidth: 1))
                    .padding(.trailing, 18)
                    .padding(.top, 18)
            }
            .onAppear {
                if selectedTrack.isEmpty { selectedTrack = trackNames.first ?? "" }
            }
            .fullScreenCover(isPresented: $showCompareLaps) {
                LapCompareView(initialTrackFilter: selectedTrack)
            }
    }

    private var trackPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(trackNames, id: \.self) { name in
                    Button(action: { selectedTrack = name }) {
                        Text(name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(selectedTrack == name ? .white : .prMuted)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(selectedTrack == name ? Color.prCoral : Color.prCardBg)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.prBorder, lineWidth: selectedTrack == name ? 0 : 1))
                            .cornerRadius(10)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

#Preview { LapTrendsView(sessions: []) }
