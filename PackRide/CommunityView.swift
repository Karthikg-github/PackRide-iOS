import SwiftUI
import FirebaseDatabase
import FirebaseAuth
import CoreLocation
import Combine
import UIKit

// MARK: - Community Model
struct Community: Identifiable, Codable {
    let id: String
    var name: String
    var passcode: String
    var createdBy: String
    var memberCount: Int
    var createdAt: Double
}

// MARK: - Community Member Model
struct CommunityMember: Identifiable {
    let id: String
    let name: String
    let initials: String
    var isRiding: Bool
    var latitude: Double
    var longitude: Double
    var speed: Double
    var lastSeen: Double
    // Firebase Auth uid of whoever this member is signed in as, if any —
    // stamped on join (CommunityMembershipStore.joinMemberRecord) and
    // refreshed on every ride (CommunityManager.updateRidingStatus) so a
    // member whose record predates this field self-heals the next time they
    // ride. Needed because community membership itself is keyed by device ID
    // (see CommunityManager.myID) while the follow/friend system needs the
    // Firebase-account ID instead — this is the bridge between the two, and
    // what the Follow button on each member row below is keyed off of.
    var authUID: String = ""

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Community Membership Store (app-wide, multi-community)
// Aug 21, 2026 — previously a device could belong to exactly one community at
// a time (a single @AppStorage("communityID") value). This is the
// replacement: a locally-persisted list of every community this device has
// joined or created, so PackRide can support belonging to several at once.
// Owned once at the app level (see PackRideApp.swift) and injected via
// .environmentObject(...) — the same pattern as VoiceChatManager/
// GroupRideSessionManager/HelpRequestManager — so every screen that needs
// "which communities am I in" (the Community tab, Need Help's share targets,
// a solo ride's live-share picker, Schedule Ride's share-to-community picker)
// reads the same list instead of each recreating its own.
//
// The local list makes the UI immediate. The shared
// users/{authUID}/communityMemberships index restores it after reinstall or
// login on another device; the device-keyed member record is then repaired.
final class CommunityMembershipStore: ObservableObject {
    @Published private(set) var myCommunities: [Community] = []
    @Published var isLoading = false
    @Published var errorMessage = ""

    private let db = Database.database().reference()
    private let myID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    private static let storageKey = "myCommunitiesV2"

    init() {
        load()
        migrateLegacySingleCommunityIfNeeded()
        syncCachedPushToken()
    }

    // Aug 22, 2026 — called from CommunityListView.onAppear. Community
    // membership is cached locally per device (that's the known tradeoff of
    // not having a server-side reverse index — see the store's own doc
    // above), so if the creator deletes a community while THIS device never
    // has that specific community's detail screen open, the stale card would
    // otherwise sit in My Communities forever, 404-ing the moment it's
    // tapped. CommunityDetailView's own wasDeleted flag catches it live
    // while someone's looking at it; this catches the rest — every time the
    // list itself is opened, each card is checked against Firebase and any
    // that no longer exist are quietly dropped, same self-healing shape as
    // the authUID/profile fixes elsewhere in this file.
    func pruneDeletedCommunities() {
        for community in myCommunities {
            db.child("communities").child(community.id).observeSingleEvent(of: .value) { [weak self] snapshot in
                guard let self, !snapshot.exists() else { return }
                DispatchQueue.main.async { self.remove(id: community.id) }
            }
        }
    }

    /// One-time-compatible migration for communities joined before private
    /// location delivery existed. It only indexes this signed-in rider's own
    /// existing member record; it never creates, alters, or removes anyone
    /// else's membership.
    func backfillCurrentUsersMembershipIndexes() {
        guard let uid = Auth.auth().currentUser?.uid, !uid.isEmpty else { return }
        restoreMembershipsFromCloud(uid: uid)
        for community in myCommunities {
            let memberRef = db.child("communities").child(community.id).child("members").child(myID)
            memberRef.observeSingleEvent(of: .value) { [weak self] snapshot in
                guard let self, snapshot.exists() else { return }
                self.db.updateChildValues([
                    "users/\(uid)/communityMemberships/\(community.id)": true,
                    "communities/\(community.id)/members/\(self.myID)/authUID": uid
                ])
            }
        }
    }

    private func restoreMembershipsFromCloud(uid: String) {
        db.child("users").child(uid).child("communityMemberships")
            .observeSingleEvent(of: .value) { [weak self] index in
                guard let self else { return }
                for child in index.children {
                    guard let membership = child as? DataSnapshot else { continue }
                    let communityID = membership.key
                    self.db.child("communities").child(communityID)
                        .observeSingleEvent(of: .value) { [weak self] snapshot in
                            guard let self else { return }
                            guard let data = snapshot.value as? [String: Any] else {
                                self.db.child("users").child(uid).child("communityMemberships")
                                    .child(communityID).removeValue()
                                DispatchQueue.main.async { self.remove(id: communityID) }
                                return
                            }
                            let community = Community(
                                id: data["id"] as? String ?? communityID,
                                name: data["name"] as? String ?? "Community",
                                passcode: data["passcode"] as? String ?? "",
                                createdBy: data["createdBy"] as? String ?? "",
                                memberCount: (data["memberCount"] as? NSNumber)?.intValue ?? 0,
                                createdAt: (data["createdAt"] as? NSNumber)?.doubleValue ?? 0
                            )
                            DispatchQueue.main.async {
                                self.myCommunities.removeAll { $0.id == communityID }
                                self.myCommunities.append(community)
                                self.save()
                            }
                            self.ensureMemberRecord(communityID: communityID, uid: uid)
                        }
                }
            }
    }

