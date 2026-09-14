import Foundation
import CoreLocation

// MARK: - GPX Point Parser
// A reusable, general-purpose reader for this app's recorded GPX files —
// parses every <trkpt> into a plain point-sample with everything downstream
// telemetry code tends to need (position, elevation, speed, lean, G-force,
// and elapsed time since the first point). Written as its own small utility
// rather than buried inside one caller because Lap Compare (LapCompareEngine.swift)
// isn't the only place that will want this shape — a future full telemetry/
// replay screen (mentioned as separate, later work) will almost certainly
// need the exact same per-point parse.
//
// Deliberately reuses the same "split on `<trkpt `, regex each field out of
// the block" approach already used in three other places in this codebase
// (RideAnalyticsEngine.parsePoints, RideFeedManager.decimatedRoute,
// RideHistoryView.GPXRouteMapView.parseGPX) rather than introducing a fourth,
// different way to read this app's GPX format (e.g. XMLParser). Kept as a
// single canonical implementation here so those don't have to keep drifting
// independently, though this task only ever touches the new Lap Compare
// callers — the existing three are left exactly as they are.
struct GPXPointSample {
    let latitude: Double
    let longitude: Double
    let elevation: Double        // meters
    let speedMph: Double         // GPX <speed> is meters/sec; converted here (same 2.23694 factor RideAnalyticsEngine already uses)
    let gforce: Double           // 1.0 = normal, from <packride:gforce>
    let leanDegrees: Double      // signed degrees, from <packride:lean>
    let timestamp: Date
    /// Seconds since the FIRST point in this particular parsed array — i.e.
    /// this parse's own t=0, not any absolute wall-clock reference. A caller
    /// that wants session-relative elapsed time (Lap Compare's lap
    /// reconstruction) gets it for free; a caller that only cares about the
    /// real timestamps still has `timestamp`.
    let elapsedSinceStart: TimeInterval

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }

    /// Straight point-to-point distance in meters — the same CLLocation-based
    /// measurement LapEngine's live per-lap trace already uses (see
    /// LapModeView.swift's `updateTrace`), reused here rather than a separate
    /// hand-rolled haversine implementation.
    func distance(from other: GPXPointSample) -> CLLocationDistance {
        location.distance(from: other.location)
    }
}

