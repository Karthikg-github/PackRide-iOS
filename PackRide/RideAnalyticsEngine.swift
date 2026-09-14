import Foundation
import CoreLocation

// MARK: - Ride Analytics
// Post-ride analysis computed once, right when a ride ends, from the GPX file
// that's already being recorded for every ride (see GPXRecorder.swift). This
// is a heuristic estimate built from phone sensors (GPS + accelerometer +
// gyroscope) — not a lab-grade instrument. It's meant to give a rider a
// useful sense of how a ride went (smooth vs. abrupt), not a precise
// telemetry reading. Scoped to solo rides for now, since that's where GPX
// recording + G-force/lean capture already exists end to end.
struct RideAnalyticsSummary: Codable, Equatable {
    var rideScore: Int              // 0-100, higher = smoother ride
    var cornerCount: Int
    var smoothCornerCount: Int
    var hardBrakeCount: Int
    var hardAccelCount: Int
    var maxLeanAngle: Double        // degrees, unsigned (magnitude)

    static let empty = RideAnalyticsSummary(
        rideScore: 100, cornerCount: 0, smoothCornerCount: 0,
        hardBrakeCount: 0, hardAccelCount: 0, maxLeanAngle: 0
    )

    var scoreGrade: String {
        switch rideScore {
        case 90...100: return "Smooth"
        case 75..<90: return "Solid"
        case 55..<75: return "Mixed"
        default: return "Aggressive"
        }
    }
}

enum RideAnalyticsEngine {
    // MARK: - Parsed point (mirrors GPXRecorder's fields, read back from XML)
    struct AnalyzedPoint {
        let lat: Double
        let lng: Double
        let speedMph: Double
        let gforce: Double
        let lean: Double
        let timestamp: Date
    }

    /// Parses a saved GPX file and computes the full analytics summary.
    /// Returns nil if the file can't be found/parsed or has too few points
    /// to meaningfully analyze (e.g. a ride that ended almost immediately).
    static func analyze(gpxFilePath: String) -> RideAnalyticsSummary? {
        guard let data = GPXStorage.contents(gpxFilePath),
              let xmlString = String(data: data, encoding: .utf8) else { return nil }
        let points = parsePoints(from: xmlString)
        guard points.count >= 5 else { return nil }
        return analyze(points: points)
    }

