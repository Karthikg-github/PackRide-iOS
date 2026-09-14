import SwiftUI
import MapKit
import CoreLocation
import Combine
import FirebaseDatabase

// MARK: - Waypoint Model
struct Waypoint: Identifiable, Codable {
    let id: String
    var name: String
    var type: WaypointType
    var latitude: Double
    var longitude: Double
    var note: String
    var isCompleted: Bool
    var address: String
    var isDestination: Bool = false
    // Aug 28, 2026 — marks the one entry (if any) that's a rider-picked
    // starting point override rather than a real stop/destination. Kept in
    // the same waypoints array (instead of a separate local-only field) so
    // it rides along the existing WaypointsManager.saveWaypoints()/
    // GroupWaypointSync publish-and-listen pipeline — the whole group sees
    // the leader's actual planned starting point, not each viewer's own
    // current location. Always kept at index 0 by WaypointsManager.setStart.
    var isStartOverride: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, name, type, latitude, longitude, note, isCompleted, address, isDestination, isStartOverride
    }

    init(id: String, name: String, type: WaypointType, latitude: Double, longitude: Double,
         note: String, isCompleted: Bool, address: String, isDestination: Bool = false, isStartOverride: Bool = false) {
        self.id = id
        self.name = name
        self.type = type
        self.latitude = latitude
        self.longitude = longitude
        self.note = note
        self.isCompleted = isCompleted
        self.address = address
        self.isDestination = isDestination
        self.isStartOverride = isStartOverride
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(WaypointType.self, forKey: .type)
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        note = try c.decode(String.self, forKey: .note)
        isCompleted = try c.decode(Bool.self, forKey: .isCompleted)
        address = try c.decode(String.self, forKey: .address)
        isDestination = try c.decodeIfPresent(Bool.self, forKey: .isDestination) ?? false
        isStartOverride = try c.decodeIfPresent(Bool.self, forKey: .isStartOverride) ?? false
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    enum WaypointType: String, Codable, CaseIterable {
        case fuel, food, scenic, rest, meetup

        var icon: String {
            switch self {
            case .fuel: return "fuelpump.fill"
            case .food: return "fork.knife"
            case .scenic: return "camera.fill"
            case .rest: return "bed.double.fill"
            case .meetup: return "person.3.fill"
            }
        }

        var label: String {
            switch self {
            case .fuel: return "Fuel Stop"
            case .food: return "Food Break"
            case .scenic: return "Scenic Spot"
            case .rest: return "Rest Stop"
            case .meetup: return "Meet Up"
            }
        }

        var color: Color {
            switch self {
            case .fuel: return .prCoral
            case .food: return Color(red: 0.180, green: 0.620, blue: 0.357)
            case .scenic: return .prTeal
            case .rest: return Color(red: 0.541, green: 0.4, blue: 0.694)
            case .meetup: return .prInk
            }
        }

        var searchQuery: String {
            switch self {
            case .fuel: return "gas station"
            case .food: return "restaurant"
            case .scenic: return "scenic viewpoint"
            case .rest: return "rest stop"
            case .meetup: return "parking"
            }
        }
    }
}

// MARK: - Waypoints Manager
class WaypointsManager: ObservableObject {
    @Published var waypoints: [Waypoint] = []
    var rideCode: String = ""

    var storageKey: String {
        rideCode.isEmpty ? "waypoints_solo" : "waypoints_\(rideCode)"
    }

    init(rideCode: String = "") {
        self.rideCode = rideCode
        loadWaypoints()
    }

    // Intermediate stops, in route order (destination and any start
    // override excluded).
    var stops: [Waypoint] { waypoints.filter { !$0.isDestination && !$0.isStartOverride } }

    // The final destination, if one has been set.
    var destination: Waypoint? { waypoints.first(where: { $0.isDestination }) }

    // Aug 28, 2026 — the rider-picked starting point, if one has been set
    // (nil means "use my current location," the default). Computed over
    // waypoints (kept at index 0 by setStart below) rather than a separate
    // stored/synced field — see Waypoint.isStartOverride for why.
    var startOverride: Waypoint? { waypoints.first(where: { $0.isStartOverride }) }

    // stops + destination, in route order — what actually gets drawn as
    // numbered pins on the map. Excludes the start override, which the map
    // renders separately (see RouteMapView's own startOverride param) so
    // it isn't double-counted as both "the start" and stop "1".
    var routeableWaypoints: [Waypoint] { waypoints.filter { !$0.isStartOverride } }

    func addStop(name: String, address: String, type: Waypoint.WaypointType, coordinate: CLLocationCoordinate2D) {
        let wp = Waypoint(id: UUID().uuidString, name: name, type: type,
                           latitude: coordinate.latitude, longitude: coordinate.longitude,
                           note: "", isCompleted: false, address: address, isDestination: false)
        if let destIndex = waypoints.firstIndex(where: { $0.isDestination }) {
            waypoints.insert(wp, at: destIndex)
        } else {
            waypoints.append(wp)
        }
        saveWaypoints()
    }

    // Aug 28, 2026 — "start": an explicit override of the default "my
    // current location" starting point. Kept IN waypoints (always at index
    // 0) rather than separately, so it publishes through the same
    // saveWaypoints()/GroupWaypointSync pipeline as stops/destination —
    // the whole group sees the leader's actual chosen starting point, and
    // Navigate's route (current location → waypoints in order →
    // destination, see TurnByTurnView) picks it up as the first leg for
    // free, with no separate wiring needed.
    func setStart(name: String, address: String, coordinate: CLLocationCoordinate2D) {
        waypoints.removeAll { $0.isStartOverride }
        let wp = Waypoint(id: UUID().uuidString, name: name, type: .meetup,
                           latitude: coordinate.latitude, longitude: coordinate.longitude,
                           note: "", isCompleted: false, address: address, isStartOverride: true)
        waypoints.insert(wp, at: 0)
        saveWaypoints()
    }

    func clearStart() {
        waypoints.removeAll { $0.isStartOverride }
        saveWaypoints()
    }

    func setDestination(name: String, address: String, coordinate: CLLocationCoordinate2D) {
        waypoints.removeAll { $0.isDestination }
        let wp = Waypoint(id: UUID().uuidString, name: name, type: .meetup,
                           latitude: coordinate.latitude, longitude: coordinate.longitude,
                           note: "", isCompleted: false, address: address, isDestination: true)
        waypoints.append(wp)
        saveWaypoints()
    }

    func clearDestination() {
        waypoints.removeAll { $0.isDestination }
        saveWaypoints()
    }

    func moveStop(from source: IndexSet, to destinationIndex: Int) {
        var reordered = stops
        reordered.move(fromOffsets: source, toOffset: destinationIndex)
        // Aug 28, 2026 — preserve the start override (if any) at the front;
        // this used to drop it entirely on any stop reorder.
        waypoints = (startOverride.map { [$0] } ?? []) + reordered + (destination.map { [$0] } ?? [])
        saveWaypoints()
    }

    func removeWaypoint(id: String) {
        waypoints.removeAll { $0.id == id }
        saveWaypoints()
    }

    func addWaypoint(_ waypoint: Waypoint) {
        if waypoint.isDestination {
            waypoints.removeAll { $0.isDestination }
            waypoints.append(waypoint)
        } else if let destIndex = waypoints.firstIndex(where: { $0.isDestination }) {
            waypoints.insert(waypoint, at: destIndex)
        } else {
            waypoints.append(waypoint)
        }
        saveWaypoints()
    }

    func toggleCompleted(_ waypoint: Waypoint) {
        if let index = waypoints.firstIndex(where: { $0.id == waypoint.id }) {
            waypoints[index].isCompleted.toggle()
            saveWaypoints()
        }
    }

    func saveWaypoints() {
        if let encoded = try? JSONEncoder().encode(waypoints) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
        // Aug 22, 2026 — bug #9: waypoints used to only ever exist in
        // UserDefaults on whichever phone set them. Fine for a solo ride,
        // but for a group ride that meant only the LEADER's own device ever
        // knew the plan — every participant's copy of this same key was
        // always empty, so they could never see or navigate to a single
        // stop the leader had set. This is a no-op for solo rides (rideCode
        // empty — see GroupWaypointSync.publish's own guard).
        GroupWaypointSync.publish(rideCode: rideCode, waypoints: waypoints)
    }

    func loadWaypoints() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([Waypoint].self, from: data) {
            waypoints = decoded
        }
    }

    func switchRideCode(_ newCode: String) {
        rideCode = newCode
        waypoints = []
        loadWaypoints()
    }

    /// Fully resets for a brand-new solo planning session — clears in-memory
    /// waypoints AND wipes the persisted "waypoints_solo" entry, so the next
    /// switchRideCode("")/loadWaypoints() doesn't silently resurrect the old route.
    func clearWaypoints() {
        rideCode = ""
        waypoints = []
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    var completedCount: Int {
        waypoints.filter { $0.isCompleted }.count
    }
}

