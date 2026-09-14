import Foundation
import CoreLocation

// MARK: - Lap Compare Engine
// The math behind Track Mode's "Compare Laps" feature (LapCompareView.swift):
// reconstructing individual lap traces out of one session's continuous GPX
// recording (Part A), then distance-aligning any two lap traces — same
// session or two entirely different ones, own or a friend's — onto a shared
// comparison (Part B). Kept as its own file, separate from the UI, since both
// halves are pure data transforms with no SwiftUI/Firebase dependency.

// MARK: - Part A: Reconstructing per-lap traces from a session GPX

/// One point inside a single lap's own trace — distance/time measured from
/// scratch relative to THIS lap's own start, not the session's.
struct LapTracePoint {
    let distanceIntoLap: Double   // meters, cumulative point-to-point distance since this lap started
    let timeIntoLap: Double       // seconds, elapsed since this lap started
    let sample: GPXPointSample    // the underlying GPX point (position, speed, lean, elevation, gforce)
    /// Signed g's derived from this point's own speed change vs. the previous
    /// point in the SAME lap trace (0 for a lap's very first point, which has
    /// no predecessor to diff against). Negative = decelerating (braking),
    /// positive = accelerating. See LapReconstructor.deriveGForces below for
    /// exactly how this is computed — same speed-delta approach
    /// RideAnalyticsEngine already uses for hard-brake/hard-accel detection,
    /// just expressed in g's instead of thresholded into a yes/no event.
    var signedGForce: Double = 0
    var brakeG: Double { max(0, -signedGForce) }
    var accelG: Double { max(0, signedGForce) }
}

/// One lap's full reconstructed trace.
struct ReconstructedLap {
    let lapIndex: Int             // 0-based index into the session's laps array
    let lapDuration: Double       // seconds — the recorded split time for this lap
    let points: [LapTracePoint]   // in order, distanceIntoLap ascending
    var lapNumber: Int { lapIndex + 1 }
    /// The lap's own total covered distance — the last point's
    /// distanceIntoLap, or 0 if the lap has no points at all (e.g. a very
    /// short/glitchy lap with no usable GPS fixes).
    var totalDistance: Double { points.last?.distanceIntoLap ?? 0 }
}

