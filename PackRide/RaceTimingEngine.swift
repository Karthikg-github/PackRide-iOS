import Foundation
import CoreLocation

enum GateDirection: String, Codable { case negativeToPositive, positiveToNegative }

struct TimingGate: Codable {
    var id: String
    var a: CLLocationCoordinate2D
    var b: CLLocationCoordinate2D
    var direction: GateDirection
}

struct TrackTimingConfiguration: Codable {
    var startFinish: TimingGate
    var sectors: [TimingGate] = []
    var minimumLapSeconds: Double = 12
    var finishGate: TimingGate? = nil
    var pitEntryGate: TimingGate? = nil
    var pitExitGate: TimingGate? = nil
}

enum TimingInvalidReason: String { case wrongDirection, skippedSector, tooShort }
enum RaceTimingEvent {
    case fixRejected(accuracy: Double, age: Double)
    case lapStarted(Date)
    case sectorCompleted(index: Int, seconds: Double, date: Date)
    case lapCompleted(seconds: Double, sectors: [Double], date: Date, confidence: Double)
    case lapInvalid(TimingInvalidReason, Date)
    case pitStateChanged(Bool, Date)
}

/// Behaviorally matched to Android's pure Kotlin RaceTimingEngine.
final class RaceTimingEngine {
    private let configuration: TrackTimingConfiguration
    private var previous: CLLocation?
    private var lapStart: Date?
    private var lastSplit: Date?
    private var nextSectorIndex = 0
    private var sectorTimes: [Double] = []
    private var worstAccuracy = 0.0
    private var inPitLane = false
    // The setup arrow is only a hint. On the first real crossing, learn the
    // direction the rider is actually travelling so a reversed/manual line
    // cannot leave the timer silently unarmed for the whole session.
    private var learnedStartFinishDirection: GateDirection?

    init(configuration: TrackTimingConfiguration) { self.configuration = configuration }

    func reset() {
        previous = nil; lapStart = nil; lastSplit = nil; nextSectorIndex = 0
        sectorTimes = []; worstAccuracy = 0; inPitLane = false
        learnedStartFinishDirection = nil
    }

    /// Arms a manually positioned, course-oriented gate immediately so the
    /// rider's first full loop is Lap 1 rather than an unrecorded out lap.
    func armFirstLap(at date: Date) {
        learnedStartFinishDirection = .positiveToNegative
        startLap(date)
    }

