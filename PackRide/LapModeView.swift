import SwiftUI
import MapKit
import CoreLocation
import Combine
import CoreMotion
import FirebaseAuth
import FirebaseDatabase

// MARK: - Lap Record Model (local device history, mirrors RideRecord/RideHistoryManager)
struct LapRecord: Identifiable, Codable {
    let id: String
    let date: Date
    let trackName: String
    let laps: [Double]           // seconds per lap, in order
    let bestLapTime: Double      // seconds, 0 if no laps were completed
    let totalDistance: Double    // miles
    let maxSpeed: Double         // mph
    var gpxFilePath: String? = nil
    var analytics: LapAnalyticsSummary? = nil
    // Aug 24, 2026 — Garage feature. Whichever bike was marked active at
    // record time (see BikeManager.currentActiveBikeID()). Optional +
    // defaulted (LapRecord has no custom decoder, so the synthesized
    // Codable conformance already decodes a missing key on an Optional as
    // nil) so sessions recorded before Garage existed still load fine.
    var bikeId: String? = nil
    var gpxURL: String? = nil
    var lapStartTimestamps: [Int64] = []

    init(id: String, date: Date, trackName: String, laps: [Double], bestLapTime: Double,
         totalDistance: Double, maxSpeed: Double, gpxFilePath: String? = nil,
         analytics: LapAnalyticsSummary? = nil, bikeId: String? = nil, gpxURL: String? = nil,
         lapStartTimestamps: [Int64] = []) {
        self.id = id; self.date = date; self.trackName = trackName; self.laps = laps
        self.bestLapTime = bestLapTime; self.totalDistance = totalDistance; self.maxSpeed = maxSpeed
        self.gpxFilePath = gpxFilePath; self.analytics = analytics; self.bikeId = bikeId
        self.gpxURL = gpxURL; self.lapStartTimestamps = lapStartTimestamps
    }

    enum CodingKeys: String, CodingKey {
        case id, date, trackName, laps, bestLapTime, totalDistance, maxSpeed, gpxFilePath, analytics, bikeId, gpxURL, lapStartTimestamps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        trackName = try c.decode(String.self, forKey: .trackName)
        laps = try c.decode([Double].self, forKey: .laps)
        bestLapTime = try c.decode(Double.self, forKey: .bestLapTime)
        totalDistance = try c.decode(Double.self, forKey: .totalDistance)
        maxSpeed = try c.decode(Double.self, forKey: .maxSpeed)
        gpxFilePath = try c.decodeIfPresent(String.self, forKey: .gpxFilePath)
        analytics = try c.decodeIfPresent(LapAnalyticsSummary.self, forKey: .analytics)
        bikeId = try c.decodeIfPresent(String.self, forKey: .bikeId)
        gpxURL = try c.decodeIfPresent(String.self, forKey: .gpxURL)
        lapStartTimestamps = try c.decodeIfPresent([Int64].self, forKey: .lapStartTimestamps) ?? []
    }

    var lapCount: Int { laps.count }
    var bestLapString: String { bestLapTime > 0 ? LapEngine.formatLapTime(bestLapTime) : "--:--" }
    var formattedDate: String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: date)
    }
}

// MARK: - Lap History Manager
// Every session gets saved here locally (same pattern as RideHistoryManager),
// regardless of whether it's ever posted to the Feed — so a session isn't lost
// just because you forgot to post it right after finishing. "Recent Sessions"
// on the Track Mode setup screen reads from this.
class LapHistoryManager: ObservableObject {
    @Published var sessions: [LapRecord] = []
    private var cloudRef: DatabaseReference?
    private var cloudHandle: DatabaseHandle?

    init() {
        loadSessions()
        migrateLocalSessionsOnce()
        syncFromCloud()
    }

    deinit { if let cloudHandle { cloudRef?.removeObserver(withHandle: cloudHandle) } }

    // Returns the newly-recorded session's id (its LapRecord.id) — added Aug
    // 24, 2026 for Lap Compare/Sharing, which both need a stable handle on
    // "this exact session" right when it's recorded, not just whatever
    // LapHistoryManager happens to reload later. The one existing call site
    // (ActiveLapView.endSession) now keeps this id around to hand to
    // LapSessionSummaryView's "Compare Laps"/"Share With a Friend" buttons.
    @discardableResult
    static func recordSession(trackName: String, laps: [Double], bestLapTime: Double,
                               totalDistance: Double, maxSpeed: Double, gpxFilePath: String?,
                               analytics: LapAnalyticsSummary? = nil, bikeId: String? = nil,
                               lapStartTimestamps: [Int64] = []) -> String {
        let session = LapRecord(
            id: UUID().uuidString, date: Date(), trackName: trackName, laps: laps,
            bestLapTime: bestLapTime, totalDistance: totalDistance, maxSpeed: maxSpeed, gpxFilePath: gpxFilePath,
            analytics: analytics, bikeId: bikeId, lapStartTimestamps: lapStartTimestamps
        )
        var existing: [LapRecord] = []
        if let data = UserDefaults.standard.data(forKey: "lapHistory"),
           let decoded = try? JSONDecoder().decode([LapRecord].self, from: data) {
            existing = decoded
        }
        existing.insert(session, at: 0)
        if let encoded = try? JSONEncoder().encode(existing) {
            UserDefaults.standard.set(encoded, forKey: "lapHistory")
        }
        let durationSeconds = Int(laps.reduce(0, +))
        RideHistoryManager.recordTrackSession(
            id: session.id, trackName: trackName, laps: laps, lapStartTimestamps: lapStartTimestamps,
            distance: totalDistance, maxSpeed: maxSpeed,
            duration: String(format: "%02d:%02d:%02d", durationSeconds / 3600, (durationSeconds % 3600) / 60, durationSeconds % 60),
            gpxFilePath: gpxFilePath, bikeId: bikeId
        )
        return session.id
    }

    func loadSessions() {
        if let data = UserDefaults.standard.data(forKey: "lapHistory"),
           let decoded = try? JSONDecoder().decode([LapRecord].self, from: data) {
            sessions = decoded
        }
    }

    private func migrateLocalSessionsOnce() {
        guard !UserDefaults.standard.bool(forKey: "lapHistoryFirebaseMigrated") else { return }
        guard Auth.auth().currentUser != nil else { return }
        for session in sessions {
            let seconds = Int(session.laps.reduce(0, +))
            RideHistoryManager.recordTrackSession(
                id: session.id, trackName: session.trackName, laps: session.laps,
                lapStartTimestamps: session.lapStartTimestamps, distance: session.totalDistance,
                maxSpeed: session.maxSpeed,
                duration: String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60),
                gpxFilePath: session.gpxFilePath, bikeId: session.bikeId
            )
        }
        UserDefaults.standard.set(true, forKey: "lapHistoryFirebaseMigrated")
    }

    private func syncFromCloud() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        if let cloudHandle { cloudRef?.removeObserver(withHandle: cloudHandle) }
        let ref = Database.database().reference().child("users").child(uid).child("rideHistory")
        cloudRef = ref
        cloudHandle = ref.observe(.value) { [weak self] snapshot in
            guard let self else { return }
            let localByID = Dictionary(uniqueKeysWithValues: self.sessions.map { ($0.id, $0) })
            var cloudSessions: [LapRecord] = []
            for child in snapshot.children {
                guard let snap = child as? DataSnapshot,
                      let dict = snap.value as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: dict),
                      let ride = try? JSONDecoder().decode(RideRecord.self, from: data),
                      !ride.lapTimes.isEmpty else { continue }
                let local = localByID[ride.id]
                cloudSessions.append(LapRecord(
                    id: ride.id, date: ride.date, trackName: ride.trackName,
                    laps: ride.lapTimes, bestLapTime: ride.lapTimes.min() ?? 0,
                    totalDistance: ride.distance, maxSpeed: ride.maxSpeed,
                    gpxFilePath: local?.gpxFilePath, analytics: local?.analytics,
                    bikeId: ride.bikeId, gpxURL: ride.gpxURL,
                    lapStartTimestamps: ride.lapStartTimestamps
                ))
            }
            DispatchQueue.main.async {
                self.sessions = cloudSessions.sorted { $0.date > $1.date }
                self.saveSessions()
            }
        }
    }

    func resolveGPX(_ session: LapRecord, completion: @escaping (URL?) -> Void) {
        if let path = session.gpxFilePath, GPXStorage.exists(path) {
            completion(GPXStorage.resolve(path)); return
        }
        guard let raw = session.gpxURL, let url = URL(string: raw) else { completion(nil); return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data, let filename = GPXStorage.saveDownloaded(data, rideID: session.id) else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            DispatchQueue.main.async {
                if let index = self.sessions.firstIndex(where: { $0.id == session.id }) {
                    self.sessions[index].gpxFilePath = filename
                    self.saveSessions()
                }
                completion(GPXStorage.resolve(filename))
            }
        }.resume()
    }

    func deleteSession(id: String) {
        if let s = sessions.first(where: { $0.id == id }), let path = s.gpxFilePath {
            GPXStorage.remove(path)
        }
        sessions.removeAll { $0.id == id }
        saveSessions()
        if let uid = Auth.auth().currentUser?.uid {
            Database.database().reference().child("users").child(uid).child("rideHistory").child(id).removeValue()
        }
    }

    private func saveSessions() {
        if let encoded = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(encoded, forKey: "lapHistory")
        }
    }
}

// MARK: - Lap Crossing Engine
// Detects laps automatically from GPS position relative to a start/finish
// coordinate set during setup — there's no button to tap mid-lap, it's purely
// GPS-driven. Uses two radii rather than one to avoid double-counting a single
// pass: once you're within `crossingRadius` of the line, the next crossing can
// only fire after you've first gotten more than `clearRadius` away from it
// (i.e. you actually left and came back around the loop) — that's what stops
// GPS jitter while sitting near the line, or a slow rolling pass, from
// registering as two or more laps. `minLapDuration` is a second safety net —
// any "lap" faster than that is almost certainly GPS noise, not a real one.
// These three numbers are reasonable starting points for a small track/parking
// lot loop, not lab-tested against a real track yet — flag if laps are being
// missed (radius too small) or double-counted (radius too big / debounce too
// short) on an actual test session.
final class LapEngine: ObservableObject {
    @Published var laps: [Double] = []
    @Published var bestLapTime: Double? = nil
    @Published var lastLapTime: Double? = nil
    @Published var currentLapElapsed: Double = 0
    // Live delta vs. the best lap's own pace at this exact distance into the
    // current lap — negative means the current lap is running ahead (faster,
    // green), positive means behind (slower, red). nil whenever there's
    // nothing to compare against yet, or once the current lap has gone
    // further than the best lap's own recorded trace covers. See
    // refreshLiveDelta()/interpolatedTime(in:atDistance:) below.
    @Published var liveDeltaSeconds: Double? = nil
    @Published var gpsAccuracyMeters: Double? = nil
    @Published var timingConfidence: Double? = nil
    @Published var sectorSplits: [Double] = []
    @Published var invalidLapReason: TimingInvalidReason? = nil
    @Published var bestSectorTimes: [Double] = []
    @Published var inPitLane = false
    @Published private(set) var bestLapCoordinates: [CLLocationCoordinate2D] = []
    @Published private(set) var lapStartTimestamps: [Int64] = []

    private var raceTimingEngine: RaceTimingEngine?
    private var pendingGateCenter: CLLocationCoordinate2D?
    private var pendingGateDirection: GateDirection = .positiveToNegative

    private(set) var startFinish: CLLocationCoordinate2D?
    private var hasClearedZone = false
    private var lapStartDate: Date?
    private var timer: Timer?

    private let crossingRadius: CLLocationDistance = 20   // meters — "you're at the line"
    private let clearRadius: CLLocationDistance = 45      // meters — "you've actually left the line"
    private let minLapDuration: TimeInterval = 12         // seconds — ignore anything faster (noise, not a real lap)

    // Aug 27, 2026 — Grok Track Mode audit, priority #1: reject fixes with
    // poor or stale accuracy up front, before they can pollute crossing
    // detection or the live-delta trace. horizontalAccuracy is negative when
    // there's no real fix at all; above 25m is unreliable enough near a 20m
    // crossing radius to false-clear the zone or fake a crossing. A fix
    // older than 3s (a buffered/replayed point) is dropped too — a
    // real-time trace shouldn't process a stale one.
    private static let maxAcceptableHorizontalAccuracy: CLLocationAccuracy = 25
    private static let maxAcceptableFixAge: TimeInterval = 3

    // Aug 27, 2026 — Grok Track Mode audit, priority #4: the previous fix's
    // distance to the line, kept so a crossing can interpolate the actual
    // crossing instant between it and the current fix — see processLocation
    // below — instead of just using whichever fix happened to land inside
    // crossingRadius first.
    private var lastCrossingCandidate: (location: CLLocation, distance: CLLocationDistance)?

    // MARK: - Live delta timer (current lap vs. best lap)
    // A per-lap distance/time trace, distinct from the straight-line
    // distance-to-start/finish used for crossing detection above — this is a
    // running sum of consecutive-GPS-point distances, i.e. actual distance
    // traveled into the lap, paired with elapsed time at that point. Every
    // completed lap that becomes the new fastest keeps its own trace saved
    // separately (bestLapSamples) so a later lap can compare "what time did
    // my best lap show at this exact distance" against its own live pace.
    private struct LapSample {
        let distance: Double      // meters, cumulative point-to-point distance since this lap started
        let elapsedTime: Double   // seconds since this lap started
    }
    // A single GPS step further than this is almost certainly a bad/glitchy
    // fix, not real movement — excluded from the trace entirely (distance
    // not added, and the trace doesn't advance onto the bad point either) so
    // one glitchy point can't throw off the pace comparison for the rest of
    // the lap.
    private let maxTraceStepDistance: CLLocationDistance = 150
    private var currentLapSamples: [LapSample] = []
    private var currentLapDistance: Double = 0
    private var lastTracePoint: CLLocation?
    private var bestLapSamples: [LapSample]?
    private var currentLapCoordinates: [CLLocationCoordinate2D] = []

