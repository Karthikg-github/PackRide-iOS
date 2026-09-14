import Foundation
import UIKit
import Combine
import FirebaseDatabase
import FirebaseAuth
import FirebaseStorage

// MARK: - Shared Lap Session Model
// One entry under users/{recipientUid}/sharedLapSessions/{ownerUid}_{sessionId}
// — a specific Track Mode session gifted into the recipient's own account, the
// same one-way-write-into-another-user's-tree shape CrashAlertManager already
// uses for crash alerts (see CrashAlertManager.swift). Not a two-way sync —
// the owner's copy is untouched, this just hands the recipient their own
// pointer to it.
//
// `laps` (every lap duration from the owner's session, not just the best one)
// is included even though the spec's minimum for "a picker row without
// downloading the GPX first" only calls out rider name/date/track/best lap —
// full lap-vs-lap flexibility ("compare my lap 5 to lap 9") needs the WHOLE
// split list to reconstruct any individual lap (see LapReconstructor), and
// that list is small (a handful of Doubles), so it's written alongside the
// row-display fields rather than requiring a second fetch later.
struct SharedLapSession: Identifiable {
    let id: String              // "{ownerUid}_{sessionId}" — also the RTDB key
    let ownerUid: String
    let sessionId: String       // the owner's own LapRecord.id
    let ownerName: String
    let date: Date
    let trackName: String
    let bestLapTime: Double
    let laps: [Double]
    let lapStartTimestamps: [Int64]

    var lapCount: Int { laps.count }
    var formattedDate: String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: date)
    }
}

// MARK: - Lap Sharing Manager
// Mirrors CrashAlertManager/RideFeedManager's house style: an ObservableObject
// wrapping Database.database().reference(), fire-and-forget writes with a
// completion handler passing back an error string (or nil) on success. The
// GPX upload itself follows RideFeedManager's photo-upload pattern
// (Storage putData -> completion), just for a GPX file instead of a JPEG.
class LapSharingManager: ObservableObject {
    private let db = Database.database().reference()

    @Published var sharedWithMe: [SharedLapSession] = []

    private var sharedRef: DatabaseReference?
    private var sharedHandle: DatabaseHandle?

    var myID: String { Auth.auth().currentUser?.uid ?? UIDevice.current.identifierForVendor?.uuidString ?? "" }

    deinit { stopListening() }