// MARK: - Group Waypoint Sync (bug #9)
// Mirrors a group ride's waypoints to Firebase so every rider's phone can
// see — and navigate to — the same plan, not just the leader's own device
// (see the comment on WaypointsManager.saveWaypoints() above for why this
// was needed). Deliberately separate from WaypointsManager's local-storage
// logic rather than folded into it: WaypointsManager stays the leader's
// own editable copy (used by WaypointsView's editing UI, unaffected by this
// change), while this is the one-way mirror everyone else's MapView and
// GroupRideView read from.
enum GroupWaypointSync {
    private static var db: DatabaseReference { Database.database().reference() }

    // Stored as one opaque JSON-encoded STRING rather than a native
    // RTDB array/object — Firebase's Realtime Database silently coerces a
    // written array into an object (with numeric-string keys) whenever
    // there's any gap or gets read back as an NSDictionary instead of an
    // NSArray depending on shape, which is exactly the kind of thing that
    // would intermittently corrupt waypoint ORDER (stops before the final
    // destination) for no obvious reason. A single string sidesteps that
    // ambiguity entirely — same trick as nowhere else needed it yet because
    // nothing else syncs an ordered array like this.
    static func publish(rideCode: String, waypoints: [Waypoint]) {
        guard !rideCode.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(waypoints),
              let jsonString = String(data: data, encoding: .utf8) else { return }
        db.child("rides").child(rideCode).child("waypointsJSON").setValue(jsonString)
    }

    /// Live-updates `onUpdate` as the leader adds/reorders/removes stops —
    /// not a one-time fetch, since a group ride can already be underway
    /// when a rider's app opens this screen. Call stopListening with the
    /// returned handle when the screen goes away.
    @discardableResult
    static func listen(rideCode: String, onUpdate: @escaping ([Waypoint]) -> Void) -> DatabaseHandle? {
        guard !rideCode.isEmpty else { return nil }
        return db.child("rides").child(rideCode).child("waypointsJSON").observe(.value) { snapshot in
            guard let jsonString = snapshot.value as? String,
                  let data = jsonString.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([Waypoint].self, from: data) else {
                DispatchQueue.main.async { onUpdate([]) }
                return
            }
            DispatchQueue.main.async { onUpdate(decoded) }
        }
    }

    static func stopListening(rideCode: String, handle: DatabaseHandle?) {
        guard !rideCode.isEmpty, let handle else { return }
        db.child("rides").child(rideCode).child("waypointsJSON").removeObserver(withHandle: handle)
    }

    /// One-time read, for screens that just need "what's the plan right
    /// now" and don't stay on screen long enough to justify a live
    /// listener's teardown bookkeeping — e.g. ScheduleRideView's "planned
    /// route" detail screen, viewed before the ride has even started.
    static func fetchOnce(rideCode: String, completion: @escaping ([Waypoint]) -> Void) {
        guard !rideCode.isEmpty else { completion([]); return }
        db.child("rides").child(rideCode).child("waypointsJSON").observeSingleEvent(of: .value) { snapshot in
            guard let jsonString = snapshot.value as? String,
                  let data = jsonString.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([Waypoint].self, from: data) else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            DispatchQueue.main.async { completion(decoded) }
        }
    }
}

// MARK: - Live Address Search (Google Maps-style autocomplete)
class LocationSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        // Aug 28, 2026 — a fresh, never-started CLLocationManager() here was
        // unreliable (often nil); the shared, already-running instance
        // reflects the real current fix.
        if let loc = SharedLocationManager.shared.location {
            completer.region = MKCoordinateRegion(center: loc.coordinate,
                                                   span: MKCoordinateSpan(latitudeDelta: 2, longitudeDelta: 2))
        }
    }

    var queryFragment: String = "" {
        didSet { completer.queryFragment = queryFragment }
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }

    func resolve(_ completion: MKLocalSearchCompletion, onResult: @escaping (String, String, CLLocationCoordinate2D) -> Void) {
        let request = MKLocalSearch.Request(completion: completion)
        MKLocalSearch(request: request).start { response, _ in
            guard let item = response?.mapItems.first else { return }
            // Aug 28, 2026 — MKMapItem.addressRepresentations/.address/.location
            // are iOS 26+ only; .placemark.title (a formatted address string)
            // and .placemark.coordinate work on every MapKit version.
            let address = item.placemark.title ?? completion.subtitle
            DispatchQueue.main.async {
                onResult(item.name ?? completion.title, address, item.placemark.coordinate)
            }
        }
    }
}

// MARK: - Location Picker Sheet
struct LocationPickerSheet: View {
    let title: String
    let placeholder: String
    var accentColor: Color = .prCoral
    let onSelect: (String, String, CLLocationCoordinate2D) -> Void

    @Environment(\.dismiss) var dismiss
    @StateObject private var completer = LocationSearchCompleter()
    @State private var query = ""
    @State private var showMapPicker = false

    var body: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button("Cancel") { dismiss() }.foregroundColor(.prMuted)
                    Spacer()
                    Text(title).font(.system(size: 17, weight: .semibold)).foregroundColor(.prInk)
                    Spacer()
                    Color.clear.frame(width: 44)
                }
                .padding(16)

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundColor(accentColor)
                    TextField("", text: $query, prompt: Text(placeholder).foregroundColor(.prMuted))
                        .foregroundColor(.prInk)
                        .autocorrectionDisabled()
                        .onChange(of: query) {
                            completer.queryFragment = query
                        }
                    if !query.isEmpty {
                        Button(action: { query = ""; completer.queryFragment = "" }) {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.prMuted)
                        }
                    }
                }
                .padding(12).background(Color.prCardBg).cornerRadius(14)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, lineWidth: 1))
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

                Button(action: { showMapPicker = true }) {
                    HStack(spacing: 12) {
                        Image(systemName: "hand.point.up.left.fill")
                            .foregroundColor(accentColor)
                            .font(.system(size: 18))
                        Text("Choose on map")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.prInk)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12)).foregroundColor(.prMuted)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
                Divider().padding(.leading, 16)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(completer.results.enumerated()), id: \.offset) { index, completion in
                            Button(action: {
                                completer.resolve(completion) { name, address, coordinate in
                                    onSelect(name, address, coordinate)
                                    dismiss()
                                }
                            }) {
                                HStack(spacing: 12) {
                                    Image(systemName: "mappin.circle.fill")
                                        .foregroundColor(accentColor)
                                        .font(.system(size: 20))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(completion.title)
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundColor(.prInk)
                                            .lineLimit(1)
                                        if !completion.subtitle.isEmpty {
                                            Text(completion.subtitle)
                                                .font(.system(size: 12))
                                                .foregroundColor(.prMuted)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 16).padding(.vertical, 12)
                            }
                            if index < completer.results.count - 1 {
                                Divider().padding(.leading, 48)
                            }
                        }
                        if query.isEmpty {
                            Text("Start typing an address, place, or city")
                                .font(.system(size: 13)).foregroundColor(.prMuted)
                                .padding(.top, 24)
                        } else if completer.results.isEmpty {
                            Text("No matches found")
                                .font(.system(size: 13)).foregroundColor(.prMuted)
                                .padding(.top, 24)
                        }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showMapPicker) {
            MapPickerView(accentColor: accentColor) { name, address, coordinate in
                onSelect(name, address, coordinate)
                dismiss()
            }
        }
    }
}

// MARK: - Choose On Map
struct MapPickerView: View {
    var accentColor: Color = .prCoral
    let onConfirm: (String, String, CLLocationCoordinate2D) -> Void

    @Environment(\.dismiss) var dismiss
    // Aug 28, 2026 — same fix as WaypointsView/RouteMapView: read the
    // shared, already-running location instead of a fresh ad-hoc
    // CLLocationManager(), which was frequently nil on first appearance.
    @ObservedObject private var locationManager = SharedLocationManager.shared
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.33, longitude: -122.03),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )
    @State private var address = "Move the map to choose a location"
    @State private var isResolving = false

    var body: some View {
        ZStack {
            PickerMapRepresentable(region: $region, currentLocation: locationManager.location) { center in
                resolveAddress(for: center)
            }
            .ignoresSafeArea()

            Image(systemName: "mappin")
                .font(.system(size: 40, weight: .semibold))
                .foregroundColor(accentColor)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                .offset(y: -20)
                .allowsHitTesting(false)

            VStack {
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.prInk)
                            .padding(10)
                            .background(Color.prCardBg)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                    }
                    Spacer()
                }
                .padding(16)

                Spacer()

                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        if isResolving {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "mappin.circle.fill").foregroundColor(accentColor)
                        }
                        Text(address).font(.system(size: 13)).foregroundColor(.prInk).lineLimit(2)
                        Spacer()
                    }
                    .padding(12).background(Color.prCardBg).cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.prBorder, lineWidth: 1))

                    Button(action: {
                        onConfirm(address, address, region.center)
                    }) {
                        Text("Set This Location")
                            .font(.system(size: 16, weight: .bold)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(accentColor)
                            .cornerRadius(14)
                    }
                }
                .padding(16)
            }
        }
        .onAppear { resolveAddress(for: region.center) }
    }

    // Aug 28, 2026 — MKReverseGeocodingRequest is iOS 26+ only; replaced
    // with CLGeocoder's async reverseGeocodeLocation (available since iOS
    // 15), which works at this project's 17.6 deployment target.
    func resolveAddress(for coordinate: CLLocationCoordinate2D) {
        isResolving = true
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        Task {
            let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location)
            await MainActor.run {
                isResolving = false
                if let placemark = placemarks?.first {
                    let shortAddress = [placemark.thoroughfare, placemark.locality]
                        .compactMap { $0 }
                        .joined(separator: ", ")
                    address = [placemark.name, shortAddress.isEmpty ? nil : shortAddress]
                        .compactMap { $0 }
                        .joined(separator: ", ")
                }
            }
        }
    }
}

