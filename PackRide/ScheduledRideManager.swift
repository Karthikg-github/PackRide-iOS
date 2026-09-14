import Foundation
import FirebaseDatabase
import FirebaseAuth
import Combine

// MARK: - Scheduled Ride Model
struct ScheduledRide: Identifiable, Codable {
    let id: String
    let rideCode: String
    let title: String
    let description: String
    let creatorID: String
    let creatorName: String
    let creatorInitials: String
    let scheduledDate: TimeInterval
    let createdAt: TimeInterval
    let meetupLocation: String
    let meetupLatitude: Double
    let meetupLongitude: Double
    var communityID: String?    // if shared to a community
    var rsvpCount: Int

    var date: Date { Date(timeIntervalSince1970: scheduledDate) }
    var isUpcoming: Bool { date > Date() }
    var isPast: Bool { date <= Date() }

    var formattedDate: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: date)
    }

    var formattedTime: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    var formattedDateTime: String { "\(formattedDate) at \(formattedTime)" }

    var timeUntil: String {
        let interval = date.timeIntervalSince(Date())
        if interval < 0 { return "Started" }
        let days = Int(interval) / 86400
        let hours = (Int(interval) % 86400) / 3600
        if days > 0 { return "\(days)d \(hours)h" }
        let minutes = (Int(interval) % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

// MARK: - RSVP Status
enum RSVPStatus: String, Codable {
    case going = "going"
    case maybe = "maybe"
    case notGoing = "notGoing"
}

// MARK: - RSVP Entry
struct RSVPEntry: Identifiable, Codable {
    let id: String      // userID
    let name: String
    let initials: String
    let status: RSVPStatus
    let timestamp: TimeInterval
}

// MARK: - Scheduled Ride Manager
class ScheduledRideManager: ObservableObject {
    private let db = Database.database().reference()
    private var handles: [DatabaseHandle] = []
    // Aug 22, 2026 — was [DatabaseReference], but queryOrdered/queryEqual/
    // queryStarting all return a DatabaseQuery, not a DatabaseReference
    // (DatabaseReference is a subclass, plain refs still fit fine).
    // Every one of the .observe(.value) calls below used to just discard the
    // handle it got back, so removeAllListeners() had nothing to remove —
    // every screen visit stacked up one more live listener forever.
    private var refs: [DatabaseQuery] = []

    deinit { removeAllListeners() }

    func removeAllListeners() {
        for (i, handle) in handles.enumerated() {
            if i < refs.count { refs[i].removeObserver(withHandle: handle) }
        }
        handles.removeAll(); refs.removeAll()
    }

    private func track(_ query: DatabaseQuery, _ handle: DatabaseHandle) {
        refs.append(query); handles.append(handle)
    }
    @Published var myScheduledRides: [ScheduledRide] = []
    @Published var communityRides: [ScheduledRide] = []
    @Published var rsvpList: [RSVPEntry] = []
    @Published var myRSVPStatus: RSVPStatus? = nil

    var myID: String { Auth.auth().currentUser?.uid ?? "" }

    // MARK: - Create Scheduled Ride
    func createScheduledRide(title: String, description: String, rideCode: String,
                              scheduledDate: Date, meetupLocation: String,
                              meetupLat: Double, meetupLng: Double,
                              creatorName: String, communityID: String? = nil,
                              completion: @escaping (Bool) -> Void) {
        guard !myID.isEmpty else { completion(false); return }

        let rideID = UUID().uuidString
        let initials = creatorName.rideInitials

        let rideData: [String: Any] = [
            "id": rideID,
            "rideCode": rideCode,
            "title": title,
            "description": description,
            "creatorID": myID,
            "creatorName": creatorName,
            "creatorInitials": initials,
            "scheduledDate": scheduledDate.timeIntervalSince1970,
            "createdAt": Date().timeIntervalSince1970,
            "meetupLocation": meetupLocation,
            "meetupLatitude": meetupLat,
            "meetupLongitude": meetupLng,
            "communityID": communityID ?? "",
            "rsvpCount": 1  // creator is auto-going
        ]

        // Save to /scheduledRides/{rideID}
        db.child("scheduledRides").child(rideID).setValue(rideData)

        // Auto-RSVP creator as "going"
        let rsvpData: [String: Any] = [
            "name": creatorName,
            "initials": initials,
            "status": RSVPStatus.going.rawValue,
            "timestamp": Date().timeIntervalSince1970
        ]
        db.child("scheduledRides").child(rideID).child("rsvps").child(myID).setValue(rsvpData)

        // If shared to a community, add reference
        if let cID = communityID, !cID.isEmpty {
            db.child("communities").child(cID).child("scheduledRides").child(rideID).setValue(true)
        }

        // Also save to user's scheduled rides
        db.child("users").child(myID).child("scheduledRides").child(rideID).setValue(true)

        completion(true)
    }

    // MARK: - Listen for My Scheduled Rides
    func listenForMyRides() {
        removeAllListeners()
        guard !myID.isEmpty else { return }
        let query = db.child("scheduledRides").queryOrdered(byChild: "creatorID").queryEqual(toValue: myID)
        let handle = query.observe(.value) { snapshot in
                var rides: [ScheduledRide] = []
                for child in snapshot.children {
                    guard let snap = child as? DataSnapshot,
                          let ride = self.parseRide(snap) else { continue }
                    rides.append(ride)
                }
                DispatchQueue.main.async {
                    self.myScheduledRides = rides.sorted { $0.scheduledDate > $1.scheduledDate }
                }
            }
        track(query, handle)
    }

    // MARK: - Listen for Community Rides
    func listenForCommunityRides(communityID: String) {
        removeAllListeners()
        let query = db.child("communities").child(communityID).child("scheduledRides")
        let handle = query.observe(.value) { snapshot in
            var rideIDs: [String] = []
            for child in snapshot.children {
                if let snap = child as? DataSnapshot { rideIDs.append(snap.key) }
            }
            self.loadRides(ids: rideIDs) { rides in
                DispatchQueue.main.async {
                    self.communityRides = rides.filter { $0.isUpcoming }.sorted { $0.scheduledDate < $1.scheduledDate }
                }
            }
        }
        track(query, handle)
    }

    // MARK: - Listen for All Upcoming Rides (that user has RSVP'd to)
    func listenForUpcomingRides() {
        removeAllListeners()
        guard !myID.isEmpty else { return }
        // Listen to all scheduled rides and filter client-side for ones user RSVP'd to
        let query = db.child("scheduledRides").queryOrdered(byChild: "scheduledDate")
            .queryStarting(atValue: Date().timeIntervalSince1970)
        let handle = query.observe(.value) { snapshot in
                var rides: [ScheduledRide] = []
                for child in snapshot.children {
                    guard let snap = child as? DataSnapshot,
                          let ride = self.parseRide(snap) else { continue }
                    rides.append(ride)
                }
                DispatchQueue.main.async {
                    self.communityRides = rides.sorted { $0.scheduledDate < $1.scheduledDate }
                }
            }
        track(query, handle)
    }

    // MARK: - RSVP to a Ride
    func rsvp(rideID: String, status: RSVPStatus, name: String) {
        guard !myID.isEmpty else { return }
        let initials = name.rideInitials
        let data: [String: Any] = [
            "name": name,
            "initials": initials,
            "status": status.rawValue,
            "timestamp": Date().timeIntervalSince1970
        ]
        db.child("scheduledRides").child(rideID).child("rsvps").child(myID).setValue(data)

        // Update rsvp count — this only ever needs to recompute once, right
        // after this RSVP write lands, so it's a single read rather than a
        // live listener. It used to be .observe(.value) with the handle
        // discarded: every call to rsvp() left one more permanent listener
        // running, each of which kept re-writing rsvpCount on every future
        // RSVP by anyone, forever.
        db.child("scheduledRides").child(rideID).child("rsvps").observeSingleEvent(of: .value) { snapshot in
            var count = 0
            for child in snapshot.children {
                if let snap = child as? DataSnapshot,
                   let val = snap.value as? [String: Any],
                   let st = val["status"] as? String, st == "going" {
                    count += 1
                }
            }
            self.db.child("scheduledRides").child(rideID).child("rsvpCount").setValue(count)
        }

        DispatchQueue.main.async { self.myRSVPStatus = status }
    }

    // MARK: - Cancel RSVP
    func cancelRSVP(rideID: String) {
        guard !myID.isEmpty else { return }
        db.child("scheduledRides").child(rideID).child("rsvps").child(myID).removeValue()
        DispatchQueue.main.async { self.myRSVPStatus = nil }
    }

    // MARK: - Load RSVPs for a ride
    func loadRSVPs(rideID: String) {
        let query = db.child("scheduledRides").child(rideID).child("rsvps")
        let handle = query.observe(.value) { snapshot in
            var entries: [RSVPEntry] = []
            for child in snapshot.children {
                guard let snap = child as? DataSnapshot,
                      let data = snap.value as? [String: Any],
                      let name = data["name"] as? String,
                      let initials = data["initials"] as? String,
                      let statusStr = data["status"] as? String,
                      let status = RSVPStatus(rawValue: statusStr),
                      let ts = data["timestamp"] as? TimeInterval
                else { continue }
                entries.append(RSVPEntry(id: snap.key, name: name, initials: initials, status: status, timestamp: ts))
            }
            DispatchQueue.main.async {
                self.rsvpList = entries
                self.myRSVPStatus = entries.first(where: { $0.id == self.myID })?.status
            }
        }
        track(query, handle)
    }

    // MARK: - Share Scheduled Ride to Community
    func shareToCommunity(rideID: String, newCommunityID: String?, oldCommunityID: String?, completion: @escaping (Bool) -> Void) {
        let normalizedNewID = newCommunityID?.isEmpty == false ? newCommunityID : nil
        let normalizedOldID = oldCommunityID?.isEmpty == false ? oldCommunityID : nil

        guard normalizedNewID != normalizedOldID else {
            completion(true)
            return
        }

        var updates: [String: Any] = [
            "/scheduledRides/\(rideID)/communityID": normalizedNewID ?? ""
        ]

        if let oldID = normalizedOldID {
            updates["/communities/\(oldID)/scheduledRides/\(rideID)"] = NSNull()
        }

        if let newID = normalizedNewID {
            updates["/communities/\(newID)/scheduledRides/\(rideID)"] = true
        }

        db.updateChildValues(updates) { error, _ in
            DispatchQueue.main.async {
                completion(error == nil)
            }
        }
    }

    // MARK: - Delete Scheduled Ride
    func deleteRide(rideID: String, communityID: String?) {
        db.child("scheduledRides").child(rideID).removeValue()
        if let cID = communityID, !cID.isEmpty {
            db.child("communities").child(cID).child("scheduledRides").child(rideID).removeValue()
        }
        db.child("users").child(myID).child("scheduledRides").child(rideID).removeValue()
    }

    // MARK: - Helpers
    private func parseRide(_ snap: DataSnapshot) -> ScheduledRide? {
        guard let data = snap.value as? [String: Any],
              let id = data["id"] as? String,
              let rideCode = data["rideCode"] as? String,
              let title = data["title"] as? String,
              let creatorID = data["creatorID"] as? String,
              let creatorName = data["creatorName"] as? String,
              let scheduledDate = data["scheduledDate"] as? TimeInterval
        else { return nil }

        return ScheduledRide(
            id: id, rideCode: rideCode, title: title,
            description: data["description"] as? String ?? "",
            creatorID: creatorID, creatorName: creatorName,
            creatorInitials: data["creatorInitials"] as? String ?? creatorName.rideInitials,
            scheduledDate: scheduledDate,
            createdAt: data["createdAt"] as? TimeInterval ?? 0,
            meetupLocation: data["meetupLocation"] as? String ?? "",
            meetupLatitude: data["meetupLatitude"] as? Double ?? 0,
            meetupLongitude: data["meetupLongitude"] as? Double ?? 0,
            communityID: data["communityID"] as? String,
            rsvpCount: data["rsvpCount"] as? Int ?? 0
        )
    }

    private func loadRides(ids: [String], completion: @escaping ([ScheduledRide]) -> Void) {
        guard !ids.isEmpty else { completion([]); return }
        var rides: [ScheduledRide] = []
        let group = DispatchGroup()
        for rideID in ids {
            group.enter()
            db.child("scheduledRides").child(rideID).observeSingleEvent(of: .value) { snap in
                if let ride = self.parseRide(snap) { rides.append(ride) }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(rides) }
    }
}