    // Aug 27, 2026 — Grok polish: first lap used to start its clock at Date()
    // (wall-clock "tap Start"), while every later lap and every crossing use
    // GPS timestamps. awaitingFirstFix holds the clock at 0 until the first
    // accuracy-gated fix arrives, then anchors lapStartDate to that fix's
    // timestamp so lap 1 is on the same clock as every other lap.
    private var awaitingFirstFix = false

    func begin(at coordinate: CLLocationCoordinate2D, direction: GateDirection = .positiveToNegative) {
        pendingGateCenter = coordinate
        pendingGateDirection = direction
        raceTimingEngine = nil
        startFinish = coordinate
        hasClearedZone = false
        awaitingFirstFix = true
        lapStartDate = nil
        laps = []
        bestLapTime = nil
        lastLapTime = nil
        currentLapElapsed = 0
        resetTrace()
        bestLapSamples = nil
        liveDeltaSeconds = nil
        lastCrossingCandidate = nil
        gpsAccuracyMeters = nil
        timingConfidence = nil
        sectorSplits = []
        invalidLapReason = nil
        bestSectorTimes = []
        inPitLane = false
        bestLapCoordinates = []
        lapStartTimestamps = []
        currentLapCoordinates = []
        timer?.invalidate()
        // Same self-correcting wall-clock pattern used for ride duration
        // elsewhere in the app (see ActiveSoloRideView) — recomputes from
        // lapStartDate every tick rather than just incrementing, so it can't
        // drift behind if the timer briefly stalls (e.g. app backgrounded).
        // Until the first GPS fix arrives, currentLapElapsed stays 0.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let start = self.lapStartDate else { return }
            self.currentLapElapsed = Date().timeIntervalSince(start)
        }
    }

    func begin(configuration: TrackTimingConfiguration) {
        let center = CLLocationCoordinate2D(
            latitude: (configuration.startFinish.a.latitude + configuration.startFinish.b.latitude) / 2,
            longitude: (configuration.startFinish.a.longitude + configuration.startFinish.b.longitude) / 2
        )
        begin(at: center)
        pendingGateCenter = nil
        raceTimingEngine = RaceTimingEngine(configuration: configuration)
        awaitingFirstFix = false
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func resetTrace(startingAt point: CLLocation? = nil) {
        // Seed with a (0m, 0s) sample so interpolation has a clean start
        // point rather than needing a special case for "before the first
        // real GPS step of the lap."
        currentLapSamples = [LapSample(distance: 0, elapsedTime: 0)]
        currentLapDistance = 0
        lastTracePoint = point
    }

    func processLocation(_ location: CLLocation) {
        gpsAccuracyMeters = location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil
        // A manually dropped start/finish remains a point. Do not silently
        // turn it into a directional line based on the first moving fix,
        // which is frequently the rider's pit-exit heading rather than the
        // course direction at the visible timing pin.
        if let raceTimingEngine {
            updateTrace(with: location)
            for event in raceTimingEngine.process(location) {
                switch event {
                case .lapStarted(let date):
                    lapStartDate = date; currentLapElapsed = 0; resetTrace(startingAt: location); sectorSplits = []
                    currentLapCoordinates = [location.coordinate]
                case .sectorCompleted(_, let seconds, _): sectorSplits.append(seconds)
                case .lapCompleted(let seconds, let sectors, let date, let confidence):
                    if let start = lapStartDate { lapStartTimestamps.append(Int64(start.timeIntervalSince1970 * 1000)) }
                    let isNewBest = bestLapTime == nil || seconds < bestLapTime!
                    laps.append(seconds); lastLapTime = seconds
                    if isNewBest {
                        bestLapTime = seconds; bestLapSamples = currentLapSamples
                        bestLapCoordinates = currentLapCoordinates
                    }
                    lapStartDate = date; currentLapElapsed = 0; timingConfidence = confidence; invalidLapReason = nil
                    resetTrace(startingAt: location); currentLapCoordinates = [location.coordinate]; liveDeltaSeconds = nil
                    bestSectorTimes = sectors.enumerated().map { index, value in min(value, bestSectorTimes.indices.contains(index) ? bestSectorTimes[index] : .greatestFiniteMagnitude) }
                case .lapInvalid(let reason, _): invalidLapReason = reason
                case .pitStateChanged(let active, _): inPitLane = active
                default: break
                }
            }
            return
        }
        guard let startFinish else { return }
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= Self.maxAcceptableHorizontalAccuracy,
              abs(location.timestamp.timeIntervalSinceNow) < Self.maxAcceptableFixAge
        else { return }

        // Anchor lap 1's clock to the first good GPS fix (not the wall-clock
        // moment Start was tapped) so every lap — including the first — is
        // measured on GPS time. See awaitingFirstFix on begin(at:).
        if awaitingFirstFix {
            awaitingFirstFix = false
            lapStartDate = location.timestamp
            currentLapElapsed = 0
            resetTrace(startingAt: location)
            currentLapCoordinates = [location.coordinate]
        }

        let linePoint = CLLocation(latitude: startFinish.latitude, longitude: startFinish.longitude)
        let distance = location.distance(from: linePoint)

        if !hasClearedZone {
            if distance > clearRadius { hasClearedZone = true }
            lastCrossingCandidate = (location, distance)
            return
        }

        // Not (yet) a crossing — keep accumulating this lap's own
        // distance/time trace and refresh the live delta against whatever
        // best-lap trace exists.
        guard distance <= crossingRadius, let start = lapStartDate else {
            updateTrace(with: location)
            lastCrossingCandidate = (location, distance)
            return
        }

        // Aug 27, 2026 — Grok Track Mode audit, priority #4: interpolate the
        // actual line-crossing instant between the previous fix (outside
        // crossingRadius) and this one (inside it) by distance ratio,
        // instead of just stamping this fix's own timestamp — recovers the
        // ~0.2-1.0s of systematic "detected late" error a GPS-sampled trace
        // otherwise bakes into every lap. Falls back to this fix's own
        // timestamp if there's no usable previous candidate (e.g. the very
        // first fix of the lap already lands inside the radius).
        let crossingTimestamp: Date
        if let prev = lastCrossingCandidate, prev.distance > crossingRadius, prev.distance > distance {
            let t = max(0, min(1, (prev.distance - crossingRadius) / (prev.distance - distance)))
            crossingTimestamp = prev.location.timestamp.addingTimeInterval(
                location.timestamp.timeIntervalSince(prev.location.timestamp) * t
            )
        } else {
            crossingTimestamp = location.timestamp
        }
        let elapsed = crossingTimestamp.timeIntervalSince(start)
        guard elapsed >= minLapDuration else {
            updateTrace(with: location)
            lastCrossingCandidate = (location, distance)
            return
        }

        // Crossing confirmed — this lap is done. If it's the new fastest,
        // its just-finished trace becomes the one future laps compare
        // against.
        let isNewBest = bestLapTime == nil || elapsed < bestLapTime!
        lapStartTimestamps.append(Int64(start.timeIntervalSince1970 * 1000))
        laps.append(elapsed)
        lastLapTime = elapsed
        if isNewBest {
            bestLapTime = elapsed
            bestLapSamples = currentLapSamples
            bestLapCoordinates = currentLapCoordinates
        }
        // Starts the next lap's clock from the interpolated crossing instant
        // itself, not "now" — keeps currentLapElapsed and the next lap's own
        // eventual elapsed time anchored to when the crossing actually
        // happened rather than when this callback happened to run.
        lapStartDate = crossingTimestamp
        currentLapElapsed = 0
        hasClearedZone = false
        resetTrace(startingAt: location)
        currentLapCoordinates = [location.coordinate]
        liveDeltaSeconds = nil
        lastCrossingCandidate = (location, distance)
    }

    private func updateTrace(with location: CLLocation) {
        guard let start = lapStartDate else { return }

        if let last = lastTracePoint {
            let step = location.distance(from: last)
            guard step <= maxTraceStepDistance else {
                // Bad/glitchy GPS fix — drop this step entirely (no distance
                // added, and lastTracePoint deliberately stays put) so the
                // next real point still measures its step from the last
                // known-good fix instead of compounding the glitch.
                return
            }
            currentLapDistance += step
            lastTracePoint = location
        } else {
            lastTracePoint = location
        }

        // Aug 27, 2026 — Grok polish: use the GPS fix's own timestamp so the
        // live-delta pace trace shares the same clock as interpolated
        // crossings (which already use location.timestamp). Date() could
        // drift under main-thread load or brief timer stalls.
        let elapsedTime = location.timestamp.timeIntervalSince(start)
        guard elapsedTime >= 0 else { return }
        currentLapSamples.append(LapSample(distance: currentLapDistance, elapsedTime: elapsedTime))
        currentLapCoordinates.append(location.coordinate)
        refreshLiveDelta()
    }

    private func refreshLiveDelta() {
        guard let bestLapSamples,
              let currentSample = currentLapSamples.last,
              let bestTimeAtDistance = Self.interpolatedTime(in: bestLapSamples, atDistance: currentSample.distance)
        else {
            liveDeltaSeconds = nil
            return
        }
        // current elapsed minus best elapsed at the same distance: negative
        // means the current lap got here faster (ahead/green), positive
        // means it took longer (behind/red).
        liveDeltaSeconds = currentSample.elapsedTime - bestTimeAtDistance
    }

    // Linearly interpolates `samples` (sorted by ascending distance,
    // starting at distance 0) to find the elapsed time the best lap showed
    // at exactly `atDistance` into the lap. Returns nil once `atDistance`
    // falls beyond the last recorded sample — deliberately never
    // extrapolates past a real recorded point.
    private static func interpolatedTime(in samples: [LapSample], atDistance: Double) -> Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        guard atDistance > first.distance else { return first.elapsedTime }
        guard atDistance <= last.distance else { return nil }

        for i in 1..<samples.count {
            let prev = samples[i - 1]
            let curr = samples[i]
            guard atDistance <= curr.distance else { continue }
            guard curr.distance > prev.distance else { return prev.elapsedTime }
            let t = (atDistance - prev.distance) / (curr.distance - prev.distance)
            return prev.elapsedTime + t * (curr.elapsedTime - prev.elapsedTime)
        }
        return last.elapsedTime
    }

    private static func coordinate(from origin: CLLocationCoordinate2D, distance: Double, bearingDegrees: Double) -> CLLocationCoordinate2D {
        let radius = 6_371_000.0
        let angular = distance / radius
        let bearing = bearingDegrees * .pi / 180
        let lat1 = origin.latitude * .pi / 180, lon1 = origin.longitude * .pi / 180
        let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(bearing))
        let lon2 = lon1 + atan2(sin(bearing) * sin(angular) * cos(lat1), cos(angular) - sin(lat1) * sin(lat2))
        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
    }

    static func formatLapTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        let tenths = Int(((seconds - seconds.rounded(.down)) * 10).rounded(.down))
        return String(format: "%d:%02d.%d", m, s, tenths)
    }

    // "+0.3s" (red, behind) / "-0.3s" (green, ahead) — the sign always shows
    // (the %+ format flag) so the ahead/behind meaning reads at a glance
    // without needing the color alone to carry it.
    static func formatDelta(_ seconds: Double) -> String {
        String(format: "%+.1fs", seconds)
    }
}

// MARK: - Track Mode Setup
// Entry point from Home. Rather than dropping a pin on a small map (fiddly to
// place precisely for something where precision matters), you physically
// stand/ride to your actual start/finish point and tap "Set Start/Finish
// Line" — it captures your current GPS location as the crossing point. This
// is how most dedicated lap-timer apps work and is more accurate than a
// manual map pin.
// MARK: - Remembered Track Locations
// Keys the start/finish pin to a lowercased, trimmed track name so typing the
// same name again next time auto-fills the line the rider actually used last
// time — no need to search or stand at the line again.
private struct SavedTrackLocation: Codable {
    let latitude: Double
    let longitude: Double
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    init(coordinate: CLLocationCoordinate2D) {
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
    }
}

private enum GateEditKind: String, CaseIterable { case start = "START", sector = "+ SECTOR", finish = "SPRINT FINISH", pitIn = "PIT IN", pitOut = "PIT OUT" }

private enum TrackLocationStore {
    private static let key = "pr_savedTrackLocations"

    private static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func loadAll() -> [String: SavedTrackLocation] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: SavedTrackLocation].self, from: data)
        else { return [:] }
        return decoded
    }

    static func save(name: String, coordinate: CLLocationCoordinate2D) {
        let normalized = normalize(name)
        guard !normalized.isEmpty else { return }
        var all = loadAll()
        all[normalized] = SavedTrackLocation(coordinate: coordinate)
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func lookup(name: String) -> CLLocationCoordinate2D? {
        let normalized = normalize(name)
        guard !normalized.isEmpty else { return nil }
        return loadAll()[normalized]?.coordinate
    }
}

/// RaceBox-style circuit presentation. It deliberately renders geographic
/// coordinates into a normalized drawing canvas rather than showing map tiles,
/// keeping the selected layout legible and centered at any screen size.
private struct TrackSchematicView: View {
    let polylines: [MKPolyline]
    let startFinish: TimingGate?
    let sectors: [TimingGate]
    let finish: TimingGate?
    let pitEntry: TimingGate?
    let pitExit: TimingGate?