enum GPXPointParser {
    /// Parses raw GPX XML text into an ordered array of samples. Points with
    /// no parseable `<time>` are dropped outright — without a timestamp a
    /// point can't be placed on the elapsed-time axis at all, and silently
    /// guessing one would corrupt every distance/time calculation built on
    /// top of this (lap reconstruction, distance alignment). Points are
    /// sorted by timestamp before elapsed time is computed, as cheap
    /// insurance against a GPX that isn't already in strict recording order.
    static func parse(xmlString: String) -> [GPXPointSample] {
        struct RawPoint {
            let lat: Double, lng: Double, ele: Double
            let speedMps: Double, gforce: Double, lean: Double
            let timestamp: Date
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var raw: [RawPoint] = []
        let blocks = xmlString.components(separatedBy: "<trkpt ")
        for block in blocks.dropFirst() {
            guard let latRange = block.range(of: #"lat="([\-\d.]+)""#, options: .regularExpression),
                  let lngRange = block.range(of: #"lon="([\-\d.]+)""#, options: .regularExpression) else { continue }
            let latStr = block[latRange].replacingOccurrences(of: "lat=", with: "").replacingOccurrences(of: "\"", with: "")
            let lngStr = block[lngRange].replacingOccurrences(of: "lon=", with: "").replacingOccurrences(of: "\"", with: "")
            guard let lat = Double(latStr), let lng = Double(lngStr), lat != 0, lng != 0 else { continue }

            var ele = 0.0, spd = 0.0, gf = 1.0, lean = 0.0
            var timestamp: Date? = nil

            if let eleRange = block.range(of: #"<ele>([\-\d.]+)</ele>"#, options: .regularExpression) {
                let eleStr = block[eleRange].replacingOccurrences(of: "<ele>", with: "").replacingOccurrences(of: "</ele>", with: "")
                ele = Double(eleStr) ?? 0
            }
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
                timestamp = iso.date(from: String(timeStr))
            }
            guard let ts = timestamp else { continue }

            raw.append(RawPoint(lat: lat, lng: lng, ele: ele, speedMps: max(spd, 0), gforce: gf, lean: lean, timestamp: ts))
        }

        raw.sort { $0.timestamp < $1.timestamp }
        guard let firstTimestamp = raw.first?.timestamp else { return [] }

        return raw.map {
            GPXPointSample(
                latitude: $0.lat, longitude: $0.lng, elevation: $0.ele,
                speedMph: $0.speedMps * 2.23694,
                gforce: $0.gforce, leanDegrees: $0.lean, timestamp: $0.timestamp,
                elapsedSinceStart: $0.timestamp.timeIntervalSince(firstTimestamp)
            )
        }
    }

    /// Convenience for this device's own recorded sessions — resolves +
    /// reads a GPX file already stored under GPXStorage's rides directory.
    static func parse(gpxFilePath: String) -> [GPXPointSample] {
        guard let data = GPXStorage.contents(gpxFilePath),
              let xmlString = String(data: data, encoding: .utf8) else { return [] }
        return parse(xmlString: xmlString)
    }

    /// Convenience for an arbitrary local file — used for a friend's
    /// shared-session GPX once LapSharingManager has downloaded/cached it,
    /// since that file lives outside GPXStorage's own rides directory.
    static func parse(fileURL: URL) -> [GPXPointSample] {
        guard let data = try? Data(contentsOf: fileURL),
              let xmlString = String(data: data, encoding: .utf8) else { return [] }
        return parse(xmlString: xmlString)
    }

    /// Signed brake/accel G-force per point, derived from the speed delta to
    /// the PREVIOUS point in this same array. This is deliberately the exact
    /// same formula LapCompareEngine.deriveGForces uses for lap traces
    /// (mph/s -> m/s² -> g's via standard gravity 9.80665, same >5s dt gap
    /// guard so a GPS/signal dropout doesn't register as a spike) — added
    /// here as one shared, canonical implementation for whole-ride (not
    /// per-lap) callers, i.e. RideTelemetryMapView's tap-to-inspect and
    /// RideReplayView's second telemetry row, rather than deriving this a
    /// third independent way for either of them.
    ///
    /// Result is index-aligned with `points` (same count); index 0 is always
    /// 0 since there's no previous point to diff against. Positive =
    /// accelerating, negative = braking — callers wanting the split use
    /// max(0, g) for accelG and max(0, -g) for brakeG, same as
    /// ReconstructedLapPoint.brakeG/accelG in LapCompareEngine.
    static func signedGForces(_ points: [GPXPointSample]) -> [Double] {
        guard points.count > 1 else { return Array(repeating: 0, count: points.count) }
        var result = [Double](repeating: 0, count: points.count)
        for i in 1..<points.count {
            let prev = points[i - 1]
            let curr = points[i]
            let dt = curr.elapsedSinceStart - prev.elapsedSinceStart
            guard dt > 0, dt < 5 else { continue }
            let speedDeltaMphPerSec = (curr.speedMph - prev.speedMph) / dt
            // mph/s -> m/s² -> g's, same conversion LapCompareEngine uses
            result[i] = (speedDeltaMphPerSec * 0.44704) / 9.80665
        }
        return result
    }

    /// Index of the recorded point nearest an arbitrary map coordinate —
    /// planar (equirectangular) distance, longitude corrected by
    /// cos(latitude) so degrees-of-longitude aren't overweighted away from
    /// the equator. No existing "nearest point" snapping utility was found
    /// elsewhere in this codebase to match, so this is a new, small,
    /// shared implementation — used by both RideTelemetryMapView's
    /// tap-to-inspect and RideReplayView's drag-to-scrub so the two features
    /// snap to a route identically rather than each rolling its own. Only
    /// the argmin matters, so squared distance (no sqrt) is enough.
    static func nearestIndex(to coordinate: CLLocationCoordinate2D, in points: [GPXPointSample]) -> Int? {
        guard !points.isEmpty else { return nil }
        let cosLat = cos(coordinate.latitude * .pi / 180)
        var bestIndex = 0
        var bestDistSq = Double.greatestFiniteMagnitude
        for (i, p) in points.enumerated() {
            let dLat = p.latitude - coordinate.latitude
            let dLng = (p.longitude - coordinate.longitude) * cosLat
            let distSq = dLat * dLat + dLng * dLng
            if distSq < bestDistSq {
                bestDistSq = distSq
                bestIndex = i
            }
        }
        return bestIndex
    }
}