    private func ensureMemberRecord(communityID: String, uid: String) {
        let ref = db.child("communities").child(communityID).child("members").child(myID)
        ref.observeSingleEvent(of: .value) { [weak self] snapshot in
            guard let self else { return }
            let existing = snapshot.value as? [String: Any] ?? [:]
            let riderName = UserDefaults.standard.string(forKey: "riderName") ?? "Rider"
            var values: [String: Any] = [
                "id": self.myID,
                "name": riderName,
                "initials": riderName.rideInitials,
                "authUID": uid,
                "fcmToken": UserDefaults.standard.string(forKey: "fcmToken") ?? ""
            ]
            if existing["isRiding"] == nil { values["isRiding"] = false }
            if existing["latitude"] == nil { values["latitude"] = 0.0 }
            if existing["longitude"] == nil { values["longitude"] = 0.0 }
            if existing["speed"] == nil { values["speed"] = 0.0 }
            if existing["lastSeen"] == nil { values["lastSeen"] = Date().timeIntervalSince1970 }
            ref.updateChildValues(values)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([Community].self, from: data) {
            myCommunities = decoded
        }
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(myCommunities) {
            UserDefaults.standard.set(encoded, forKey: Self.storageKey)
        }
    }

    // An FCM registration token is normally saved when Firebase issues or
    // rotates it. That callback is not guaranteed on every launch, though,
    // and a person can join a community after it already happened. Refresh
    // the cached token for every local membership at launch so Cloud
    // Functions can always deliver community Help alerts to this device.
    private func syncCachedPushToken() {
        guard let token = UserDefaults.standard.string(forKey: "fcmToken"),
              !token.isEmpty else { return }
        for community in myCommunities {
            db.child("communities").child(community.id).child("members").child(myID)
                .child("fcmToken").setValue(token)
        }
    }

    // One-time upgrade path for anyone who joined/created a single community
    // before this feature existed — folds the old @AppStorage trio into the
    // new list, once, then clears the old keys so this never runs again.
    private func migrateLegacySingleCommunityIfNeeded() {
        let d = UserDefaults.standard
        let legacyID = d.string(forKey: "communityID") ?? ""
        if !legacyID.isEmpty, !myCommunities.contains(where: { $0.id == legacyID }) {
            let legacy = Community(
                id: legacyID,
                name: d.string(forKey: "communityName") ?? "Community",
                passcode: d.string(forKey: "communityPasscode") ?? "",
                createdBy: "", memberCount: 0, createdAt: 0
            )
            myCommunities.append(legacy)
            save()
        }
        d.removeObject(forKey: "communityID")
        d.removeObject(forKey: "communityName")
        d.removeObject(forKey: "communityPasscode")
    }

    func add(_ community: Community) {
        guard !myCommunities.contains(where: { $0.id == community.id }) else { return }
        myCommunities.append(community)
        save()
    }

    func remove(id: String) {
        myCommunities.removeAll { $0.id == id }
        save()
    }

    // MARK: - Create / Join
    // 4-character codes (see JoinCodeGenerator) have a much smaller space than
    // the old 8-character UUID-based ID, so unlike group ride codes (ephemeral,
    // low stakes if two ever collided) a community ID could plausibly already
    // be taken — checked here and retried a few times rather than risking a
    // `setValue` silently overwriting someone else's existing community.
    func createCommunity(name: String, passcode: String, completion: @escaping (Bool) -> Void = { _ in }) {
        isLoading = true
        attemptCreateCommunity(name: name, passcode: passcode, attemptsLeft: 5, completion: completion)
    }

    private func attemptCreateCommunity(name: String, passcode: String, attemptsLeft: Int, completion: @escaping (Bool) -> Void) {
        let id = JoinCodeGenerator.generate()
        db.child("communities").child(id).observeSingleEvent(of: .value) { [weak self] snapshot in
            guard let self else { return }
            if snapshot.exists() {
                guard attemptsLeft > 0 else {
                    DispatchQueue.main.async {
                        self.isLoading = false
                        self.errorMessage = "Couldn't generate a unique community code — try again."
                        completion(false)
                    }
                    return
                }
                self.attemptCreateCommunity(name: name, passcode: passcode, attemptsLeft: attemptsLeft - 1, completion: completion)
                return
            }

            let community = Community(id: id, name: name, passcode: passcode, createdBy: self.myID, memberCount: 1, createdAt: Date().timeIntervalSince1970)
            let data: [String: Any] = [
                "id": community.id, "name": community.name, "passcode": community.passcode,
                "createdBy": community.createdBy, "memberCount": community.memberCount, "createdAt": community.createdAt
            ]
            self.db.child("communities").child(community.id).setValue(data) { error, _ in
                DispatchQueue.main.async {
                    self.isLoading = false
                    if error == nil {
                        self.joinMemberRecord(community: community)
                        self.add(community)
                        completion(true)
                    } else {
                        self.errorMessage = "Failed to create community"
                        completion(false)
                    }
                }
            }
        }
    }

    func joinCommunity(id: String, passcode: String, completion: @escaping (Bool) -> Void) {
        isLoading = true
        db.child("communities").child(id).observeSingleEvent(of: .value) { [weak self] snapshot in
            guard let self else { return }
            DispatchQueue.main.async {
                self.isLoading = false
                guard let data = snapshot.value as? [String: Any],
                      let storedPasscode = data["passcode"] as? String,
                      storedPasscode == passcode else {
                    self.errorMessage = "Invalid community ID or passcode"
                    completion(false)
                    return
                }
                let community = Community(
                    id: id, name: data["name"] as? String ?? "Community", passcode: passcode,
                    createdBy: data["createdBy"] as? String ?? "", memberCount: data["memberCount"] as? Int ?? 0,
                    createdAt: data["createdAt"] as? Double ?? 0
                )
                self.joinMemberRecord(community: community)
                self.add(community)
                completion(true)
            }
        }
    }

    // Writes this device's own member record — shared by both create and join,
    // since creating a community also makes you its first member.
    private func joinMemberRecord(community: Community) {
        let riderName = UserDefaults.standard.string(forKey: "riderName") ?? "Rider"
        let memberData: [String: Any] = [
            "id": myID, "name": riderName, "initials": riderName.rideInitials,
            "authUID": Auth.auth().currentUser?.uid ?? "",
            "isRiding": false, "latitude": 0.0, "longitude": 0.0, "speed": 0.0, "lastSeen": Date().timeIntervalSince1970,
            "fcmToken": UserDefaults.standard.string(forKey: "fcmToken") ?? ""
        ]
        db.child("communities").child(community.id).child("members").child(myID).setValue(memberData)
        if let uid = Auth.auth().currentUser?.uid {
            db.child("users").child(uid).child("communityMemberships").child(community.id).setValue(true)
        }
    }

    // MARK: - Static helper for non-SwiftUI contexts
    // AppDelegate (NotificationManager.swift) needs "every community I'm in"
    // to fan an FCM token write out to each one, without owning a full
    // ObservableObject instance just for that.
    static func allJoinedIDs() -> [String] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Community].self, from: data) else { return [] }
        return decoded.map { $0.id }
    }
}

