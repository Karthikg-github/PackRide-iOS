import Foundation
import UIKit
import Combine
import FirebaseDatabase
import FirebaseAuth

// MARK: - Ride Invite Model
// One entry under users/{friendUid}/rideInvites/{senderId} in Firebase — an
// in-app invite to a specific PLANNED ROUTE, sent from Plan Route's "Share"
// button (see WaypointsView.swift) to a followed PackRide friend
// (UserProfileManager.followedUsers). Carries the same ride code that
// GroupWaypointSync already mirrors this plan's waypoints under (see
// WaypointsView.swift's promoteToRideCodeIfNeeded()), so the recipient's own
// Plan Route screen can bind straight to that code and see the exact same
// stops the sender picked — no separate "invite payload" duplicating the
// route data, the code IS the pointer to it.
struct RideInvite: Identifiable {
    let id: String          // sender's Firebase uid (also the Firebase key)
    let senderName: String
    let rideCode: String
    let destinationName: String
    let stopCount: Int
    let timestamp: TimeInterval

    var dateString: String {
        let date = Date(timeIntervalSince1970: timestamp)
        let f = DateFormatter()
        f.dateFormat = "M/d/yy • h:mm a"
        return f.string(from: date)
    }
}

// MARK: - Ride Invite Manager
// Mirrors CrashAlertManager.swift's house style exactly (same
// ObservableObject-wrapping-Database.database().reference() shape, same
// completion(String?) error-or-nil convention): sending is a fire-and-forget
// write from WaypointsView's "Share" flow, one write per selected friend, so
// a single bad/unfollowed uid never blocks the others from going out.
// Receiving is a live listener on this device's own inbox, surfaced as the
// "Ride Invites" card in ProfileView.swift — same card pattern as Crash
// Alerts / Follow Requests there.
class RideInviteManager: ObservableObject {
    private let db = Database.database().reference()

    @Published var receivedInvites: [RideInvite] = []

    private var invitesRef: DatabaseReference?
    private var invitesHandle: DatabaseHandle?

    var myID: String { Auth.auth().currentUser?.uid ?? UIDevice.current.identifierForVendor?.uuidString ?? "" }

    deinit { stopListening() }

    // MARK: - Sending (Plan Route's Share button)
    func sendInvite(to friendUID: String, rideCode: String, senderName: String,
                     destinationName: String, stopCount: Int,
                     completion: @escaping (String?) -> Void = { _ in }) {
        guard !myID.isEmpty, friendUID != myID, !rideCode.isEmpty else {
            completion("Couldn't send invite — try again.")
            return
        }
        let data: [String: Any] = [
            "senderName": senderName,
            "rideCode": rideCode,
            "destinationName": destinationName,
            "stopCount": stopCount,
            "timestamp": Date().timeIntervalSince1970
        ]
        db.child("users").child(friendUID).child("rideInvites").child(myID).setValue(data) { error, _ in
            DispatchQueue.main.async { completion(error?.localizedDescription) }
        }
    }

    // MARK: - Receiving (my inbox)
    func listenForRideInvites() {
        guard !myID.isEmpty else { return }
        stopListening()
        let ref = db.child("users").child(myID).child("rideInvites")
        invitesRef = ref
        invitesHandle = ref.observe(.value) { [weak self] snapshot in
            var invites: [RideInvite] = []
            for child in snapshot.children {
                guard let snap = child as? DataSnapshot,
                      let data = snap.value as? [String: Any],
                      let senderName = data["senderName"] as? String,
                      let rideCode = data["rideCode"] as? String,
                      let timestamp = data["timestamp"] as? TimeInterval
                else { continue }
                invites.append(RideInvite(
                    id: snap.key,
                    senderName: senderName,
                    rideCode: rideCode,
                    destinationName: data["destinationName"] as? String ?? "",
                    stopCount: data["stopCount"] as? Int ?? 0,
                    timestamp: timestamp
                ))
            }
            DispatchQueue.main.async {
                self?.receivedInvites = invites.sorted { $0.timestamp > $1.timestamp }
            }
        }
    }

    func stopListening() {
        if let invitesHandle { invitesRef?.removeObserver(withHandle: invitesHandle) }
        invitesHandle = nil
        invitesRef = nil
    }

    // MARK: - Dismiss
    // Removing the Firebase node is the entire "dismiss" action, same as
    // CrashAlertManager.dismiss — no separate read/unread flag. Used both for
    // an explicit decline AND to clear the invite out of the inbox once
    // accepted (ProfileView calls this right before navigating into Plan Route).
    func dismiss(_ invite: RideInvite, completion: @escaping (String?) -> Void = { _ in }) {
        guard !myID.isEmpty else { completion("Not signed in — try logging out and back in."); return }
        db.child("users").child(myID).child("rideInvites").child(invite.id).removeValue { error, _ in
            DispatchQueue.main.async { completion(error?.localizedDescription) }
        }
    }
}