struct PickerMapRepresentable: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    // Aug 28, 2026 — passed in from the shared location manager (see
    // MapPickerView) instead of grabbing a fresh, unreliable
    // CLLocationManager() here. May still be nil at makeUIView time if
    // CoreLocation hasn't delivered a fix yet — updateUIView below centers
    // once as soon as it does, without fighting the rider's own panning
    // afterward.
    var currentLocation: CLLocation? = nil
    var onRegionSettled: (CLLocationCoordinate2D) -> Void

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        if let userLoc = currentLocation {
            mapView.setRegion(MKCoordinateRegion(center: userLoc.coordinate, span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)), animated: false)
            context.coordinator.hasCenteredOnUser = true
        } else {
            mapView.setRegion(region, animated: false)
        }
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        guard !context.coordinator.hasCenteredOnUser, let userLoc = currentLocation else { return }
        mapView.setRegion(MKCoordinateRegion(center: userLoc.coordinate, span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)), animated: true)
        context.coordinator.hasCenteredOnUser = true
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: PickerMapRepresentable
        var debounce: Timer?
        var hasCenteredOnUser = false
        init(_ parent: PickerMapRepresentable) { self.parent = parent }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            parent.region = mapView.region
            debounce?.invalidate()
            debounce = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                self.parent.onRegionSettled(mapView.region.center)
            }
        }
    }
}