// MARK: - Community Manager (one community's detail: members, riding status, leave/delete)
class CommunityManager: ObservableObject {
    private let db = Database.database().reference()
    private let myID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    private var membersRef: DatabaseReference?
    private var membersHandle: DatabaseHandle?

    let communityID: String
    @Published var myCommunity: Community?
    @Published var members: [CommunityMember] = []
    @Published var activeRiders: [CommunityMember] = []
    // Aug 22, 2026 — flips true the moment this community's Firebase node is
    // observed gone (the creator deleted it). Community membership is
    // local-storage-only per device (see CommunityMembershipStore), so
    // deleting the node doesn't remove it from every OTHER member's My
    // Communities list by itself — this is what lets each member's own
    // device self-heal that the next time they're looking at it, instead of
    // being left with a dead community that 404s. CommunityDetailView below
    // watches this to drop it locally and back out automatically.
    @Published var wasDeleted = false

    // Seeded immediately from the store's cached copy (name/passcode/ID) so
    // the dashboard never opens blank, then refreshed from Firebase for
    // fields the cache doesn't carry (createdBy, live memberCount).
    init(community: Community) {
        self.communityID = community.id
        self.myCommunity = community
        loadCommunity()
        listenForMembers()
        stampMyAuthUID()
    }

    // Refreshes this device's member record when its community opens. Besides
    // keeping authUID current for Follow, this repairs a record that an older
    // build may have deleted after confusing another device on the same
    // account for the current member.
    private func stampMyAuthUID() {
        let ref = db.child("communities").child(communityID).child("members").child(myID)
        ref.observeSingleEvent(of: .value) { snapshot in
            let existing = snapshot.value as? [String: Any] ?? [:]
            let riderName = UserDefaults.standard.string(forKey: "riderName") ?? "Rider"
            var updates: [String: Any] = [
                "id": self.myID,
                "name": riderName,
                "initials": riderName.rideInitials,
                "authUID": Auth.auth().currentUser?.uid ?? "",
                "fcmToken": UserDefaults.standard.string(forKey: "fcmToken") ?? ""
            ]

            // Preserve a live rider's status and location, but supply the
            // complete shape when recreating a missing/partial record.
            if existing["isRiding"] == nil { updates["isRiding"] = false }
            if existing["latitude"] == nil { updates["latitude"] = 0.0 }
            if existing["longitude"] == nil { updates["longitude"] = 0.0 }
            if existing["speed"] == nil { updates["speed"] = 0.0 }
            if existing["lastSeen"] == nil { updates["lastSeen"] = Date().timeIntervalSince1970 }
            ref.updateChildValues(updates)
        }
    }

    // True creator identity — a stable device ID, not the display name
    // (display names aren't unique and can change, so they can't be trusted
    // for "am I the creator?" checks).
    var isCreator: Bool { !myID.isEmpty && myCommunity?.createdBy == myID }

    // Community membership is keyed by the installation's device ID, not the
    // Firebase Auth account ID. In particular, two phones can legitimately be
    // signed into the same PackRide account. Treating a matching authUID as
    // this device caused one phone to hide—and then delete—the other phone's
    // membership record, leaving a joiner with a misleading "1 total" list.
    private func isCurrentUserMemberRecord(key: String, id: String) -> Bool {
        id == myID || key == myID
    }

    private func removeStaleCurrentUserMemberRecord(key: String) {
        guard key != myID else { return }
        db.child("communities").child(communityID).child("members").child(key).removeValue()
    }

    func loadCommunity() {
        db.child("communities").child(communityID).observeSingleEvent(of: .value) { [weak self] snapshot in
            guard let self, let data = snapshot.value as? [String: Any] else { return }
            DispatchQueue.main.async {
                self.myCommunity = Community(
                    id: self.communityID,
                    name: data["name"] as? String ?? self.myCommunity?.name ?? "Community",
                    passcode: data["passcode"] as? String ?? self.myCommunity?.passcode ?? "",
                    createdBy: data["createdBy"] as? String ?? "",
                    memberCount: data["memberCount"] as? Int ?? 0,
                    createdAt: data["createdAt"] as? Double ?? 0
                )
            }
        }
    }

    func listenForMembers() {
        stopListeningForMembers()
        let ref = db.child("communities").child(communityID).child("members")
        membersRef = ref
        membersHandle = ref.observe(.value) { [weak self] snapshot in
            guard let self else { return }

            // The community's whole node (name/passcode/members, everything)
            // is removed in one shot by deleteCommunity() below, so this
            // members-node listener firing with nothing there is a reliable
            // signal the community itself is gone, not just emptied out.
            guard snapshot.exists() else {
                DispatchQueue.main.async {
                    self.members = []
                    self.activeRiders = []
                    self.wasDeleted = true
                }
                return
            }

            var allMembers: [CommunityMember] = []

            for child in snapshot.children {
                guard let snap = child as? DataSnapshot,
                      let data = snap.value as? [String: Any]
                else { continue }

                let id = data["id"] as? String ?? snap.key
                let authUID = data["authUID"] as? String ?? ""
                if self.isCurrentUserMemberRecord(key: snap.key, id: id) {
                    self.removeStaleCurrentUserMemberRecord(key: snap.key)
                    continue
                }

                guard let name = data["name"] as? String,
                      let initials = data["initials"] as? String,
                      let isRiding = data["isRiding"] as? Bool,
                      let lat = data["latitude"] as? Double,
                      let lng = data["longitude"] as? Double,
                      let speed = data["speed"] as? Double,
                      let lastSeen = data["lastSeen"] as? Double
                else { continue }

                allMembers.append(CommunityMember(id: id, name: name, initials: initials, isRiding: isRiding, latitude: lat, longitude: lng, speed: speed, lastSeen: lastSeen, authUID: authUID))
            }

            DispatchQueue.main.async {
                self.members = allMembers
                self.activeRiders = allMembers.filter { $0.isRiding }
            }
        }
    }

