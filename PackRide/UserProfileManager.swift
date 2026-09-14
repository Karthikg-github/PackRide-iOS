import Foundation
import UIKit
import FirebaseDatabase
import FirebaseAuth
import CoreLocation
import Combine

// MARK: - User Profile Model
struct RiderProfile: Identifiable {
    let id: String
    let name: String
    let initials: String
    let bike: String
    let city: String
    let experience: String
    var avatarURL: String = ""
    var bannerURL: String = ""
    var isOnline: Bool
    var lastSeen: TimeInterval
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Follow Request Model
struct FollowRequest: Identifiable {
    let id: String       // requester's userID
    let name: String
    let initials: String
    let timestamp: TimeInterval
}

// MARK: - Follow Status
enum FollowStatus {
    case notFollowing
    case requested
    case following
    case isMe
}

// MARK: - User Profile Manager
class UserProfileManager: ObservableObject {
    private let db = Database.database().reference()

    deinit { cleanup() }

    func cleanup() {
        db.child("users").removeAllObservers()
        stopListeningForFollowRequests()
        stopListeningForFollowedUsers()
        stopListeningForFollowerCount()
        stopListeningForMyProfile()
        stopListeningForPrivateLocations()
        stopListeningForAllUsers()
        stopNearbyRiderDetection()
    }
    private var followRequestsRef: DatabaseReference?
    private var followRequestsHandle: DatabaseHandle?
    private var followingRef: DatabaseReference?
    private var followingHandle: DatabaseHandle?
    private var followersRef: DatabaseReference?
    private var followersHandle: DatabaseHandle?
    private var myProfileRef: DatabaseReference?
    private var myProfileHandle: DatabaseHandle?
    private var privateLocationsHandle: DatabaseHandle?
    // Aug 27, 2026 — Grok battery/perf audit, fix #4: listenForAllUsers() and
    // listenForNearbyRiders() each used to open their OWN full `/users` tree
    // `.observe(.value)` — meaning every profile screen showing suggested
    // riders (allUsersHandle) running at the same time as an active ride
    // showing nearby riders (nearbyUsersHandle) pulled the entire users tree
    // down TWICE on every single change anywhere in it. There's no per-field
    // Firebase Realtime Database query that can narrow this to just online
    // riders' locations without a schema change to a dedicated index (a real
    // geo query would need one, e.g. geohashing — worth doing as a follow-up,
    // but a bigger, riskier change to make against live production data than
    // this pass), so the fix here is to stop duplicating the read: one shared
    // observer feeds both allUserProfiles and nearbyRiders, and each of the
    // two features is tracked with its own "is anyone still asking for this"
    // flag so the shared observer tears down once neither is.
    private var usersTreeRef: DatabaseReference?
    private var usersTreeHandle: DatabaseHandle?
    private var allUsersWanted = false
    private var nearbyRidersWanted = false
    private var nearbySearchLocation: CLLocation?
    private var nearbySearchRadiusMiles: Double = 1.0
    
    @Published var followRequests: [FollowRequest] = []
    @Published var followedUsers: [RiderProfile] = []
    @Published var followers: [RiderProfile] = []
    @Published var followingCount = 0
    @Published var followerCount = 0
    @Published var followStatus: [String: FollowStatus] = [:]
    @Published var privateLocations: [String: CLLocationCoordinate2D] = [:]
    @Published private var allUserProfiles: [RiderProfile] = []
    
    // Published image URLs to notify SwiftUI views when profile loads
    @Published var avatarURL: String = UserDefaults.standard.string(forKey: "avatarURL") ?? "" {
        didSet {
            UserDefaults.standard.set(avatarURL, forKey: "avatarURL")
        }
    }

    @Published var bannerURL: String = UserDefaults.standard.string(forKey: "bannerURL") ?? "" {
        didSet {
            UserDefaults.standard.set(bannerURL, forKey: "bannerURL")
        }
    }

    var suggestedUsers: [RiderProfile] {
        let followingIDs = Set(followedUsers.map { $0.id })
        return allUserProfiles.filter { $0.id != myID && !followingIDs.contains($0.id) }
    }

    var myID: String { Auth.auth().currentUser?.uid ?? UIDevice.current.identifierForVendor?.uuidString ?? "" }