    var body: some View {
        ZStack {
            Color(red: 0.055, green: 0.059, blue: 0.071)
            Canvas { context, size in
                drawGrid(in: &context, size: size)
                let mapPoints = polylinePoints
                guard !mapPoints.isEmpty else { return }
                let bounds = drawingBounds(for: mapPoints)
                let project: (MKMapPoint) -> CGPoint = { point in
                    let availableWidth = size.width * 0.84
                    let availableHeight = size.height * 0.60
                    let scale = min(availableWidth / max(bounds.width, 1), availableHeight / max(bounds.height, 1))
                    let drawnWidth = bounds.width * scale
                    let drawnHeight = bounds.height * scale
                    return CGPoint(
                        x: (size.width - drawnWidth) / 2 + (point.x - bounds.minX) * scale,
                        y: (size.height - drawnHeight) / 2 + (point.y - bounds.minY) * scale
                    )
                }

                for polyline in polylines {
                    let points = points(in: polyline)
                    guard let first = points.first else { continue }
                    var road = Path()
                    road.move(to: project(first))
                    for point in points.dropFirst() { road.addLine(to: project(point)) }
                    context.stroke(road, with: .color(Color.white.opacity(0.16)),
                                   style: StrokeStyle(lineWidth: 18, lineCap: .round, lineJoin: .round))
                    context.stroke(road, with: .color(Color.white.opacity(0.72)),
                                   style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                    context.stroke(road, with: .color(Color.prCoral.opacity(0.9)),
                                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [3, 5]))
                }

                drawGate(startFinish, color: .white, width: 5, context: &context, project: project)
                for gate in sectors { drawGate(gate, color: .purple, width: 4, context: &context, project: project) }
                drawGate(finish, color: .prCoral, width: 5, context: &context, project: project)
                drawGate(pitEntry, color: .yellow, width: 4, context: &context, project: project)
                drawGate(pitExit, color: .cyan, width: 4, context: &context, project: project)
            }

            if polylines.isEmpty {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("Loading circuit layout…")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
        }
    }

    private var polylinePoints: [MKMapPoint] { polylines.flatMap(points(in:)) }

    private func points(in polyline: MKPolyline) -> [MKMapPoint] {
        let pointer = polyline.points()
        return (0..<polyline.pointCount).map { pointer[$0] }
    }

    private func drawingBounds(for points: [MKMapPoint]) -> MKMapRect {
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 1
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 1
        return MKMapRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        var grid = Path()
        stride(from: 0.0, through: size.width, by: 34).forEach {
            grid.move(to: CGPoint(x: $0, y: 0)); grid.addLine(to: CGPoint(x: $0, y: size.height))
        }
        stride(from: 0.0, through: size.height, by: 34).forEach {
            grid.move(to: CGPoint(x: 0, y: $0)); grid.addLine(to: CGPoint(x: size.width, y: $0))
        }
        context.stroke(grid, with: .color(Color.white.opacity(0.055)), lineWidth: 1)
    }

    private func drawGate(_ gate: TimingGate?, color: Color, width: CGFloat,
                          context: inout GraphicsContext, project: (MKMapPoint) -> CGPoint) {
        guard let gate else { return }
        var line = Path()
        line.move(to: project(MKMapPoint(gate.a)))
        line.addLine(to: project(MKMapPoint(gate.b)))
        context.stroke(line, with: .color(Color.black.opacity(0.8)), lineWidth: width + 3)
        context.stroke(line, with: .color(color), lineWidth: width)
    }
}

/// Compact geometry preview used by the layout picker. It uses the same
/// normalized circuit projection as the full RaceBox-style schematic, so a
/// rider can recognize Default/Loop A/Loop B instead of choosing by name only.
private struct TrackLayoutThumbnail: View {
    let coordinates: [CLLocationCoordinate2D]

    var body: some View {
        Canvas { context, size in
            let points = coordinates.map(MKMapPoint.init)
            guard points.count > 1 else { return }
            let minX = points.map(\.x).min() ?? 0, maxX = points.map(\.x).max() ?? 1
            let minY = points.map(\.y).min() ?? 0, maxY = points.map(\.y).max() ?? 1
            let width = max(maxX - minX, 1), height = max(maxY - minY, 1)
            let scale = min((size.width - 14) / width, (size.height - 14) / height)
            let project: (MKMapPoint) -> CGPoint = { point in
                CGPoint(
                    x: (size.width - width * scale) / 2 + (point.x - minX) * scale,
                    y: (size.height - height * scale) / 2 + (point.y - minY) * scale
                )
            }
            var path = Path()
            path.move(to: project(points[0]))
            points.dropFirst().forEach { path.addLine(to: project($0)) }
            context.stroke(path, with: .color(.white.opacity(0.22)), style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(.prCoral), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
        .background(Color(red: 0.055, green: 0.059, blue: 0.071))
        .overlay {
            if coordinates.count < 2 {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundColor(.white.opacity(0.45))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct TrackModeView: View {
    @State private var mode: TrackTimingMode = .circuit

    var body: some View {
        Group {
            switch mode {
            case .circuit: CircuitTrackModeView(onOpenDrag: { mode = .drag })
            case .drag: DragModeView(onOpenCircuit: { mode = .circuit })
            }
        }
    }
}

private enum TrackTimingMode { case circuit, drag }

private struct CircuitTrackModeView: View {
    let onOpenDrag: () -> Void
    @AppStorage("riderName") var riderName: String = "Rider"
    @AppStorage("trackDataAndGpsNoticeAcknowledgedV2") private var accuracyNoticeAcknowledged = false
    @ObservedObject private var locationManager = SharedLocationManager.shared
    @StateObject private var historyManager = LapHistoryManager()
    @State private var trackName: String = ""
    @State private var startFinishSet = false
    @State private var startFinishCoordinate: CLLocationCoordinate2D? = nil
    @State private var startFinishEndCoordinate: CLLocationCoordinate2D? = nil
    @State private var gateDirection: GateDirection = .positiveToNegative
    @State private var showActiveLap = false
    @State private var showMountingAndCalibrationNotice = false
    @State private var finalLaps: [Double] = []
    @State private var finalBest: Double = 0
    @State private var finalDistance: Double = 0
    @State private var finalMaxSpeed: Double = 0
    @State private var finalGPXPath: String? = nil
    @State private var finalAnalytics: LapAnalyticsSummary? = nil
    @State private var showTrends = false
    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.33, longitude: -122.03),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
    ))
    @State private var isSearching = false
    @State private var searchError: String? = nil
    @State private var pinSource: PinSource? = nil   // nil = no pin yet
    @State private var pinPulse = false
    @State private var showHistory = false
    @State private var isDraggingPin = false
    @State private var activeTrackPolylines: [MKPolyline] = []
    @State private var nearbyTracks: [NearbyTrackDefinition] = []
    @State private var showNearbyTracks = false
    @State private var nearbyDiscoveryStarted = false
    @State private var configurationTrack: NearbyTrackDefinition? = nil
    @State private var pendingConfirmationTrack: NearbyTrackDefinition? = nil
    @State private var pendingConfirmationConfiguration: NearbyTrackConfiguration? = nil
    @State private var layoutConfirmationMessage: String? = nil
    @State private var selectedCatalogTiming: TrackTimingConfiguration? = nil
    @State private var selectedCatalogTrack: NearbyTrackDefinition? = nil
    @State private var gateEditKind: GateEditKind = .start
    @State private var draftGatePoint: CLLocationCoordinate2D? = nil
    @State private var customSectors: [TimingGate] = []
    @State private var customFinishGate: TimingGate? = nil
    @State private var customPitEntryGate: TimingGate? = nil
    @State private var customPitExitGate: TimingGate? = nil
    @State private var isTrackFocused = false
    @State private var showFocusedSatellite = false
    @State private var isTrackLayoutLoading = false

    enum PinSource { case searched, manual, remembered }

    var body: some View {
        ZStack {
            MapReader { proxy in
                ZStack {
                Map(position: $cameraPosition) {
                    UserAnnotation()
                    // Renders the global track vector overlay on the satellite map
                        ForEach(0..<activeTrackPolylines.count, id: \.self) { index in
                            MapPolyline(activeTrackPolylines[index])
                                .stroke(Color.prCoral, lineWidth: 4)
                        }
                    if let coord = startFinishCoordinate {
                        if hasFixedTimingGate, let end = startFinishEndCoordinate {
                            MapPolyline(coordinates: [coord, end])
                                .stroke(Color.prCoral, lineWidth: 6)
                            Annotation("", coordinate: end) {
                                Image(systemName: "arrowtriangle.right.fill")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white)
                                    .rotationEffect(.degrees(gateDirection == .positiveToNegative ? 0 : 180))
                                    .frame(width: 22, height: 22)
                                    .background(Color.prCoral)
                                    .clipShape(Circle())
                            }
                        }
                        Annotation("Start/Finish", coordinate: coord) {
                            ZStack {
                                Circle()
                                    .stroke(Color.prCoral.opacity(0.5), lineWidth: 3)
                                    .frame(width: pinPulse ? 54 : 30, height: pinPulse ? 54 : 30)
                                    .opacity(pinPulse ? 0 : 0.9)
                                Circle()
                                    .fill(Color.prCoral)
                                    .frame(width: 30, height: 30)
                                    .overlay(Circle().stroke(Color.white, lineWidth: 3))
                                Image(systemName: "flag.checkered")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            .scaleEffect(isDraggingPin ? 1.2 : 1)
                            .offset(y: isDraggingPin ? -12 : 0)
                            .onAppear {
                                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                                    pinPulse = true
                                }
                            }
                            .gesture(
                                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                    .onChanged { value in
                                        isDraggingPin = true
                                        if let c = proxy.convert(value.location, from: .global) {
                                            startFinishCoordinate = c
                                            startFinishEndCoordinate = defaultGateEnd(from: c)
                                        }
                                    }
                                    .onEnded { value in
                                        isDraggingPin = false
                                        if let c = proxy.convert(value.location, from: .global) {
                                            startFinishCoordinate = c
                                            startFinishEndCoordinate = defaultGateEnd(from: c)
                                        }
                                        startFinishSet = true
                                        pinSource = .manual
                                        rememberCurrentPin()
                                    }
                            )
                        }
                    }
                    ForEach(Array(customSectors.enumerated()), id: \.offset) { _, gate in
                        MapPolyline(coordinates: [gate.a, gate.b]).stroke(Color.purple, lineWidth: 5)
                    }
                    if let gate = customFinishGate { MapPolyline(coordinates: [gate.a, gate.b]).stroke(Color.white, lineWidth: 5) }
                    if let gate = customPitEntryGate { MapPolyline(coordinates: [gate.a, gate.b]).stroke(Color.yellow, lineWidth: 5) }
                    if let gate = customPitExitGate { MapPolyline(coordinates: [gate.a, gate.b]).stroke(Color.cyan, lineWidth: 5) }
                }
                .mapStyle(.hybrid(
                    elevation: .realistic,
                    pointsOfInterest: isTrackFocused ? .excludingAll : .all,
                    showsTraffic: !isTrackFocused
                ))
                .ignoresSafeArea()
                .gesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            if let c = proxy.convert(value.location, from: .local) {
                                if gateEditKind != .start {
                                    if let first = draftGatePoint {
                                        let gate = TimingGate(id: "\(gateEditKind.rawValue)-\(Date().timeIntervalSince1970)", a: first, b: c, direction: .positiveToNegative)
                                        switch gateEditKind {
                                        case .sector: customSectors.append(gate)
                                        case .finish: customFinishGate = gate
                                        case .pitIn: customPitEntryGate = gate
                                        case .pitOut: customPitExitGate = gate
                                        case .start: break
                                        }
                                        draftGatePoint = nil
                                    } else { draftGatePoint = c }
                                } else {
                                    startFinishCoordinate = c
                                    startFinishEndCoordinate = defaultGateEnd(from: c)
                                    startFinishSet = true
                                }
                                pinSource = .manual
                                rememberCurrentPin()
                            }
                        }
                )
                .opacity(isTrackFocused && !showFocusedSatellite ? 0 : 1)
                .allowsHitTesting(!isTrackFocused || showFocusedSatellite)

                if isTrackFocused && !showFocusedSatellite {
                    TrackSchematicView(
                        polylines: activeTrackPolylines,
                        startFinish: startFinishCoordinate.flatMap { a in
                            startFinishEndCoordinate.map { TimingGate(id: "start-finish", a: a, b: $0, direction: gateDirection) }
                        },
                        sectors: customSectors.isEmpty ? (selectedCatalogTiming?.sectors ?? []) : customSectors,
                        finish: customFinishGate ?? selectedCatalogTiming?.finishGate,
                        pitEntry: customPitEntryGate ?? selectedCatalogTiming?.pitEntryGate,
                        pitExit: customPitExitGate ?? selectedCatalogTiming?.pitExitGate
                    )
                    .ignoresSafeArea()
                    .transition(.opacity)
                }
                }
            }

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("TRACK MODE")
                            .font(.system(size: 10, weight: .heavy))
                            .tracking(2.6)
                            .foregroundColor(.prCoral)
                        Text(trackName.isEmpty ? "Set your line" : trackName)
                            .font(.system(size: 25, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(startFinishSet ? (hasFixedTimingGate ? "Directional start / finish line ready" : "Start / finish point ready — direction calibrates while moving") : "Tap once to place the start / finish point")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.68))
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 8) {
                        Button(action: onOpenDrag) {
                            Text("DRAG")
                                .font(.system(size: 10, weight: .heavy))
                                .foregroundColor(.white)
                                .frame(height: 38)
                                .padding(.horizontal, 12)
                                .background(Color.black.opacity(0.42))
                                .clipShape(Capsule())
                        }
                        Button(action: { showHistory = true }) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 38, height: 38)
                                .background(Color.black.opacity(0.42))
                                .clipShape(Circle())
                        }
                        Button(action: { showTrends = true }) {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 38, height: 38)
                                .background(Color.black.opacity(0.42))
                                .clipShape(Circle())
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 22)