    func stopListeningForMembers() {
        if let membersHandle { membersRef?.removeObserver(withHandle: membersHandle) }
        membersHandle = nil
        membersRef = nil
    }

    func updateRidingStatus(isRiding: Bool, location: CLLocation? = nil, speed: Double = 0) {
        var updates: [String: Any] = [
            "isRiding": isRiding, "speed": speed, "lastSeen": Date().timeIntervalSince1970,
            "authUID": Auth.auth().currentUser?.uid ?? ""
        ]
        if let location = location {
            updates["latitude"] = location.coordinate.latitude
            updates["longitude"] = location.coordinate.longitude
        }
        db.child("communities").child(communityID).child("members").child(myID).updateChildValues(updates)
    }

    func leaveCommunity() {
        stopListeningForMembers()
        var updates: [String: Any] = [
            "communities/\(communityID)/members/\(myID)": NSNull()
        ]
        if let uid = Auth.auth().currentUser?.uid {
            updates["users/\(uid)/communityMemberships/\(communityID)"] = NSNull()
        }
        db.updateChildValues(updates)
    }

    // Creator-only: removes the community entirely for everyone, not just yourself.
    // Gated in the UI (only shown when isCreator is true), matching how the rest of
    // the app enforces "leader/creator" actions (e.g. ending a group ride).
    func deleteCommunity() {
        guard isCreator else { return }
        stopListeningForMembers()
        db.child("communities").child(communityID).removeValue()
    }

    deinit { stopListeningForMembers() }
}

// MARK: - Community List (top-level "My Communities" — entry point from Home)
// Aug 21, 2026 — replaces the old single-community CommunityView as the
// destination from Home's Community tile. Shows a card per joined/created
// community; tap one to open its own dashboard (CommunityDetailView).
struct CommunityListView: View {
    @EnvironmentObject var membershipStore: CommunityMembershipStore
    // Aug 22, 2026 — a tapped packride://joincommunity link lands here (see
    // HomeView's hidden NavigationLink) with id + passcode already known;
    // consumed on appear to prefill and auto-open Join Community, same
    // "prefill, don't auto-submit" shape as the group ride join link.
    @EnvironmentObject var deepLinkRouter: DeepLinkRouter
    @State private var showCreateSheet = false
    @State private var showJoinSheet = false
    @State private var prefilledJoinID = ""
    @State private var prefilledJoinPasscode = ""

    var body: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()

            VStack(spacing: 0) {
                PRWebPageHeader(
                    eyebrow: "The Pack",
                    title: "My Communities",
                    subtitle: membershipStore.myCommunities.isEmpty
                        ? "Find your riding crew"
                        : "\(membershipStore.myCommunities.count) communit\(membershipStore.myCommunities.count == 1 ? "y" : "ies")",
                    trailing: membershipStore.myCommunities.isEmpty ? nil : AnyView(
                        Button(action: { showCreateSheet = true }) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 22))
                                .foregroundColor(.prCoral)
                        }
                    )
                )

                if membershipStore.myCommunities.isEmpty {
                    CommunityWelcome(onCreate: { showCreateSheet = true }, onJoin: { showJoinSheet = true })
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            PRWebMetricStrip(metrics: [
                                ("\(membershipStore.myCommunities.count)", "Communities"),
                                ("PRIVATE", "Network"),
                                ("READY", "To Ride")
                            ])

                            PRWebSectionLabel(title: "Your communities", detail: "Choose a crew")

                            ForEach(membershipStore.myCommunities) { community in
                                NavigationLink(destination: CommunityDetailView(community: community)) {
                                    CommunityListCard(community: community)
                                }
                            }

                            Button(action: { showJoinSheet = true }) {
                                HStack(spacing: 12) {
                                    Image(systemName: "person.badge.plus")
                                        .font(.system(size: 15, weight: .bold))
                                    Text("JOIN ANOTHER COMMUNITY")
                                        .font(.system(size: 12, weight: .heavy))
                                        .tracking(1.2)
                                    Spacer()
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 12, weight: .bold))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 20)
                                .frame(height: 52)
                                .background(Color.prCoral)
                            }
                            .padding(.top, 20)
                        }
                        .padding(.bottom, 28)
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showCreateSheet) { CreateCommunityView(membershipStore: membershipStore) }
        .sheet(isPresented: $showJoinSheet) {
            JoinCommunityView(membershipStore: membershipStore, prefilledID: prefilledJoinID, prefilledPasscode: prefilledJoinPasscode)
        }
        .onAppear {
            membershipStore.pruneDeletedCommunities()
            membershipStore.backfillCurrentUsersMembershipIndexes()
            if let pending = deepLinkRouter.pendingCommunityJoin {
                deepLinkRouter.pendingCommunityJoin = nil
                prefilledJoinID = pending.id
                prefilledJoinPasscode = pending.passcode
                showJoinSheet = true
            }
        }
    }
}

// MARK: - Community List Card
struct CommunityListCard: View {
    let community: Community
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.prCoralSoft).frame(width: 46, height: 46)
                Image(systemName: "person.3.fill").font(.system(size: 18)).foregroundColor(.prCoral)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(community.name).font(.system(size: 16, weight: .bold)).foregroundColor(.prInk)
                Text("CREW ID  \(community.id)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundColor(.prMuted)
            }
            Spacer()
            Image(systemName: "arrow.up.right").font(.system(size: 14, weight: .semibold)).foregroundColor(.prMuted)
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 74)
        .background(Color.prBg)
        .overlay(Rectangle().fill(Color.prBorder).frame(height: 1), alignment: .bottom)
    }
}

