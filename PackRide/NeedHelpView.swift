import SwiftUI
import MapKit
import CoreLocation
import FirebaseDatabase
import FirebaseAuth
import UIKit
import Combine

// MARK: - Help Request Model
// A rider can have at most one active request (keyed by their own ID, not an
// auto-ID) — starting a new one just overwrites the old one, which is the
// right behavior since only the latest share should ever be "live."
//
// Two IDs are carried because the app uses two different identity schemes in
// different places: the Firebase-UID-preferring scheme (Auth uid, falling
// back to device ID) used by follow/Feed, and the plain device-ID scheme
// used by Community and Group Ride membership. Carrying both means whichever
// screen is checking "does this person I can see have an active request"
// can match against whichever ID it already has on hand, without needing an
// app-wide ID scheme unification.
struct HelpRequest: Identifiable {
    let id: String                  // == requesterUID, and the Firebase node key
    let requesterUID: String
    let requesterDeviceID: String
    let requesterName: String
    let requesterInitials: String
    let latitude: Double
    let longitude: Double
    let startedAt: TimeInterval
    let lastUpdated: TimeInterval
    let targetType: String          // "friend" | "community" | "group"
    let targetID: String
    let targetName: String

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    // If the app got killed/crashed without tapping "Stop Sharing," the node
    // would otherwise sit there looking "active" forever to anyone viewing
    // it — anything not updated in the last 20 minutes is treated as stale
    // and hidden rather than shown as a live request.
    var isStale: Bool { Date().timeIntervalSince1970 - lastUpdated > 20 * 60 }
}

// MARK: - Help Request Manager
// One instance handles both sides: the rider asking for help (start /
// updateLocation / stop) and anyone checking whether someone they can see
// currently has an active request (listenForActiveRequests + local
// filtering per screen — Map/FriendsMap/Community each filter the same
// small shared list rather than running separate queries).
class HelpRequestManager: ObservableObject {
    private let db = Database.database().reference()
    @Published var activeRequests: [HelpRequest] = []
    @Published var isSharing = false
    // Published (not local view @State) so reopening NeedHelpView mid-share —
    // e.g. tapping the "Sharing Location" pill on the Map screen — shows the
    // right label immediately instead of a blank one from a freshly created view.
    @Published private(set) var sharingWithLabel = ""

    private var listenerRef: DatabaseReference?
    private var listenerHandle: DatabaseHandle?
    private var lastSentLocation: CLLocation?
    private var lastSentDate: Date?
    // Keeps location updates flowing to the active request for as long as
    // `isSharing` is true, regardless of whether NeedHelpView itself is still
    // on screen — see beginLocationUpdates() below.
    private var locationCancellable: AnyCancellable?

    var myID: String { Auth.auth().currentUser?.uid ?? UIDevice.current.identifierForVendor?.uuidString ?? "" }
    private var myDeviceID: String { UIDevice.current.identifierForVendor?.uuidString ?? "" }

    deinit { stopListening() }

    // MARK: - Requester side
    func start(targetType: String, targetID: String, targetName: String,
               requesterName: String, requesterInitials: String, coordinate: CLLocationCoordinate2D,
               completion: @escaping (String?) -> Void = { _ in }) {
        guard !myID.isEmpty else { completion("Not signed in — try logging out and back in."); return }
        let now = Date().timeIntervalSince1970
        let data: [String: Any] = [
            "requesterUID": myID,
            "requesterDeviceID": myDeviceID,
            "requesterName": requesterName,
            "requesterInitials": requesterInitials,
            "latitude": coordinate.latitude, "longitude": coordinate.longitude,
            "startedAt": now, "lastUpdated": now,
            "targetType": targetType, "targetID": targetID, "targetName": targetName
        ]
        db.child("helpRequests").child(myID).setValue(data) { [weak self] error, _ in
            DispatchQueue.main.async {
                if error == nil {
                    self?.isSharing = true
                    self?.sharingWithLabel = targetName
                    self?.beginLocationUpdates()
                }
                completion(error?.localizedDescription)
            }
        }
    }

    // Started once, right when sharing begins, and kept alive on this manager
    // itself (not on whatever view happens to be showing) — a Combine
    // subscription directly against the location singleton, so the share
    // keeps updating even if the rider backs out of the Need Help screen to
    // go look at the map, exactly like a real "share my location" would.
    private func beginLocationUpdates() {
        SharedLocationManager.shared.requestBackgroundUpdates(reason: "needHelp")
        locationCancellable = SharedLocationManager.shared.$location
            .compactMap { $0 }
            .sink { [weak self] loc in self?.updateLocation(loc.coordinate) }
    }

