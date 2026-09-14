import Foundation
import UIKit
import SwiftUI
import Combine
import FirebaseDatabase

// MARK: - Moto Run multiplayer session
// Aug 27, 2026 — backs the "Invite Friends" flow in MotoRunView: up to 3
// riders (1 host + 2 guests) race the same obstacle sequence together.
// Deliberately its own Firebase root ("motorun/{code}/...", separate from
// "rides/...") and its own lightweight Database reference — same
// self-contained principle as the rest of Moto Run: a bug here can never
// touch real ride-tracking data.
//
// Sync design: obstacles are NEVER sent over the network. Every device
// generates the identical obstacle schedule locally from one shared `seed`
// (see RaceObstacleSchedule) plus a shared `raceStartAt` server-corrected
// timestamp, so every obstacle's position at any instant is a pure function
// of elapsed time — no per-frame network traffic, and nothing to drift even
// if a device's own frame timer stutters. What IS synced, at a low rate, is
// each rider's own authoritative state: bike color/initials, a jump counter
// (so other devices know when to replay a hop), and score/alive/finished
// once they crash or the race ends. No device ever re-derives *another*
// rider's collisions — each device is the sole authority on whether *it*
// crashed, and broadcasts that fact.

enum MotoBikeColor {
    static let palette: [Color] = [
        .prCoral,
        .prTeal,
        Color(red: 0.180, green: 0.620, blue: 0.357),
        Color(red: 0.541, green: 0.4, blue: 0.694),
        Color(red: 0.196, green: 0.4, blue: 0.808),
        Color(red: 0.85, green: 0.32, blue: 0.55)
    ]
    static let names = ["Coral", "Teal", "Green", "Purple", "Blue", "Pink"]
}

struct MotoRacer: Identifiable, Equatable {
    let id: String            // device identifierForVendor
    var initials: String
    var colorIndex: Int
    var isHost: Bool
    var jumpCount: Int = 0
    var score: Int = 0
    var alive: Bool = true
    var finished: Bool = false   // this rider's run has ended (crashed, or race timed out while they were still alive)

    var color: Color { MotoBikeColor.palette[colorIndex % MotoBikeColor.palette.count] }
}

enum MotoRaceState: String {
    case idle    // no multiplayer session — solo play
    case lobby   // waiting room, race not started
    case active  // countdown + racing — distinguished locally by elapsed time (see MotoRunSessionManager.elapsed)
}

// Deterministic seeded RNG (SplitMix64) — identical algorithm on every
// device, so `SeededGenerator(seed: x)` produces the exact same sequence
// everywhere, letting the obstacle schedule be generated locally instead of
// transmitted.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// Pure function of elapsed race time — the same speed/distance curve
// computed identically on every device, so obstacle positions never need
// syncing. Units are points/second rather than points/frame so the math
// doesn't depend on any device's actual frame rate.
enum MotoRacePhysics {
    static let baseSpeed: Double = 190
    static let maxSpeed: Double = 660
    static let rampPerSecond: Double = 10
    static let maxDuration: Double = 90   // race auto-ends here even if someone's still alive
    private static let capTime = (maxSpeed - baseSpeed) / rampPerSecond

    static func speed(at t: Double) -> Double {
        min(baseSpeed + max(0, t) * rampPerSecond, maxSpeed)
    }

    static func distance(at t: Double) -> Double {
        let t = max(0, t)
        if t <= capTime {
            return baseSpeed * t + 0.5 * rampPerSecond * t * t
        }
        let distAtCap = baseSpeed * capTime + 0.5 * rampPerSecond * capTime * capTime
        return distAtCap + maxSpeed * (t - capTime)
    }
}

// Precomputed once per race from the shared seed — every obstacle's spawn
// time (seconds since race start) for the whole race. Identical on every
// device given the same seed, so no obstacle ever needs to be sent over
// the network.
struct RaceObstacleSchedule {
    let spawnTimes: [Double]

    static func generate(seed: UInt64) -> RaceObstacleSchedule {
        var rng = SeededGenerator(seed: seed)
        var times: [Double] = []
        var t: Double = 4.0   // generous first gap, matches solo mode's grace period
        while t < MotoRacePhysics.maxDuration {
            times.append(t)
            t += Double.random(in: 1.7...2.9, using: &rng)
        }
        return RaceObstacleSchedule(spawnTimes: times)
    }

    /// Obstacle x-positions (points from a lane's left edge) visible at
    /// elapsed race time `t`, for a lane of the given width.
    func visibleObstacleX(at t: Double, laneWidth: CGFloat) -> [Double] {
        guard t >= 0 else { return [] }
        let dNow = MotoRacePhysics.distance(at: t)
        return spawnTimes
            .filter { $0 <= t }
            .map { spawnTime in Double(laneWidth) + 20 - (dNow - MotoRacePhysics.distance(at: spawnTime)) }
            .filter { $0 > -40 }
    }
}

class MotoRunSessionManager: ObservableObject {
    private let db = Database.database().reference().child("motorun")
    private var handle: DatabaseHandle?
    private var raceRef: DatabaseReference?
    private var serverOffsetHandle: DatabaseHandle?
    private var serverOffsetMs: Double = 0

    let myID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString

    @Published var raceCode: String = ""
    @Published var raceState: MotoRaceState = .idle
    @Published var racers: [MotoRacer] = []
    @Published var seed: UInt64 = 0
    @Published var raceStartAt: Double = 0   // server-corrected epoch seconds

    var isHost: Bool { racers.first(where: { $0.id == myID })?.isHost ?? false }
    var me: MotoRacer? { racers.first(where: { $0.id == myID }) }