// MARK: - Community Detail (one community's dashboard)
struct CommunityDetailView: View {
    @EnvironmentObject var membershipStore: CommunityMembershipStore
    @StateObject private var manager: CommunityManager
    @State private var showLeaveAlert = false
    @State private var showDeleteAlert = false
    @Environment(\.dismiss) var dismiss

    init(community: Community) {
        _manager = StateObject(wrappedValue: CommunityManager(community: community))
    }

    var body: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()
            CommunityDashboard(manager: manager, showLeaveAlert: $showLeaveAlert, showDeleteAlert: $showDeleteAlert)
        }
        .navigationBarHidden(true)
        .alert("Leave Community?", isPresented: $showLeaveAlert) {
            Button("Leave", role: .destructive) {
                manager.leaveCommunity()
                membershipStore.remove(id: manager.communityID)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will no longer be visible to community members during rides.")
        }
        .alert("Delete Community?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                manager.deleteCommunity()
                membershipStore.remove(id: manager.communityID)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the community for every member, not just you. This can't be undone.")
        }
        // Aug 22, 2026 — the creator's own Delete button above already
        // removes it from THEIR local list, but every other member's copy
        // is separately cached (see CommunityMembershipStore) and had no way
        // to find out the community was gone. manager.wasDeleted flips true
        // the moment this device's listener sees the Firebase node is gone
        // (whether from this creator's Delete button on this same device
        // seconds ago, or another device's), so this closes the loop for
        // everyone still viewing or with it saved: drop it locally, and back
        // out if they're looking at it right now. What's deliberately NOT
        // touched here: the Firebase Auth follow relationships built with
        // this community's members — those live under users/{uid}/following,
        // entirely separate from the communities/{id} node this deletes, so
        // they're untouched and still show up in Friends after this.
        .onChange(of: manager.wasDeleted) { _, deleted in
            guard deleted else { return }
            membershipStore.remove(id: manager.communityID)
            dismiss()
        }
    }
}

// MARK: - Community Welcome
struct CommunityWelcome: View {
    let onCreate: () -> Void
    let onJoin: () -> Void

    var body: some View {
        // Aug 27, 2026 — this was a fixed VStack with a Spacer above and
        // below squeezed between the page header and the tab bar. On top of
        // the header now also taking a bit more room (the new back button —
        // see PRWebPageHeader), the icon + title + subtitle + feature card +
        // both buttons no longer all fit: the two Spacers collapsed to zero
        // and text got clipped mid-line (the subtitle's second line and the
        // feature rows truncating with "…") with the "Join a Community"
        // button pushed down behind the tab bar. Scrollable now, so nothing
        // is ever cut off regardless of screen size or how much room the
        // header takes.
        ScrollView(showsIndicators: false) {
            VStack(spacing: 28) {
                ZStack {
                    Circle().fill(Color.prCoralSoft).frame(width: 110, height: 110)
                    Image(systemName: "person.3.fill").font(.system(size: 44)).foregroundColor(.prCoral)
                }
                .padding(.top, 28)

                VStack(spacing: 12) {
                    Text("Your Riding Tribe")
                        .font(.system(size: 26, weight: .bold)).foregroundColor(.prInk)
                    Text("Create or join a community to\nride together and stay safe.")
                        .font(.system(size: 15)).foregroundColor(.prMuted)
                        .multilineTextAlignment(.center).lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)

                VStack(alignment: .leading, spacing: 14) {
                    CommunityFeatureRow(icon: "location.fill", color: .prCoral, text: "See community riders live on the map during solo rides")
                    PRWebDivider(inset: 50)
                    CommunityFeatureRow(icon: "shield.fill", color: Color(red: 0.180, green: 0.620, blue: 0.357), text: "Get notified if a community rider crashes")
                    PRWebDivider(inset: 50)
                    CommunityFeatureRow(icon: "bell.fill", color: .prTeal, text: "Instant alerts when someone needs help")
                    PRWebDivider(inset: 50)
                    CommunityFeatureRow(icon: "lock.fill", color: Color(red: 0.541, green: 0.4, blue: 0.694), text: "Private — join only with a passcode")
                }
                .padding(.horizontal, 20)

                VStack(spacing: 12) {
                    Button(action: onCreate) {
                        HStack(spacing: 10) {
                            Image(systemName: "plus.circle.fill").font(.system(size: 20))
                            Text("Create a Community").font(.system(size: 16, weight: .bold))
                        }
                        .foregroundColor(.white).frame(maxWidth: .infinity)
                        .frame(height: 54).background(Color.prCoral)
                    }

                    Button(action: onJoin) {
                        HStack(spacing: 10) {
                            Image(systemName: "person.badge.plus").font(.system(size: 20))
                            Text("Join a Community").font(.system(size: 16, weight: .bold))
                        }
                        .foregroundColor(.prCoral).frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .overlay(Rectangle().stroke(Color.prCoral.opacity(0.4), lineWidth: 1))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
    }
}

// MARK: - Community Dashboard
// Aug 21, 2026 — the community identity/passcode card, Scheduled Rides,
// Riding Now, and Members used to be four separate floating cards. Now that
// a device can belong to several communities (see CommunityMembershipStore
// above), each community gets its own screen (CommunityDetailView), so these
// four sections are merged into a single bordered card here — reads as "this
// community's info," not four unrelated panels stacked on the page.
struct CommunityDashboard: View {
    @ObservedObject var manager: CommunityManager
    @Binding var showLeaveAlert: Bool
    @Binding var showDeleteAlert: Bool
    @AppStorage("riderName") var riderName: String = "Rider"
    @State private var showMap = false
    @StateObject private var helpManager = HelpRequestManager()
    // Aug 27, 2026 — Grok re-review, small cleanup: was its own private
    // UserProfileManager() — a duplicate instance alongside PackRideApp's
    // app-wide one. CommunityDashboard is only ever reached inside
    // CommunityDetailView, pushed from CommunityListView within ContentView's
    // navigation tree, so the shared instance is already in its environment.
    @EnvironmentObject private var profileManager: UserProfileManager

    // Membership here (see CommunityManager.myID) uses plain device IDs, same
    // as Group Ride — matching against requesterDeviceID, not requesterUID,
    // is what lines this up correctly with a member's own ID.
    var memberHelpRequests: [HelpRequest] {
        helpManager.activeRequests.filter { $0.targetType == "community" && $0.targetID == manager.communityID }
    }
    func memberNeedsHelp(_ memberID: String) -> Bool {
        memberHelpRequests.contains { $0.requesterDeviceID == memberID }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                PRWebPageHeader(
                    eyebrow: "Community",
                    title: manager.myCommunity?.name ?? "My Community",
                    subtitle: "\(manager.members.count + 1) member\(manager.members.count == 0 ? "" : "s")"
                )

                PRWebMetricStrip(metrics: [
                    ("\(manager.members.count + 1)", "Members"),
                    ("\(manager.activeRiders.count)", "Riding now"),
                    (manager.isCreator ? "OWNER" : "MEMBER", "Your role")
                ])

                VStack(spacing: 0) {
                if let firstRequest = memberHelpRequests.first {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 15))
                        Text(memberHelpRequests.count > 1
                             ? "\(firstRequest.requesterName) and \(memberHelpRequests.count - 1) other\(memberHelpRequests.count > 2 ? "s" : "") need help"
                             : "\(firstRequest.requesterName) needs help")
                            .font(.system(size: 13, weight: .bold))
                        Spacer()
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(Color(red: 0.827, green: 0.231, blue: 0.173))
                }

                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        ZStack {
                            Circle().fill(Color.prCoral).frame(width: 50, height: 50)
                            Image(systemName: "person.3.fill").font(.system(size: 20)).foregroundColor(.white)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(manager.myCommunity?.name ?? "My Community")
                                .font(.system(size: 19, weight: .bold)).foregroundColor(.prInk)
                            Text("ID: \(manager.communityID)")
                                .font(.system(size: 13, design: .monospaced)).foregroundColor(.prMuted)
                        }

                        Spacer()

                        if manager.isCreator {
                            Button(action: { showDeleteAlert = true }) {
                                Image(systemName: "trash")
                                    .foregroundColor(Color(red: 0.827, green: 0.231, blue: 0.173)).font(.system(size: 18))
                            }
                            .padding(.trailing, 4)
                        }

                        Button(action: { showLeaveAlert = true }) {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .foregroundColor(.prMuted).font(.system(size: 18))
                        }
                    }

                    PRWebDivider(inset: 0)

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Passcode").font(.system(size: 12)).foregroundColor(.prMuted)
                            Text(manager.myCommunity?.passcode ?? "")
                                .font(.system(size: 18, weight: .bold, design: .monospaced)).foregroundColor(.prCoral)
                        }
                        Spacer()
                        Button(action: shareCommunity) {
                            HStack(spacing: 6) {
                                Image(systemName: "square.and.arrow.up")
                                Text("Invite")
                            }
                            .font(.system(size: 14, weight: .medium)).foregroundColor(.white)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Color.prCoral).cornerRadius(10)
                        }
                    }