enum LapReconstructor {
    /// Reconstructs every lap's own point trace from (a) a session's full,
    /// continuous GPX point stream and (b) its list of lap durations —
    /// there's no per-lap boundary marker stored anywhere; a lap's window is
    /// purely "however many seconds after the previous lap ended."
    ///
    /// Assumption (confirmed by how ActiveLapView.startSession() calls
    /// `gpxRecorder.startRecording()` and `lapEngine.begin()` back to back,
    /// the same instant Lap 1's own timer starts): the GPX's first point is
    /// the session's t=0, i.e. also lap 1's t=0. Every point's elapsed time
    /// since session start is therefore just its timestamp minus the GPX's
    /// first point's timestamp (GPXPointSample.elapsedSinceStart already is
    /// exactly this).
    ///
    /// Distance/time into each lap is computed from scratch, per lap,
    /// resetting to zero at every boundary — the same idea as LapEngine's own
    /// live per-lap trace (LapModeView.swift, `currentLapSamples`/
    /// `updateTrace`), just computed after the fact from a stored file
    /// instead of live GPS.
    ///
    /// Correctness detail this was specifically built to get right: points
    /// recorded AFTER the session's final lap finished (riding back to the
    /// pits, sitting at the line before "End Session" was tapped) must never
    /// bleed into that last lap's trace. Two separate guards enforce this:
    /// the lap-advance loop is capped so it can never step past the last lap
    /// index, and there's an explicit break the moment a point's own elapsed
    /// time exceeds the last lap's own end time — see the worked example in
    /// the doc comment on `lastLapEndTime` below.
    static func reconstructLaps(points: [GPXPointSample], lapDurations: [Double], lapStartTimestamps: [Int64] = []) -> [ReconstructedLap] {
        guard !points.isEmpty, !lapDurations.isEmpty else { return [] }

        // New sessions persist the actual line-crossing timestamp that began
        // every completed lap. This removes the approach/out-lap and cooldown
        // from comparison traces. Legacy sessions fall through to the former
        // duration-only approximation below.
        if lapStartTimestamps.count >= lapDurations.count {
            return lapDurations.indices.map { index in
                let start = Date(timeIntervalSince1970: Double(lapStartTimestamps[index]) / 1000)
                let end = start.addingTimeInterval(lapDurations[index])
                let samples = points.filter { $0.timestamp >= start && $0.timestamp <= end }
                var distance = 0.0
                var trace: [LapTracePoint] = []
                for sample in samples {
                    if let previous = trace.last?.sample { distance += sample.distance(from: previous) }
                    trace.append(LapTracePoint(distanceIntoLap: distance,
                                               timeIntoLap: sample.timestamp.timeIntervalSince(start),
                                               sample: sample))
                }
                return deriveGForces(ReconstructedLap(lapIndex: index, lapDuration: lapDurations[index], points: trace))
            }
        }

        // Cumulative end-time-since-session-start for each lap, e.g. laps
        // [42.0, 41.5, 43.0] -> boundaries [42.0, 83.5, 126.5]. Lap k (0-based)
        // covers session-elapsed times in [boundaries[k-1], boundaries[k]),
        // with boundaries[-1] treated as 0.
        var boundaries: [Double] = []
        var running = 0.0
        for duration in lapDurations {
            running += duration
            boundaries.append(running)
        }
        // The instant the LAST lap's own finish crossing happened. Any point
        // whose elapsed time is past this, however long the recording kept
        // running afterward, does not belong to any lap.
        //
        // Worked example: laps = [42.0, 41.5, 43.0] -> lastLapEndTime = 126.5.
        // A point at elapsed = 126.4 (just before the finish line) is kept —
        // it's the last lap's final data point. A point at elapsed = 140.0
        // (the rider coasting back to the pits after the session's own last
        // lap already finished) hits `elapsed > lastLapEndTime` below and
        // breaks the loop immediately, so it — and everything captured after
        // it — never gets added to lap 3's distance/time totals.
        let lastLapEndTime = boundaries.last!
        let lastLapIndex = boundaries.count - 1

        var traces: [ReconstructedLap] = []
        var lapIndex = 0
        var lapPoints: [LapTracePoint] = []
        var lapStartElapsed = 0.0
        var cumulativeDistance = 0.0
        var previousSample: GPXPointSample? = nil

        for sample in points {
            let elapsed = sample.elapsedSinceStart

            // Past the last lap's own finish — stop entirely. (See the worked
            // example above.)
            if elapsed > lastLapEndTime { break }

            // Advance into whichever lap this point's elapsed time actually
            // falls in. Capped at `lastLapIndex` so this can NEVER step past
            // the final lap, even if `elapsed` somehow lands past every
            // boundary in one jump (e.g. a GPS gap that spans a lap) — the
            // `elapsed > lastLapEndTime` break above is what actually excludes
            // post-session points; this cap just guarantees the loop itself
            // has nowhere further to advance to.
            while lapIndex < lastLapIndex && elapsed >= boundaries[lapIndex] {
                traces.append(ReconstructedLap(lapIndex: lapIndex, lapDuration: lapDurations[lapIndex], points: lapPoints))
                lapIndex += 1
                lapPoints = []
                cumulativeDistance = 0
                previousSample = nil
                lapStartElapsed = boundaries[lapIndex - 1]
            }

            let timeIntoLap = elapsed - lapStartElapsed
            var stepDistance = 0.0
            if let previousSample {
                stepDistance = sample.distance(from: previousSample)
            }
            cumulativeDistance += stepDistance
            previousSample = sample

            lapPoints.append(LapTracePoint(distanceIntoLap: cumulativeDistance, timeIntoLap: timeIntoLap, sample: sample))
        }

        // Whatever lap was still being accumulated when the walk ended —
        // whether that's because the points ran out naturally or because the
        // `elapsed > lastLapEndTime` break fired — never goes through the
        // while-loop's own "finalize and advance" branch (there was no next
        // boundary crossing to trigger it), so it has to be flushed here
        // unconditionally. This also covers the unhappy case of a GPX that
        // stops recording early (a crash, a killed app) before every lap's
        // boundary was ever reached: whatever partial trace exists for the
        // lap in progress is still returned rather than silently dropped —
        // downstream (LapComparisonBuilder) already treats a too-short trace
        // as "not enough data to compare," so a partial/empty lap here is
        // handled safely, not fatally.
        traces.append(ReconstructedLap(lapIndex: lapIndex, lapDuration: lapDurations[lapIndex], points: lapPoints))

        return traces.map(deriveGForces)
    }