    // MARK: - Publish my profile & location
    func publishProfile(
        name: String,
        bike: String,
        city: String,
        experience: String,
        avatarURL: String = "",
        bannerURL: String = ""
    ) {
        guard !myID.isEmpty else { return }
        let initials = name.rideInitials
        var profileData: [String: Any] = [
            "name": name,
            "initials": initials,
            "bike": bike,
            "city": city,
            "experience": experience,
            "isOnline": true,
            "lastSeen": Date().timeIntervalSince1970
        ]
        if !avatarURL.isEmpty {
            profileData["avatarURL"] = avatarURL
            self.avatarURL = avatarURL
        }
        if !bannerURL.isEmpty {
            profileData["bannerURL"] = bannerURL
            self.bannerURL = bannerURL
        }
        db.child("users").child(myID).child("profile").updateChildValues(profileData)
        db.child("publicRiders").child(myID).updateChildValues([
            "name": name, "initials": initials, "bike": bike, "city": city,
            "experience": experience, "avatarURL": avatarURL, "bannerURL": bannerURL
        ])
    }

    func fetchMyProfile() {
        guard !myID.isEmpty else { return }
        stopListeningForMyProfile()
        let ref = db.child("users").child(myID).child("profile")
        myProfileRef = ref
        myProfileHandle = ref.observe(.value) { [weak self] snapshot in
            guard let data = snapshot.value as? [String: Any] else { return }
            DispatchQueue.main.async {
                let defaults = UserDefaults.standard
                if let name = data["name"] as? String,
                   !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    defaults.set(name.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "riderName")
                }
                if let bike = data["bike"] as? String { defaults.set(bike, forKey: "riderBike") }
                if let city = data["city"] as? String { defaults.set(city, forKey: "riderCity") }
                if let experience = data["experience"] as? String, !experience.isEmpty {
                    defaults.set(experience, forKey: "riderExperience")
                }
                if let avatar = data["avatarURL"] as? String, !avatar.isEmpty {
                    self?.avatarURL = avatar
                }
                if let banner = data["bannerURL"] as? String, !banner.isEmpty {
                    self?.bannerURL = banner
                }
            }
        }
    }

    func stopListeningForMyProfile() {
        if let myProfileHandle { myProfileRef?.removeObserver(withHandle: myProfileHandle) }
        myProfileHandle = nil
        myProfileRef = nil
    }

    func listenForPrivateLocations() {
        guard !myID.isEmpty else { return }
        if let privateLocationsHandle { db.child("locationFeeds").child(myID).removeObserver(withHandle: privateLocationsHandle) }
        privateLocationsHandle = db.child("locationFeeds").child(myID).observe(.value) { [weak self] snapshot in
            var locations: [String: CLLocationCoordinate2D] = [:]
            for child in snapshot.children {
                guard let snap = child as? DataSnapshot, let value = snap.value as? [String: Any],
                      let lat = value["latitude"] as? Double, let lng = value["longitude"] as? Double else { continue }
                locations[snap.key] = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            }
            DispatchQueue.main.async {
                self?.privateLocations = locations
                self?.refreshNearbyRidersFromPrivateLocations()
            }
        }
    }

    func stopListeningForPrivateLocations() {
        if let privateLocationsHandle {
            db.child("locationFeeds").child(myID).removeObserver(withHandle: privateLocationsHandle)
        }
        privateLocationsHandle = nil
        privateLocations = [:]
    }

    func updateMyLocation(location: CLLocation) {
        guard !myID.isEmpty else { return }
        db.child("users").child(myID).child("location").updateChildValues([
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "isOnline": true,
            "lastSeen": Date().timeIntervalSince1970
        ])
    }

    func goOffline() {
        guard !myID.isEmpty else { return }
        db.child("users").child(myID).child("location").updateChildValues([
            "isOnline": false,
            "lastSeen": Date().timeIntervalSince1970
        ])
    }

    // MARK: - Follow Request
    func sendFollowRequest(to targetUserID: String, myName: String, myInitials: String) {
        guard !myID.isEmpty, targetUserID != myID else { return }
        let requestData: [String: Any] = [
            "name": myName,
            "initials": myInitials,
            "timestamp": Date().timeIntervalSince1970
        ]
        db.child("users").child(targetUserID).child("followRequests").child(myID).setValue(requestData)
        followStatus[targetUserID] = .requested
    }

    func cancelFollowRequest(to targetUserID: String) {
        guard !myID.isEmpty, targetUserID != myID else { return }
        db.child("users").child(targetUserID).child("followRequests").child(myID).removeValue { [weak self] error, _ in
            guard error == nil else { return }
            DispatchQueue.main.async { self?.followStatus[targetUserID] = .notFollowing }
        }
    }

