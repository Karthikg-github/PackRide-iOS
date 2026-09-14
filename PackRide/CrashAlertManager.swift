import Foundation
import UIKit
import Combine
import FirebaseDatabase
import FirebaseAuth
import CoreLocation

// An inbox entry points to one shared incident. Acknowledging it stops the
// server-side reminders for every recipient, rather than simply hiding a card.
struct CrashAlert: Identifiable {
    let id: String
    let senderName: String
    let timestamp: TimeInterval
    let mapURL: String?
    let peakG: Double?

    var dateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d/yy • h:mm a"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}

final class CrashAlertManager: ObservableObject {
    private let db = Database.database().reference()
    @Published var receivedAlerts: [CrashAlert] = []
    private var alertsRef: DatabaseReference?
    private var alertsHandle: DatabaseHandle?

    var myID: String { Auth.auth().currentUser?.uid ?? "" }
    deinit { stopListening() }

    // The Cloud Function triggered by this node handles urgent push delivery
    // and bounded re-notification. This is a personal safety aid, not EMS.
    func createCrashIncident(senderName: String, coordinate: CLLocationCoordinate2D?, peakG: Double,
                             groupRideCode: String?, primaryResponderUIDs: [String],
                             completion: @escaping (String?, String?) -> Void) {
        guard !myID.isEmpty else { completion(nil, "Sign in is required to notify linked PackRide contacts."); return }
        let ref = db.child("crashIncidents").childByAutoId()
        guard let incidentID = ref.key else { completion(nil, "Couldn't create the safety incident."); return }

        let now = Date().timeIntervalSince1970
        let responders = Set(primaryResponderUIDs.filter { !$0.isEmpty && $0 != myID })
        var payload: [String: Any] = [
            "senderUID": myID,
            "senderDeviceID": UIDevice.current.identifierForVendor?.uuidString ?? "",
            "senderName": senderName,
            "timestamp": now,
            "peakG": peakG,
            "status": "open",
            "escalationCount": 0,
            "nextEscalationAt": now + 120,
            "primaryResponderUIDs": Dictionary(uniqueKeysWithValues: responders.map { ($0, true) })
        ]
        if let groupRideCode, !groupRideCode.isEmpty { payload["groupRideCode"] = groupRideCode }
        if let coordinate {
            payload["latitude"] = coordinate.latitude
            payload["longitude"] = coordinate.longitude
            payload["mapURL"] = "https://maps.apple.com/?ll=\(coordinate.latitude),\(coordinate.longitude)"
        }
        ref.setValue(payload) { error, _ in
            DispatchQueue.main.async { completion(error == nil ? incidentID : nil, error?.localizedDescription) }
        }
    }

    // Linked contacts receive an inbox item as well as the remote push.
    func sendCrashAlerts(to recipientUIDs: [String], incidentID: String, senderName: String,
                         coordinate: CLLocationCoordinate2D?, peakG: Double) {
        let recipients = Set(recipientUIDs.filter { !$0.isEmpty && $0 != myID })
        guard !recipients.isEmpty else { return }
        var payload: [String: Any] = ["senderName": senderName, "timestamp": Date().timeIntervalSince1970,
                                      "peakG": peakG, "incidentID": incidentID]
        if let coordinate { payload["mapURL"] = "https://maps.apple.com/?ll=\(coordinate.latitude),\(coordinate.longitude)" }
        for uid in recipients {
            db.child("users").child(uid).child("crashAlerts").child(incidentID).setValue(payload)
        }
    }

    func listenForCrashAlerts() {
        guard !myID.isEmpty else { return }
        stopListening()
        let ref = db.child("users").child(myID).child("crashAlerts")
        alertsRef = ref
        alertsHandle = ref.observe(.value) { [weak self] snapshot in
            let alerts = snapshot.children.compactMap { child -> CrashAlert? in
                guard let snap = child as? DataSnapshot,
                      let data = snap.value as? [String: Any],
                      let senderName = data["senderName"] as? String,
                      let timestamp = data["timestamp"] as? TimeInterval else { return nil }
                return CrashAlert(id: (data["incidentID"] as? String) ?? snap.key,
                                  senderName: senderName, timestamp: timestamp,
                                  mapURL: data["mapURL"] as? String, peakG: data["peakG"] as? Double)
            }
            DispatchQueue.main.async { self?.receivedAlerts = alerts.sorted { $0.timestamp > $1.timestamp } }
        }
    }

    func acknowledge(_ alert: CrashAlert, responderName: String, completion: @escaping (String?) -> Void = { _ in }) {
        guard !myID.isEmpty else { completion("Sign in is required to acknowledge an incident."); return }
        let update: [String: Any] = ["status": "acknowledged", "acknowledgedByUID": myID,
                                     "acknowledgedByName": responderName, "acknowledgedAt": Date().timeIntervalSince1970]
        db.child("crashIncidents").child(alert.id).updateChildValues(update) { [weak self] error, _ in
            if error == nil { self?.dismiss(alert) }
            DispatchQueue.main.async { completion(error?.localizedDescription) }
        }
    }

    func stopListening() {
        if let alertsHandle { alertsRef?.removeObserver(withHandle: alertsHandle) }
        alertsHandle = nil
        alertsRef = nil
    }

    func dismiss(_ alert: CrashAlert, completion: @escaping (String?) -> Void = { _ in }) {
        guard !myID.isEmpty else { completion("Not signed in."); return }
        db.child("users").child(myID).child("crashAlerts").child(alert.id).removeValue { error, _ in
            DispatchQueue.main.async { completion(error?.localizedDescription) }
        }
    }
}