                if isTrackFocused {
                    HStack(spacing: 10) {
                        Label("Circuit isolated", systemImage: "scope")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                        Spacer()
                        if let track = selectedCatalogTrack, track.configurations.count > 1 {
                            Button("Layout") { configurationTrack = track }
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundColor(.white)
                        }
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { showFocusedSatellite.toggle() }
                        } label: {
                            Label(showFocusedSatellite ? "Schematic" : "Satellite",
                                  systemImage: showFocusedSatellite ? "point.3.connected.trianglepath.dotted" : "map.fill")
                                .font(.system(size: 11, weight: .heavy))
                        }
                        .foregroundColor(.white)
                        Button("Change Track") { clearSelectedTrack() }
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundColor(.prCoral)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(Color.black.opacity(0.64))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.16)))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                } else {
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .semibold))
                        TextField("Search a track", text: $trackName)
                            .foregroundColor(.white)
                            .submitLabel(.search)
                            .onSubmit { searchTrack() }
                        if isSearching {
                            ProgressView().tint(.white).scaleEffect(0.75)
                        } else if !trackName.isEmpty {
                            Button(action: { trackName = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.white.opacity(0.6))
                            }
                        }
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.72))
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.16), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    Button(action: setStartFinish) {
                        Image(systemName: startFinishSet ? "checkmark" : "location.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(startFinishSet ? Color(red: 0.18, green: 0.62, blue: 0.36) : Color.black.opacity(0.48))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(!startFinishSet && locationManager.location == nil)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                }

                if let layoutConfirmationMessage {
                    statusCapsule(icon: "checkmark.seal.fill", text: layoutConfirmationMessage, tint: .white)
                        .padding(.top, 8)
                } else if let searchError {
                    statusCapsule(icon: "exclamationmark.triangle.fill", text: searchError, tint: .prCoral)
                        .padding(.top, 8)
                } else if startFinishSet {
                    statusCapsule(icon: pinStatusIcon, text: pinStatusText, tint: .white)
                        .padding(.top, 8)
                } else if locationManager.location == nil {
                    statusCapsule(icon: "location.slash", text: "Waiting for GPS signal…", tint: .white)
                        .padding(.top, 8)
                }

                if startFinishSet && hasFixedTimingGate {
                    Button {
                        // The physical line and selected layout stay fixed.
                        // Swapping A/B and flipping the direction enum would
                        // reverse the crossing test twice and cancel out.
                        gateDirection = gateDirection == .positiveToNegative ? .negativeToPositive : .positiveToNegative
                    } label: {
                        Label("Reverse crossing direction", systemImage: "arrow.left.arrow.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Color.black.opacity(0.48)).clipShape(Capsule())
                    }
                    .padding(.top, 8)
                }

                Spacer()

                VStack(spacing: 12) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(GateEditKind.allCases, id: \.self) { kind in
                                Button(kind.rawValue) { gateEditKind = kind; draftGatePoint = nil }
                                    .font(.system(size: 9, weight: .heavy)).foregroundColor(.white)
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(gateEditKind == kind ? Color.prCoral : Color.white.opacity(0.12)).clipShape(Capsule())
                            }
                            Button("CLEAR GATES") {
                                customSectors = []; customFinishGate = nil; customPitEntryGate = nil; customPitExitGate = nil; draftGatePoint = nil
                            }.font(.system(size: 9, weight: .heavy)).foregroundColor(.red)
                        }
                    }
                    HStack(spacing: 10) {
                        webLapStep(number: "01", title: "Choose line", done: startFinishSet)
                        webLapStep(number: "02", title: "Ride laps", done: false)
                        webLapStep(number: "03", title: "Compare", done: false)
                    }

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("READY TO RUN")
                                .font(.system(size: 9, weight: .heavy))
                                .tracking(1.8)
                                .foregroundColor(.white.opacity(0.55))
                            Text("GPS timing + lap analytics")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        Spacer()
                        Button(action: beginActiveSession) {
                            HStack(spacing: 8) {
                                Image(systemName: "stopwatch.fill")
                                Text("Start Session")
                            }
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundColor(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 13)
                            .background(startFinishSet ? Color.prCoral : Color.white.opacity(0.18))
                            .clipShape(Capsule())
                        }
                        .disabled(!startFinishSet)
                    }

                    Text("Your driven GPS laps form the circuit layout. After two valid laps, you can contribute it for community review.")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
                .background(Color.black.opacity(0.58))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.13), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .alert("Track Mode data and timing", isPresented: Binding(
            get: { !accuracyNoticeAcknowledged },
            set: { if !$0 { accuracyNoticeAcknowledged = true } }
        )) {
            Button("I Understand") { accuracyNoticeAcknowledged = true }
        } message: {
            Text("PackRide builds a circuit layout from the GPS trace you record after placing the start/finish point. After at least two valid laps, you can submit that layout for community review. PackRide uses your phone’s GPS and is not a certified professional lap timer. Mounting the phone securely on the handlebar with a clear view of the sky provides a much more accurate racing line and timing. Weak GPS reception may produce larger differences or invalidate a lap.")
        }
        .alert("Before you start", isPresented: $showMountingAndCalibrationNotice) {
            Button("Cancel", role: .cancel) { }
            Button("Start Session") { launchActiveSession() }
        } message: {
            Text("Mount the phone securely on the handlebar with a clear view of the sky for a more accurate racing line and timing. Keep the motorcycle upright and the phone still for a few seconds after starting while PackRide calibrates lean angle.")
        }
        .onAppear {
            locationManager.startUpdating(reason: "lapModePicker")
            // Re-evaluate nearby circuits on every visit. A previous empty result
            // or a location acquired after the first render must not suppress the
            // default 10-mile discovery prompt for the rest of this view's life.
            nearbyDiscoveryStarted = false
            nearbyTracks = []
            discoverNearbyTracksWhenReady()
        }
        .onChange(of: locationManager.location) { _, _ in discoverNearbyTracksWhenReady() }
        .onDisappear { locationManager.stopUpdating(reason: "lapModePicker") }
        .fullScreenCover(isPresented: $showActiveLap, onDismiss: {
            historyManager.loadSessions()
        }) {
            if let coord = startFinishCoordinate, let end = startFinishEndCoordinate {
                let gate = TimingGate(id: "start-finish", a: coord, b: end, direction: gateDirection)
                let base = selectedCatalogTiming ?? TrackTimingConfiguration(startFinish: gate)
                let timing = TrackTimingConfiguration(startFinish: gate,
                    sectors: customSectors.isEmpty ? base.sectors : customSectors,
                    minimumLapSeconds: base.minimumLapSeconds,
                    finishGate: customFinishGate ?? base.finishGate,
                    pitEntryGate: customPitEntryGate ?? base.pitEntryGate,
                    pitExitGate: customPitExitGate ?? base.pitExitGate)
                ActiveLapView(
                    startFinish: coord, timingConfiguration: timing, trackName: trackName.isEmpty ? "Track Session" : trackName,
                    offersCommunityLayoutSubmission: selectedCatalogTiming == nil,
                    isPresented: $showActiveLap, finalLaps: $finalLaps, finalBest: $finalBest,
                    finalDistance: $finalDistance, finalMaxSpeed: $finalMaxSpeed, finalGPXPath: $finalGPXPath,
                    finalAnalytics: $finalAnalytics
                )
            }
        }
        .sheet(isPresented: $showHistory) { historySheet }
        .sheet(isPresented: $showTrends) { LapTrendsView(sessions: historyManager.sessions) }
        .confirmationDialog(MeasurementUnits.current == .metric ? "Tracks within 16 km" : "Tracks within 10 miles", isPresented: $showNearbyTracks, titleVisibility: .visible) {
            ForEach(nearbyTracks) { track in
                Button("\(track.name) · \(MeasurementUnits.distanceMiles(track.distanceMiles))") { chooseNearbyTrack(track) }
            }
            Button("Search manually", role: .cancel) {}
        } message: { Text("Choose the circuit you are riding.") }
        .sheet(item: $configurationTrack) { track in
            NavigationStack {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(track.configurations) { config in
                            Button {
                                configurationTrack = nil
                                selectCatalogLayout(track: track, configuration: config)
                            } label: {
                                HStack(spacing: 12) {
                                    TrackLayoutThumbnail(coordinates: config.centerline)
                                        .frame(width: 92, height: 66)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(config.name + (config.isDefault ? " · Default" : ""))
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundColor(.prInk)
                                        Text(config.timing == nil ? "Set start/finish" : "Start/finish saved · \(config.timing?.sectors.count ?? 0) sectors")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(.prMuted)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.prMuted)
                                }
                                .padding(10)
                                .background(Color.prCardBg)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(.plain)
                        }
                        Button("Record a different layout") {
                            configurationTrack = nil
                            prepareNewLayout(at: track)
                        }
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.prCoral)
                        .padding(.vertical, 14)
                    }
                    .padding(16)
                }
                .background(Color.prBg)
                .navigationTitle("Choose \(track.name) layout")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { configurationTrack = nil } } }
            }
            .presentationDetents([.medium, .large])
        }
        .alert("Confirm this layout", isPresented: Binding(
            get: { pendingConfirmationTrack != nil && pendingConfirmationConfiguration != nil },
            set: { if !$0 { pendingConfirmationTrack = nil; pendingConfirmationConfiguration = nil } }
        )) {
            Button("Yes, use this layout") { confirmAndApplyPendingLayout() }
            Button("Record a different layout") {
                if let track = pendingConfirmationTrack { prepareNewLayout(at: track) }
                pendingConfirmationTrack = nil
                pendingConfirmationConfiguration = nil
            }
            Button("Cancel", role: .cancel) {
                pendingConfirmationTrack = nil
                pendingConfirmationConfiguration = nil
            }
        } message: {
            if let config = pendingConfirmationConfiguration {
                Text("Are you riding \"​\(config.name)\"​ with this same start/finish line? Confirming helps improve this community-sourced layout for the next rider.")
            }
        }
    }

    // MARK: - Floating Top Bar (search + stand-here + history)
    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold)).foregroundColor(.prMuted)
                TextField("", text: $trackName, prompt: Text("Track name").foregroundColor(.prMuted))
                    .foregroundColor(.prInk)
                    .submitLabel(.search)
                    .onSubmit { searchTrack() }
                if isSearching {
                    ProgressView().scaleEffect(0.75)
                } else if !trackName.isEmpty {
                    Button(action: { trackName = "" }) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundColor(.prMuted)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.prBorder, lineWidth: 1))

            // Stand-here override — still available, just compact now.
            Button(action: setStartFinish) {
                Image(systemName: startFinishSet ? "checkmark" : "location.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 42, height: 42)
                    .background(startFinishSet ? Color(red: 0.180, green: 0.620, blue: 0.357) : Color.prInkFixed)
                    .clipShape(Circle())
            }
            .disabled(!startFinishSet && locationManager.location == nil)

            Button(action: { showHistory = true }) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.prInk)
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.prBorder, lineWidth: 1))
            }

            Button(action: { showTrends = true }) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.prInk)
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.prBorder, lineWidth: 1))
            }
        }
        .padding(.horizontal, 16)
    }

    private func webLapStep(number: String, title: String, done: Bool) -> some View {
        HStack(spacing: 7) {
            Text(number)
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundColor(done ? Color.prCoral : .white.opacity(0.42))
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(done ? 0.92 : 0.55))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusCapsule(icon: String, text: String, tint: Color) -> some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11))
                Text(text).font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(tint)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Bottom Bar (tiny Start Session pill)
    private var bottomBar: some View {
        HStack {
            Spacer()
            Button(action: {
                rememberCurrentPin()
                showActiveLap = true
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "stopwatch.fill").font(.system(size: 14, weight: .bold))
                    Text("Start Session").font(.system(size: 14, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 22).padding(.vertical, 14)
                .background(startFinishSet ? Color.prCoral : Color.prMuted)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            }
            .disabled(!startFinishSet)
            Spacer()
        }
        .padding(.bottom, 28)
    }

    // MARK: - History Sheet
    // Recent Sessions used to be an always-visible card eating most of the
    // screen — moved behind the clock icon in the top bar so the map stays
    // full-size. Local history only (not tied to Feed posting), so a session
    // is never "lost" just because you forgot to post it.
    private var historySheet: some View {
        NavigationStack {
            Group {
                if historyManager.sessions.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "stopwatch").font(.system(size: 34)).foregroundColor(.prMuted)
                        Text("No sessions yet").font(.system(size: 15, weight: .semibold)).foregroundColor(.prInk)
                        Text("Finish a Track Mode session to see it here.")
                            .font(.system(size: 12)).foregroundColor(.prMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.prBg)
                } else {
                    List {
                        ForEach(historyManager.sessions) { session in
                            NavigationLink {
                                LapSessionSummaryView(
                                    trackName: session.trackName, laps: session.laps,
                                    bestLapTime: session.bestLapTime, distance: session.totalDistance,
                                    maxSpeed: session.maxSpeed, gpxFilePath: session.gpxFilePath,
                                    date: session.date, analytics: session.analytics,
                                    sessionId: session.id,
                                    lapStartTimestamps: session.lapStartTimestamps
                                )
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.trackName).font(.system(size: 14, weight: .semibold)).foregroundColor(.prInk)
                                        Text(session.formattedDate).font(.system(size: 11)).foregroundColor(.prMuted)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("\(session.lapCount) laps").font(.system(size: 12, weight: .semibold)).foregroundColor(.prMuted)
                                        Text(session.bestLapString).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundColor(.prCoral)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.prCardBg)
                        }
                        .onDelete { offsets in
                            offsets.map { historyManager.sessions[$0].id }.forEach(historyManager.deleteSession)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .background(Color.prBg)
                }
            }
            .navigationTitle("Recent Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showHistory = false }
                }
            }
        }
    }

    private func setStartFinish() {
        if startFinishSet {
            startFinishSet = false
            startFinishCoordinate = nil
            startFinishEndCoordinate = nil
            pinSource = nil
        } else if let loc = locationManager.location {
            startFinishCoordinate = loc.coordinate
            startFinishEndCoordinate = defaultGateEnd(from: loc.coordinate)
            startFinishSet = true
            pinSource = .manual
            cameraPosition = .region(MKCoordinateRegion(
                center: loc.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
            ))
            rememberCurrentPin()
        }
    }

    private func beginActiveSession() {
        guard let start = startFinishCoordinate else {
            searchError = "Set the start / finish line before starting."
            return
        }
        if startFinishEndCoordinate == nil {
            startFinishEndCoordinate = defaultGateEnd(from: start)
        }
        startFinishSet = true
        rememberCurrentPin()
        showMountingAndCalibrationNotice = true
    }

    /// Never present an empty full-screen cover: repair any legacy one-point
    /// start/finish value first, then allow SwiftUI to commit it before launch.
    private func launchActiveSession() {
        DispatchQueue.main.async {
            guard startFinishCoordinate != nil, startFinishEndCoordinate != nil else { return }
            showActiveLap = true
        }
    }

    private func discoverNearbyTracksWhenReady() {
        guard !nearbyDiscoveryStarted, nearbyTracks.isEmpty, trackName.isEmpty,
              let location = locationManager.location else { return }
        nearbyDiscoveryStarted = true
        TrackCatalogService.nearby(to: location) { tracks in
            nearbyTracks = tracks
            if tracks.count == 1 { chooseNearbyTrack(tracks[0]) }
            else if tracks.count > 1 { showNearbyTracks = true }
            else { discoverNearbyVenueWithMapKit(from: location) }
        }
    }

    /// Firebase is authoritative for timing layouts, but a new venue will not
    /// be in that catalogue yet. Apple Maps can still identify the nearest
    /// circuit so Track Mode pre-fills its name within the same 10-mile rule.
    /// It intentionally does not invent a start/finish line.
    private func discoverNearbyVenueWithMapKit(from location: CLLocation) {
        let region = MKCoordinateRegion(
            center: location.coordinate,
            latitudinalMeters: 32_186.88,
            longitudinalMeters: 32_186.88
        )
        searchNearbyMotorsportVenues(
            queries: ["go kart track", "motorsports park", "motorcycle race track"],
            index: 0,
            region: region,
            location: location,
            results: []
        )
    }

    private func searchNearbyMotorsportVenues(
        queries: [String],
        index: Int,
        region: MKCoordinateRegion,
        location: CLLocation,
        results: [MKMapItem]
    ) {
        guard index < queries.count else {
            DispatchQueue.main.async {
                let candidate = results
                    .compactMap { item -> (MKMapItem, Int, CLLocationDistance)? in
                        let score = motorsportVenueScore(item)
                        guard score > 0 else { return nil }
                        let coordinate = item.placemark.coordinate
                        let distance = location.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
                        return distance <= 16_093.44 ? (item, score, distance) : nil
                    }
                    .sorted { left, right in
                        left.1 == right.1 ? left.2 < right.2 : left.1 > right.1
                    }
                    .first?.0
                guard let candidate,
                      let name = candidate.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty else {
                    return
                }
                trackName = name
                selectedCatalogTrack = nil
                selectedCatalogTiming = nil
                startFinishCoordinate = nil
                startFinishEndCoordinate = nil
                startFinishSet = false
                pinSource = nil
                searchError = "Nearby venue detected. PackRide is still collecting layouts here—choose START and tap both ends of the actual timing line."
                let coordinate = candidate.placemark.coordinate
                cameraPosition = .region(MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
                ))
            }
            return
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = queries[index]
        request.resultTypes = [.pointOfInterest]
        request.region = region
        MKLocalSearch(request: request).start { response, _ in
            let combined = results + (response?.mapItems ?? [])
            searchNearbyMotorsportVenues(
                queries: queries,
                index: index + 1,
                region: region,
                location: location,
                results: combined
            )
        }
    }

    /// MapKit does not expose a dependable race-circuit category on all iOS
    /// versions. Require explicit motorsport language in the result name and
    /// reject common horse/running-track terms. A false negative leaves the
    /// field editable; a false positive would silently select the wrong venue.
    private func motorsportVenueScore(_ item: MKMapItem) -> Int {
        let value = [item.name, item.placemark.title]
            .compactMap { $0 }
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let rejected = ["horse", "equestrian", "farm", "ranch", "thoroughbred", "greyhound", "athletic", "running track"]
        guard !rejected.contains(where: value.contains) else { return 0 }
        let strong = ["kartplex", "karting", "go kart", "gokart", "motorsport", "motor speedway", "motorplex"]
        if strong.contains(where: value.contains) { return 3 }
        let accepted = ["raceway", "speedway", "racing circuit", "race circuit", "dragway", "autodrome"]
        if accepted.contains(where: value.contains) { return 2 }
        return 0
    }

    private func chooseNearbyTrack(_ track: NearbyTrackDefinition) {
        // A catalogue match supplies the venue only. The rider places the
        // timing point and the driven GPS trace becomes the proposed layout.
        trackName = track.name
        selectedCatalogTrack = nil
        selectedCatalogTiming = nil
        activeTrackPolylines = []
        startFinishCoordinate = nil
        startFinishEndCoordinate = nil
        startFinishSet = false
        pinSource = nil
        isTrackFocused = false
        showFocusedSatellite = false
        configurationTrack = nil
        showNearbyTracks = false
        searchError = "Track found. Drop the start / finish pin, then ride at least two laps to build the GPS layout."
        cameraPosition = .region(MKCoordinateRegion(center: track.center, span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)))
    }

    private func layoutChoiceLabel(_ configuration: NearbyTrackConfiguration) -> String {
        let defaultText = configuration.isDefault ? " · Default" : ""
        if let timing = configuration.timing {
            return "\(configuration.name)\(defaultText) · Start/finish saved · \(timing.sectors.count) sectors"
        }
        return "\(configuration.name)\(defaultText) · Set start/finish"
    }

    private func selectCatalogLayout(track: NearbyTrackDefinition, configuration: NearbyTrackConfiguration) {
        if configuration.timing == nil {
            apply(track: track, configuration: configuration)
        } else {
            requestConfirmation(track: track, configuration: configuration)
        }
    }

    private func requestConfirmation(track: NearbyTrackDefinition, configuration: NearbyTrackConfiguration) {
        configurationTrack = nil
        pendingConfirmationTrack = track
        pendingConfirmationConfiguration = configuration
    }

    private func confirmAndApplyPendingLayout() {
        guard let track = pendingConfirmationTrack, let configuration = pendingConfirmationConfiguration else { return }
        pendingConfirmationTrack = nil
        pendingConfirmationConfiguration = nil
        apply(track: track, configuration: configuration)
        CommunityTrackLayoutService.confirm(venueID: track.id, configurationID: configuration.id) { result in
            switch result {
            case .success: layoutConfirmationMessage = "Community layout confirmed. Thank you!"
            case .failure: layoutConfirmationMessage = "Layout loaded. Confirmation will be retried next time."
            }
        }
    }

    private func prepareNewLayout(at track: NearbyTrackDefinition) {
        configurationTrack = nil
        selectedCatalogTrack = nil
        selectedCatalogTiming = nil
        trackName = track.name
        startFinishCoordinate = nil
        startFinishEndCoordinate = nil
        startFinishSet = false
        pinSource = nil
        customSectors = []
        customFinishGate = nil
        customPitEntryGate = nil
        customPitExitGate = nil
        draftGatePoint = nil
        isTrackFocused = false
        showFocusedSatellite = false
        searchError = "New layout mode: choose START and tap both ends of the actual timing line, then complete at least two valid laps."
        cameraPosition = .region(MKCoordinateRegion(center: track.center, span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)))
        loadAndFocusTrackLayout(around: track.center)
    }

    private func apply(track: NearbyTrackDefinition, configuration: NearbyTrackConfiguration) {
        selectedCatalogTrack = track
        selectedCatalogTiming = configuration.timing
        trackName = track.name
        if let timing = configuration.timing {
            startFinishCoordinate = timing.startFinish.a
            startFinishEndCoordinate = timing.startFinish.b
            gateDirection = timing.startFinish.direction
            startFinishSet = true
            pinSource = .searched
            searchError = nil
        } else {
            startFinishCoordinate = nil
            startFinishEndCoordinate = nil
            startFinishSet = false
            pinSource = nil
            searchError = "Circuit layout loaded. Tap once on the map to place the start / finish line."
        }
        isTrackFocused = true
        // Never block the screen on the optional OSM schematic download.
        // Satellite is useful immediately; switch to schematic when ready.
        showFocusedSatellite = true
        isTrackLayoutLoading = false
        configurationTrack = nil
        cameraPosition = .region(MKCoordinateRegion(center: track.center, span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)))
        if configuration.centerline.count > 1 {
            let polyline = MKPolyline(coordinates: configuration.centerline, count: configuration.centerline.count)
            activeTrackPolylines = [polyline]
            focusMap(on: [polyline], fallback: track.center)
            // A schematic cannot translate a tap back to latitude/longitude.
            // Keep the real map visible until the rider places a missing
            // timing line; the selected circuit polyline remains overlaid.
            showFocusedSatellite = configuration.timing == nil
        } else {
            loadAndFocusTrackLayout(around: track.center)
        }
    }

    private func clearSelectedTrack() {
        trackName = ""
        startFinishSet = false
        startFinishCoordinate = nil
        startFinishEndCoordinate = nil
        selectedCatalogTiming = nil
        selectedCatalogTrack = nil
        activeTrackPolylines = []
        customSectors = []
        customFinishGate = nil
        customPitEntryGate = nil
        customPitExitGate = nil
        draftGatePoint = nil
        pinSource = nil
        isTrackFocused = false
        showFocusedSatellite = false
        nearbyDiscoveryStarted = false
        cameraPosition = .userLocation(fallback: .automatic)
    }

    private func loadAndFocusTrackLayout(around center: CLLocationCoordinate2D) {
        isTrackLayoutLoading = true
        TrackLayoutService.fetchNearbyTrackLayouts(around: center, radiusMeters: 2_500) { polylines, _ in
            isTrackLayoutLoading = false
            // Avoid pulling another nearby circuit into the focused viewport.
            let centerPoint = MKMapPoint(center)
            let relevant = polylines.filter { polyline in
                let rect = polyline.boundingMapRect
                let nearestX = min(max(centerPoint.x, rect.minX), rect.maxX)
                let nearestY = min(max(centerPoint.y, rect.minY), rect.maxY)
                return centerPoint.distance(to: MKMapPoint(x: nearestX, y: nearestY)) < 2_500
            }
            activeTrackPolylines = relevant
            if relevant.isEmpty {
                // A schematic cannot be drawn without a centerline. The timing
                // gates remain valid, so show the focused satellite map instead
                // of trapping the rider behind an endless loading indicator.
                showFocusedSatellite = true
                searchError = "Circuit drawing unavailable — showing the focused satellite view."
            } else {
                focusMap(on: relevant, fallback: center)
                withAnimation(.easeInOut(duration: 0.2)) { showFocusedSatellite = false }
            }
        }
    }

    private func focusMap(on polylines: [MKPolyline], fallback center: CLLocationCoordinate2D) {
        guard var rect = polylines.first?.boundingMapRect else {
            cameraPosition = .region(MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)))
            return
        }
        for polyline in polylines.dropFirst() { rect = rect.union(polyline.boundingMapRect) }
        let padding = max(rect.width, rect.height) * 0.18
        cameraPosition = .rect(rect.insetBy(dx: -padding, dy: -padding))
    }

    private var pinStatusIcon: String {
        switch pinSource {
        case .searched: return "mappin.circle.fill"
        case .remembered: return "clock.arrow.circlepath"
        case .manual, .none: return "hand.point.up.left.fill"
        }
    }

    private var pinStatusText: String {
        if selectedCatalogTiming == nil {
            return "Start / finish point set — timing direction calibrates from your movement"
        }
        switch pinSource {
        case .searched: return "Pin found from search — drag it to fine-tune the position"
        case .remembered: return "Pin loaded from your saved line for this track — drag to adjust"
        case .manual, .none: return "Pin set — drag it to reposition"
        }
    }

    private var hasFixedTimingGate: Bool { selectedCatalogTiming != nil }

    // Saves the current pin against the current track name so typing the same
    // name next time auto-fills this exact spot. No-op if the name is blank.
    private func rememberCurrentPin() {
        guard let coord = startFinishCoordinate else { return }
        TrackLocationStore.save(name: trackName, coordinate: coord)
    }

    private func defaultGateEnd(from coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let longitudeOffset = 30.0 / (111_320.0 * max(0.15, cos(coordinate.latitude * .pi / 180)))
        return CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude + longitudeOffset)
    }

    // MARK: - Search by Track Name
    // Finds a real-world location for the typed track name via Apple Maps search.
    // This is only a starting point — venue search returns roughly where the
    // track/facility is (e.g. its parking lot or main entrance), not the exact
    // start/finish line, so the pin lands on the map and the rider can tap
    // anywhere nearby to drag it onto the actual line before starting a session.
    private func searchTrack() {
        let query = trackName.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        searchError = nil
        isSearching = true

        TrackCatalogService.matching(name: query, near: locationManager.location) { matches in
            if let best = matches.first {
                isSearching = false
                chooseNearbyTrack(best)
                return
            }
            searchTrackWithMapKit(query)
        }
    }

    /// Fallback for venues that have not been configured in the shared PackRide
    /// catalogue yet. MapKit supplies only an approximate venue coordinate, so
    /// users can still position a gate manually after the map is centered.
    private func searchTrackWithMapKit(_ query: String) {

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        if let userLoc = locationManager.location {
            // Bias results toward the rider's current area so "Thunderhill" etc.
            // doesn't return a same-named result on the other side of the world.
            request.region = MKCoordinateRegion(
                center: userLoc.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 5, longitudeDelta: 5)
            )
        }

        MKLocalSearch(request: request).start { response, error in
            DispatchQueue.main.async {
                isSearching = false
                // Aug 28, 2026 — MKMapItem.location is iOS 26+ only;
                // .placemark.coordinate works on every MapKit version.
                guard let coordinate = response?.mapItems.first?.placemark.coordinate else {
                    searchError = "Couldn't find \"\(query)\" — try a more specific name, or tap the map to set the line yourself."
                    return
                }
                // MapKit found a venue, not a timing layout. Do not invent a
                // gate or imply that the venue's OSM ways are an official
                // configuration. The rider may define a custom gate explicitly.
                selectedCatalogTrack = nil
                selectedCatalogTiming = nil
                startFinishCoordinate = nil
                startFinishEndCoordinate = nil
                startFinishSet = false
                pinSource = nil
                isTrackFocused = false
                showFocusedSatellite = false
                searchError = "Venue found, but PackRide has no verified layouts for it yet. Choose START and tap both ends of the real timing line."
                cameraPosition = .region(MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                ))
                rememberCurrentPin()

                self.activeTrackPolylines = []
                searchError = "Track found. Drop the start / finish pin, then ride at least two laps to build the GPS layout."
            }
        }
    }
}