    func acceptFollowRequest(requesterID: String, requesterName: String, requesterInitials: String,
                             completion: @escaping (String?) -> Void = { _ in }) {
        guard !myID.isEmpty else {
            completion("You need to be signed in to approve a follow request.")
            return
        }

        // These three writes describe one state change: the requester is now
        // following me, I recognize them as a follower, and their pending
        // request is gone. A single root-level update keeps them atomic and,
        // unlike the former fire-and-forget writes, returns any permission or
        // network error to the UI instead of making an approval look broken.
        let updates: [String: Any] = [
            "users/\(myID)/followers/\(requesterID)": true,
            "users/\(requesterID)/following/\(myID)": true,
            "users/\(myID)/followRequests/\(requesterID)": NSNull()
        ]
        db.updateChildValues(updates) { [weak self] error, _ in
            DispatchQueue.main.async {
                if error == nil {
                    self?.followRequests.removeAll { $0.id == requesterID }
                }
                completion(error?.localizedDescription)
            }
        }
    }

    func declineFollowRequest(requesterID: String) {
        guard !myID.isEmpty else { return }
        db.child("users").child(myID).child("followRequests").child(requesterID).removeValue()
        followRequests.removeAll { $0.id == requesterID }
    }

    func unfollowUser(targetUserID: String) {
        guard !myID.isEmpty else { return }
        db.child("users").child(targetUserID).child("followers").child(myID).removeValue()
        db.child("users").child(myID).child("following").child(targetUserID).removeValue()
        followStatus[targetUserID] = .notFollowing
        followedUsers.removeAll { $0.id == targetUserID }
    }

    func removeFollower(userID: String) {
        guard !myID.isEmpty else { return }
        // Removing a follower also removes this account from their Following
        // list, so both profiles immediately agree on the relationship.
        db.updateChildValues([
            "users/\(myID)/followers/\(userID)": NSNull(),
            "users/\(userID)/following/\(myID)": NSNull()
        ])
        followers.removeAll { $0.id == userID }
    }

    // MARK: - Check follow status for a user
    func checkFollowStatus(for targetUserID: String) {
        guard !myID.isEmpty else { return }
        if targetUserID == myID { followStatus[targetUserID] = .isMe; return }

        db.child("users").child(targetUserID).child("followRequests").child(myID).observeSingleEvent(of: .value) { snap in
            if snap.exists() {
                DispatchQueue.main.async { self.followStatus[targetUserID] = .requested }
                return
            }
            self.db.child("users").child(targetUserID).child("followers").child(self.myID).observeSingleEvent(of: .value) { snap2 in
                DispatchQueue.main.async {
                    self.followStatus[targetUserID] = snap2.exists() ? .following : .notFollowing
                }
            }
        }
    }

    // MARK: - Listen for follow requests
    func listenForFollowRequests() {
        guard !myID.isEmpty else { return }
        stopListeningForFollowRequests()
        let ref = db.child("users").child(myID).child("followRequests")
        followRequestsRef = ref
        followRequestsHandle = ref.observe(.value) { snapshot in
            var requests: [FollowRequest] = []
            for child in snapshot.children {
                guard let snap = child as? DataSnapshot,
                      let data = snap.value as? [String: Any],
                      let name = data["name"] as? String,
                      let initials = data["initials"] as? String,
                      let ts = data["timestamp"] as? TimeInterval
                else { continue }
                requests.append(FollowRequest(id: snap.key, name: name, initials: initials, timestamp: ts))
            }
            DispatchQueue.main.async { self.followRequests = requests }
        }
    }

    func stopListeningForFollowRequests() {
        if let followRequestsHandle {
            followRequestsRef?.removeObserver(withHandle: followRequestsHandle)
        }
        followRequestsHandle = nil
        followRequestsRef = nil
    }

    // MARK: - Listen for followed users
    func listenForFollowedUsers() {
        guard !myID.isEmpty else { return }
        stopListeningForFollowedUsers()
        let ref = db.child("users").child(myID).child("following")
        followingRef = ref
        followingHandle = ref.observe(.value) { snapshot in
            let followingIDs: [String] = snapshot.children.compactMap {
                ($0 as? DataSnapshot)?.key
            }
            DispatchQueue.main.async { self.followingCount = followingIDs.count }
            self.loadFollowedUserProfiles(ids: followingIDs)
        }
    }

    func stopListeningForFollowedUsers() {
        if let followingHandle {
            followingRef?.removeObserver(withHandle: followingHandle)
        }
        followingHandle = nil
        followingRef = nil
    }

    // Counts are observed independently of profile loading so a missing or
    // incomplete profile can never make the social totals look incorrect.
    func listenForFollowerCount() {
        guard !myID.isEmpty else { return }
        stopListeningForFollowerCount()
        let ref = db.child("users").child(myID).child("followers")
        followersRef = ref
        followersHandle = ref.observe(.value) { [weak self] snapshot in
            let followerIDs: [String] = snapshot.children.compactMap {
                ($0 as? DataSnapshot)?.key
            }
            DispatchQueue.main.async { self?.followerCount = Int(snapshot.childrenCount) }
            self?.loadFollowerProfiles(ids: followerIDs)
        }
    }