// MARK: - Waypoints View
struct WaypointsView: View {
    @AppStorage("pendingWaypointRideCode") var pendingWaypointRideCode: String = ""
    @AppStorage("myCreatedRideCode") var myCreatedRideCode: String = ""
    @AppStorage("riderName") var riderName: String = "Rider"
    @StateObject private var manager = WaypointsManager()
    // Aug 28, 2026 — was grabbing a fresh, never-started CLLocationManager()
    // inline at every use site below, which is unreliable: an ad-hoc
    // CLLocationManager().location is very often nil until something has
    // actually called startUpdatingLocation(), so the map frequently opened
    // with no location to center on at all. Using the app's one shared,
    // already-running instance (same pattern as MapView/FriendsMapView/
    // LapModeView) fixes that — see startUpdating/stopUpdating below.
    @ObservedObject private var locationManager = SharedLocationManager.shared
    // Followed-friends list for the Share picker (UserProfileManager.followedUsers
    // — same source Garage's bike-linking and Lap Sharing's friend-picker use)
    // and the Firebase invite inbox writer for Share.
    // Aug 27, 2026 — Grok re-review, small cleanup: was its own private
    // UserProfileManager() — a duplicate instance alongside PackRideApp's
    // app-wide one. WaypointsView is only ever pushed/presented from
    // ContentView's navigation tree, which already has the shared instance
    // in its environment.
    @EnvironmentObject private var profileManager: UserProfileManager
    // Aug 29, 2026 — needed so the "Group Ride" choice below can route into
    // the Group tab the same way a join link does (see ContentView's
    // .onChange(of: deepLinkRouter.pendingRideCode)), instead of the old
    // fullScreenCover(GroupRideView()) that presented outside ContentView's
    // tab structure entirely — which is why the bottom tab bar and back
    // button vanished on that path.
    @EnvironmentObject private var deepLinkRouter: DeepLinkRouter
    @StateObject private var inviteManager = RideInviteManager()
    @State private var mapStyleIndex = 2 // Hybrid by default so street names are visible
    @State private var boundRideCode = ""
    @State private var showModeSelection = false
    @State private var showNavigation = false
    @State private var showRideTypeChoice = false
    @State private var launchSoloRide = false
    // Aug 24, 2026 — set by TurnByTurnView's onRideRecorded when a ride
    // actually finished recording (not just "backed out of navigation").
    // Checked in both fullScreenCover(showNavigation/launchSoloRide)
    // onDismiss handlers below so Plan Route pops itself too once
    // navigation ends, landing the rider back on Home instead of leaving
    // them stranded on this screen.
    @State private var justFinishedRecordedRide = false
    @State private var generatedGroupCode = ""
    @State private var showLeaderError = false
    @State private var enteredGroupCode = ""
    @State private var showStartPicker = false
    @State private var showStopPicker = false
    @State private var showDestinationPicker = false
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.33, longitude: -122.03),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )

    @State private var droppedCoordinate: CLLocationCoordinate2D? = nil
    @State private var showDropPinSheet = false
    @State private var droppedPinName = ""
    @State private var droppedPinType: Waypoint.WaypointType = .meetup

    // MARK: - Weather-Ahead / Share / Schedule (shown once 2+ stops picked)
    @State private var showWeatherAhead = false
    @State private var showSharePicker = false
    @State private var showScheduleSheet = false
    @State private var sentInviteIDs: Set<String> = []

    // Every stop AND the destination, in route order — the set this screen's
    // distance preview, Weather, Share, and Schedule entry points all gate on.
    private var plannedPoints: [Waypoint] {
        manager.destination.map { manager.stops + [$0] } ?? manager.stops
    }
    private var hasEnoughStopsPlanned: Bool { plannedPoints.count >= 2 }

    // Honest straight-line ("as the crow flies") distance across the whole
    // planned route — current location (if known) through every stop to the
    // destination, summed leg by leg with CLLocation.distance(from:) (a
    // great-circle/haversine-class measurement, NOT routed mileage). Labeled
    // clearly as an estimate everywhere it's shown — see distancePreview below.
    private var crowFliesDistanceMiles: Double? {
        var points: [CLLocationCoordinate2D] = []
        // Aug 28, 2026 — respects a rider-picked starting point, falling
        // back to their live location exactly as before when none is set.
        if let userCoordinate = manager.startOverride?.coordinate ?? locationManager.location?.coordinate { points.append(userCoordinate) }
        points.append(contentsOf: plannedPoints.map { $0.coordinate })
        guard points.count >= 2 else { return nil }
        var totalMeters: Double = 0
        for i in 0..<(points.count - 1) {
            let from = CLLocation(latitude: points[i].latitude, longitude: points[i].longitude)
            let to = CLLocation(latitude: points[i + 1].latitude, longitude: points[i + 1].longitude)
            totalMeters += from.distance(from: to)
        }
        return totalMeters * 0.000621371
    }

    var body: some View {
        ZStack {
            RouteMapView(waypoints: manager.routeableWaypoints, region: $region, mapStyleIndex: mapStyleIndex, currentLocation: locationManager.location, startOverride: manager.startOverride) { coordinate in
                droppedCoordinate = coordinate
                droppedPinName = ""
                droppedPinType = .meetup
                showDropPinSheet = true
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                routePanel
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        MapStyleBtn(icon: "globe.americas.fill", label: "SAT", isActive: mapStyleIndex == 0) { mapStyleIndex = 0 }
                        MapStyleBtn(icon: "map.fill", label: "MAP", isActive: mapStyleIndex == 1) { mapStyleIndex = 1 }
                        MapStyleBtn(icon: "car.fill", label: "HYB", isActive: mapStyleIndex == 2) { mapStyleIndex = 2 }
                    }
                    .padding(4)
                    .background(Color.prCardBg)
                    .cornerRadius(14)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, lineWidth: 1))
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                    .padding(.trailing, 16)
                }
                Spacer()
                bottomButtons
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !pendingWaypointRideCode.isEmpty {
                boundRideCode = pendingWaypointRideCode
                manager.switchRideCode(pendingWaypointRideCode)
                pendingWaypointRideCode = ""
            } else if boundRideCode.isEmpty {
                // Fresh start — actually clear previous waypoints (both in
                // memory and the persisted "waypoints_solo" entry), not just
                // reload them back from storage.
                manager.clearWaypoints()
            }
            // Needed so the Share picker has a followed-friends list to invite,
            // and so a sent invite actually reaches the right Firebase inbox.
            profileManager.listenForFollowedUsers()
            locationManager.startUpdating(reason: "waypointsMap")
        }
        .onDisappear {
            profileManager.stopListeningForFollowedUsers()
            locationManager.stopUpdating(reason: "waypointsMap")
        }
        .sheet(isPresented: $showModeSelection) { modeSelectionSheet }
        .sheet(isPresented: $showWeatherAhead) {
            RouteWeatherAheadView(
                startCoordinate: manager.startOverride?.coordinate ?? locationManager.location?.coordinate,
                stops: plannedPoints.map { (name: $0.name, coordinate: $0.coordinate) }
            )
        }
        .sheet(isPresented: $showSharePicker) {
            SharePlanSheet(
                followedUsers: profileManager.followedUsers,
                sentTo: sentInviteIDs,
                onSend: { friend in sharePlan(to: friend) },
                onDone: { showSharePicker = false }
            )
        }
        .sheet(isPresented: $showScheduleSheet) {
            ScheduleRideSheet(rideCode: promoteToRideCodeIfNeeded()) {
                // On scheduled callback — nothing extra needed here, the sheet
                // dismisses itself (see ScheduleRideSheet.onScheduled in
                // ScheduleRideView.swift).
            }
        }
        .fullScreenCover(isPresented: $showNavigation, onDismiss: {
            if justFinishedRecordedRide {
                justFinishedRecordedRide = false
                dismiss()
            }
        }) {
            if let last = manager.waypoints.last {
                TurnByTurnView(
                    destination: last.coordinate,
                    destinationName: last.name,
                    waypoints: Array(manager.waypoints.dropLast().map { $0.coordinate }),
                    onRideRecorded: { justFinishedRecordedRide = true }
                )
            }
        }
        .sheet(isPresented: $showRideTypeChoice) {
            rideTypeChoiceSheet
        }
        .fullScreenCover(isPresented: $launchSoloRide, onDismiss: {
            if justFinishedRecordedRide {
                justFinishedRecordedRide = false
                dismiss()
            }
        }) {
            if let last = manager.waypoints.last {
                TurnByTurnView(
                    destination: last.coordinate,
                    destinationName: last.name,
                    waypoints: Array(manager.waypoints.dropLast().map { $0.coordinate }),
                    onRideRecorded: { justFinishedRecordedRide = true }
                )
            }
        }
        .sheet(isPresented: $showDropPinSheet) { dropPinSheet }
        .sheet(isPresented: $showStartPicker) {
            LocationPickerSheet(title: "Starting Point", placeholder: "Search for a place or address", accentColor: .prTeal) { name, address, coordinate in
                manager.setStart(name: name, address: address, coordinate: coordinate)
            }
        }
        .sheet(isPresented: $showStopPicker) {
            LocationPickerSheet(title: "Add Stop", placeholder: "Search for a place or address", accentColor: .prTeal) { name, address, coordinate in
                manager.addStop(name: name, address: address, type: .meetup, coordinate: coordinate)
            }
        }
        .sheet(isPresented: $showDestinationPicker) {
            LocationPickerSheet(title: "Choose Destination", placeholder: "Search for a place or address", accentColor: .prCoral) { name, address, coordinate in
                manager.setDestination(name: name, address: address, coordinate: coordinate)
            }
        }
    }

    // MARK: - Route Panel
    // Redesigned to match this app's own bottom-sheet language (see
    // ProfileView's AddContactSheet / GarageView's AddEditBikeSheet): a drag
    // handle affordance, generously rounded corners, a more lifted shadow,
    // and each route row as a tinted card with a circular icon badge instead
    // of a plain flat row with a small color dot.
    private var routePanel: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3).fill(Color.prBorder)
                .frame(width: 36, height: 5)
                .padding(.top, 10).padding(.bottom, 6)

            if !boundRideCode.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "crown.fill").foregroundColor(.prCoral).font(.system(size: 11))
                    Text("Group Ride: \(boundRideCode)")
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(.prCoral)
                    Spacer()
                    Button(action: { boundRideCode = ""; manager.switchRideCode("") }) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.prMuted).font(.system(size: 14))
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.prCoralSoft)
            }

            VStack(spacing: 6) {
                // Aug 28, 2026 — was permanently locked to "Your location"
                // with no way to plan from anywhere else. Now defaults to
                // your current location (unchanged) but is tappable to pick
                // a different starting point, same as the destination row
                // below — with an X to clear back to the default. This only
                // affects route PREVIEW/planning here (the map, the crow-
                // flies distance, the weather-ahead check); actual
                // turn-by-turn navigation always starts from wherever the
                // rider physically is when they start riding.
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Color.prTeal.opacity(0.15)).frame(width: 34, height: 34)
                        Image(systemName: "location.fill").font(.system(size: 13)).foregroundColor(.prTeal)
                    }
                    Text(manager.startOverride?.name ?? "Your location")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.prInk)
                        .lineLimit(1)
                    Spacer()
                    if manager.startOverride != nil {
                        Button(action: { manager.clearStart() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.prMuted)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color.prTeal.opacity(0.06))
                .cornerRadius(12)
                .contentShape(Rectangle())
                .onTapGesture { showStartPicker = true }

                if !manager.stops.isEmpty || manager.destination != nil {
                    HStack {
                        Rectangle().fill(Color.prBorder).frame(width: 1, height: 8).padding(.leading, 27)
                        Spacer()
                    }
                }

                // Reorderable intermediate stops
                if !manager.stops.isEmpty {
                    List {
                        ForEach(manager.stops) { stop in
                            stopRow(stop)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .deleteDisabled(true)
                        }
                        .onMove { manager.moveStop(from: $0, to: $1) }
                    }
                    .environment(\.editMode, .constant(.active))
                    .listStyle(.plain)
                    .scrollDisabled(true)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .frame(height: CGFloat(manager.stops.count) * 58)
                }

                // Add stop
                Button(action: { showStopPicker = true }) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Color.prTeal.opacity(0.15)).frame(width: 34, height: 34)
                            Image(systemName: "plus").font(.system(size: 14, weight: .bold)).foregroundColor(.prTeal)
                        }
                        Text("Add stop")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.prTeal)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }

                HStack {
                    Rectangle().fill(Color.prBorder).frame(width: 1, height: 8).padding(.leading, 27)
                    Spacer()
                }

                // Destination
                if let destination = manager.destination {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Color.prCoralSoft).frame(width: 34, height: 34)
                            Image(systemName: "flag.checkered").font(.system(size: 13)).foregroundColor(.prCoral)
                        }
                        Text(destination.name)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.prInk)
                            .lineLimit(1)
                        Spacer()
                        Button(action: { manager.clearDestination() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.prMuted)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Color.prCoral.opacity(0.06))
                    .cornerRadius(12)
                    .contentShape(Rectangle())
                    .onTapGesture { showDestinationPicker = true }
                } else {
                    Button(action: { showDestinationPicker = true }) {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().stroke(Color.prMuted, lineWidth: 1.5).frame(width: 34, height: 34)
                                Image(systemName: "mappin").font(.system(size: 13)).foregroundColor(.prMuted)
                            }
                            Text("Where to?")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.prMuted)
                            Spacer()
                            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundColor(.prMuted)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                    }
                }

                // Distance preview + Weather/Share/Schedule — all gated
                // together on "2+ stops picked" (plannedPoints = stops + destination).
                if hasEnoughStopsPlanned {
                    distancePreview
                    planActionsRow
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 10)
        }
        .background(Color.prCardBg)
        .cornerRadius(22)
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.prBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Distance Preview
    // An HONEST straight-line distance, clearly labeled as such — see
    // crowFliesDistanceMiles above for why this is never presented as actual
    // riding mileage.
    private var distancePreview: some View {
        Group {
            if let miles = crowFliesDistanceMiles {
                HStack(spacing: 8) {
                    Image(systemName: "ruler.fill").font(.system(size: 11)).foregroundColor(.prMuted)
                    Text("~\(MeasurementUnits.distanceMiles(miles)) as the crow flies")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.prMuted)
                    Text("(straight-line, not riding distance)")
                        .font(.system(size: 10))
                        .foregroundColor(.prMuted.opacity(0.8))
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.top, 6)
            }
        }
    }

    // MARK: - Weather / Share / Schedule row
    private var planActionsRow: some View {
        HStack(spacing: 8) {
            planActionButton(icon: "cloud.sun.fill", label: "Weather", color: .orange) {
                showWeatherAhead = true
            }
            planActionButton(icon: "square.and.arrow.up.fill", label: "Share", color: .prCoral) {
                sentInviteIDs = []
                showSharePicker = true
            }
            planActionButton(icon: "calendar.badge.clock", label: "Schedule", color: .prTeal) {
                showScheduleSheet = true
            }
        }
        .padding(.horizontal, 12).padding(.top, 8)
    }

    private func planActionButton(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 15)).foregroundColor(color)
                Text(label).font(.system(size: 11, weight: .semibold)).foregroundColor(.prInk)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(color.opacity(0.08))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.2), lineWidth: 1))
        }
    }

    private func stopRow(_ waypoint: Waypoint) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(waypoint.type.color.opacity(0.15)).frame(width: 34, height: 34)
                Image(systemName: waypoint.type.icon).font(.system(size: 13)).foregroundColor(waypoint.type.color)
            }
            Text(waypoint.name)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.prInk)
                .lineLimit(1)
            Spacer()
            Button(action: { manager.removeWaypoint(id: waypoint.id) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.prMuted)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(height: 58)
        .background(waypoint.type.color.opacity(0.06))
        .cornerRadius(12)
    }

    @Environment(\.dismiss) var dismiss

    // MARK: - Bottom Buttons
    private var bottomButtons: some View {
        VStack(spacing: 8) {
            Text("Long press on map to drop a pin")
                .font(.system(size: 11))
                .foregroundColor(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.prInkFixed.opacity(0.85)).cornerRadius(12)

            // Navigate button
            // Aug 28, 2026 — routeableWaypoints excludes a lone start
            // override with no real stop/destination, which manager.waypoints
            // alone would otherwise count as "something to navigate to."
            if !manager.routeableWaypoints.isEmpty {
                Button(action: { showNavigation = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "location.fill.viewfinder").font(.system(size: 16))
                        Text("Navigate").font(.system(size: 16, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(Color.prCoral).cornerRadius(14)
                }
                .padding(.horizontal, 16)
            }

            // Done — if waypoints exist, ask group or solo. Otherwise just dismiss.
            Button(action: {
                manager.saveWaypoints()
                if manager.routeableWaypoints.isEmpty {
                    dismiss()
                } else if !boundRideCode.isEmpty {
                    // Already bound to a group ride — just dismiss
                    dismiss()
                } else {
                    showRideTypeChoice = true
                }
            }) {
                Text("Done")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(Color(red: 0.180, green: 0.620, blue: 0.357))
                    .cornerRadius(14)
            }
            // Aug 28, 2026 — the ad banner that used to sit here (below Done)
            // made this full-bleed map screen feel cluttered and cut into
            // the map's visible area for no real benefit — removed per
            // Karthik's request. AdBannerFooter is still used on the
            // before/after-ride screens (Ride Feed, Ride History, Profile,
            // Group Ride overview) where it doesn't compete with a map.
            .padding(.horizontal, 16).padding(.bottom, 22)
        }
    }
}

// MARK: - Waypoint Card
struct WaypointCard: View {
    let waypoint: Waypoint
    let number: Int
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(waypoint.isCompleted ? Color(red: 0.180, green: 0.620, blue: 0.357) : waypoint.type.color)
                .frame(width: 4)
                .padding(.vertical, 8)

            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(waypoint.isCompleted ? Color(red: 0.180, green: 0.620, blue: 0.357).opacity(0.15) : waypoint.type.color.opacity(0.15))
                        .frame(width: 46, height: 46)
                    if waypoint.isCompleted {
                        Image(systemName: "checkmark")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(Color(red: 0.180, green: 0.620, blue: 0.357))
                    } else {
                        Image(systemName: waypoint.type.icon)
                            .font(.system(size: 20))
                            .foregroundColor(waypoint.type.color)
                    }
                    Text("\(number)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 18, height: 18)
                        .background(waypoint.type.color)
                        .clipShape(Circle())
                        .offset(x: 16, y: -16)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(waypoint.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(waypoint.isCompleted ? .prMuted : .prInk)
                        .strikethrough(waypoint.isCompleted)
                        .lineLimit(1)
                    if !waypoint.address.isEmpty {
                        Text(waypoint.address)
                            .font(.system(size: 12))
                            .foregroundColor(.prMuted)
                            .lineLimit(1)
                    }
                    if !waypoint.note.isEmpty {
                        Text(waypoint.note)
                            .font(.system(size: 11))
                            .foregroundColor(.prCoral.opacity(0.8))
                            .lineLimit(1)
                    }
                }

                Spacer()

                Button(action: onToggle) {
                    Text(waypoint.isCompleted ? "Done" : waypoint.type.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(waypoint.isCompleted ? Color(red: 0.180, green: 0.620, blue: 0.357) : waypoint.type.color)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(waypoint.isCompleted ? Color(red: 0.180, green: 0.620, blue: 0.357).opacity(0.15) : waypoint.type.color.opacity(0.12))
                        .cornerRadius(8)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .padding(.vertical, 12)
        }
        .background(Color.prCardBg)
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, lineWidth: 1))
        .opacity(waypoint.isCompleted ? 0.65 : 1)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button(action: onToggle) {
                Label(waypoint.isCompleted ? "Mark Incomplete" : "Mark Complete",
                      systemImage: waypoint.isCompleted ? "circle" : "checkmark.circle")
            }
            Button(role: .destructive, action: onDelete) {
                Label("Delete Waypoint", systemImage: "trash")
            }
        }
    }
}