    func process(_ sample: CLLocation, now: Date = Date()) -> [RaceTimingEvent] {
        let age = abs(now.timeIntervalSince(sample.timestamp))
        guard sample.horizontalAccuracy >= 0, sample.horizontalAccuracy <= 25, age <= 3 else {
            return [.fixRejected(accuracy: sample.horizontalAccuracy, age: age)]
        }
        guard let from = previous, sample.timestamp > from.timestamp else {
            previous = sample; worstAccuracy = max(worstAccuracy, sample.horizontalAccuracy); return []
        }
        previous = sample
        worstAccuracy = max(worstAccuracy, sample.horizontalAccuracy)
        var events: [RaceTimingEvent] = []

        if let gate = configuration.pitExitGate, let hit = crossing(from, sample, gate), hit.correct {
            inPitLane = false; events.append(.pitStateChanged(false, hit.date))
        }
        if let gate = configuration.pitEntryGate, let hit = crossing(from, sample, gate), hit.correct {
            inPitLane = true; events.append(.pitStateChanged(true, hit.date))
        }
        guard !inPitLane else { return events }

        if nextSectorIndex < configuration.sectors.count,
           let hit = crossing(from, sample, configuration.sectors[nextSectorIndex]), hit.correct,
           let start = lapStart {
            let prior = lastSplit ?? start
            let split = hit.date.timeIntervalSince(prior)
            sectorTimes.append(split); lastSplit = hit.date
            events.append(.sectorCompleted(index: nextSectorIndex, seconds: split, date: hit.date))
            nextSectorIndex += 1
        }

        var activeGate = lapStart == nil ? configuration.startFinish : (configuration.finishGate ?? configuration.startFinish)
        if activeGate.id == configuration.startFinish.id, let learnedStartFinishDirection {
            activeGate.direction = learnedStartFinishDirection
        }
        guard let hit = crossing(from, sample, activeGate) else { return events }
        if lapStart == nil && learnedStartFinishDirection == nil {
            learnedStartFinishDirection = hit.correct
                ? activeGate.direction
                : (activeGate.direction == .negativeToPositive ? .positiveToNegative : .negativeToPositive)
            startLap(hit.date); events.append(.lapStarted(hit.date)); return events
        }
        guard hit.correct else {
            if lapStart != nil { events.append(.lapInvalid(.wrongDirection, hit.date)) }
            return events
        }
        guard let start = lapStart else {
            startLap(hit.date); events.append(.lapStarted(hit.date)); return events
        }
        let elapsed = hit.date.timeIntervalSince(start)
        if nextSectorIndex < configuration.sectors.count {
            events.append(.lapInvalid(.skippedSector, hit.date))
        } else if elapsed < configuration.minimumLapSeconds {
            events.append(.lapInvalid(.tooShort, hit.date))
        } else {
            let finalStart = lastSplit ?? start
            events.append(.lapCompleted(seconds: elapsed, sectors: sectorTimes + [hit.date.timeIntervalSince(finalStart)], date: hit.date, confidence: max(0, min(1, 1 - worstAccuracy / 25))))
        }
        if configuration.finishGate == nil { startLap(hit.date); events.append(.lapStarted(hit.date)) }
        else { lapStart = nil; lastSplit = nil }
        return events
    }

    private func startLap(_ date: Date) {
        lapStart = date; lastSplit = date; nextSectorIndex = 0; sectorTimes = []; worstAccuracy = 0
    }

    private func crossing(_ from: CLLocation, _ to: CLLocation, _ gate: TimingGate) -> (date: Date, correct: Bool)? {
        let originLat = (gate.a.latitude + gate.b.latitude) / 2
        func xy(_ coordinate: CLLocationCoordinate2D) -> (Double, Double) {
            (coordinate.longitude * cos(originLat * .pi / 180) * 111_320, coordinate.latitude * 111_320)
        }
        let (ax, ay) = xy(gate.a), (bx, by) = xy(gate.b)
        let (px, py) = xy(from.coordinate), (qx, qy) = xy(to.coordinate)
        let rx = qx-px, ry = qy-py, sx = bx-ax, sy = by-ay
        func cross(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double { x1*y2-y1*x2 }
        let denominator = cross(rx, ry, sx, sy)
        guard abs(denominator) >= 1e-9 else { return nil }
        let t = cross(ax-px, ay-py, sx, sy) / denominator
        let u = cross(ax-px, ay-py, rx, ry) / denominator
        guard (0...1).contains(t), (0...1).contains(u) else { return nil }
        let fromSide = cross(sx, sy, px-ax, py-ay), toSide = cross(sx, sy, qx-ax, qy-ay)
        guard fromSide != 0, toSide != 0, fromSide * toSide < 0 else { return nil }
        let correct = gate.direction == .negativeToPositive ? (fromSide < 0 && toSide > 0) : (fromSide > 0 && toSide < 0)
        return (from.timestamp.addingTimeInterval(to.timestamp.timeIntervalSince(from.timestamp) * t), correct)
    }
}

extension CLLocationCoordinate2D: @retroactive Codable {
    enum CodingKeys: String, CodingKey { case latitude, longitude }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(latitude: try values.decode(Double.self, forKey: .latitude), longitude: try values.decode(Double.self, forKey: .longitude))
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(latitude, forKey: .latitude); try values.encode(longitude, forKey: .longitude)
    }
}