    func stopListeningForFollowerCount() {
        if let followersHandle {
            followersRef?.removeObserver(withHandle: followersHandle)
        }
        followersHandle = nil
        followersRef = nil
    }

    private func loadFollowerProfiles(ids: [String]) {
        guard !ids.isEmpty else { followers = []; return }
        var profiles: [RiderProfile] = []
        let group = DispatchGroup()

        for userID in ids {
            group.enter()
            db.child("publicRiders").child(userID).observeSingleEvent(of: .value) { snapshot, _ in
                defer { group.leave() }
                guard let data = snapshot.value as? [String: Any],
                      let name = data["name"] as? String,
                      let initials = data["initials"] as? String
                else { return }
                let location = data["location"] as? [String: Any]
                profiles.append(RiderProfile(
                    id: userID, name: name, initials: initials,
                    bike: data["bike"] as? String ?? "",
                    city: data["city"] as? String ?? "",
                    experience: data["experience"] as? String ?? "",
                    avatarURL: data["avatarURL"] as? String ?? "",
                    bannerURL: data["bannerURL"] as? String ?? "",
                    isOnline: location?["isOnline"] as? Bool ?? false,
                    lastSeen: location?["lastSeen"] as? TimeInterval ?? 0,
                    latitude: location?["latitude"] as? Double ?? 0,
                    longitude: location?["longitude"] as? Double ?? 0
                ))
            }
        }

        group.notify(queue: .main) { self.followers = profiles }
    }

    // MARK: - Listen for all users
    // Shares one `/users` tree observer with listenForNearbyRiders below —
    // see usersTreeHandle above for why, and startUsersTreeObserverIfNeeded/
    // handleUsersTreeSnapshot further down for the shared implementation.
    func listenForAllUsers() {
        guard !myID.isEmpty else { return }
        allUsersWanted = true
        startUsersTreeObserverIfNeeded()
    }

    func stopListeningForAllUsers() {
        allUsersWanted = false
        allUserProfiles = []
        stopUsersTreeObserverIfNoLongerNeeded()
    }

    private func loadFollowedUserProfiles(ids: [String]) {
        guard !ids.isEmpty else { followedUsers = []; return }
        var profiles: [RiderProfile] = []
        let group = DispatchGroup()

        for userID in ids {
            group.enter()
            db.child("publicRiders").child(userID).observeSingleEvent(of: .value) { snapshot, _ in
                defer { group.leave() }
                guard let data = snapshot.value as? [String: Any],
                      let name = data["name"] as? String,
                      let initials = data["initials"] as? String
                else { return }

                let location = data["location"] as? [String: Any]
                let riderProfile = RiderProfile(
                    id: userID,
                    name: name,
                    initials: initials,
                    bike: data["bike"] as? String ?? "", city: data["city"] as? String ?? "",
                    experience: data["experience"] as? String ?? "", avatarURL: data["avatarURL"] as? String ?? "", bannerURL: data["bannerURL"] as? String ?? "",
                    isOnline: location?["isOnline"] as? Bool ?? false,
                    lastSeen: location?["lastSeen"] as? TimeInterval ?? 0,
                    latitude: location?["latitude"] as? Double ?? 0,
                    longitude: location?["longitude"] as? Double ?? 0
                )
                profiles.append(riderProfile)
            }
        }

        group.notify(queue: .main) {
            self.followedUsers = profiles
        }
    }

    // MARK: - Nearby Riders Detection
    @Published var nearbyRiders: [RiderProfile] = []
    @Published var newNearbyRiderAlert: RiderProfile? = nil
    private var notifiedRiderIDs: Set<String> = []

    // Shares the same `/users` tree observer as listenForAllUsers above —
    // see usersTreeHandle above and the shared implementation below.
    func listenForNearbyRiders(myLocation: CLLocation, radiusMiles: Double = 1.0) {
        guard !myID.isEmpty else { return }
        nearbySearchLocation = myLocation
        nearbySearchRadiusMiles = radiusMiles
        nearbyRidersWanted = true
        listenForPrivateLocations()
        startUsersTreeObserverIfNeeded()
    }

    func stopNearbyRiderDetection() {
        nearbyRidersWanted = false
        nearbySearchLocation = nil
        nearbyRiders = []
        notifiedRiderIDs.removeAll()
        stopListeningForPrivateLocations()
        stopUsersTreeObserverIfNoLongerNeeded()
    }