// MARK: - Waypoint Map Pin
struct WaypointMapPin: View {
    let waypoint: Waypoint
    @State private var showInfo = false

    var body: some View {
        VStack(spacing: 0) {
            if showInfo {
                Text(waypoint.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.prInk)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.prCardBg)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.prBorder, lineWidth: 1))
                    .padding(.bottom, 4)
            }
            Button(action: { showInfo.toggle() }) {
                ZStack {
                    Circle()
                        .fill(waypoint.type.color)
                        .frame(width: 36, height: 36)
                        .shadow(color: waypoint.type.color.opacity(0.5), radius: 4)
                    Image(systemName: waypoint.type.icon)
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                }
            }
            Triangle()
                .fill(waypoint.type.color)
                .frame(width: 10, height: 6)
        }
    }
}

struct RouteMapView: UIViewRepresentable {
    let waypoints: [Waypoint]
    @Binding var region: MKCoordinateRegion
    var mapStyleIndex: Int = 2
    // Aug 28, 2026 — passed in from the shared location manager (see
    // WaypointsView) instead of a fresh, unreliable CLLocationManager()
    // grabbed inline here. Often still nil the instant this view is
    // created — CoreLocation hasn't necessarily delivered a fix yet — so
    // updateUIView below centers once as soon as it does, without fighting
    // the rider's own panning afterward (same "don't fight the gesture"
    // principle as the waypoint-refit gating below).
    var currentLocation: CLLocation? = nil
    // Aug 28, 2026 — an explicit rider-picked starting point (see
    // WaypointsManager.startOverride); nil means "route from wherever I
    // actually am," the previous, only behavior.
    var startOverride: Waypoint? = nil
    var onPinDropped: ((CLLocationCoordinate2D) -> Void)? = nil

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.mapType = .standard
        // Aug 28, 2026 — was .follow, which kept re-centering the camera on
        // every GPS update on top of updateUIView's own unconditional refit
        // below (now gated, see there) — together these made the map feel
        // frozen at the user's location with no way to pan/zoom away from
        // it. .none still starts centered on the user (set once below) but
        // no longer fights the rider's own map gestures afterward.
        mapView.userTrackingMode = .none

        if let userLoc = currentLocation {
            let userRegion = MKCoordinateRegion(
                center: userLoc.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
            mapView.setRegion(userRegion, animated: false)
            context.coordinator.hasCenteredOnUser = true
        }

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.5
        mapView.addGestureRecognizer(longPress)
        context.coordinator.parent = self
        // Highlight nearby gas stations, restaurants and convenience stores as soon as the map appears.
        context.coordinator.searchPOIs(in: mapView)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        mapView.applyStyleIndex(mapStyleIndex)

        // Aug 28, 2026 — runs ahead of the waypoint-signature gate below (which
        // can early-return before ever reaching this point once there's a
        // stable empty/unchanged waypoint list) so a location that arrives
        // just after makeUIView still gets applied. Only ever centers once.
        if !context.coordinator.hasCenteredOnUser, let userLoc = currentLocation {
            mapView.setRegion(
                MKCoordinateRegion(center: userLoc.coordinate, span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)),
                animated: true
            )
            context.coordinator.hasCenteredOnUser = true
        }

        // Aug 28, 2026 — this used to rebuild every annotation/overlay and
        // re-fit the camera (setVisibleMapRect) on EVERY SwiftUI re-render of
        // WaypointsView, not just when the route actually changed. That
        // screen re-renders for all sorts of unrelated reasons (toggling map
        // style, opening a sheet, a dropped-pin sheet field changing), so the
        // camera kept snapping back to fit user+waypoints the instant a
        // rider tried to pan or zoom the map — it read as frozen on the
        // user's location. Now the rebuild + refit only runs when the
        // waypoint list itself has actually changed since the last update,
        // so manual pan/zoom is preserved between unrelated re-renders.
        // Aug 28, 2026 — startOverride folded into the signature so picking
        // (or clearing) a custom starting point re-draws the route even
        // when the stop/destination list itself hasn't changed.
        let startSignature = startOverride.map { "\($0.latitude),\($0.longitude)" } ?? "current"
        let signature = startSignature + "|" + waypoints.map { "\($0.id):\($0.latitude),\($0.longitude)" }.joined(separator: "|")
        guard signature != context.coordinator.lastWaypointSignature else { return }
        context.coordinator.lastWaypointSignature = signature

        mapView.removeAnnotations(mapView.annotations.filter { $0 is WaypointAnnotation || $0 is StartOverrideAnnotation })
        mapView.removeOverlays(mapView.overlays)