// MARK: - Active Lap Session (live tracking)
struct ActiveLapView: View {
    let startFinish: CLLocationCoordinate2D
    let timingConfiguration: TrackTimingConfiguration
    let trackName: String
    let offersCommunityLayoutSubmission: Bool
    @Binding var isPresented: Bool
    @Binding var finalLaps: [Double]
    @Binding var finalBest: Double
    @Binding var finalDistance: Double
    @Binding var finalMaxSpeed: Double
    @Binding var finalGPXPath: String?
    @Binding var finalAnalytics: LapAnalyticsSummary?

    @ObservedObject private var locationManager = SharedLocationManager.shared
    @StateObject private var lapEngine = LapEngine()
    @StateObject private var gpxRecorder = GPXRecorder()
    // Aug 27, 2026 — Grok Track Mode audit, priority #5: this default value
    // is only reached if the custom init below (which sets a fixed region
    // centered on startFinish instead) somehow isn't used — kept as a
    // fallback with the same shape as before, but init(...) is what actually
    // runs for every real ActiveLapView instance.
    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.33, longitude: -122.03),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
    ))
    @State private var showEndAlert = false
    @State private var sessionStarted = false
    @State private var mapStyleIndex = 2

    // MARK: - Motion capture (G-force + lean angle)
    // Same CoreMotion setup used for solo rides (see ActiveSoloRideView) —
    // Track Mode previously never fed these into the GPX recorder at all,
    // so every lap session's GPX had flat/default gforce and lean values,
    // which would have made the smoothness half of Track Score meaningless.
    private let motionManager = CMMotionManager()
    // Aug 27, 2026 — Grok Track Mode audit, priority #2: both callbacks
    // below used to deliver `to: .main` — continuous main-thread work every
    // 100-200ms for an entire session. Delivery now goes to this background
    // queue instead, at 5Hz rather than the solo-ride 10Hz (Track Mode's HUD
    // doesn't show live G-force/lean, only GPX needs the samples, so the
    // higher rate wasn't buying anything). The accelerometer callback only
    // writes gpxRecorder.currentGForce (a plain var, not @Published — safe
    // to write from here). The device-motion callback also updates
    // leanCalibrated/leanCalibrationSamples/leanZeroOffset/isLeanCalibrating,
    // which ARE @State and drive the calibration badge, so that one hops
    // back to DispatchQueue.main.async for its body.
    private let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.packride.lap.motion"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        return q
    }()
    @State private var leanZeroOffset: Double = 0
    @State private var leanCalibrated: Bool = false
    // Aug 24, 2026 — samples collected toward leanZeroOffset while
    // calibrating (see startMotionCapture below), and a flag mirroring that
    // ~1s window so the HUD can show it via LeanCalibrationBadge. True by
    // default since a fresh view instance genuinely hasn't calibrated yet.
    @State private var leanCalibrationSamples: [Double] = []
    @State private var isLeanCalibrating: Bool = true
    // Once true, this same fullScreenCover shows the summary instead of the
    // live map — no separate dismiss-then-re-present chain. Ending a session
    // used to fully dismiss this view and have the parent present a summary
    // sheet ~0.4s later on a timer; if that timing ever raced with anything
    // (including switching tabs), the summary could get stuck half-presented
    // with the bottom tab bar unresponsive underneath it. Staying inside one
    // continuous presentation removes that race entirely.
    @State private var sessionEnded = false
    // The just-recorded session's LapHistoryManager id — nil only in the edge
    // case where recordSession() never ran at all (no laps AND no distance,
    // see endSession() below), in which case Compare Laps/Share With a Friend
    // simply have nothing to point at yet.
    @State private var finalSessionId: String? = nil
    @State private var completedGPXPath: String? = nil
    @State private var showLayoutSubmission = false
    @State private var proposedLayoutName = "Default"
    @State private var layoutSubmissionMessage: String? = nil
    @State private var submittingLayout = false
    @State private var liveRouteCoordinates: [CLLocationCoordinate2D] = []

    // Aug 27, 2026 — Grok Track Mode audit, priority #5: cameraPosition used
    // to default to .userLocation(...), continuously re-centering the map on
    // every location update for the entire session — real GPU cost for
    // something that buys nothing, since the start/finish line and the track
    // around it don't move. This custom init sets a fixed region centered on
    // startFinish instead; the blue dot (UserAnnotation in body) still moves
    // within it exactly as before, the camera just stops chasing it.
    init(
        startFinish: CLLocationCoordinate2D,
        timingConfiguration: TrackTimingConfiguration,
        trackName: String,
        offersCommunityLayoutSubmission: Bool,
        isPresented: Binding<Bool>,
        finalLaps: Binding<[Double]>,
        finalBest: Binding<Double>,
        finalDistance: Binding<Double>,
        finalMaxSpeed: Binding<Double>,
        finalGPXPath: Binding<String?>,
        finalAnalytics: Binding<LapAnalyticsSummary?>
    ) {
        self.startFinish = startFinish
        self.timingConfiguration = timingConfiguration
        self.trackName = trackName
        self.offersCommunityLayoutSubmission = offersCommunityLayoutSubmission
        self._isPresented = isPresented
        self._finalLaps = finalLaps
        self._finalBest = finalBest
        self._finalDistance = finalDistance
        self._finalMaxSpeed = finalMaxSpeed
        self._finalGPXPath = finalGPXPath
        self._finalAnalytics = finalAnalytics
        self._cameraPosition = State(initialValue: .region(MKCoordinateRegion(
            center: startFinish,
            span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
        )))
    }

    var body: some View {
        Group {
            if sessionEnded {
                LapSessionSummaryView(
                    trackName: trackName, laps: finalLaps, bestLapTime: finalBest,
                    distance: finalDistance, maxSpeed: finalMaxSpeed, gpxFilePath: completedGPXPath ?? finalGPXPath,
                    analytics: finalAnalytics, sessionId: finalSessionId,
                    lapStartTimestamps: lapEngine.lapStartTimestamps
                )
            } else {
                ZStack(alignment: .top) {
                    Map(position: $cameraPosition) {
                        UserAnnotation()
                        if liveRouteCoordinates.count > 1 {
                            MapPolyline(coordinates: liveRouteCoordinates)
                                .stroke(Color.prTeal, lineWidth: 5)
                        }
                        MapPolyline(coordinates: [timingConfiguration.startFinish.a, timingConfiguration.startFinish.b])
                            .stroke(Color.prCoral, lineWidth: 6)
                        Annotation("Start/Finish", coordinate: startFinish) {
                            ZStack {
                                Circle().fill(Color.prCoral).frame(width: 28, height: 28)
                                Image(systemName: "flag.checkered").font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                            }
                        }
                    }
                    .mapStyle(.fromIndex(mapStyleIndex))
                    .ignoresSafeArea()

                    VStack(spacing: 0) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 7) {
                                    Circle().fill(Color(red: 0.18, green: 0.62, blue: 0.36)).frame(width: 7, height: 7)
                                    Text("LIVE SESSION").font(.system(size: 10, weight: .heavy)).tracking(2).foregroundColor(.white)
                                }
                                Text(trackName)
                                    .font(.system(size: 22, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                            }
                            Spacer()
                            MapStylePickerView(selectedIndex: $mapStyleIndex)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 22)

                        VStack(spacing: 5) {
                            HStack {
                                Text("CURRENT LAP").font(.system(size: 9, weight: .heavy)).tracking(1.8).foregroundColor(.white.opacity(0.55))
                                Spacer()
                                Text(lapEngine.gpsAccuracyMeters.map { "GPS ±\(Int($0.rounded()))m" } ?? "GPS SEARCHING")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(gpsQualityColor)
                            }
                            Text(LapEngine.formatLapTime(lapEngine.currentLapElapsed))
                                .font(.system(size: 54, weight: .heavy, design: .monospaced)).foregroundColor(.white)
                            HStack {
                                Text("BEST  \(lapEngine.bestLapTime.map { LapEngine.formatLapTime($0) } ?? "--:--")").foregroundColor(.green)
                                Spacer(); Text("LAP \(lapEngine.laps.count + 1)")
                                if let confidence = lapEngine.timingConfidence { Spacer(); Text("CONF \(Int(confidence * 100))%") }
                            }
                            .font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(.white)
                            if !lapEngine.bestSectorTimes.isEmpty {
                                Text("THEORETICAL  \(LapEngine.formatLapTime(lapEngine.bestSectorTimes.reduce(0, +)))")
                                    .font(.system(size: 11, weight: .heavy, design: .monospaced)).foregroundColor(.purple)
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(Color.black.opacity(0.72)).clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.14)))
                        .padding(.horizontal, 16).padding(.top, 14)

                        if let delta = lapEngine.liveDeltaSeconds {
                            VStack(spacing: 5) {
                                HStack { Text(delta < 0 ? "AHEAD" : "BEHIND"); Spacer(); Text(LapEngine.formatDelta(delta)).font(.system(size: 18, weight: .heavy, design: .monospaced)) }
                                GeometryReader { geometry in
                                    ZStack {
                                        Capsule().fill(Color.white.opacity(0.24)).frame(height: 4)
                                        Rectangle().fill(Color.white.opacity(0.65)).frame(width: 1, height: 12)
                                        Circle().fill(deltaColor(for: delta)).frame(width: 10, height: 10)
                                            .offset(x: CGFloat(max(-1, min(1, delta / 3))) * (geometry.size.width / 2 - 5))
                                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                                }.frame(height: 12)
                            }
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundColor(deltaColor(for: delta))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.52))
                            .clipShape(Capsule())
                            .padding(.top, 9)
                        }

                        if lapEngine.inPitLane {
                            Text("PIT LANE · TIMING PAUSED").font(.system(size: 11, weight: .heavy)).foregroundColor(.black)
                                .padding(.horizontal, 12).padding(.vertical, 7).background(Color.yellow).clipShape(Capsule()).padding(.top, 8)
                        } else if let reason = lapEngine.invalidLapReason {
                            Text("INVALID LAP · \(invalidReasonText(reason))").font(.system(size: 11, weight: .heavy)).foregroundColor(.white)
                                .padding(.horizontal, 12).padding(.vertical, 7).background(Color.red).clipShape(Capsule()).padding(.top, 8)
                        }

                        LeanCalibrationBadge(isCalibrating: isLeanCalibrating)
                            .padding(.top, 8)

                        if !isLeanCalibrating && lapEngine.laps.isEmpty {
                            coldTireBanner.padding(.top, 8)
                        }

                        Spacer()

                        VStack(spacing: 12) {
                            HStack(spacing: 9) {
                                liveMetricCard(value: String(format: "%.0f", locationManager.speed), label: "MPH")
                                liveMetricCard(value: String(format: "%.1f", locationManager.distance), label: "MILES")
                                liveMetricCard(value: String(format: "%.0f", locationManager.maxSpeed), label: "TOP MPH")
                            }

                            Button(action: { showEndAlert = true }) {
                                HStack(spacing: 9) {
                                    Image(systemName: "stop.circle.fill")
                                    Text("End Session")
                                }
                                .font(.system(size: 16, weight: .heavy))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .background(Color.prCoral)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                            }
                        }
                        .padding(16)
                        .background(Color.black.opacity(0.64))
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.12), lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                    }
                }
                .alert("End Session?", isPresented: $showEndAlert) {
                    Button("End Session", role: .destructive) { endSession() }
                    Button("Keep Riding", role: .cancel) {}
                } message: {
                    Text("You'll see your lap times and best lap.")
                }
                .onChange(of: locationManager.location) { _, loc in
                    guard let loc else { return }
                    lapEngine.processLocation(loc)
                    gpxRecorder.capturePoint(location: loc)
                    liveRouteCoordinates.append(loc.coordinate)
                    if liveRouteCoordinates.count > 2_000 { liveRouteCoordinates.removeFirst(500) }
                }
                .onAppear { startSession() }
                .onDisappear {
                    if sessionStarted {
                        stopRideServices()
                        gpxRecorder.cancelRecording()
                    }
                }
            }
        }
        .sheet(isPresented: $showLayoutSubmission) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Create Community Layout")
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                    Text("Your fastest completed lap will become a pending community layout. Other riders can confirm it before it becomes verified.")
                        .font(.system(size: 14)).foregroundColor(.secondary)
                    TextField("Layout name (for example: Loop A)", text: $proposedLayoutName)
                        .textFieldStyle(.roundedBorder)
                    if let layoutSubmissionMessage {
                        Text(layoutSubmissionMessage).font(.system(size: 13, weight: .semibold))
                            .foregroundColor(layoutSubmissionMessage.contains("Submitted") ? .green : .red)
                    }
                    Button {
                        submitCommunityLayout()
                    } label: {
                        HStack {
                            if submittingLayout { ProgressView().tint(.white) }
                            Text(submittingLayout ? "Submitting…" : "Submit Layout")
                        }
                        .font(.system(size: 15, weight: .heavy)).foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(proposedLayoutName.trimmingCharacters(in: .whitespaces).isEmpty ? Color.gray : Color.prCoral)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(submittingLayout || proposedLayoutName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                }
                .padding(20)
                .navigationTitle("Save Layout")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Not Now") { showLayoutSubmission = false } } }
            }
            .presentationDetents([.medium])
        }
    }

    private func lapOverlayMetric(label: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 8, weight: .heavy)).tracking(1.4).foregroundColor(.white.opacity(0.5))
            Text(value).font(.system(size: 18, weight: .bold, design: .monospaced)).foregroundColor(accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.black.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var gpsQualityColor: Color {
        guard let accuracy = lapEngine.gpsAccuracyMeters else { return .yellow }
        if accuracy <= 8 { return .green }
        if accuracy <= 18 { return .yellow }
        return .red
    }

    private func invalidReasonText(_ reason: TimingInvalidReason) -> String {
        switch reason {
        case .wrongDirection: return "WRONG DIRECTION"
        case .skippedSector: return "SECTOR MISSED"
        case .tooShort: return "TOO SHORT"
        }
    }

    private func liveMetricCard(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 17, weight: .bold, design: .monospaced)).foregroundColor(.white)
            Text(label).font(.system(size: 9, weight: .heavy)).tracking(1.2).foregroundColor(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Top Overlay
    private var topOverlay: some View {
        VStack(spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(Color(red: 0.827, green: 0.231, blue: 0.173)).frame(width: 8, height: 8)
                    Text("LAPPING").font(.system(size: 11, weight: .bold)).foregroundColor(.white).tracking(2)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.black.opacity(0.5)).cornerRadius(12)
                Spacer()
                MapStylePickerView(selectedIndex: $mapStyleIndex)
                Text(trackName)
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.black.opacity(0.5)).cornerRadius(10)
            }
            .padding(.horizontal, 16).padding(.top, 50)

            // Aug 24, 2026 — see LeanCalibrationBadge.swift's header. Answers
            // Karthik's "how does the rider know it's calibrated to 0?"
            LeanCalibrationBadge(isCalibrating: isLeanCalibrating)

            if lapEngine.laps.isEmpty {
                coldTireBanner
            }

            VStack(spacing: 2) {
                Text(LapEngine.formatLapTime(lapEngine.currentLapElapsed))
                    .font(.system(size: 58, weight: .heavy, design: .monospaced))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.5), radius: 4)
                Text("CURRENT LAP")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.9)).tracking(3)
                // Live delta vs. best lap's own pace at this exact distance
                // into the lap — nil (and hidden) until there's a best lap
                // to compare against, or once this lap has gone further
                // than the best lap's trace covers. See
                // LapEngine.refreshLiveDelta().
                if let delta = lapEngine.liveDeltaSeconds {
                    VStack(spacing: 1) {
                        Text(LapEngine.formatDelta(delta))
                            .font(.system(size: 17, weight: .bold, design: .monospaced))
                            .foregroundColor(deltaColor(for: delta))
                            .shadow(color: .black.opacity(0.5), radius: 3)
                        Text("VS BEST LAP")
                            .font(.system(size: 9, weight: .semibold)).foregroundColor(.white.opacity(0.6)).tracking(2)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.top, 6)

            HStack(spacing: 10) {
                lapStatChip(label: "Last Lap", value: lapEngine.lastLapTime.map { LapEngine.formatLapTime($0) } ?? "--:--")
                lapStatChip(label: "Best Lap", value: lapEngine.bestLapTime.map { LapEngine.formatLapTime($0) } ?? "--:--", highlight: true)
                lapStatChip(label: "Laps", value: "\(lapEngine.laps.count)")
            }
            .padding(.horizontal, 16).padding(.top, 6)
        }
    }

    // MARK: - Cold Tire Warning
    // Shown only while the rider is still on their very first lap of the
    // session — a pure UI read of data the lap-crossing engine already
    // tracks (laps.isEmpty), no new state needed. Disappears on its own the
    // instant the first lap completes. Non-dismissible by design — it's
    // meant to go away because the situation resolved, not because it was
    // tapped away.
    private var coldTireBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "thermometer.low").font(.system(size: 11, weight: .semibold))
            Text("Cold tires — ease in this first lap").font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(Color(red: 0.976, green: 0.702, blue: 0.153))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.black.opacity(0.5))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color(red: 0.976, green: 0.702, blue: 0.153).opacity(0.4), lineWidth: 1))
    }

    // Negative delta (current lap running faster than the best lap's own
    // pace here) reads as green/ahead; positive (slower) reads as red/behind.
    private func deltaColor(for delta: Double) -> Color {
        delta < 0 ? Color(red: 0.180, green: 0.620, blue: 0.357) : Color(red: 0.827, green: 0.231, blue: 0.173)
    }

    private func lapStatChip(label: String, value: String, highlight: Bool = false) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(highlight ? Color(red: 0.373, green: 0.851, blue: 0.541) : .white)
            Text(label).font(.system(size: 9)).foregroundColor(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(Color.black.opacity(0.4)).cornerRadius(10)
    }

    // MARK: - Bottom Overlay
    private var bottomOverlay: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                VStack(spacing: 3) {
                    Text(String(format: "%.0f", locationManager.speed))
                        .font(.system(size: 18, weight: .bold, design: .monospaced)).foregroundColor(.white)
                    Text("MPH").font(.system(size: 10)).foregroundColor(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(Color.black.opacity(0.4)).cornerRadius(12)

                VStack(spacing: 3) {
                    Text(String(format: "%.1f", locationManager.distance))
                        .font(.system(size: 18, weight: .bold, design: .monospaced)).foregroundColor(.white)
                    Text("Miles").font(.system(size: 10)).foregroundColor(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(Color.black.opacity(0.4)).cornerRadius(12)

                VStack(spacing: 3) {
                    Text(String(format: "%.0f", locationManager.maxSpeed))
                        .font(.system(size: 18, weight: .bold, design: .monospaced)).foregroundColor(.white)
                    Text(MeasurementUnits.current == .metric ? "Top km/h" : "Top mph").font(.system(size: 10)).foregroundColor(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(Color.black.opacity(0.4)).cornerRadius(12)
            }
            .padding(.horizontal, 16)

            Button(action: { showEndAlert = true }) {
                HStack(spacing: 10) {
                    Image(systemName: "stop.circle.fill").font(.system(size: 22))
                    Text("End Session").font(.system(size: 17, weight: .bold))
                }
                .foregroundColor(.white).frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color(red: 0.827, green: 0.231, blue: 0.173))
                .cornerRadius(16)
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 30)
        }
    }

    // MARK: - Session Lifecycle
    private func startSession() {
        guard !sessionStarted else { return }
        sessionStarted = true
        locationManager.requestPermission()
        locationManager.resetTracking()
        // Aug 27, 2026 — Grok Track Mode audit, priority #3: tagged
        // "lapTracking" instead of the generic default so
        // SharedLoactionManager's accuracy tiering gives this session the
        // tighter 3m distance filter — lap crossings care about denser
        // samples near the line more than a street ride does.
        locationManager.startTracking(reason: "lapTracking")
        gpxRecorder.startRecording(rideName: "\(trackName)_Laps", timingPoint: startFinish)
        if offersCommunityLayoutSubmission {
            // A single manually placed point has no meaningful orientation.
            // Learn a centered line perpendicular to the first valid moving
            // GPS course instead of assuming an east-west gate.
            lapEngine.begin(at: startFinish, direction: timingConfiguration.startFinish.direction)
        } else {
            lapEngine.begin(configuration: timingConfiguration)
        }
        startMotionCapture()
    }

    private func endSession() {
        let laps = lapEngine.laps
        let best = lapEngine.bestLapTime ?? 0
        let dist = locationManager.distance
        let maxSpd = locationManager.maxSpeed
        let gpx = gpxRecorder.stopAndSave()
        completedGPXPath = gpx

        stopRideServices()

        finalLaps = laps
        finalBest = best
        finalDistance = dist
        finalMaxSpeed = maxSpd
        finalGPXPath = gpx
        // Track Score: consistency from the lap splits + smoothness from the
        // GPX that was just recorded (now with real G-force/lean data, see
        // startMotionCapture below). nil if there weren't at least 2
        // completed laps — see LapAnalyticsEngine.analyze.
        let analytics = LapAnalyticsEngine.analyze(gpxFilePath: gpx, laps: laps)
        finalAnalytics = analytics

        // Record right when the session actually ends, not whenever this
        // view eventually finishes dismissing — the two used to be separate
        // steps chained together with a timer.
        if !laps.isEmpty || dist > 0 {
            finalSessionId = LapHistoryManager.recordSession(
                trackName: trackName, laps: laps, bestLapTime: best,
                totalDistance: dist, maxSpeed: maxSpd, gpxFilePath: gpx, analytics: analytics,
                bikeId: BikeManager.currentActiveBikeID(),
                lapStartTimestamps: lapEngine.lapStartTimestamps
            )
        }
        sessionEnded = true
        if offersCommunityLayoutSubmission && laps.count >= 2 && !lapEngine.bestLapCoordinates.isEmpty {
            showLayoutSubmission = true
        }
    }

    private func submitCommunityLayout() {
        submittingLayout = true
        layoutSubmissionMessage = nil
        CommunityTrackLayoutService.submit(
            venueName: trackName, layoutName: proposedLayoutName,
            bestLapRoute: lapEngine.bestLapCoordinates, timing: timingConfiguration,
            completedLapCount: lapEngine.laps.count, timingConfidence: lapEngine.timingConfidence
        ) { result in
            submittingLayout = false
            switch result {
            case .success:
                layoutSubmissionMessage = "Submitted for community confirmation."
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { showLayoutSubmission = false }
            case .failure(let error): layoutSubmissionMessage = error.localizedDescription
            }
        }
    }

    private func stopRideServices() {
        locationManager.stopTracking(reason: "lapTracking")
        lapEngine.stop()
        stopMotionCapture()
        sessionStarted = false
    }

    // MARK: - Motion Capture (G-force + lean angle)
    // Same CoreMotion pattern as solo rides (ActiveSoloRideView) — feeds the
    // GPX recorder directly rather than also driving a live on-screen
    // readout, since Track Mode's HUD doesn't currently show G-force/lean.
    private func startMotionCapture() {
        leanCalibrated = false
        // Aug 24, 2026 — reset alongside leanCalibrated so a restarted
        // session re-runs the full averaging window below instead of reusing
        // stale samples or leaving the badge stuck hidden.
        leanCalibrationSamples = []
        isLeanCalibrating = true
        if motionManager.isAccelerometerAvailable {
            motionManager.accelerometerUpdateInterval = 0.2   // 5Hz — GPX only, no live gauge to keep smooth
            motionManager.startAccelerometerUpdates(to: motionQueue) { data, _ in
                guard let data else { return }
                let g = sqrt(data.acceleration.x * data.acceleration.x +
                             data.acceleration.y * data.acceleration.y +
                             data.acceleration.z * data.acceleration.z)
                // Aug 27, 2026 — independent review catch: gpxRecorder.currentGForce
                // is a plain var, but it's READ on main inside GPXRecorder.capturePoint
                // (called from .onChange(of: locationManager.location), which runs on
                // main). Writing it from motionQueue with no hop was an unsynchronized
                // cross-thread race this move introduced — wrapping it here restores
                // the same main-thread serialization the old `to: .main` delivery gave
                // it for free.
                DispatchQueue.main.async {
                    gpxRecorder.currentGForce = g
                }
            }
        }
        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = 0.25   // ~4Hz — same reasoning as above
            motionManager.startDeviceMotionUpdates(to: motionQueue) { motion, _ in
                guard let motion else { return }
                let rollDegrees = motion.attitude.roll * 180 / .pi
                DispatchQueue.main.async {
                    if !leanCalibrated {
                        // Aug 24, 2026 — leanZeroOffset used to be locked from a
                        // single reading taken the instant capture started, which
                        // is right as the rider's hand is still leaving the Start
                        // button — a moment as likely as any to catch some
                        // tap/hand motion rather than the phone actually settled
                        // on its mount. Averaging leanCalibrationSampleCount
                        // consecutive readings before locking the zero point in
                        // smooths out exactly that kind of momentary jostle.
                        leanCalibrationSamples.append(rollDegrees)
                        guard leanCalibrationSamples.count >= Self.leanCalibrationSampleCount else {
                            return // still settling — gpxRecorder.currentLeanAngle stays at its default
                        }
                        leanZeroOffset = leanCalibrationSamples.reduce(0, +) / Double(leanCalibrationSamples.count)
                        leanCalibrated = true
                        isLeanCalibrating = false
                    }
                    let rawLean = rollDegrees - leanZeroOffset
                    gpxRecorder.currentLeanAngle = max(-65, min(65, rawLean))
                }
            }
        }
    }

    private static let leanCalibrationSampleCount = 5

    private func stopMotionCapture() {
        motionManager.stopAccelerometerUpdates()
        motionManager.stopDeviceMotionUpdates()
    }
}