    func updateLocation(_ coordinate: CLLocationCoordinate2D) {
        guard isSharing, !myID.isEmpty else { return }
        let newLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        // Same throttle style used for group-ride location updates elsewhere
        // in the app — no need to write on every single GPS fix.
        if let lastSentLocation, let lastSentDate,
           Date().timeIntervalSince(lastSentDate) < 5, newLoc.distance(from: lastSentLocation) < 25 {
            return
        }
        lastSentLocation = newLoc
        lastSentDate = Date()
        db.child("helpRequests").child(myID).updateChildValues([
            "latitude": coordinate.latitude, "longitude": coordinate.longitude,
            "lastUpdated": Date().timeIntervalSince1970
        ])
    }

    func stop() {
        guard !myID.isEmpty else { return }
        db.child("helpRequests").child(myID).removeValue()
        isSharing = false
        lastSentLocation = nil
        lastSentDate = nil
        sharingWithLabel = ""
        locationCancellable?.cancel(); locationCancellable = nil
        SharedLocationManager.shared.releaseBackgroundUpdates(reason: "needHelp")
    }

    // MARK: - Recipient side
    func listenForActiveRequests() {
        stopListening()
        guard !myID.isEmpty else { return }
        let ref = db.child("users").child(myID).child("helpAlerts")
        listenerRef = ref
        listenerHandle = ref.observe(.value) { [weak self] snapshot in
            var loaded: [HelpRequest] = []
            for child in snapshot.children {
                guard let snap = child as? DataSnapshot,
                      let data = snap.value as? [String: Any],
                      let requesterUID = data["requesterUID"] as? String,
                      let requesterDeviceID = data["requesterDeviceID"] as? String,
                      let requesterName = data["requesterName"] as? String,
                      let requesterInitials = data["requesterInitials"] as? String,
                      let lat = data["latitude"] as? Double,
                      let lng = data["longitude"] as? Double,
                      let startedAt = data["startedAt"] as? TimeInterval,
                      let lastUpdated = data["lastUpdated"] as? TimeInterval,
                      let targetType = data["targetType"] as? String,
                      let targetID = data["targetID"] as? String,
                      let targetName = data["targetName"] as? String
                else { continue }
                loaded.append(HelpRequest(
                    id: snap.key, requesterUID: requesterUID, requesterDeviceID: requesterDeviceID,
                    requesterName: requesterName, requesterInitials: requesterInitials,
                    latitude: lat, longitude: lng, startedAt: startedAt, lastUpdated: lastUpdated,
                    targetType: targetType, targetID: targetID, targetName: targetName
                ))
            }
            DispatchQueue.main.async { self?.activeRequests = loaded.filter { !$0.isStale } }
        }
    }

    func stopListening() {
        if let listenerHandle { listenerRef?.removeObserver(withHandle: listenerHandle) }
        listenerHandle = nil
        listenerRef = nil
    }
}

// MARK: - Need Help View
// Replaces the old "I Need Assistance" alert (Map tab), which only offered
// "alert my whole group" or "alert my whole community" and — since nothing
// anywhere in the app ever listened for those alerts — didn't actually
// reach anyone either way. This shows your live location on a map and lets
// you pick exactly who to share it with: a specific friend, your community,
// or your active group ride if you're in one. The location keeps updating
// until you tap Stop Sharing.
struct NeedHelpView: View {
    @AppStorage("riderName") var riderName: String = "Rider"
    @AppStorage("activeRideCode") var activeRideCode: String = ""
    @Environment(\.dismiss) var dismiss