        if let startOverride {
            mapView.addAnnotation(StartOverrideAnnotation(waypoint: startOverride))
        }

        guard !waypoints.isEmpty else { return }

        for (index, waypoint) in waypoints.enumerated() {
            let annotation = WaypointAnnotation(
                waypoint: waypoint,
                number: index + 1
            )
            mapView.addAnnotation(annotation)
        }

        // Aug 29, 2026 — was falling back straight to mapView.userLocation.coordinate,
        // MapKit's own internal blue-dot fix (from showsUserLocation) — a second
        // location source, timed completely independently of the currentLocation
        // passed in above (from SharedLocationManager) that the "center on me" pass
        // just used. Whichever one happened to have arrived first varied call to
        // call, so this fit sometimes included the rider's real position and
        // sometimes silently didn't ("centers on me" felt inconsistent). Preferring
        // currentLocation here keeps the fit consistent with what just got centered.
        let effectiveStart = startOverride?.coordinate ?? currentLocation?.coordinate ?? mapView.userLocation.coordinate
        drawRoute(on: mapView, userLocation: effectiveStart)

        var fitCoords = waypoints.map { $0.coordinate }
        if startOverride != nil || currentLocation != nil || mapView.userLocation.coordinate.latitude != 0 {
            fitCoords.insert(effectiveStart, at: 0)
        }
        let polyline = MKPolyline(coordinates: fitCoords, count: fitCoords.count)
        let rect = polyline.boundingMapRect
        mapView.setVisibleMapRect(
            rect.insetBy(dx: -rect.size.width * 0.2, dy: -rect.size.height * 0.2),
            animated: true
        )
    }

    func drawRoute(on mapView: MKMapView, userLocation: CLLocationCoordinate2D) {
        var coordinates = [userLocation] + waypoints.map { $0.coordinate }
        if userLocation.latitude == 0 && userLocation.longitude == 0 {
            coordinates = waypoints.map { $0.coordinate }
        }
        guard coordinates.count >= 2 else { return }

        var requestIndex = 0

        func requestNextRoute() {
            guard requestIndex < coordinates.count - 1 else { return }

            let request = MKDirections.Request()
            let sourceCoordinate = coordinates[requestIndex]
            let destinationCoordinate = coordinates[requestIndex + 1]
            // Aug 28, 2026 — MKMapItem(location:address:) is iOS 26+ only;
            // the MKPlacemark-based initializer works on every MapKit version.
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: sourceCoordinate))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destinationCoordinate))
            request.transportType = .automobile

            let directions = MKDirections(request: request)
            directions.calculate { response, error in
                if let route = response?.routes.first {
                    DispatchQueue.main.async {
                        mapView.addOverlay(route.polyline, level: .aboveRoads)
                        requestIndex += 1
                        requestNextRoute()
                    }
                } else {
                    let fallback = MKPolyline(
                        coordinates: [coordinates[requestIndex], coordinates[requestIndex + 1]],
                        count: 2
                    )
                    DispatchQueue.main.async {
                        mapView.addOverlay(fallback, level: .aboveRoads)
                        requestIndex += 1
                        requestNextRoute()
                    }
                }
            }
        }

        requestNextRoute()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: RouteMapView
        // Aug 28, 2026 — see updateUIView: gates the annotation/overlay
        // rebuild + camera refit to only run when the waypoint list itself
        // changes, not on every unrelated SwiftUI re-render.
        var lastWaypointSignature: String = ""
        // Aug 28, 2026 — see makeUIView/updateUIView: the map centers on the
        // rider's location once, whether that happens immediately or a beat
        // later once CoreLocation delivers a fix, and never again after that.
        var hasCenteredOnUser = false

        init(parent: RouteMapView) {
            self.parent = parent
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began,
                  let mapView = gesture.view as? MKMapView else { return }
            let touchPoint = gesture.location(in: mapView)
            let coordinate = mapView.convert(touchPoint, toCoordinateFrom: mapView)

            let tempAnnotation = MKPointAnnotation()
            tempAnnotation.coordinate = coordinate
            tempAnnotation.title = "New Waypoint"
            mapView.annotations.filter { $0.title == "New Waypoint" }.forEach {
                mapView.removeAnnotation($0)
            }
            mapView.addAnnotation(tempAnnotation)

            parent.onPinDropped?(coordinate)
        }

        // MARK: - Nearby POI highlighting (gas, food, convenience)
        private var poiDebounce: Timer?

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            poiDebounce?.invalidate()
            poiDebounce = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self, weak mapView] _ in
                guard let self = self, let mapView = mapView else { return }
                self.searchPOIs(in: mapView)
            }
        }

        func searchPOIs(in mapView: MKMapView) {
            let request = MKLocalSearch.Request()
            request.region = mapView.region
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.gasStation, .restaurant, .foodMarket])
            let search = MKLocalSearch(request: request)
            search.start { response, _ in
                guard let items = response?.mapItems else { return }
                DispatchQueue.main.async {
                    mapView.removeAnnotations(mapView.annotations.filter { $0 is POIAnnotation })
                    mapView.addAnnotations(items.prefix(30).map { POIAnnotation(mapItem: $0) })
                }
            }
        }

        static func poiColor(for category: MKPointOfInterestCategory?) -> UIColor {
            switch category {
            case .gasStation: return UIColor(red: 0.886, green: 0.278, blue: 0.165, alpha: 1)
            case .restaurant: return UIColor(red: 0.180, green: 0.620, blue: 0.357, alpha: 1)
            case .foodMarket: return UIColor(red: 0.169, green: 0.431, blue: 0.522, alpha: 1)
            default: return .systemGray
            }
        }

        static func poiIcon(for category: MKPointOfInterestCategory?) -> String {
            switch category {
            case .gasStation: return "fuelpump.fill"
            case .restaurant: return "fork.knife"
            case .foodMarket: return "cart.fill"
            default: return "mappin"
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor(red: 0.886, green: 0.278, blue: 0.165, alpha: 1) // brand coral
                renderer.lineWidth = 4
                renderer.lineDashPattern = [8, 4]
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let poi = annotation as? POIAnnotation {
                let id = "POIPin"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.canShowCallout = true
                view.markerTintColor = Coordinator.poiColor(for: poi.category)
                view.glyphImage = UIImage(systemName: Coordinator.poiIcon(for: poi.category))
                view.displayPriority = .defaultLow
                return view
            }

            if annotation is StartOverrideAnnotation {
                let id = "StartOverridePin"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.canShowCallout = true
                // Teal, matching the "starting point" row's color in the route panel.
                view.markerTintColor = UIColor(red: 0.153, green: 0.549, blue: 0.541, alpha: 1)
                view.glyphImage = UIImage(systemName: "location.fill")
                view.displayPriority = .required
                return view
            }

            guard let waypointAnnotation = annotation as? WaypointAnnotation else { return nil }

            let identifier = "WaypointPin"
            let view = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.canShowCallout = true

            let pinView = UIView(frame: CGRect(x: 0, y: 0, width: 44, height: 56))

            let circle = UIView(frame: CGRect(x: 2, y: 0, width: 40, height: 40))
            circle.backgroundColor = waypointAnnotation.waypoint.type.uiColor
            circle.layer.cornerRadius = 20
            circle.layer.shadowColor = waypointAnnotation.waypoint.type.uiColor.cgColor
            circle.layer.shadowOpacity = 0.5
            circle.layer.shadowRadius = 4

            let numberLabel = UILabel(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
            numberLabel.text = "\(waypointAnnotation.number)"
            numberLabel.textColor = .white
            numberLabel.font = UIFont.boldSystemFont(ofSize: 16)
            numberLabel.textAlignment = .center
            circle.addSubview(numberLabel)

            let triangle = UIView(frame: CGRect(x: 15, y: 40, width: 14, height: 8))
            triangle.backgroundColor = .clear

            let trianglePath = UIBezierPath()
            trianglePath.move(to: CGPoint(x: 7, y: 8))
            trianglePath.addLine(to: CGPoint(x: 0, y: 0))
            trianglePath.addLine(to: CGPoint(x: 14, y: 0))
            trianglePath.close()

            let triangleLayer = CAShapeLayer()
            triangleLayer.path = trianglePath.cgPath
            triangleLayer.fillColor = waypointAnnotation.waypoint.type.uiColor.cgColor
            triangle.layer.addSublayer(triangleLayer)

            pinView.addSubview(circle)
            pinView.addSubview(triangle)

            view.addSubview(pinView)
            view.frame = pinView.frame
            view.centerOffset = CGPoint(x: 0, y: -28)

            let iconImage = UIImageView(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
            let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            iconImage.image = UIImage(systemName: waypointAnnotation.waypoint.type.icon, withConfiguration: config)
            iconImage.tintColor = waypointAnnotation.waypoint.type.uiColor
            iconImage.contentMode = .scaleAspectFit
            view.leftCalloutAccessoryView = iconImage

            return view
        }
    }
}

// MARK: - Nearby POI Annotation (gas, food, convenience)
class POIAnnotation: NSObject, MKAnnotation {
    let mapItem: MKMapItem
    var category: MKPointOfInterestCategory? { mapItem.pointOfInterestCategory }
    // Aug 28, 2026 — MKMapItem.location is iOS 26+ only; .placemark.coordinate
    // works on every MapKit version.
    var coordinate: CLLocationCoordinate2D { mapItem.placemark.coordinate }
    var title: String? { mapItem.name }

    init(mapItem: MKMapItem) {
        self.mapItem = mapItem
    }
}

// MARK: - Start Override Annotation
// Aug 28, 2026 — marks a rider-picked starting point on the map (see
// WaypointsManager.startOverride). Only added when an override is set;
// the default "my current location" start is just the blue dot, as before.
class StartOverrideAnnotation: NSObject, MKAnnotation {
    let waypoint: Waypoint
    var coordinate: CLLocationCoordinate2D { waypoint.coordinate }
    var title: String? { waypoint.name }
    var subtitle: String? { "Starting point" }

    init(waypoint: Waypoint) {
        self.waypoint = waypoint
    }
}

// MARK: - Waypoint Annotation
class WaypointAnnotation: NSObject, MKAnnotation {
    let waypoint: Waypoint
    let number: Int

    var coordinate: CLLocationCoordinate2D { waypoint.coordinate }
    var title: String? { "\(number). \(waypoint.name)" }
    var subtitle: String? { waypoint.type.label }

    init(waypoint: Waypoint, number: Int) {
        self.waypoint = waypoint
        self.number = number
    }
}

// MARK: - UIColor extension for waypoint types
extension Waypoint.WaypointType {
    var uiColor: UIColor {
        switch self {
        case .fuel: return UIColor(red: 0.886, green: 0.278, blue: 0.165, alpha: 1)
        case .food: return UIColor(red: 0.180, green: 0.620, blue: 0.357, alpha: 1)
        case .scenic: return UIColor(red: 0.169, green: 0.431, blue: 0.522, alpha: 1)
        case .rest: return UIColor(red: 0.541, green: 0.4, blue: 0.694, alpha: 1)
        case .meetup: return UIColor(red: 0.110, green: 0.102, blue: 0.090, alpha: 1)
        }
    }
}

// MARK: - Drop Pin Sheet
extension WaypointsView {
    var dropPinSheet: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()
            VStack(spacing: 24) {
                RoundedRectangle(cornerRadius: 3).fill(Color.prBorder)
                    .frame(width: 40, height: 5).padding(.top, 12)

                VStack(spacing: 8) {
                    Image(systemName: "mappin.circle.fill").font(.system(size: 44)).foregroundColor(.prCoral)
                    Text("Name This Waypoint")
                        .font(.system(size: 22, weight: .bold)).foregroundColor(.prInk)
                    if let coord = droppedCoordinate {
                        Text(String(format: "%.4f, %.4f", coord.latitude, coord.longitude))
                            .font(.system(size: 12, design: .monospaced)).foregroundColor(.prMuted)
                    }
                }

                HStack(spacing: 12) {
                    Image(systemName: "pencil").foregroundColor(.prCoral).frame(width: 20)
                    TextField("", text: $droppedPinName, prompt: Text("Waypoint name (e.g. Fuel Stop)").foregroundColor(.prMuted))
                        .foregroundColor(.prInk)
                }
                .padding(14).background(Color.prCardBg).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.prBorder, lineWidth: 1)).cornerRadius(12)
                .padding(.horizontal, 24)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Type").font(.system(size: 13)).foregroundColor(.prMuted)
                        .padding(.horizontal, 24)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Waypoint.WaypointType.allCases, id: \.self) { type in
                                Button(action: { droppedPinType = type }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: type.icon).font(.system(size: 13))
                                        Text(type.label).font(.system(size: 13, weight: .medium))
                                    }
                                    .foregroundColor(droppedPinType == type ? .white : .prMuted)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(droppedPinType == type ? type.color : Color.prCardBg)
                                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.prBorder, lineWidth: droppedPinType == type ? 0 : 1))
                                    .cornerRadius(20)
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                }

                VStack(spacing: 12) {
                    Button(action: {
                        guard let coord = droppedCoordinate, !droppedPinName.isEmpty else { return }
                        let waypoint = Waypoint(
                            id: UUID().uuidString,
                            name: droppedPinName,
                            type: droppedPinType,
                            latitude: coord.latitude,
                            longitude: coord.longitude,
                            note: "",
                            isCompleted: false,
                            address: String(format: "%.4f, %.4f", coord.latitude, coord.longitude)
                        )
                        manager.addWaypoint(waypoint)
                        droppedCoordinate = nil
                        droppedPinName = ""
                        showDropPinSheet = false
                    }) {
                        Text("Add Waypoint")
                            .font(.system(size: 17, weight: .semibold)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(droppedPinName.isEmpty ? Color.prCoral.opacity(0.4) : Color.prCoral)
                            .cornerRadius(14)
                    }
                    .disabled(droppedPinName.isEmpty)
                    .padding(.horizontal, 24)

                    Button(action: { showDropPinSheet = false; droppedCoordinate = nil }) {
                        Text("Cancel").font(.system(size: 15)).foregroundColor(.prMuted)
                    }
                }
                Spacer()
            }
        }
    }
}

