import Foundation
import UIKit
import Combine
import FirebaseDatabase
import FirebaseStorage
import FirebaseAuth
import CoreLocation
import CoreMotion

class FirebaseManager: ObservableObject {
    private let db = Database.database().reference()
    private var ridersRef: DatabaseReference?
    private var ridersHandle: DatabaseHandle?
    private var lastLocationUpdateByRide: [String: (location: CLLocation, date: Date)] = [:]
    
    @Published var groupRiders: [LiveRider] = []
    
    // MARK: - Firebase Storage Upload (Profile Avatar / Hero Banner)
    /// Uploads an image to Firebase Storage under `users/{myUID}/{type}.jpg`,
    /// fetches the download URL, and automatically updates the user's Realtime Database profile record.
    func uploadProfileImage(_ image: UIImage, type: String, completion: @escaping (Result<String, Error>) -> Void) {
        let myUID = Auth.auth().currentUser?.uid ?? UIDevice.current.identifierForVendor?.uuidString ?? "guest_user"
        guard let imageData = image.jpegData(compressionQuality: 0.75) else {
            completion(.failure(NSError(domain: "ImageUpload", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to compress image."])))
            return
        }
        
        let storageRef = Storage.storage().reference().child("users/\(myUID)/\(type).jpg")
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"
        
        storageRef.putData(imageData, metadata: metadata) { _, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            storageRef.downloadURL { [weak self] url, error in
                if let downloadURL = url?.absoluteString {
                    self?.updateUserProfileImageURL(uid: myUID, key: "\(type)URL", url: downloadURL)
                    completion(.success(downloadURL))
                } else if let error = error {
                    completion(.failure(error))
                }
            }
        }
    }
    
    /// Keeps the private account profile and the location-free public rider
    /// summary in sync. The latter powers discover/connections after the
    /// private `/users` read rules are enabled.
    func updateUserProfileImageURL(uid: String, key: String, url: String) {
        db.updateChildValues([
            "users/\(uid)/profile/\(key)": url,
            "publicRiders/\(uid)/\(key)": url
        ])
    }
    
    // MARK: - Join a ride room
    func joinRide(rideCode: String, riderName: String, initials: String, isLeader: Bool = false, avatarURL: String = "") {
        let myID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString

        let riderData: [String: Any] = [
            "id": myID,
            "name": riderName,
            "initials": initials,
            "latitude": 0.0,
            "longitude": 0.0,
            "speed": 0.0,
            "timestamp": Date().timeIntervalSince1970,
            "fcmToken": UserDefaults.standard.string(forKey: "fcmToken") ?? "",
            // Device IDs key the live ride roster; Auth UIDs let the crash
            // escalation service recognise a linked emergency contact riding
            // in the same group.
            "authUID": Auth.auth().currentUser?.uid ?? "",
            "isLeader": isLeader,
            "avatarURL": avatarURL
        ]

        guard let authUID = Auth.auth().currentUser?.uid, !authUID.isEmpty else { return }
        // A small auth-UID keyed index lets Database Rules grant a rider
        // access to this room without exposing every ride to every account.
        db.updateChildValues([
            "rides/\(rideCode)/riders/\(myID)": riderData,
            "rideMembers/\(rideCode)/\(authUID)": true
        ]) { [weak self] error, _ in
            guard error == nil else { return }
            self?.listenForRiders(rideCode: rideCode, myID: myID)
        }
    }
    
    // MARK: - Update my location
    func updateLocation(rideCode: String, location: CLLocation, speed: Double) {
        guard shouldSendLocationUpdate(rideCode: rideCode, location: location) else { return }
        let myID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        let ridersRef = db.child("rides").child(rideCode).child("riders").child(myID)

        ridersRef.updateChildValues([
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "speed": speed,
            "timestamp": Date().timeIntervalSince1970
        ])

        logTrackPoint(rideCode: rideCode, myID: myID, location: location, speed: speed)
    }

    private func logTrackPoint(rideCode: String, myID: String, location: CLLocation, speed: Double) {
        let point: [String: Any] = [
            "lat": location.coordinate.latitude,
            "lng": location.coordinate.longitude,
            "speed": speed,
            "timestamp": Date().timeIntervalSince1970
        ]
        db.child("rides").child(rideCode).child("tracks").child(myID).childByAutoId().setValue(point)
    }

    // MARK: - Final stats
    func publishFinalStats(rideCode: String, riderName: String, initials: String, isLeader: Bool, distance: Double, maxSpeed: Double, duration: String, completion: @escaping (Error?) -> Void = { _ in }) {
        let myID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        let stats: [String: Any] = [
            "name": riderName,
            "initials": initials,
            "isLeader": isLeader,
            "distance": distance,
            "maxSpeed": maxSpeed,
            "duration": duration,
            "timestamp": Date().timeIntervalSince1970
        ]
        db.child("rides").child(rideCode).child("finalStats").child(myID).setValue(stats) { error, _ in
            completion(error)
        }
    }

    func fetchFinalStats(rideCode: String, completion: @escaping ([ParticipantStat]) -> Void) {
        db.child("rides").child(rideCode).child("finalStats").observeSingleEvent(of: .value) { snapshot in
            var results: [ParticipantStat] = []
            for child in snapshot.children {
                guard let snap = child as? DataSnapshot,
                      let data = snap.value as? [String: Any],
                      let name = data["name"] as? String,
                      let initials = data["initials"] as? String,
                      let distance = data["distance"] as? Double,
                      let maxSpeed = data["maxSpeed"] as? Double,
                      let duration = data["duration"] as? String
                else { continue }
                let isLeader = data["isLeader"] as? Bool ?? false
                results.append(ParticipantStat(deviceID: snap.key, name: name, initials: initials, isLeader: isLeader, distance: distance, maxSpeed: maxSpeed, duration: duration))
            }
            DispatchQueue.main.async {
                completion(results.sorted { $0.isLeader && !$1.isLeader })
            }
        }
    }

    func fetchTrack(rideCode: String, deviceID: String, completion: @escaping ([FirebaseTrackPoint]) -> Void) {
        db.child("rides").child(rideCode).child("tracks").child(deviceID).observeSingleEvent(of: .value) { snapshot in
            var points: [FirebaseTrackPoint] = []
            for child in snapshot.children {
                guard let snap = child as? DataSnapshot,
                      let data = snap.value as? [String: Any],
                      let lat = data["lat"] as? Double,
                      let lng = data["lng"] as? Double,
                      let ts = data["timestamp"] as? Double
                else { continue }
                let speed = data["speed"] as? Double ?? 0
                points.append(FirebaseTrackPoint(lat: lat, lng: lng, speed: speed, timestamp: ts))
            }
            DispatchQueue.main.async {
                completion(points.sorted { $0.timestamp < $1.timestamp })
            }
        }
    }

    private func shouldSendLocationUpdate(rideCode: String, location: CLLocation) -> Bool {
        let now = Date()
        guard let lastUpdate = lastLocationUpdateByRide[rideCode] else {
            lastLocationUpdateByRide[rideCode] = (location, now)
            return true
        }
        let shouldSend = now.timeIntervalSince(lastUpdate.date) >= 5 || location.distance(from: lastUpdate.location) >= 25
        if shouldSend {
            lastLocationUpdateByRide[rideCode] = (location, now)
        }
        return shouldSend
    }
    
    // MARK: - Listen for other riders
    // Group members receive this per-viewer feed from Cloud Functions. This
    // avoids exposing another rider's raw room record to a non-member.
    func listenForRiders(rideCode: String, myID: String) {
        stopListeningForRiders()
        guard let authUID = Auth.auth().currentUser?.uid, !authUID.isEmpty else { return }
        let ridersRef = db.child("groupLocationFeeds").child(rideCode).child(authUID)
        self.ridersRef = ridersRef
        
        ridersHandle = ridersRef.observe(.value) { snapshot in
            var riders: [LiveRider] = []
            
            for child in snapshot.children {
                guard let snap = child as? DataSnapshot,
                      let data = snap.value as? [String: Any],
                      let id = data["riderUID"] as? String,
                      let name = data["name"] as? String,
                      let initials = data["initials"] as? String
                else { continue }

                // Membership should not depend on having a GPS fix yet. A rider
                // who has joined the room may still have 0/0 coordinates until
                // Core Location produces its first update.
                let lat = data["latitude"] as? Double ?? 0
                let lng = data["longitude"] as? Double ?? 0
                let speed = data["speed"] as? Double ?? 0
                
                // isLeader/avatarURL are read with a fallback rather than in
                // the guard above — an older rider record written before
                // this field existed (or mid-write) shouldn't make the whole
                // rider vanish from the map, just show as a follower with no
                // photo.
                let rider = LiveRider(
                    id: id,
                    name: name,
                    initials: initials,
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                    speed: speed,
                    isLeader: data["isLeader"] as? Bool ?? false,
                    avatarURL: data["avatarURL"] as? String ?? ""
                )
                riders.append(rider)
            }
            
            DispatchQueue.main.async {
                self.groupRiders = riders
            }
        }
    }
    
    func stopListeningForRiders() {
        if let ridersHandle {
            ridersRef?.removeObserver(withHandle: ridersHandle)
        }
        ridersHandle = nil
        ridersRef = nil
    }
    
    // MARK: - Leave ride
    func leaveRide(rideCode: String) {
        stopListeningForRiders()
        let myID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        var updates: [String: Any] = ["rides/\(rideCode)/riders/\(myID)": NSNull()]
        if let authUID = Auth.auth().currentUser?.uid, !authUID.isEmpty {
            updates["rideMembers/\(rideCode)/\(authUID)"] = NSNull()
        }
        db.updateChildValues(updates)
        groupRiders = []
    }
    
    deinit {
        stopListeningForRiders()
    }
}

// MARK: - Live Rider Model
struct LiveRider: Identifiable {
    let id: String
    let name: String
    let initials: String
    let coordinate: CLLocationCoordinate2D
    let speed: Double
    // Aug 27, 2026 — added so the live group-ride map can show each rider's
    // actual profile photo (falling back to initials, same as everywhere
    // else in the app) and mark which pin is the leader, for the
    // distance-from-leader feature (see MapView.swift).
    let isLeader: Bool
    let avatarURL: String
}

// MARK: - Final Ride Stats
struct ParticipantStat: Identifiable {
    var id: String { deviceID }
    let deviceID: String
    let name: String
    let initials: String
    let isLeader: Bool
    let distance: Double
    let maxSpeed: Double
    let duration: String

    var distanceString: String { MeasurementUnits.distanceMiles(distance) }
    var maxSpeedString: String { MeasurementUnits.speedMph(maxSpeed) }
}

// MARK: - Synced Route Breadcrumb
struct FirebaseTrackPoint {
    let lat: Double
    let lng: Double
    let speed: Double
    let timestamp: Double
}

// MARK: - Group Ride Session Manager
final class GroupRideSessionManager: ObservableObject {
    let firebase = FirebaseManager()
    let gpxRecorder = GPXRecorder()

    @Published private(set) var groupRiders: [LiveRider] = []
    @Published private(set) var isActive = false
    private(set) var rideCode = ""

    private var ridersCancellable: AnyCancellable?
    private var locationCancellable: AnyCancellable?
    private var maxGForce: Double = 1.0
    private var didEndCurrentSession = false
    private let motionManager = CMMotionManager()
    // Aug 27, 2026 — Grok re-review, general issue #2: the accelerometer
    // callback below used to deliver `to: .main`. Neither gpxRecorder.currentGForce
    // (plain var) nor maxGForce (plain var here, not @Published) drive SwiftUI
    // directly, so unlike TurnByTurnView/ActiveSoloRideView this one can run
    // its whole body on the background queue with no main hop needed at all.
    private let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.packride.groupRide.motion"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        return q
    }()

    init() {
        ridersCancellable = firebase.$groupRiders
            .receive(on: DispatchQueue.main)
            .sink { [weak self] riders in self?.groupRiders = riders }
    }

    func startSession(rideCode: String, riderName: String, initials: String, isLeader: Bool = false, avatarURL: String = "") {
        self.rideCode = rideCode
        isActive = true
        didEndCurrentSession = false
        maxGForce = 1.0
        firebase.joinRide(rideCode: rideCode, riderName: riderName, initials: initials, isLeader: isLeader, avatarURL: avatarURL)
        gpxRecorder.startRecording(rideName: "\(riderName)_Group_\(rideCode)")

        let locationManager = SharedLocationManager.shared
        locationManager.resetTracking()
        locationManager.startTracking()

        locationCancellable = locationManager.$location
            .compactMap { $0 }
            .sink { [weak self] loc in
                guard let self, self.isActive else { return }
                self.gpxRecorder.capturePoint(location: loc)
                self.firebase.updateLocation(rideCode: self.rideCode, location: loc, speed: locationManager.speed)
            }

        if motionManager.isAccelerometerAvailable {
            motionManager.accelerometerUpdateInterval = 0.1
            motionManager.startAccelerometerUpdates(to: motionQueue) { [weak self] data, _ in
                guard let self, let data else { return }
                let g = sqrt(data.acceleration.x * data.acceleration.x +
                             data.acceleration.y * data.acceleration.y +
                             data.acceleration.z * data.acceleration.z)
                // Aug 27, 2026 — independent review catch: gpxRecorder.currentGForce
                // is a plain var, but it's READ on main inside GPXRecorder.capturePoint
                // (called from the $location sink below, which runs on main).
                // Writing it from motionQueue with no hop was an unsynchronized
                // cross-thread race this move introduced — wrapping it here restores
                // the same main-thread serialization the old `to: .main` delivery
                // gave it for free.
                DispatchQueue.main.async {
                    self.gpxRecorder.currentGForce = g
                    if g > self.maxGForce { self.maxGForce = g }
                }
            }
        }
    }

    struct SessionResult {
        let distance: Double
        let maxSpeed: Double
        let gpxFilePath: String?
    }

    func ensureListening(rideCode: String, myID: String) {
        guard !isActive else { return }
        firebase.listenForRiders(rideCode: rideCode, myID: myID)
    }

    @discardableResult
    func endSession() -> SessionResult {
        // End can be triggered from either the Group Ride screen or the live
        // map. Treat it as idempotent so a second tap/navigation callback can
        // never finalize the same recorder twice.
        guard isActive, !didEndCurrentSession else {
            return SessionResult(distance: SharedLocationManager.shared.distance,
                                  maxSpeed: SharedLocationManager.shared.maxSpeed,
                                  gpxFilePath: nil)
        }
        didEndCurrentSession = true

        let locationManager = SharedLocationManager.shared
        let result = SessionResult(
            distance: locationManager.distance,
            maxSpeed: locationManager.maxSpeed,
            gpxFilePath: gpxRecorder.stopAndSave()
        )
        locationCancellable?.cancel(); locationCancellable = nil
        motionManager.stopAccelerometerUpdates()
        locationManager.stopTracking()
        isActive = false
        rideCode = ""
        return result
    }
}