    // App-wide singletons (see PackRideApp.swift), not owned locally —
    // sharing needs to keep running (and keep sending location updates) even
    // after this screen is dismissed, so the manager can't be tied to this
    // view's own lifecycle. communityStore is read-only here (which
    // communities to offer as share targets — see Aug 21, 2026 multi-community
    // support in CommunityView.swift).
    @EnvironmentObject private var helpManager: HelpRequestManager
    @EnvironmentObject private var communityStore: CommunityMembershipStore
    @ObservedObject private var locationManager = SharedLocationManager.shared
    // Aug 27, 2026 — Grok re-review, small cleanup: was its own private
    // UserProfileManager(), the same bug as helpManager/communityStore above
    // used to be before they were made shared — now the app-wide instance.
    @EnvironmentObject private var profileManager: UserProfileManager

    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.33, longitude: -122.03),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
    ))
    @State private var showFriendPicker = false
    @State private var startError: String? = nil
    @State private var pinPulse = false
    // Aug 27, 2026 — .userLocation(fallback:) only actually recenters the
    // map once MapKit itself decides to track the user, which in practice
    // often doesn't happen until the person touches/drags the map — so this
    // screen opened centered on the fallback coordinate with no blue dot
    // until you interacted with it. Explicitly recentering the moment a
    // location fix is available (immediately if one's already cached, via
    // onChange the first time one arrives otherwise) makes it auto-detect
    // for real instead of waiting on a gesture. Only fires once so it never
    // fights a ride you've since panned/zoomed away yourself.
    @State private var hasCenteredOnUser = false

    var myInitials: String { riderName.rideInitials }

    var body: some View {
        ZStack {
            Map(position: $cameraPosition) {
                UserAnnotation()
                if helpManager.isSharing, let loc = locationManager.location {
                    Annotation("You", coordinate: loc.coordinate) {
                        ZStack {
                            Circle()
                                .stroke(Color(red: 0.827, green: 0.231, blue: 0.173).opacity(0.5), lineWidth: 3)
                                .frame(width: pinPulse ? 58 : 34, height: pinPulse ? 58 : 34)
                                .opacity(pinPulse ? 0 : 0.9)
                            Circle()
                                .fill(Color(red: 0.827, green: 0.231, blue: 0.173))
                                .frame(width: 34, height: 34)
                                .overlay(Circle().stroke(Color.white, lineWidth: 3))
                            Image(systemName: "exclamationmark").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                        }
                        .onAppear {
                            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pinPulse = true }
                        }
                    }
                }
            }
            .mapStyle(.hybrid(elevation: .realistic, showsTraffic: true))
            .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                bottomCard
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            // "needHelpScreen" is deliberately a different reason than the
            // "needHelp" background-tracking one requestBackgroundUpdates
            // uses in beginLocationUpdates() below — this just keeps this
            // screen's own "You" pin live while it's open, and releasing it
            // on dismiss must never touch the separate background share.
            locationManager.startUpdating(reason: "needHelpScreen")
            profileManager.listenForFollowedUsers()
            // A location fix from an earlier screen this session is often
            // already cached — center on it immediately rather than waiting
            // for onChange below to ever fire.
            if let loc = locationManager.location {
                hasCenteredOnUser = true
                cameraPosition = .region(MKCoordinateRegion(
                    center: loc.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                ))
            }
        }
        .onChange(of: locationManager.location) { _, loc in
            guard !hasCenteredOnUser, let loc else { return }
            hasCenteredOnUser = true
            withAnimation {
                cameraPosition = .region(MKCoordinateRegion(
                    center: loc.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                ))
            }
        }
        .onDisappear {
            // Deliberately does NOT stop an active share on dismiss — closing
            // this screen (X button, swipe back) is how you return to the map
            // while still sharing, not how you cancel. The manager keeps
            // pushing location updates on its own; "Stop Sharing" below (or
            // reopening this screen and tapping it) is the only way to end it.
            locationManager.stopUpdating(reason: "needHelpScreen")
            profileManager.stopListeningForFollowedUsers()
        }
        .sheet(isPresented: $showFriendPicker) {
            FriendPickerSheet(friends: profileManager.followedUsers) { friend in
                startSharing(targetType: "friend", targetID: friend.id, targetName: friend.name)
            }
        }
        .alert("Couldn't Start Sharing", isPresented: Binding(
            get: { startError != nil }, set: { if !$0 { startError = nil } }
        )) {
            Button("OK", role: .cancel) { startError = nil }
        } message: {
            Text(startError ?? "")
        }
    }

    // MARK: - Top Bar
    private var topBar: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundColor(.prInk)
                    .frame(width: 40, height: 40).background(.ultraThinMaterial).clipShape(Circle())
            }
            Spacer()
            Text("Need Help").font(.system(size: 14, weight: .bold)).foregroundColor(.prInk)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial).clipShape(Capsule())
            Spacer()
            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    // MARK: - Bottom Card
    private var bottomCard: some View {
        VStack(spacing: 16) {
            if helpManager.isSharing {
                VStack(spacing: 14) {
                    HStack(spacing: 8) {
                        Circle().fill(Color(red: 0.827, green: 0.231, blue: 0.173)).frame(width: 9, height: 9)
                        Text("Sharing your live location").font(.system(size: 14, weight: .bold)).foregroundColor(.prInk)
                    }
                    Text("with \(helpManager.sharingWithLabel) — updates automatically until you stop")
                        .font(.system(size: 12)).foregroundColor(.prMuted)
                        .multilineTextAlignment(.center)

                    Button(action: { helpManager.stop() }) {
                        Text("Stop Sharing").font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(Color(red: 0.827, green: 0.231, blue: 0.173)).cornerRadius(16)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Do you need assistance or help?").font(.system(size: 16, weight: .bold)).foregroundColor(.prInk)
                    Text("Share your live location — it keeps updating until you stop it.")
                        .font(.system(size: 12)).foregroundColor(.prMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 10) {
                    Button(action: { showFriendPicker = true }) {
                        shareRow(icon: "person.fill", label: "Share with a Friend")
                    }
                    .disabled(profileManager.followedUsers.isEmpty)

                    ForEach(communityStore.myCommunities) { community in
                        Button(action: {
                            startSharing(targetType: "community", targetID: community.id, targetName: community.name)
                        }) {
                            shareRow(icon: "flame.fill", label: "Share with \(community.name)")
                        }
                    }

                    if !activeRideCode.isEmpty {
                        Button(action: {
                            startSharing(targetType: "group", targetID: activeRideCode, targetName: "your Group Ride")
                        }) {
                            shareRow(icon: "person.3.fill", label: "Share with Group Ride")
                        }
                    }
                }

                if profileManager.followedUsers.isEmpty && communityStore.myCommunities.isEmpty && activeRideCode.isEmpty {
                    Text("You're not following anyone, in a community, or in a group ride yet — follow a friend or join one from the Community tab so there's someone to alert.")
                        .font(.system(size: 11)).foregroundColor(.prMuted)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(20)
        .background(Color.prBg)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color.prBorder, lineWidth: 1))
        .padding(.horizontal, 16).padding(.bottom, 20)
    }

    private func shareRow(icon: String, label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 14))
            Text(label).font(.system(size: 14, weight: .semibold))
            Spacer()
            Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold))
        }
        .foregroundColor(.white)
        .padding(.vertical, 14).padding(.horizontal, 16)
        .background(Color.prCoral)
        .cornerRadius(14)
    }

    private func startSharing(targetType: String, targetID: String, targetName: String) {
        guard let loc = locationManager.location else {
            startError = "Waiting for your GPS location — try again in a moment."
            return
        }
        helpManager.start(
            targetType: targetType, targetID: targetID, targetName: targetName,
            requesterName: riderName, requesterInitials: myInitials, coordinate: loc.coordinate
        ) { error in
            if let error {
                startError = error
            }
        }
    }
}