    /// Fills in each point's `signedGForce` from the speed change to the
    /// previous point in the SAME lap trace — the same speed-delta-per-second
    /// approach RideAnalyticsEngine.analyze(points:) already uses to flag
    /// hard-brake/hard-accel events (`(curr.speedMph - prev.speedMph) / dt`),
    /// reused here instead of a different formula, just converted from
    /// mph-per-second into g's (standard gravity = 9.80665 m/s²) and kept as
    /// a continuous signed value rather than thresholded into a boolean
    /// event. Same dt guard as RideAnalyticsEngine (skip gaps ≥5s so a brief
    /// GPS/signal dropout doesn't register as a massive speed change).
    private nonisolated static func deriveGForces(_ lap: ReconstructedLap) -> ReconstructedLap {
        guard lap.points.count > 1 else { return lap }
        var points = lap.points
        for i in 1..<points.count {
            let prev = points[i - 1].sample
            let curr = points[i].sample
            let dt = points[i].timeIntoLap - points[i - 1].timeIntoLap
            guard dt > 0, dt < 5 else { continue }
            let speedDeltaMphPerSec = (curr.speedMph - prev.speedMph) / dt
            // mph/s -> m/s² -> g's
            let g = (speedDeltaMphPerSec * 0.44704) / 9.80665
            points[i].signedGForce = g
        }
        return ReconstructedLap(lapIndex: lap.lapIndex, lapDuration: lap.lapDuration, points: points)
    }
}

// MARK: - Part B: Comparing two arbitrary laps

enum LapCompareMetric: String, CaseIterable, Identifiable {
    case speed = "Speed"
    case lean = "Lean"
    case elevation = "Elevation"
    case brakeG = "Brake G"
    case accelG = "Accel G"

    var id: String { rawValue }

    var unit: String {
        switch self {
        case .speed: return MeasurementUnits.current == .metric ? "km/h" : "mph"
        case .lean: return "°"
        case .elevation: return MeasurementUnits.current == .metric ? "m" : "ft"
        case .brakeG, .accelG: return "g"
        }
    }

    func value(_ point: LapTracePoint) -> Double {
        switch self {
        case .speed: return MeasurementUnits.current == .metric ? point.sample.speedMph * 1.609344 : point.sample.speedMph
        case .lean: return abs(point.sample.leanDegrees)
        case .elevation: return MeasurementUnits.current == .metric ? point.sample.elevation : point.sample.elevation * 3.28084
        case .brakeG: return point.brakeG
        case .accelG: return point.accelG
        }
    }
}

/// One distance-aligned sample across both laps.
struct LapCompareSample: Identifiable {
    var id: Double { distanceMeters }
    let distanceMeters: Double
    let lapATime: Double
    let lapBTime: Double
    /// Lap B's elapsed time at this distance minus Lap A's — negative means
    /// Lap B is running AHEAD of Lap A's pace here (faster/green), positive
    /// means Lap B is BEHIND (slower/red). Same sign convention as
    /// LapEngine.liveDeltaSeconds.
    var deltaSeconds: Double { lapBTime - lapATime }
    let metricsA: [LapCompareMetric: Double]
    let metricsB: [LapCompareMetric: Double]
}

struct LapCompareResult {
    let samples: [LapCompareSample]
    let lapADuration: Double
    let lapBDuration: Double
    /// The distance both laps are actually compared over — always the
    /// SHORTER lap's own total covered distance, per the "never extrapolate
    /// past where a lap's real trace actually ends" requirement.
    let comparedDistance: Double
    /// The result at the timing line must come from the recorded lap splits,
    /// not the final distance-aligned telemetry sample. GPS traces commonly
    /// stop a few metres apart, so the latter may represent two different
    /// physical positions and can disagree noticeably with the lap timer.
    var finishDelta: Double { lapBDuration - lapADuration }
}