    init() {
        serverOffsetHandle = Database.database().reference(withPath: ".info/serverTimeOffset").observe(.value) { [weak self] snap in
            self?.serverOffsetMs = snap.value as? Double ?? 0
        }
    }

    /// Server-corrected seconds since the race began. Negative before the
    /// race has actually started (still in the 3-second countdown).
    var elapsed: Double {
        guard raceStartAt > 0 else { return -.greatestFiniteMagnitude }
        let nowMs = Date().timeIntervalSince1970 * 1000 + serverOffsetMs
        return (nowMs / 1000) - raceStartAt
    }

    // MARK: - Create / join

    func createRace(initials: String, colorIndex: Int) {
        let code = JoinCodeGenerator.generate()
        let racerData: [String: Any] = [
            "initials": initials, "colorIndex": colorIndex, "isHost": true,
            "jumpCount": 0, "score": 0, "alive": true, "finished": false
        ]
        db.child(code).child("riders").child(myID).setValue(racerData)
        db.child(code).child("state").setValue(MotoRaceState.lobby.rawValue)
        raceCode = code
        listen(code: code)
    }

    func joinRace(code: String, initials: String, colorIndex: Int) {
        let racerData: [String: Any] = [
            "initials": initials, "colorIndex": colorIndex, "isHost": false,
            "jumpCount": 0, "score": 0, "alive": true, "finished": false
        ]
        db.child(code).child("riders").child(myID).setValue(racerData)
        raceCode = code
        listen(code: code)
    }

    func updateMyColor(_ index: Int) {
        guard !raceCode.isEmpty else { return }
        db.child(raceCode).child("riders").child(myID).child("colorIndex").setValue(index)
    }

    private func listen(code: String) {
        stopListening()
        let ref = db.child(code)
        raceRef = ref
        handle = ref.observe(.value) { [weak self] snapshot in
            guard let self else { return }
            var newRacers: [MotoRacer] = []
            let ridersSnap = snapshot.childSnapshot(forPath: "riders")
            for child in ridersSnap.children {
                guard let snap = child as? DataSnapshot,
                      let data = snap.value as? [String: Any],
                      let initials = data["initials"] as? String,
                      let colorIndex = data["colorIndex"] as? Int,
                      let isHost = data["isHost"] as? Bool
                else { continue }
                newRacers.append(MotoRacer(
                    id: snap.key, initials: initials, colorIndex: colorIndex, isHost: isHost,
                    jumpCount: data["jumpCount"] as? Int ?? 0,
                    score: data["score"] as? Int ?? 0,
                    alive: data["alive"] as? Bool ?? true,
                    finished: data["finished"] as? Bool ?? false
                ))
            }
            let stateString = snapshot.childSnapshot(forPath: "state").value as? String
            let seedValue = snapshot.childSnapshot(forPath: "seed").value as? Double
            let startAtValue = snapshot.childSnapshot(forPath: "raceStartAt").value as? Double

            DispatchQueue.main.async {
                self.racers = newRacers.sorted { $0.isHost && !$1.isHost }
                if let stateString, let state = MotoRaceState(rawValue: stateString) {
                    self.raceState = state
                }
                if let seedValue { self.seed = UInt64(seedValue) }
                if let startAtValue { self.raceStartAt = startAtValue }
            }
        }
    }

    // MARK: - Host controls

    /// Starts (or restarts, for "Play Again") a race: fresh seed, a
    /// server-corrected start time 3 seconds out (that gap is the shared
    /// countdown every device shows), and every current rider reset to a
    /// clean run.
    func startRace() {
        guard isHost, let ref = raceRef else { return }
        let newSeed = UInt64.random(in: 0...(1 << 52))   // stays exactly representable as a Double round-trip
        let nowMs = Date().timeIntervalSince1970 * 1000 + serverOffsetMs
        let startAtSeconds = (nowMs / 1000) + 3.0

        for racer in racers {
            ref.child("riders").child(racer.id).updateChildValues([
                "alive": true, "score": 0, "finished": false, "jumpCount": 0
            ])
        }
        ref.child("seed").setValue(Double(newSeed))
        ref.child("raceStartAt").setValue(startAtSeconds)
        ref.child("state").setValue(MotoRaceState.active.rawValue)
    }

    // MARK: - Per-rider self-reporting (each device is authoritative only about itself)

    func sendJump() {
        guard let ref = raceRef else { return }
        ref.child("riders").child(myID).child("jumpCount").setValue((me?.jumpCount ?? 0) + 1)
    }

    func sendScore(_ score: Int) {
        raceRef?.child("riders").child(myID).child("score").setValue(score)
    }

    func sendCrash(finalScore: Int) {
        raceRef?.child("riders").child(myID).updateChildValues(["alive": false, "finished": true, "score": finalScore])
    }

    func sendTimeoutFinish(finalScore: Int) {
        raceRef?.child("riders").child(myID).updateChildValues(["finished": true, "score": finalScore])
    }

    func leaveRace() {
        stopListening()
        if !raceCode.isEmpty {
            db.child(raceCode).child("riders").child(myID).removeValue()
        }
        raceCode = ""
        raceState = .idle
        racers = []
        seed = 0
        raceStartAt = 0
    }

    private func stopListening() {
        if let handle { raceRef?.removeObserver(withHandle: handle) }
        handle = nil
        raceRef = nil
    }

    deinit {
        if let handle { raceRef?.removeObserver(withHandle: handle) }
        if let serverOffsetHandle {
            Database.database().reference(withPath: ".info/serverTimeOffset").removeObserver(withHandle: serverOffsetHandle)
        }
    }
}