                    PRWebDivider(inset: 0)

                    CommunityScheduledRidesSection(communityID: manager.communityID, embedded: true)

                    if !manager.activeRiders.isEmpty {
                        PRWebDivider(inset: 0)

                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                HStack(spacing: 6) {
                                    Circle().fill(Color(red: 0.180, green: 0.620, blue: 0.357)).frame(width: 8, height: 8)
                                    Text("Riding Now").font(.system(size: 15, weight: .semibold)).foregroundColor(.prInk)
                                }
                                Spacer()
                                Text("\(manager.activeRiders.count) active")
                                    .font(.system(size: 13)).foregroundColor(Color(red: 0.180, green: 0.620, blue: 0.357))
                            }

                            ForEach(manager.activeRiders) { rider in ActiveRiderRow(rider: rider) }

                            Button(action: { showMap = true }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "map.fill")
                                    Text("View on Live Map")
                                }
                                .font(.system(size: 14, weight: .medium)).foregroundColor(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(Color.prCoral).cornerRadius(12)
                            }
                        }
                    }

                        PRWebDivider(inset: 0)

                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Members").font(.system(size: 15, weight: .bold)).foregroundColor(.prInk)
                            Spacer()
                            Text("\(manager.members.count + 1) total").font(.system(size: 13)).foregroundColor(.prMuted)
                        }

                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(Color.prCoral).frame(width: 44, height: 44)
                                Text(riderName.rideInitials)
                                    .font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(riderName).font(.system(size: 14, weight: .medium)).foregroundColor(.prInk)
                                    Text("(You)").font(.system(size: 12)).foregroundColor(.prMuted)
                                }
                                Text(manager.isCreator ? "Creator" : "Member")
                                    .font(.system(size: 12))
                                    .foregroundColor(manager.isCreator ? .prCoral : .prMuted)
                            }
                            Spacer()
                            Circle().fill(Color(red: 0.180, green: 0.620, blue: 0.357)).frame(width: 8, height: 8)
                        }
                        .padding(.vertical, 12)
                        .overlay(Rectangle().fill(Color.prBorder).frame(height: 1), alignment: .bottom)

                        ForEach(manager.members) { member in
                            MemberRow(member: member, needsHelp: memberNeedsHelp(member.id), profileManager: profileManager)
                        }

                        if manager.members.isEmpty {
                            HStack {
                                Spacer()
                                VStack(spacing: 8) {
                                    Image(systemName: "person.badge.plus").font(.system(size: 28)).foregroundColor(.prMuted)
                                    Text("No members yet — invite your riding friends!")
                                        .font(.system(size: 13)).foregroundColor(.prMuted)
                                        .multilineTextAlignment(.center)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 20)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 30)
                }
            }
        }
        .sheet(isPresented: $showMap) { CommunityMapView(members: manager.activeRiders) }
        .onAppear { helpManager.listenForActiveRequests() }
        .onDisappear { helpManager.stopListening() }
    }

    // Aug 22, 2026 — added the packride://joincommunity link, matching what
    // GroupRideView.shareCode() already does for group rides. Before this,
    // "Invite" only shared the ID + passcode as plain text the recipient had
    // to type into Join Community by hand — same trust model as sharing a
    // Wi-Fi password over text, but with none of the one-tap convenience a
    // group ride invite already had.
    private func shareCommunity() {
        let name = manager.myCommunity?.name ?? "my community"
        let passcode = manager.myCommunity?.passcode ?? ""
        PackRideShareCard.shareCommunity(
            name: name,
            id: manager.communityID,
            passcode: passcode,
            memberCount: manager.members.count + 1
        )
    }
}