    // MARK: - Shared /users tree observer
    // One `.observe(.value)` on the whole tree, fanned out locally to
    // whichever of allUserProfiles/nearbyRiders is currently wanted, instead
    // of each opening its own identical full-tree read (Grok audit fix #4 —
    // see usersTreeHandle above for the full rationale).
    private func startUsersTreeObserverIfNeeded() {
        guard usersTreeHandle == nil else { return }
        let ref = db.child("publicRiders")
        usersTreeRef = ref
        usersTreeHandle = ref.observe(.value) { [weak self] snapshot in
            self?.handleUsersTreeSnapshot(snapshot)
        }
    }

    private func stopUsersTreeObserverIfNoLongerNeeded() {
        guard !allUsersWanted, !nearbyRidersWanted else { return }
        if let usersTreeHandle {
            usersTreeRef?.removeObserver(withHandle: usersTreeHandle)
        }
        usersTreeHandle = nil
        usersTreeRef = nil
    }

    private func handleUsersTreeSnapshot(_ snapshot: DataSnapshot) {
        if allUsersWanted || nearbyRidersWanted {
            var profiles: [RiderProfile] = []
            for child in snapshot.children {
                guard let snap = child as? DataSnapshot,
                      let data = snap.value as? [String: Any],
                      let name = data["name"] as? String,
                      let initials = data["initials"] as? String
                else { continue }
                let location = data["location"] as? [String: Any]
                profiles.append(RiderProfile(
                    id: snap.key,
                    name: name,
                    initials: initials,
                    bike: data["bike"] as? String ?? "", city: data["city"] as? String ?? "",
                    experience: data["experience"] as? String ?? "", avatarURL: data["avatarURL"] as? String ?? "", bannerURL: data["bannerURL"] as? String ?? "",
                    isOnline: location?["isOnline"] as? Bool ?? false,
                    lastSeen: location?["lastSeen"] as? TimeInterval ?? 0,
                    latitude: location?["latitude"] as? Double ?? 0,
                    longitude: location?["longitude"] as? Double ?? 0
                ))
            }
            DispatchQueue.main.async { self.allUserProfiles = profiles }
        }

        refreshNearbyRidersFromPrivateLocations()
    }

    /// Nearby riders are intentionally calculated only from locations that the
    /// signed-in rider is authorized to receive through `locationFeeds`.
    private func refreshNearbyRidersFromPrivateLocations() {
        guard nearbyRidersWanted, let searchLocation = nearbySearchLocation else { return }
        var profilesByID = Dictionary(uniqueKeysWithValues: allUserProfiles.map { ($0.id, $0) })
        for profile in followedUsers {
            profilesByID[profile.id] = profile
        }
        var nearby: [RiderProfile] = []

        for (id, coordinate) in privateLocations where id != myID {
            guard let profile = profilesByID[id] else { continue }
            let otherLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let distanceMiles = searchLocation.distance(from: otherLocation) * 0.000621371
            guard distanceMiles <= nearbySearchRadiusMiles else { continue }

            let rider = RiderProfile(
                id: id, name: profile.name, initials: profile.initials,
                bike: profile.bike, city: profile.city, experience: profile.experience,
                avatarURL: profile.avatarURL, bannerURL: profile.bannerURL,
                isOnline: true, lastSeen: Date().timeIntervalSince1970,
                latitude: coordinate.latitude, longitude: coordinate.longitude
            )
            nearby.append(rider)
            if !notifiedRiderIDs.contains(id) {
                notifiedRiderIDs.insert(id)
                newNearbyRiderAlert = rider
            }
        }
        nearbyRiders = nearby
    }

    func fetchProfile(for userID: String, completion: @escaping (RiderProfile?) -> Void) {
        db.child("publicRiders").child(userID).observeSingleEvent(of: .value) { snapshot in
            guard let data = snapshot.value as? [String: Any],
                  let name = data["name"] as? String,
                  let initials = data["initials"] as? String
            else { completion(nil); return }

            let riderProfile = RiderProfile(
                id: userID,
                name: name,
                initials: initials,
                bike: data["bike"] as? String ?? "Not specified",
                city: data["city"] as? String ?? "Unknown",
                experience: data["experience"] as? String ?? "Rider",
                avatarURL: data["avatarURL"] as? String ?? "",
                bannerURL: data["bannerURL"] as? String ?? "",
                isOnline: false, lastSeen: 0, latitude: 0, longitude: 0
            )
            DispatchQueue.main.async { completion(riderProfile) }
        }
    }
}