    // MARK: - XML parsing (same regex approach used elsewhere for GPX, e.g. RideHistoryView)
    private static func parsePoints(from xmlString: String) -> [AnalyzedPoint] {
        var points: [AnalyzedPoint] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        let blocks = xmlString.components(separatedBy: "<trkpt ")
        for block in blocks.dropFirst() {
            guard let latRange = block.range(of: #"lat="([\-\d.]+)""#, options: .regularExpression),
                  let lngRange = block.range(of: #"lon="([\-\d.]+)""#, options: .regularExpression) else { continue }
            let latStr = block[latRange].replacingOccurrences(of: "lat=", with: "").replacingOccurrences(of: "\"", with: "")
            let lngStr = block[lngRange].replacingOccurrences(of: "lon=", with: "").replacingOccurrences(of: "\"", with: "")
            guard let lat = Double(latStr), let lng = Double(lngStr) else { continue }

            var spd = 0.0, gf = 1.0, lean = 0.0
            var timestamp = Date()

            if let spdRange = block.range(of: #"<speed>([\-\d.]+)</speed>"#, options: .regularExpression) {
                let spdStr = block[spdRange].replacingOccurrences(of: "<speed>", with: "").replacingOccurrences(of: "</speed>", with: "")
                spd = Double(spdStr) ?? 0
            }
            if let gfRange = block.range(of: #"<packride:gforce>([\-\d.]+)</packride:gforce>"#, options: .regularExpression) {
                let gfStr = block[gfRange].replacingOccurrences(of: "<packride:gforce>", with: "").replacingOccurrences(of: "</packride:gforce>", with: "")
                gf = Double(gfStr) ?? 1.0
            }
            if let leanRange = block.range(of: #"<packride:lean>([\-\d.]+)</packride:lean>"#, options: .regularExpression) {
                let leanStr = block[leanRange].replacingOccurrences(of: "<packride:lean>", with: "").replacingOccurrences(of: "</packride:lean>", with: "")
                lean = Double(leanStr) ?? 0
            }
            if let timeRange = block.range(of: #"<time>([^<]+)</time>"#, options: .regularExpression) {
                let timeStr = block[timeRange].replacingOccurrences(of: "<time>", with: "").replacingOccurrences(of: "</time>", with: "")
                timestamp = iso.date(from: String(timeStr)) ?? timestamp
            }

            if lat != 0 && lng != 0 {
                points.append(AnalyzedPoint(lat: lat, lng: lng, speedMph: spd * 2.23694, gforce: gf, lean: lean, timestamp: timestamp))
            }
        }
        return points
    }

    // MARK: - Analysis
    private static func analyze(points: [AnalyzedPoint]) -> RideAnalyticsSummary {
        var cornerCount = 0
        var smoothCornerCount = 0
        var hardBrakeCount = 0
        var hardAccelCount = 0
        var maxLean = 0.0

        var inCorner = false
        var cornerHadHighG = false

        for i in 1..<points.count {
            let prev = points[i - 1]
            let curr = points[i]
            let dt = curr.timestamp.timeIntervalSince(prev.timestamp)
            guard dt > 0, dt < 5 else { continue } // skip gaps (e.g. a brief signal loss)

            maxLean = max(maxLean, abs(curr.lean))

            // Hard brake / hard accel — a speed change per second beyond typical
            // relaxed riding, only counted while actually moving (excludes stop
            // sign creep/parking lot noise).
            guard curr.speedMph > 5 || prev.speedMph > 5 else { continue }
            let speedDeltaPerSec = (curr.speedMph - prev.speedMph) / dt
            if speedDeltaPerSec < -8 { hardBrakeCount += 1 }
            if speedDeltaPerSec > 7 { hardAccelCount += 1 }

            // Corner detection: sustained lean beyond a small threshold while
            // moving counts as "in a corner." A corner is scored "smooth" if
            // G-force never spiked hard during it (i.e. no abrupt mid-corner
            // braking/acceleration), "abrupt" otherwise.
            let leaning = abs(curr.lean) > 8 && curr.speedMph > 8
            if leaning && !inCorner {
                inCorner = true
                cornerHadHighG = false
            }
            if inCorner {
                if curr.gforce > 1.4 { cornerHadHighG = true }
                if !leaning {
                    inCorner = false
                    cornerCount += 1
                    if !cornerHadHighG { smoothCornerCount += 1 }
                }
            }
        }
        if inCorner {
            cornerCount += 1
            if !cornerHadHighG { smoothCornerCount += 1 }
        }

        // Score: start at 100, deduct for harsh events. Deductions are capped per
        // category so one rough stretch of road doesn't tank the whole ride's
        // score, and floored at 40 so the number stays meaningful/encouraging
        // rather than reading as "broken."
        var score = 100
        score -= min(hardBrakeCount * 3, 24)
        score -= min(hardAccelCount * 2, 16)
        let abruptCorners = cornerCount - smoothCornerCount
        score -= min(abruptCorners * 2, 20)
        score = max(score, 40)

        return RideAnalyticsSummary(
            rideScore: score,
            cornerCount: cornerCount,
            smoothCornerCount: smoothCornerCount,
            hardBrakeCount: hardBrakeCount,
            hardAccelCount: hardAccelCount,
            maxLeanAngle: maxLean
        )
    }
}

// MARK: - Track/Lap Analytics
// Track riding is judged differently than street riding — consistency (how
// tightly your lap times cluster together) is usually the first thing that
// improves as a rider gets better at a track, often before their outright
// pace does. Track Score is a composite of that consistency (from the lap
// splits themselves) and the same GPS/motion smoothness analysis used for
// solo rides (corner smoothness, hard brake/accel events, lean angle),
// applied to the session's own GPX recording.
struct LapAnalyticsSummary: Codable, Equatable {
    var trackScore: Int          // 0-100 composite of consistency + smoothness
    var consistencyScore: Int    // 0-100, tighter lap-time spread = higher
    var smoothnessScore: Int     // 0-100, same GPS/motion analysis as solo rides
    var lapTimeStdDev: Double    // seconds, standard deviation across laps
    var cornerCount: Int
    var smoothCornerCount: Int
    var hardBrakeCount: Int
    var hardAccelCount: Int
    var maxLeanAngle: Double

    static let empty = LapAnalyticsSummary(
        trackScore: 100, consistencyScore: 100, smoothnessScore: 100,
        lapTimeStdDev: 0, cornerCount: 0, smoothCornerCount: 0,
        hardBrakeCount: 0, hardAccelCount: 0, maxLeanAngle: 0
    )

    var scoreGrade: String {
        switch trackScore {
        case 90...100: return "Dialed In"
        case 75..<90: return "Solid"
        case 55..<75: return "Building"
        default: return "Rough Session"
        }
    }
}

enum LapAnalyticsEngine {
    /// Computes a composite track score from the session's lap splits (for
    /// consistency) and its recorded GPX, if any (for smoothness). Returns
    /// nil if there aren't at least 2 completed laps — consistency has
    /// nothing to measure a spread against with only one lap (or none),
    /// same as how RideAnalyticsEngine needs a minimum number of GPS points.
    static func analyze(gpxFilePath: String?, laps: [Double]) -> LapAnalyticsSummary? {
        guard laps.count >= 2 else { return nil }

        let consistency = consistencyScore(for: laps)

        // Smoothness reuses the exact same GPS+motion analysis as solo
        // rides — a hard brake or an abrupt corner mid-lap is just as real
        // on a track as on the street. Defaults to a perfect 100/no events
        // if there's no GPX (e.g. it failed to save) rather than failing
        // the whole score outright, since consistency alone is still useful.
        var smoothness = 100
        var corner = 0, smoothCorner = 0, hardBrake = 0, hardAccel = 0
        var maxLean = 0.0
        if let gpxFilePath, let rideAnalytics = RideAnalyticsEngine.analyze(gpxFilePath: gpxFilePath) {
            smoothness = rideAnalytics.rideScore
            corner = rideAnalytics.cornerCount
            smoothCorner = rideAnalytics.smoothCornerCount
            hardBrake = rideAnalytics.hardBrakeCount
            hardAccel = rideAnalytics.hardAccelCount
            maxLean = rideAnalytics.maxLeanAngle
        }

        let composite = Int(((Double(consistency) + Double(smoothness)) / 2).rounded())

        return LapAnalyticsSummary(
            trackScore: composite, consistencyScore: consistency, smoothnessScore: smoothness,
            lapTimeStdDev: stdDev(of: laps), cornerCount: corner, smoothCornerCount: smoothCorner,
            hardBrakeCount: hardBrake, hardAccelCount: hardAccel, maxLeanAngle: maxLean
        )
    }

    /// 0-100, scored by *percentage* spread (coefficient of variation)
    /// rather than raw seconds — a 2-second spread matters a lot more on a
    /// 45-second lap than a 3-minute one. Tuned so ~10% spread lands around
    /// 60 and a couple percent spread reads as 90+.
    private static func consistencyScore(for laps: [Double]) -> Int {
        let mean = laps.reduce(0, +) / Double(laps.count)
        guard mean > 0 else { return 100 }
        let coefficientOfVariation = stdDev(of: laps) / mean
        let score = 100 - Int((coefficientOfVariation * 400).rounded())
        return min(max(score, 0), 100)
    }

    private static func stdDev(of values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count - 1)
        return sqrt(variance)
    }
}