// MARK: - Community Member Row
// Aug 21, 2026 — gained a Follow button. Previously there was no way to
// follow a community member at all, online or offline — community
// membership only ever stored a device ID, never the member's Firebase
// account ID, so there was nothing to hand the follow system even if a
// button existed. CommunityMember.authUID (see above) is the fix; this row
// just renders against it.
struct MemberRow: View {
    let member: CommunityMember
    let needsHelp: Bool
    @ObservedObject var profileManager: UserProfileManager
    @AppStorage("riderName") var riderName: String = "Rider"

    var followStatus: FollowStatus {
        profileManager.followStatus[member.authUID] ?? .notFollowing
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(needsHelp ? Color(red: 0.827, green: 0.231, blue: 0.173) : (member.isRiding ? Color.prCoralSoft : Color(red: 0.941, green: 0.925, blue: 0.898))).frame(width: 44, height: 44)
                Text(member.initials).font(.system(size: 13, weight: .bold)).foregroundColor(needsHelp ? .white : (member.isRiding ? .prCoral : .prMuted))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(member.name).font(.system(size: 14, weight: .medium)).foregroundColor(.prInk)
                if needsHelp {
                    NeedsHelpBadge()
                } else {
                    Text(member.isRiding ? "Riding now" : "Offline")
                        .font(.system(size: 12)).foregroundColor(member.isRiding ? .prCoral : .prMuted)
                }
            }
            Spacer()
            followButton
            Circle().fill(needsHelp ? Color(red: 0.827, green: 0.231, blue: 0.173) : (member.isRiding ? Color.prCoral : Color.prBorder)).frame(width: 8, height: 8)
        }
        .padding(.vertical, 12)
        .overlay(Rectangle().fill(Color.prBorder).frame(height: 1), alignment: .bottom)
        .onAppear {
            if !member.authUID.isEmpty { profileManager.checkFollowStatus(for: member.authUID) }
        }
    }

    @ViewBuilder
    private var followButton: some View {
        // A member record saved before this feature existed won't carry an
        // authUID until that rider next rides with location sharing on
        // (CommunityManager.updateRidingStatus stamps it) — no button shows
        // for those until then, rather than one that can't actually work.
        if !member.authUID.isEmpty {
            switch followStatus {
            case .isMe:
                EmptyView()
            case .notFollowing:
                Button(action: {
                    profileManager.sendFollowRequest(to: member.authUID, myName: riderName, myInitials: riderName.rideInitials)
                }) {
                    Text("Follow").font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color.prCoral).cornerRadius(10)
                }
            case .requested:
                Text("Sent").font(.system(size: 12, weight: .semibold)).foregroundColor(.prMuted)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color.prCoralSoft).cornerRadius(10)
            case .following:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundColor(Color(red: 0.180, green: 0.620, blue: 0.357))
            }
        }
    }
}

// MARK: - Active Rider Row
struct ActiveRiderRow: View {
    let rider: CommunityMember

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.prCoralSoft).frame(width: 44, height: 44)
                Text(rider.initials).font(.system(size: 13, weight: .bold)).foregroundColor(.prCoral)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(rider.name).font(.system(size: 14, weight: .medium)).foregroundColor(.prInk)
                Text(MeasurementUnits.speedMph(rider.speed)).font(.system(size: 12)).foregroundColor(.prMuted)
            }
            Spacer()
            HStack(spacing: 4) {
                Circle().fill(Color(red: 0.180, green: 0.620, blue: 0.357)).frame(width: 6, height: 6)
                Text("Live").font(.system(size: 11)).foregroundColor(Color(red: 0.180, green: 0.620, blue: 0.357))
            }
        }
        .padding(.vertical, 12)
        .overlay(Rectangle().fill(Color.prBorder).frame(height: 1), alignment: .bottom)
    }
}

// MARK: - Community Map View
struct CommunityMapView: View {
    let members: [CommunityMember]
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            ZStack {
                Color.prBg.ignoresSafeArea()

                if members.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "map").font(.system(size: 44)).foregroundColor(.prMuted)
                        Text("No active riders right now").font(.system(size: 15)).foregroundColor(.prMuted)
                    }
                } else {
                    MapView()
                }
            }
            .navigationTitle("Community Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.foregroundColor(.prCoral)
                }
            }
        }
    }
}

// MARK: - Create Community View
struct CreateCommunityView: View {
    @ObservedObject var membershipStore: CommunityMembershipStore
    @Environment(\.dismiss) var dismiss

    @State private var communityName = ""
    @State private var passcode = ""
    @State private var showError = false