// MARK: - Friend Picker Sheet
struct FriendPickerSheet: View {
    let friends: [RiderProfile]
    let onPick: (RiderProfile) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if friends.isEmpty {
                    ContentUnavailableView(
                        "No Friends Available",
                        systemImage: "person.2.slash",
                        description: Text("Follow a rider first, then return here to share this session with them.")
                    )
                } else {
                    List(friends) { friend in
                        Button(action: {
                            onPick(friend)
                            dismiss()
                        }) {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle().fill(Color.prCoral).frame(width: 36, height: 36)
                                    Text(friend.initials).font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                                }
                                Text(friend.name).font(.system(size: 14, weight: .semibold)).foregroundColor(.prInk)
                                Spacer()
                            }
                        }
                        .listRowBackground(Color.prCardBg)
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.prBg)
            .navigationTitle("Share With a Friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

// MARK: - Incoming Help Alerts (recipient side — someone shared WITH you)
// Aug 22, 2026 — presented from ContentView's app-wide banner (see
// incomingHelpBanner there). Shows every currently-relevant request at once
// rather than one at a time, since more than one person could plausibly be
// sharing with the same community/group simultaneously.
struct IncomingHelpAlertsView: View {
    let requests: [HelpRequest]
    @Environment(\.dismiss) var dismiss
    @State private var selected: HelpRequest?
    @State private var cameraPosition: MapCameraPosition

    init(requests: [HelpRequest]) {
        self.requests = requests
        let first = requests.first
        _selected = State(initialValue: first)
        _cameraPosition = State(initialValue: .region(MKCoordinateRegion(
            center: first?.coordinate ?? CLLocationCoordinate2D(latitude: 37.33, longitude: -122.03),
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        )))
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                requestsMap

                if let selected {
                    selectedCard(selected)
                }
            }
            .navigationTitle("Need Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    // MARK: - Map
    private var requestsMap: some View {
        Map(position: $cameraPosition) {
            ForEach(requests) { request in
                Annotation(request.requesterName, coordinate: request.coordinate) {
                    Button(action: { withAnimation { selected = request } }) {
                        ZStack {
                            Circle().fill(Color(red: 0.827, green: 0.231, blue: 0.173))
                                .frame(width: 34, height: 34)
                                .overlay(Circle().stroke(Color.white, lineWidth: 3))
                            Text(request.requesterInitials)
                                .font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                        }
                    }
                }
            }
        }
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - Selected Request Card
    private func selectedCard(_ selected: HelpRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color(red: 0.827, green: 0.231, blue: 0.173)).frame(width: 40, height: 40)
                    Text(selected.requesterInitials).font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(selected.requesterName).font(.system(size: 15, weight: .bold)).foregroundColor(.prInk)
                    Text(contextLine(selected)).font(.system(size: 12)).foregroundColor(.prMuted)
                }
                Spacer()
            }

            Button(action: { openDirections(to: selected) }) {
                HStack(spacing: 8) {
                    Image(systemName: "location.fill").font(.system(size: 13))
                    Text("Get Directions").font(.system(size: 14, weight: .bold))
                }
                .foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(Color(red: 0.827, green: 0.231, blue: 0.173)).cornerRadius(14)
            }

            if requests.count > 1 {
                chipRow(selected: selected)
            }
        }
        .padding(16)
        .background(Color.prBg)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.prBorder, lineWidth: 1))
        .padding(.horizontal, 16).padding(.bottom, 16)
    }

    private func chipRow(selected: HelpRequest) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(requests) { request in
                    Button(action: { focus(on: request) }) {
                        HelpAlertChip(name: request.requesterName, isSelected: request.id == selected.id)
                    }
                }
            }
        }
    }

    private func contextLine(_ request: HelpRequest) -> String {
        switch request.targetType {
        case "friend": return "Shared their location with you"
        case "community": return "Shared with \(request.targetName)"
        case "group": return "Shared with \(request.targetName)"
        default: return "Needs help"
        }
    }

    private func focus(on request: HelpRequest) {
        withAnimation {
            selected = request
            cameraPosition = .region(MKCoordinateRegion(
                center: request.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            ))
        }
    }

    private func openDirections(to request: HelpRequest) {
        // Aug 28, 2026 — MKMapItem(location:address:) is iOS 26+ only; the
        // MKPlacemark-based initializer works on every MapKit version.
        let item = MKMapItem(placemark: MKPlacemark(coordinate: request.coordinate))
        item.name = request.requesterName
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }
}

// MARK: - Help Alert Chip
// Extracted out of IncomingHelpAlertsView's ForEach — the compiler couldn't
// type-check that chip's several ternaries (foreground/background/border
// all keyed off the same "is this the selected request" check) chained
// directly inline within a ForEach/Button/ScrollView nest ("unable to
// type-check this expression in reasonable time"). A dedicated small view
// with the condition computed once above it, same fix as HistoryFilterBar's
// `isSelected` in RideHistoryView.swift, resolves it.
struct HelpAlertChip: View {
    let name: String
    let isSelected: Bool

    var body: some View {
        Text(name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(isSelected ? .white : .prInk)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(isSelected ? Color(red: 0.827, green: 0.231, blue: 0.173) : Color.prCardBg)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.prBorder, lineWidth: isSelected ? 0 : 1))
    }
}

// MARK: - Needs Help Badge (small reusable pill, used on pins/rows across the app)
struct NeedsHelpBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
            Text("NEEDS HELP").font(.system(size: 9, weight: .heavy)).tracking(0.5)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color(red: 0.827, green: 0.231, blue: 0.173))
        .clipShape(Capsule())
    }
}