// MARK: - Mode Selection Sheet
extension WaypointsView {
    // MARK: - Ride Type Choice (shown after planning route)
    var rideTypeChoiceSheet: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()
            VStack(spacing: 24) {
                RoundedRectangle(cornerRadius: 3).fill(Color.prBorder)
                    .frame(width: 40, height: 5).padding(.top, 12)

                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44)).foregroundColor(Color(red: 0.180, green: 0.620, blue: 0.357))
                    Text("Route Ready!")
                        .font(.system(size: 24, weight: .bold, design: .rounded)).foregroundColor(.prInk)
                    Text("\(manager.routeableWaypoints.count) stop\(manager.routeableWaypoints.count == 1 ? "" : "s") planned. How do you want to ride?")
                        .font(.system(size: 14, design: .rounded)).foregroundColor(.prMuted)
                        .multilineTextAlignment(.center).padding(.horizontal, 24)
                }

                VStack(spacing: 12) {
                    // Group Ride option
                    Button(action: {
                        // Aug 29, 2026 — bind the route just planned to a new
                        // group ride code. This used to call
                        // manager.switchRideCode(code), which clears
                        // `waypoints` to [] and reloads from the brand-new
                        // code's (empty) storage key BEFORE saveWaypoints()
                        // below could persist/publish the real route — so
                        // the group ride always started from an empty plan
                        // (Ride Room showed "Add Waypoints" instead of the
                        // route, and reopening it dropped the destination).
                        // Assign the code directly instead, same fix already
                        // used by promoteToRideCodeIfNeeded() below, so the
                        // in-memory route survives into the save/publish.
                        let code = generateGroupCode()
                        generatedGroupCode = code
                        manager.rideCode = code
                        manager.saveWaypoints()
                        // Marks this device as the code's leader once
                        // GroupRideView reads it in onAppear.
                        UserDefaults.standard.set(code, forKey: "pendingGroupRideCode")
                        showRideTypeChoice = false
                        // Aug 29, 2026 — route into the Group tab the same
                        // way a join link does (was fullScreenCover(GroupRideView()),
                        // a separate view stack outside ContentView's tab
                        // bar — that's why the tab bar and back button
                        // disappeared going this route).
                        deepLinkRouter.pendingRideCode = code
                        dismiss()
                    }) {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(LinearGradient(colors: [Color(red: 0.25, green: 0.6, blue: 1.0), Color(red: 0.15, green: 0.4, blue: 0.85)],
                                                          startPoint: .top, endPoint: .bottom))
                                    .frame(width: 52, height: 52)
                                Image(systemName: "person.3.fill")
                                    .font(.system(size: 20)).foregroundColor(.white)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Group Ride")
                                    .font(.system(size: 18, weight: .bold, design: .rounded)).foregroundColor(.prInk)
                                Text("Generate a code and invite your pack")
                                    .font(.system(size: 12, design: .rounded)).foregroundColor(.prMuted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .bold)).foregroundColor(.prMuted)
                        }
                        .padding(16)
                        .background(Color.prCardBg)
                        .cornerRadius(16)
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(red: 0.25, green: 0.6, blue: 1.0).opacity(0.3), lineWidth: 1))
                    }

                    // Solo Ride option
                    Button(action: {
                        manager.switchRideCode("")
                        manager.saveWaypoints()
                        showRideTypeChoice = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            launchSoloRide = true
                        }
                    }) {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(LinearGradient(colors: [.orange, Color(red: 0.9, green: 0.35, blue: 0.0)],
                                                          startPoint: .top, endPoint: .bottom))
                                    .frame(width: 52, height: 52)
                                Image(systemName: "motorcycle")
                                    .font(.system(size: 22)).foregroundColor(.white)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Solo Ride")
                                    .font(.system(size: 18, weight: .bold, design: .rounded)).foregroundColor(.prInk)
                                Text("Start navigating with turn-by-turn voice")
                                    .font(.system(size: 12, design: .rounded)).foregroundColor(.prMuted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .bold)).foregroundColor(.prMuted)
                        }
                        .padding(16)
                        .background(Color.prCardBg)
                        .cornerRadius(16)
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.orange.opacity(0.3), lineWidth: 1))
                    }
                }
                .padding(.horizontal, 20)

                Button(action: { showRideTypeChoice = false }) {
                    Text("Keep Planning")
                        .font(.system(size: 15, design: .rounded)).foregroundColor(.prMuted)
                }

                Spacer()
            }
        }
    }

    func generateGroupCode() -> String {
        let letters = "ABCDEFGHJKLMNPQRSTUVWXYZ"
        let digits = "23456789"
        let part1 = String((0..<2).compactMap { _ in letters.randomElement() })
        let part2 = String((0..<4).compactMap { _ in digits.randomElement() })
        return "\(part1)-\(part2)"
    }
}

