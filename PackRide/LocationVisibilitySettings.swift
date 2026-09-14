import Foundation
import Combine
import FirebaseAuth
import FirebaseDatabase

/// Rider-controlled, opt-in location visibility. Group Ride sharing is never
/// stored here: it is a temporary room-scoped exception while a ride is active.
final class LocationVisibilitySettings: ObservableObject {
    @Published var shareWithFollowers: Bool { didSet { persist() } }
    @Published var shareWithCommunities: Bool { didSet { persist() } }
    @Published var nearbyRadiusMiles: Double { didSet { persist() } }
    @Published var usesSelectedFollowers: Bool { didSet { persist() } }
    @Published private(set) var selectedFollowerIDs: Set<String> = []

    private let db = Database.database().reference()
    private let defaults = UserDefaults.standard
    private var isLoading = false

    init() {
        shareWithFollowers = defaults.bool(forKey: "shareLocationWithFollowers")
        shareWithCommunities = defaults.bool(forKey: "shareLocationWithCommunities")
        nearbyRadiusMiles = defaults.object(forKey: "nearbyRadiusMiles") as? Double ?? 1
        usesSelectedFollowers = defaults.bool(forKey: "usesSelectedLocationFollowers")
    }

    func load() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        db.child("users").child(uid).child("locationVisibility").observeSingleEvent(of: .value) { [weak self] snapshot in
            guard let self, let value = snapshot.value as? [String: Any] else { return }
            self.isLoading = true
            self.shareWithFollowers = value["followers"] as? Bool ?? false
            self.shareWithCommunities = value["communities"] as? Bool ?? false
            self.nearbyRadiusMiles = value["nearbyRadiusMiles"] as? Double ?? self.nearbyRadiusMiles
            self.usesSelectedFollowers = value["followerSelectionEnabled"] as? Bool ?? false
            let selected = (value["selectedFollowers"] as? [String: Bool] ?? [:])
            self.selectedFollowerIDs = Set(selected.compactMap { $0.value ? $0.key : nil })
            self.isLoading = false
        }
    }

    func toggleFollower(_ id: String) {
        if selectedFollowerIDs.contains(id) {
            selectedFollowerIDs.remove(id)
        } else {
            selectedFollowerIDs.insert(id)
        }
        usesSelectedFollowers = true
        persist()
    }

    func shareWithAllFollowers() {
        selectedFollowerIDs.removeAll()
        usesSelectedFollowers = false
        persist()
    }

    private func persist() {
        guard !isLoading, let uid = Auth.auth().currentUser?.uid else { return }
        defaults.set(shareWithFollowers, forKey: "shareLocationWithFollowers")
        defaults.set(shareWithCommunities, forKey: "shareLocationWithCommunities")
        defaults.set(nearbyRadiusMiles, forKey: "nearbyRadiusMiles")
        defaults.set(usesSelectedFollowers, forKey: "usesSelectedLocationFollowers")
        let selectedFollowers = Dictionary(uniqueKeysWithValues: selectedFollowerIDs.map { ($0, true) })
        db.child("users").child(uid).child("locationVisibility").updateChildValues([
            "followers": shareWithFollowers,
            "communities": shareWithCommunities,
            "nearbyRadiusMiles": nearbyRadiusMiles,
            "followerSelectionEnabled": usesSelectedFollowers,
            "selectedFollowers": selectedFollowers
        ])
    }
}