    // MARK: - Share (one-way gift into a friend's account)
    // Uploads the session's GPX to Storage at sharedLapGpx/{myID}/{session.id}.gpx,
    // then — only once that upload actually succeeds, same "never write a post
    // that silently lost its attachment" ordering RideFeedManager.postRide uses
    // for photos — writes the metadata row into the recipient's own tree.
    func shareSession(_ session: LapRecord, ownerName: String, recipientUID: String, completion: @escaping (String?) -> Void) {
        guard !myID.isEmpty else { completion("Not signed in — try logging out and back in."); return }
        guard recipientUID != myID else { completion("You can't share a session with yourself."); return }
        guard let gpxFilePath = session.gpxFilePath, let gpxData = GPXStorage.contents(gpxFilePath) else {
            completion("This session doesn't have a recorded route to share.")
            return
        }

        let storageRef = Storage.storage().reference().child("sharedLapGpx/\(myID)/\(session.id).gpx")
        let metadata = StorageMetadata()
        metadata.contentType = "application/gpx+xml"
        storageRef.putData(gpxData, metadata: metadata) { [weak self] _, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async { completion(error.localizedDescription) }
                return
            }

            let data: [String: Any] = [
                "ownerUid": self.myID,
                "sessionId": session.id,
                "ownerName": ownerName,
                "date": session.date.timeIntervalSince1970,
                "trackName": session.trackName,
                "bestLapTime": session.bestLapTime,
                "laps": session.laps,
                "lapStartTimestamps": session.lapStartTimestamps
            ]
            self.db.child("users").child(recipientUID).child("sharedLapSessions")
                .child("\(self.myID)_\(session.id)").setValue(data) { error, _ in
                    DispatchQueue.main.async { completion(error?.localizedDescription) }
                }
        }
    }

    // MARK: - Receiving ("sessions shared with me")
    func listenForSharedSessions() {
        guard !myID.isEmpty else { return }
        stopListening()
        let ref = db.child("users").child(myID).child("sharedLapSessions")
        sharedRef = ref
        sharedHandle = ref.observe(.value) { [weak self] snapshot in
            var sessions: [SharedLapSession] = []
            for child in snapshot.children {
                guard let snap = child as? DataSnapshot,
                      let data = snap.value as? [String: Any],
                      let ownerUid = data["ownerUid"] as? String,
                      let sessionId = data["sessionId"] as? String,
                      let ownerName = data["ownerName"] as? String,
                      let dateTs = data["date"] as? TimeInterval,
                      let trackName = data["trackName"] as? String
                else { continue }

                // Same [Double] vs [Any]/NSNumber handling RideFeedManager
                // already needs for lapTimes — Firebase can hand back a
                // numeric array either way depending on the exact values.
                var laps: [Double] = []
                if let direct = data["laps"] as? [Double] {
                    laps = direct
                } else if let boxed = data["laps"] as? [Any] {
                    laps = boxed.compactMap { ($0 as? NSNumber)?.doubleValue }
                }
                let starts = (data["lapStartTimestamps"] as? [Any])?.compactMap { ($0 as? NSNumber)?.int64Value } ?? []

                sessions.append(SharedLapSession(
                    id: snap.key, ownerUid: ownerUid, sessionId: sessionId, ownerName: ownerName,
                    date: Date(timeIntervalSince1970: dateTs), trackName: trackName,
                    bestLapTime: data["bestLapTime"] as? Double ?? 0, laps: laps,
                    lapStartTimestamps: starts
                ))
            }
            DispatchQueue.main.async {
                self?.sharedWithMe = sessions.sorted { $0.date > $1.date }
            }
        }
    }

    func stopListening() {
        if let sharedHandle { sharedRef?.removeObserver(withHandle: sharedHandle) }
        sharedHandle = nil
        sharedRef = nil
    }

    // MARK: - Download & cache a shared session's GPX
    // A shared session's GPX doesn't belong to this device's own ride history
    // (GPXStorage's rides directory), so it gets its own cache directory,
    // keyed off a deterministic "{ownerUid}_{sessionId}.gpx" filename — same
    // "resolve by stable name, look it up fresh every time" idea GPXStorage
    // itself uses, just for files that came from a friend instead of this
    // device's own recorder. Re-opening the same comparison later finds the
    // file already on disk and skips the network round trip entirely.
    static var cacheDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("sharedLapGpx", isDirectory: true)
    }

    static func cachedFileURL(ownerUid: String, sessionId: String) -> URL {
        cacheDirectory.appendingPathComponent("\(ownerUid)_\(sessionId).gpx")
    }

    func downloadAndCacheGPX(ownerUid: String, sessionId: String, completion: @escaping (URL?, String?) -> Void) {
        let localURL = Self.cachedFileURL(ownerUid: ownerUid, sessionId: sessionId)
        if FileManager.default.fileExists(atPath: localURL.path) {
            completion(localURL, nil)
            return
        }

        let fm = FileManager.default
        if !fm.fileExists(atPath: Self.cacheDirectory.path) {
            try? fm.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
        }

        let storageRef = Storage.storage().reference().child("sharedLapGpx/\(ownerUid)/\(sessionId).gpx")
        storageRef.write(toFile: localURL) { url, error in
            DispatchQueue.main.async {
                if let error {
                    completion(nil, error.localizedDescription)
                } else {
                    completion(url, nil)
                }
            }
        }
    }
}