// MARK: - Share / Schedule (route-code promotion)
extension WaypointsView {
    // A purely local, unshared plan has nowhere to sync a Share invite or a
    // Schedule Ride listing to until it has a REAL ride code — so both entry
    // points below promote the plan the same way the "Group Ride" choice in
    // rideTypeChoiceSheet does: generate a code via the same JoinCodeGenerator
    // GroupRideView/CommunityView use, bind waypoints to it (which mirrors
    // them to Firebase at rides/{code}/waypointsJSON via GroupWaypointSync),
    // and mark this device as the code's creator/leader. Idempotent — if the
    // plan is already bound (boundRideCode set), returns that existing code.
    //
    // Deliberately does NOT call WaypointsManager.switchRideCode(_:) the way
    // rideTypeChoiceSheet's Group Ride button does — switchRideCode clears
    // `waypoints` to [] and reloads from the brand-new code's storage key,
    // which doesn't exist yet, so the freshly-planned route the rider is
    // trying to share/schedule would silently come back empty right before
    // saveWaypoints() persists (and publishes to Firebase) that empty array.
    // Assigning `rideCode` directly instead keeps the in-memory plan intact,
    // so saveWaypoints() below actually persists/publishes the real route.
    func promoteToRideCodeIfNeeded() -> String {
        if !boundRideCode.isEmpty { return boundRideCode }
        let code = JoinCodeGenerator.generate()
        boundRideCode = code
        myCreatedRideCode = code
        manager.rideCode = code
        manager.saveWaypoints()
        return code
    }

    // Share: promote to a real ride code (if not already one), then write a
    // Firebase invite carrying that code to the selected friend's inbox —
    // see RideInviteManager.swift. sentInviteIDs just drives the "Sent" state
    // in SharePlanSheet; it's reset each time the sheet reopens.
    func sharePlan(to friend: RiderProfile) {
        let code = promoteToRideCodeIfNeeded()
        inviteManager.sendInvite(
            to: friend.id,
            rideCode: code,
            senderName: riderName,
            destinationName: manager.destination?.name ?? "",
            stopCount: manager.routeableWaypoints.count
        )
        sentInviteIDs.insert(friend.id)
    }
}

extension WaypointsView {
    var modeSelectionSheet: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()
            VStack(spacing: 28) {
                RoundedRectangle(cornerRadius: 3).fill(Color.prBorder)
                    .frame(width: 40, height: 5).padding(.top, 12)

                VStack(spacing: 10) {
                    Image(systemName: "mappin.and.ellipse").font(.system(size: 44)).foregroundColor(.prCoral)
                    Text("Group Ride Waypoints").font(.system(size: 24, weight: .bold)).foregroundColor(.prInk)
                    Text("Enter your group ride code to bind waypoints to it.")
                        .font(.system(size: 15)).foregroundColor(.prMuted)
                        .multilineTextAlignment(.center).padding(.horizontal, 24)
                }

                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle().fill(Color.prCoralSoft).frame(width: 48, height: 48)
                                Image(systemName: "person.3.fill").font(.system(size: 20)).foregroundColor(.prCoral)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Group Ride").font(.system(size: 16, weight: .semibold)).foregroundColor(.prInk)
                                Text("Bind waypoints to a group ride (leader only)")
                                    .font(.system(size: 12)).foregroundColor(.prMuted)
                            }
                        }

                        HStack(spacing: 10) {
                            TextField("", text: $enteredGroupCode, prompt: Text("Enter your ride code").foregroundColor(.prMuted))
                                .font(.system(size: 15, design: .monospaced)).foregroundColor(.prInk)
                                .padding(12).background(Color(red: 0.941, green: 0.925, blue: 0.898)).cornerRadius(10)
                                .autocapitalization(.allCharacters)

                            Button(action: {
                                let code = enteredGroupCode.uppercased()
                                if code == myCreatedRideCode {
                                    boundRideCode = code
                                    manager.switchRideCode(code)
                                    enteredGroupCode = ""
                                    showModeSelection = false
                                } else {
                                    showLeaderError = true
                                }
                            }) {
                                Text("Confirm")
                                    .font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                                    .padding(.horizontal, 14).padding(.vertical, 12)
                                    .background(enteredGroupCode.isEmpty ? Color.prCoral.opacity(0.4) : Color.prCoral)
                                    .cornerRadius(10)
                            }
                            .disabled(enteredGroupCode.isEmpty)
                        }

                        if showLeaderError {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Color(red: 0.827, green: 0.231, blue: 0.173))
                                Text("Only the group leader can add waypoints to a group ride.")
                                    .font(.system(size: 12)).foregroundColor(Color(red: 0.827, green: 0.231, blue: 0.173))
                            }
                        }
                    }
                    .padding(16).background(Color.prCardBg).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, lineWidth: 1)).cornerRadius(14)
                }
                .padding(.horizontal, 24)
                Spacer()
            }
        }
    }
}

// MARK: - Share Plan Sheet
// Opened from Plan Route's "Share" button once 2+ stops are picked. Lists
// UserProfileManager.followedUsers (same source Garage's bike-linking and Lap
// Sharing's friend-picker use) and writes a Firebase in-app invite per tap —
// see RideInviteManager.swift / WaypointsView.sharePlan(to:). Styled like
// ProfileView's AddContactSheet / GarageView's AddEditBikeSheet: drag handle,
// rounded card rows, coral primary action.
struct SharePlanSheet: View {
    let followedUsers: [RiderProfile]
    let sentTo: Set<String>
    let onSend: (RiderProfile) -> Void
    let onDone: () -> Void

    var body: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 3).fill(Color.prBorder)
                    .frame(width: 40, height: 5).padding(.top, 12).padding(.bottom, 20)

                VStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up.circle.fill").font(.system(size: 40)).foregroundColor(.prCoral)
                    Text("Share This Route").font(.system(size: 19, weight: .bold)).foregroundColor(.prInk)
                    Text("Send an in-app invite to a friend you follow.")
                        .font(.system(size: 13)).foregroundColor(.prMuted)
                }
                .padding(.bottom, 20)

                if followedUsers.isEmpty {
                    Spacer()
                    VStack(spacing: 10) {
                        Image(systemName: "person.2.slash").font(.system(size: 28)).foregroundColor(.prMuted)
                        Text("You're not following anyone yet.\nFollow riders from Community or Profile to invite them.")
                            .font(.system(size: 13)).foregroundColor(.prMuted).multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 30)
                    Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(followedUsers) { friend in
                                let isSent = sentTo.contains(friend.id)
                                Button(action: { onSend(friend) }) {
                                    HStack(spacing: 12) {
                                        ZStack {
                                            Circle().fill(Color.prCoralSoft).frame(width: 44, height: 44)
                                            Text(friend.initials).font(.system(size: 14, weight: .bold)).foregroundColor(.prCoral)
                                        }
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(friend.name).font(.system(size: 14, weight: .semibold)).foregroundColor(.prInk)
                                            Text(friend.city.isEmpty ? "PackRide rider" : friend.city)
                                                .font(.system(size: 11)).foregroundColor(.prMuted)
                                        }
                                        Spacer()
                                        if isSent {
                                            HStack(spacing: 4) {
                                                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                                                Text("Sent").font(.system(size: 12, weight: .semibold))
                                            }
                                            .foregroundColor(Color(red: 0.180, green: 0.620, blue: 0.357))
                                        } else {
                                            Image(systemName: "paperplane.fill").font(.system(size: 14)).foregroundColor(.prCoral)
                                        }
                                    }
                                    .padding(12).background(Color.prFieldBg).cornerRadius(14)
                                }
                                .disabled(isSent)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }

                Button(action: onDone) {
                    Text("Done")
                        .font(.system(size: 16, weight: .bold)).foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(Color.prCoral).cornerRadius(14)
                }
                .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 30)
            }
        }
    }
}

#Preview {
    NavigationView {
        WaypointsView()
    }
    .environmentObject(UserProfileManager())
}