// MARK: - Lap Session Summary
struct LapSessionSummaryView: View {
    let trackName: String
    let laps: [Double]
    let bestLapTime: Double
    let distance: Double
    let maxSpeed: Double
    var gpxFilePath: String? = nil
    var date: Date = Date()
    var analytics: LapAnalyticsSummary? = nil
    // Aug 24, 2026 — Lap Compare/Sharing. The LapHistoryManager id for THIS
    // exact session — nil only for the rare edge case where the session was
    // never actually saved to history (no laps and no distance recorded).
    // "Compare Laps" and "Share With a Friend" both need it: Compare Laps to
    // preset Slot A with this session's best lap, Share to build the LapRecord
    // LapSharingManager.shareSession uploads.
    var sessionId: String? = nil
    var lapStartTimestamps: [Int64] = []

    @Environment(\.dismiss) var dismiss
    // Aug 27, 2026 — Grok polish: use the app-wide UserProfileManager injected
    // from PackRideApp (same instance ContentView / ActiveSoloRideView already
    // share) instead of spinning up a private StateObject that opened its own
    // follow-list Firebase listeners on the summary screen.
    @EnvironmentObject private var profileManager: UserProfileManager
    @AppStorage("riderName") var riderName: String = "Rider"
    @State private var showPostToFeed = false
    @State private var showFriendPicker = false
    @StateObject private var sharingManager = LapSharingManager()
    @State private var shareResultMessage: String? = nil
    @State private var showSystemShare = false
    @State private var systemShareText = ""