enum LapComparisonBuilder {
    /// Distance-aligns two lap traces onto a shared, evenly-spaced sample
    /// grid (default 40 points) via linear interpolation of each lap's OWN
    /// trace, then reads off every comparison metric plus the delta-seconds-
    /// at-distance line at each grid point.
    ///
    /// Capped at the SHORTER lap's own covered distance — `comparedDistance`
    /// below is `min(lapA.totalDistance, lapB.totalDistance)`, and every grid
    /// point sits inside `0...comparedDistance`, so interpolation is always
    /// reading between two REAL recorded points on both laps; it never
    /// extrapolates past where either lap's actual trace ends.
    ///
    /// Worked example: Lap A covers 1200m total, Lap B covers 950m total
    /// (say Lap B was cut short, or is just a shorter layout/line). With the
    /// default 40 points, comparedDistance = min(1200, 950) = 950, and the
    /// grid is 40 evenly spaced points from 0 to 950 (step ≈ 24.4m) — the
    /// last grid point sits at distance 950, exactly Lap B's own last
    /// recorded point, and Lap A is simply read at that same 950m mark
    /// (which is well inside its own 1200m trace, so still real
    /// interpolation, never a guess past its end). The 250m of Lap A beyond
    /// 950m is never sampled at all.
    static func build(lapA: ReconstructedLap, lapB: ReconstructedLap, sampleCount: Int = 40) -> LapCompareResult? {
        guard lapA.points.count >= 2, lapB.points.count >= 2 else { return nil }
        let comparedDistance = min(lapA.totalDistance, lapB.totalDistance)
        guard comparedDistance > 0 else { return nil }

        let count = max(sampleCount, 2)
        let step = comparedDistance / Double(count - 1)

        var samples: [LapCompareSample] = []
        samples.reserveCapacity(count)
        for i in 0..<count {
            // Last point pinned exactly to comparedDistance rather than
            // `Double(i) * step` (which can land a hair short/over due to
            // floating-point step accumulation) — guarantees the final
            // sample is exactly at the shorter lap's own real endpoint.
            let distance = (i == count - 1) ? comparedDistance : Double(i) * step

            let timeA = interpolate(lapA.points, atDistance: distance) { $0.timeIntoLap }
            let timeB = interpolate(lapB.points, atDistance: distance) { $0.timeIntoLap }

            var metricsA: [LapCompareMetric: Double] = [:]
            var metricsB: [LapCompareMetric: Double] = [:]
            for metric in LapCompareMetric.allCases {
                metricsA[metric] = interpolate(lapA.points, atDistance: distance) { metric.value($0) }
                metricsB[metric] = interpolate(lapB.points, atDistance: distance) { metric.value($0) }
            }

            samples.append(LapCompareSample(
                distanceMeters: distance, lapATime: timeA, lapBTime: timeB,
                metricsA: metricsA, metricsB: metricsB
            ))
        }

        return LapCompareResult(
            samples: samples, lapADuration: lapA.lapDuration, lapBDuration: lapB.lapDuration,
            comparedDistance: comparedDistance
        )
    }

    /// Linearly interpolates `extractor`'s value at `atDistance` from a lap's
    /// own ascending-distance point trace. Below the first point's distance,
    /// clamps to the first point's value; at/after the last point's distance,
    /// clamps to the last point's value — the same "never extrapolate past a
    /// real recorded point" clamping LapEngine.interpolatedTime already uses
    /// for the live best-lap-pace comparison, reused here for consistency.
    /// `build` above only ever calls this with `atDistance` inside
    /// `0...comparedDistance`, i.e. inside both laps' own real coverage, so
    /// in practice this only ever does genuine interpolation — the clamps are
    /// a defensive floor/ceiling, not something the capped grid should hit.
    private static func interpolate(_ points: [LapTracePoint], atDistance: Double, _ extractor: (LapTracePoint) -> Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if atDistance <= first.distanceIntoLap { return extractor(first) }
        if atDistance >= last.distanceIntoLap { return extractor(last) }

        for i in 1..<points.count {
            let prev = points[i - 1]
            let curr = points[i]
            guard atDistance <= curr.distanceIntoLap else { continue }
            guard curr.distanceIntoLap > prev.distanceIntoLap else { return extractor(prev) }
            let t = (atDistance - prev.distanceIntoLap) / (curr.distanceIntoLap - prev.distanceIntoLap)
            return extractor(prev) + t * (extractor(curr) - extractor(prev))
        }
        return extractor(last)
    }
}
