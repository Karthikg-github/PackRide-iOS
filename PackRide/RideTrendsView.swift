import SwiftUI
import Charts

// MARK: - Ride Trends View
// Shows how riding has changed over the last several rides — ride score, top
// speed, and corner count, each as a simple trend chart. Only rides that have
// analytics (i.e. recorded after the Advanced Ride Analytics feature shipped)
// are included; older rides recorded before that just don't have the data.
struct RideTrendsView: View {
    let rides: [RideRecord]

    // Oldest-to-newest, most recent 15 rides with analytics — a trend chart
    // reads left-to-right as "getting more recent," and 15 keeps it readable
    // on a phone screen without feeling too zoomed out.
    private var trendRides: [RideRecord] {
        rides
            .filter { $0.analytics != nil }
            .sorted { $0.date < $1.date }
            .suffix(15)
    }

    private var averageScore: Int {
        let scores = trendRides.compactMap { $0.analytics?.rideScore }
        guard !scores.isEmpty else { return 0 }
        return scores.reduce(0, +) / scores.count
    }

    private var totalCorners: Int {
        trendRides.compactMap { $0.analytics?.cornerCount }.reduce(0, +)
    }

    private var totalHardEvents: Int {
        trendRides.reduce(0) { $0 + ($1.analytics?.hardBrakeCount ?? 0) + ($1.analytics?.hardAccelCount ?? 0) }
    }

    var body: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    PRWebPageHeader(
                        eyebrow: "Trends",
                        title: "Riding Trends",
                        subtitle: trendRides.isEmpty ? "Track your progress ride over ride" : "Your last \(trendRides.count) analyzed rides"
                    )

                    if trendRides.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 30)).foregroundColor(.prMuted)
                            Text("Not enough data yet")
                                .font(.system(size: 16, weight: .bold)).foregroundColor(.prInk)
                            Text("Trends show up once you've recorded a few solo rides.")
                                .font(.system(size: 13)).foregroundColor(.prMuted)
                                .multilineTextAlignment(.center).padding(.horizontal, 40)
                        }
                        .padding(.top, 20)
                        .padding(.bottom, 40)
                    } else {
                        VStack(spacing: 20) {
                            HStack(spacing: 10) {
                                AllTimeCard(icon: "gauge.medium", value: "\(averageScore)", label: "Avg Ride Score", color: .prCoral)
                                AllTimeCard(icon: "arrow.triangle.swap", value: "\(totalCorners)", label: "Corners Logged", color: .prTeal)
                                AllTimeCard(icon: "exclamationmark.triangle.fill", value: "\(totalHardEvents)", label: "Hard Events", color: Color(red: 0.827, green: 0.231, blue: 0.173))
                            }
                            .padding(.horizontal, 16)

                            TrendChartCard(title: "Ride Score", subtitle: "Higher = smoother riding") {
                                Chart(Array(trendRides.enumerated()), id: \.offset) { index, ride in
                                    LineMark(
                                        x: .value("Ride", index),
                                        y: .value("Score", ride.analytics?.rideScore ?? 0)
                                    )
                                    .foregroundStyle(Color.prCoral)
                                    .symbol(Circle())
                                    .interpolationMethod(.catmullRom)
                                }
                                .chartYScale(domain: 0...100)
                            }

                            TrendChartCard(title: "Top Speed", subtitle: MeasurementUnits.current == .metric ? "km/h, per ride" : "mph, per ride") {
                                Chart(Array(trendRides.enumerated()), id: \.offset) { index, ride in
                                    BarMark(
                                        x: .value("Ride", index),
                                        y: .value("Top Speed", MeasurementUnits.current == .metric ? ride.maxSpeed * 1.609344 : ride.maxSpeed)
                                    )
                                    .foregroundStyle(Color.prTeal)
                                }
                            }

                            TrendChartCard(title: "Corners per Ride", subtitle: "smooth vs. total") {
                                Chart(Array(trendRides.enumerated()), id: \.offset) { index, ride in
                                    BarMark(
                                        x: .value("Ride", index),
                                        y: .value("Total", ride.analytics?.cornerCount ?? 0)
                                    )
                                    .foregroundStyle(Color.prBorder)
                                    BarMark(
                                        x: .value("Ride", index),
                                        y: .value("Smooth", ride.analytics?.smoothCornerCount ?? 0)
                                    )
                                    .foregroundStyle(Color(red: 0.180, green: 0.620, blue: 0.357))
                                }
                            }

                            HStack(spacing: 6) {
                                Image(systemName: "info.circle").font(.system(size: 10)).foregroundColor(.prMuted)
                                Text("Left = oldest of your last \(trendRides.count) analyzed rides, right = most recent.")
                                    .font(.system(size: 10)).foregroundColor(.prMuted)
                            }
                            .padding(.horizontal, 16)
                        }
                        .padding(.top, 4)
                        .padding(.bottom, 30)
                    }
                }
            }
        }
        .navigationBarHidden(true)
    }
}

// MARK: - Trend Chart Card
struct TrendChartCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .bold)).foregroundColor(.prInk)
                Text(subtitle).font(.system(size: 11)).foregroundColor(.prMuted)
            }
            content
                .frame(height: 140)
        }
        .padding(16)
        .background(Color.prCardBg)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.prBorder, lineWidth: 1))
        .padding(.horizontal, 16)
    }
}

#Preview { NavigationStack { RideTrendsView(rides: []) } }