    private var formattedDate: String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: date)
    }

    // The lap this session is proudest of — used to preset Lap Compare's
    // Slot A. Falls back to lap 0 if, somehow, no lap exactly matches
    // bestLapTime (shouldn't happen — bestLapTime is always copied straight
    // from one of these values, never recomputed, same as the "lap ==
    // bestLapTime" check the Lap Times list below already relies on).
    private var bestLapIndex: Int { laps.firstIndex(where: { $0 == bestLapTime }) ?? 0 }

    private func asLapRecord() -> LapRecord? {
        guard let sessionId, let gpxFilePath else { return nil }
        return LapRecord(
            id: sessionId, date: date, trackName: trackName, laps: laps, bestLapTime: bestLapTime,
            totalDistance: distance, maxSpeed: maxSpeed, gpxFilePath: gpxFilePath, analytics: analytics,
            lapStartTimestamps: lapStartTimestamps
        )
    }

    var body: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    PRWebPageHeader(
                        eyebrow: "TRACK SESSION",
                        title: trackName.isEmpty ? "Session Complete" : trackName,
                        subtitle: "Recorded \(formattedDate) · \(laps.count) completed lap\(laps.count == 1 ? "" : "s")"
                    )

                    PRWebMetricStrip(metrics: [
                        ("\(laps.count)", "Laps"),
                        (bestLapTime > 0 ? LapEngine.formatLapTime(bestLapTime) : "--:--", "Best Lap"),
                        (String(format: "%.1f", distance), "Miles")
                    ])
                    .padding(.top, 2)

                    if let analytics {
                        PRWebSectionLabel(title: "Performance", detail: "Track score")
                        TrackScoreCard(analytics: analytics)
                            .padding(.horizontal, 20)
                    }

                    PRWebSectionLabel(title: "Lap Times", detail: "Fastest first")
                    if !laps.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(laps.enumerated()), id: \.offset) { index, lap in
                                HStack(spacing: 12) {
                                    Text(String(format: "%02d", index + 1))
                                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                                        .foregroundColor(.prMuted)
                                        .frame(width: 24, alignment: .leading)
                                    Text("Lap \(index + 1)")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.prInk)
                                    Spacer()
                                    if lap == bestLapTime {
                                        Text("BEST")
                                            .font(.system(size: 8, weight: .heavy))
                                            .tracking(1.2)
                                            .foregroundColor(Color(red: 0.18, green: 0.62, blue: 0.36))
                                    }
                                    Text(LapEngine.formatLapTime(lap))
                                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                                        .foregroundColor(lap == bestLapTime ? Color(red: 0.18, green: 0.62, blue: 0.36) : .prInk)
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 13)
                                if index < laps.count - 1 { PRWebDivider(inset: 56) }
                            }
                        }
                        .background(Color.prCardBg)
                        .overlay(Rectangle().fill(Color.prBorder).frame(height: 1), alignment: .top)
                        .overlay(Rectangle().fill(Color.prBorder).frame(height: 1), alignment: .bottom)
                    } else {
                        Text("No completed laps were detected for this session.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.prMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 24)
                    }

                    PRWebSectionLabel(title: "Actions")
                    VStack(spacing: 0) {
                        if let gpxFilePath, !gpxFilePath.isEmpty {
                            NavigationLink {
                                GPXRouteMapView(gpxFilePath: gpxFilePath, rideName: trackName, rideDate: formattedDate)
                            } label: {
                                webActionLabel(icon: "map.fill", title: "View Racing Line", subtitle: "See this session on the track", tint: .prTeal)
                            }
                            .buttonStyle(.plain)
                            PRWebDivider(inset: 56)
                        }
                        if let gpxFilePath, !laps.isEmpty {
                            NavigationLink {
                                LapCompareView(presetSlotA: LapCompareView.PresetLap(
                                    trackName: trackName.isEmpty ? "Track Session" : trackName, date: date,
                                    lapIndex: bestLapIndex, lapDurations: laps,
                                    lapStartTimestamps: lapStartTimestamps, gpxFilePath: gpxFilePath
                                ))
                            } label: {
                                webActionLabel(icon: "chart.xyaxis.line", title: "Compare Laps", subtitle: "Put this session beside another", tint: .prCoral)
                            }
                            .buttonStyle(.plain)
                        } else {
                            webActionRow(icon: "chart.xyaxis.line", title: "Compare Laps", subtitle: "Put this session beside another", tint: .prCoral, disabled: true) {}
                        }
                        PRWebDivider(inset: 56)
                        webActionRow(icon: "person.badge.plus", title: "Share With a Friend", subtitle: "Send the recorded session", tint: .prCoral, disabled: sessionId == nil || gpxFilePath == nil) { showFriendPicker = true }
                        PRWebDivider(inset: 56)
                        webActionRow(icon: "newspaper.fill", title: "Post to Feed", subtitle: "Share your result with the Pack", tint: .prCoral, disabled: laps.isEmpty) { showPostToFeed = true }
                        PRWebDivider(inset: 56)
                        webActionRow(icon: "square.and.arrow.up", title: "Share My Session", subtitle: "Share a quick summary", tint: .prInk) {
                            systemShareText = "Just ran \(laps.count) laps at \(trackName) on PackRide! Best lap: \(bestLapTime > 0 ? LapEngine.formatLapTime(bestLapTime) : "--:--")"
                            showSystemShare = true
                        }
                    }
                    .background(Color.prCardBg)

                    Button(action: { dismiss() }) {
                        Text("Done")
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(Color.prCoral)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                }
            }
        }
        .onAppear { profileManager.listenForFollowedUsers() }
        .onDisappear { profileManager.stopListeningForFollowedUsers() }
        .sheet(isPresented: $showPostToFeed) {
            PostLapToFeedSheet(trackName: trackName, laps: laps, bestLapTime: bestLapTime, distance: distance)
        }
        .sheet(isPresented: $showFriendPicker) {
            FriendPickerSheet(friends: profileManager.followedUsers) { friend in
                guard let record = asLapRecord() else { return }
                sharingManager.shareSession(record, ownerName: riderName, recipientUID: friend.id) { error in
                    shareResultMessage = error ?? "Shared \"\(trackName.isEmpty ? "Track Session" : trackName)\" with \(friend.name)!"
                }
            }
        }
        .sheet(isPresented: $showSystemShare) {
            TrackSessionActivitySheet(items: [systemShareText])
        }
        .alert("Share With a Friend", isPresented: Binding(
            get: { shareResultMessage != nil }, set: { if !$0 { shareResultMessage = nil } }
        )) {
            Button("OK", role: .cancel) { shareResultMessage = nil }
        } message: { Text(shareResultMessage ?? "") }
    }
}