    var body: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Button("Cancel") { dismiss() }.foregroundColor(.prMuted)
                    Spacer()
                    Text("Create Community").font(.system(size: 16, weight: .semibold)).foregroundColor(.prInk)
                    Spacer()
                    Button("Create") {
                        guard !communityName.isEmpty && !passcode.isEmpty else { showError = true; return }
                        membershipStore.createCommunity(name: communityName, passcode: passcode) { success in
                            if success { dismiss() }
                        }
                    }
                    .foregroundColor(communityName.isEmpty || passcode.isEmpty ? .prMuted : .prCoral)
                    .disabled(communityName.isEmpty || passcode.isEmpty)
                }
                .padding(16)

                ScrollView {
                    VStack(spacing: 20) {
                        ZStack {
                            Circle().fill(Color.prCoralSoft).frame(width: 80, height: 80)
                            Image(systemName: "person.3.fill").font(.system(size: 34)).foregroundColor(.prCoral)
                        }
                        .padding(.top, 20)

                        VStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Community Name").font(.system(size: 13)).foregroundColor(.prMuted)
                                TextField("", text: $communityName, prompt: Text("e.g. Tampa Bay Riders").foregroundColor(.prMuted))
                                    .foregroundColor(.prInk)
                                    .padding(14).background(Color.prCardBg).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.prBorder, lineWidth: 1)).cornerRadius(12)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Passcode").font(.system(size: 13)).foregroundColor(.prMuted)
                                TextField("", text: $passcode, prompt: Text("e.g. RIDE2024").foregroundColor(.prMuted))
                                    .foregroundColor(.prInk)
                                    .autocapitalization(.allCharacters)
                                    .padding(14).background(Color.prCardBg).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.prBorder, lineWidth: 1)).cornerRadius(12)
                                Text("Share this passcode with riders you want to invite.")
                                    .font(.system(size: 12)).foregroundColor(.prMuted)
                            }
                        }
                        .padding(.horizontal, 20)

                        VStack(alignment: .leading, spacing: 14) {
                            CommunityFeatureRow(icon: "eye.fill", color: .prCoral, text: "Members can see each other during solo rides")
                            CommunityFeatureRow(icon: "shield.fill", color: Color(red: 0.180, green: 0.620, blue: 0.357), text: "Crash alerts go to all community members")
                            CommunityFeatureRow(icon: "lock.fill", color: .prTeal, text: "Private — passcode required to join")
                        }
                        .padding(16)
                        .background(Color.prCardBg)
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.prBorder, lineWidth: 1))
                        .cornerRadius(16)
                        .padding(.horizontal, 20)

                        if membershipStore.isLoading { ProgressView().tint(.prCoral) }

                        if showError || !membershipStore.errorMessage.isEmpty {
                            Text(membershipStore.errorMessage.isEmpty ? "Please fill in all fields" : membershipStore.errorMessage)
                                .font(.system(size: 13)).foregroundColor(Color(red: 0.827, green: 0.231, blue: 0.173))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Join Community View
struct JoinCommunityView: View {
    @ObservedObject var membershipStore: CommunityMembershipStore
    @Environment(\.dismiss) var dismiss

    @State private var communityID: String
    @State private var passcode: String
    @State private var showError = false
    @State private var isJoining = false

    // Aug 22, 2026 — prefilledID/prefilledPasscode come from a tapped
    // packride://joincommunity link (see CommunityListView.onAppear). Seeds
    // the fields but still requires the person to tap Join themselves — same
    // "prefill, don't auto-submit" choice GroupRideView makes for its own
    // join link.
    init(membershipStore: CommunityMembershipStore, prefilledID: String = "", prefilledPasscode: String = "") {
        self.membershipStore = membershipStore
        _communityID = State(initialValue: prefilledID)
        _passcode = State(initialValue: prefilledPasscode)
    }

    var body: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Button("Cancel") { dismiss() }.foregroundColor(.prMuted)
                    Spacer()
                    Text("Join Community").font(.system(size: 16, weight: .semibold)).foregroundColor(.prInk)
                    Spacer()
                    Button("Join") { joinCommunity() }
                        .foregroundColor(communityID.isEmpty || passcode.isEmpty ? .prMuted : .prCoral)
                        .disabled(communityID.isEmpty || passcode.isEmpty)
                }
                .padding(16)

                ScrollView {
                    VStack(spacing: 20) {
                        ZStack {
                            Circle().fill(Color.prCoralSoft).frame(width: 80, height: 80)
                            Image(systemName: "person.badge.plus").font(.system(size: 34)).foregroundColor(.prCoral)
                        }
                        .padding(.top, 20)

                        Text("Ask your ride leader for the\nCommunity ID and Passcode")
                            .font(.system(size: 14)).foregroundColor(.prMuted)
                            .multilineTextAlignment(.center)

                        VStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Community ID").font(.system(size: 13)).foregroundColor(.prMuted)
                                TextField("", text: $communityID, prompt: Text("Enter community ID").foregroundColor(.prMuted))
                                    .foregroundColor(.prInk)
                                    .autocapitalization(.allCharacters)
                                    .padding(14).background(Color.prCardBg).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.prBorder, lineWidth: 1)).cornerRadius(12)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Passcode").font(.system(size: 13)).foregroundColor(.prMuted)
                                TextField("", text: $passcode, prompt: Text("Enter passcode").foregroundColor(.prMuted))
                                    .foregroundColor(.prInk)
                                    .autocapitalization(.allCharacters)
                                    .padding(14).background(Color.prCardBg).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.prBorder, lineWidth: 1)).cornerRadius(12)
                            }
                        }
                        .padding(.horizontal, 20)

                        if isJoining { ProgressView().tint(.prCoral) }

                        if showError || !membershipStore.errorMessage.isEmpty {
                            Text(membershipStore.errorMessage.isEmpty ? "Please fill in all fields" : membershipStore.errorMessage)
                                .font(.system(size: 13)).foregroundColor(Color(red: 0.827, green: 0.231, blue: 0.173))
                        }
                    }
                }
            }
        }
    }

    func joinCommunity() {
        guard !communityID.isEmpty && !passcode.isEmpty else { showError = true; return }
        isJoining = true
        membershipStore.joinCommunity(id: communityID, passcode: passcode) { success in
            isJoining = false
            if success { dismiss() }
        }
    }
}

// MARK: - Community Feature Row
struct CommunityFeatureRow: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(color.opacity(0.15)).frame(width: 36, height: 36)
                Image(systemName: icon).font(.system(size: 15)).foregroundColor(color)
            }
            Text(text).font(.system(size: 14)).foregroundColor(.prInk).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    NavigationView { CommunityListView() }
        .environmentObject(CommunityMembershipStore())
        .environmentObject(DeepLinkRouter())
}