private struct TrackSessionActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private func webActionRow(icon: String, title: String, subtitle: String, tint: Color, disabled: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        webActionLabel(icon: icon, title: title, subtitle: subtitle, tint: tint)
            .opacity(disabled ? 0.35 : 1)
    }
    .disabled(disabled)
    .buttonStyle(.plain)
}

private func webActionLabel(icon: String, title: String, subtitle: String, tint: Color) -> some View {
    HStack(spacing: 13) {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(tint)
            .frame(width: 26)
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundColor(.prInk)
            Text(subtitle).font(.system(size: 11)).foregroundColor(.prMuted)
        }
        Spacer()
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.prMuted.opacity(0.7))
    }
    .contentShape(Rectangle())
    .padding(.horizontal, 20)
    .padding(.vertical, 14)
}

// MARK: - Track Score Card (shown right after a session ends)
// Mirrors RideScoreCard's look, but bound to LapAnalyticsSummary — a
// composite of lap-time consistency and GPS/motion smoothness rather than
// smoothness alone, since consistency is usually the first thing that
// improves as a rider gets better at a track.
struct TrackScoreCard: View {
    let analytics: LapAnalyticsSummary

    var scoreColor: Color {
        switch analytics.trackScore {
        case 90...100: return Color(red: 0.180, green: 0.620, blue: 0.357)
        case 75..<90: return .prTeal
        case 55..<75: return .prCoral
        default: return Color(red: 0.827, green: 0.231, blue: 0.173)
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(Color.prBorder, lineWidth: 6).frame(width: 60, height: 60)
                    Circle()
                        .trim(from: 0, to: CGFloat(analytics.trackScore) / 100)
                        .stroke(scoreColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .frame(width: 60, height: 60)
                        .rotationEffect(.degrees(-90))
                    Text("\(analytics.trackScore)")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(.prInk)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Track Score: \(analytics.scoreGrade)")
                        .font(.system(size: 15, weight: .bold)).foregroundColor(.prInk)
                    Text("Consistency + smoothness, estimated from GPS + motion sensors")
                        .font(.system(size: 10)).foregroundColor(.prMuted)
                }
                Spacer()
            }

            Divider().background(Color.prBorder)

            HStack(spacing: 0) {
                AnalyticsStatItem(icon: "chart.bar.fill", value: "\(analytics.consistencyScore)", label: "Consistency")
                AnalyticsStatItem(icon: "wind", value: "\(analytics.smoothnessScore)", label: "Smoothness")
                AnalyticsStatItem(icon: "angle", value: String(format: "%.0f°", analytics.maxLeanAngle), label: "Max Lean")
                AnalyticsStatItem(icon: "hand.raised.fill", value: "\(analytics.hardBrakeCount)", label: "Hard Brakes")
            }
        }
        .padding(16)
        .background(Color.prCardBg)
        .cornerRadius(18)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.prBorder, lineWidth: 1))
    }
}

// MARK: - Post Lap Session To Feed
struct PostLapToFeedSheet: View {
    let trackName: String
    let laps: [Double]
    let bestLapTime: Double
    let distance: Double

    @AppStorage("riderName") var riderName: String = "Rider"
    @StateObject private var feedManager = RideFeedManager()
    @State private var title: String = ""
    @State private var isPosting = false
    @State private var posted = false
    @State private var errorMessage: String? = nil
    @Environment(\.dismiss) var dismiss

    var myInitials: String { riderName.rideInitials }

    var body: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()
            VStack(spacing: 20) {
                RoundedRectangle(cornerRadius: 3).fill(Color.prBorder)
                    .frame(width: 40, height: 5).padding(.top, 12)

                if posted {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 44)).foregroundColor(Color(red: 0.180, green: 0.620, blue: 0.357))
                        Text("Posted to Feed!").font(.system(size: 18, weight: .bold)).foregroundColor(.prInk)
                    }
                    .padding(.top, 40)

                    Button(action: { dismiss() }) {
                        Text("Done").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(Color.prCoral).cornerRadius(16)
                    }
                    .padding(.horizontal, 20)
                } else {
                    VStack(spacing: 6) {
                        Text("Share to Feed?").font(.system(size: 20, weight: .bold)).foregroundColor(.prInk)
                        Text("Riders who follow you will see your lap times under \"My Laps.\"")
                            .font(.system(size: 13)).foregroundColor(.prMuted)
                            .multilineTextAlignment(.center).padding(.horizontal, 30)
                    }

                    TextField("Session title", text: $title)
                        .foregroundColor(.prInk)
                        .padding(14).background(Color.prCardBg).cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.prBorder, lineWidth: 1))
                        .padding(.horizontal, 20)

                    HStack(spacing: 20) {
                        Text("\(laps.count) laps")
                        Text("Best: \(bestLapTime > 0 ? LapEngine.formatLapTime(bestLapTime) : "--:--")")
                    }
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(.prMuted)

                    Button(action: post) {
                        Group {
                            if isPosting {
                                ProgressView().tint(.white)
                            } else {
                                Text("Post to Feed").font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.vertical, 16).background(Color.prCoral).cornerRadius(16)
                    .padding(.horizontal, 20)
                    .disabled(isPosting || title.trimmingCharacters(in: .whitespaces).isEmpty)

                    if let errorMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(errorMessage)
                        }
                        .font(.system(size: 12)).foregroundColor(Color(red: 0.827, green: 0.231, blue: 0.173))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                    }

                    Button(action: { dismiss() }) {
                        Text("Not Now").font(.system(size: 14)).foregroundColor(.prMuted)
                    }
                }
                Spacer()
            }
        }
        .onAppear { if title.isEmpty { title = "\(trackName) Laps" } }
    }

    func post() {
        isPosting = true
        errorMessage = nil
        feedManager.postLapSession(
            title: title, trackName: trackName, laps: laps, bestLapTime: bestLapTime, distance: distance,
            authorName: riderName, authorInitials: myInitials
        ) { failure in
            isPosting = false
            if let failure {
                errorMessage = failure
            } else {
                withAnimation { posted = true }
            }
        }
    }
}
