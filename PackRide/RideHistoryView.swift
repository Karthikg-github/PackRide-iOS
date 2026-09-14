import SwiftUI
import Combine
import MapKit
import FirebaseDatabase
import FirebaseStorage
import FirebaseAuth

// MARK: - Ride Model
struct RideRecord: Identifiable, Codable {
    let id: String
    let date: Date
    let distance: Double
    let maxSpeed: Double
    let duration: String
    let rideCode: String
    var gpxFilePath: String? = nil
    // Aug 27, 2026 — download URL for this ride's GPX in Firebase Storage,
    // set once recordRide()'s background upload finishes (see
    // RideHistoryManager.syncRideToCloud). Lets a ride recorded on THIS
    // install still show its route/replay/telemetry after a reinstall or a
    // login on a different device — resolveGPXPath() downloads it into the
    // new install's local GPXStorage on first use, same as before.
    var gpxURL: String? = nil
    var maxLeanAngle: Double = 0
    var analytics: RideAnalyticsSummary? = nil
    var isGroupRide: Bool = false
    var isLeader: Bool = false
    var bikeId: String? = nil
    var trackName: String = ""
    var lapTimes: [Double] = []
    var lapStartTimestamps: [Int64] = []

    init(id: String, date: Date, distance: Double, maxSpeed: Double, duration: String, rideCode: String, gpxFilePath: String? = nil, gpxURL: String? = nil, maxLeanAngle: Double = 0, analytics: RideAnalyticsSummary? = nil, isGroupRide: Bool = false, isLeader: Bool = false, bikeId: String? = nil, trackName: String = "", lapTimes: [Double] = [], lapStartTimestamps: [Int64] = []) {
        self.id = id; self.date = date; self.distance = distance; self.maxSpeed = maxSpeed
        self.duration = duration; self.rideCode = rideCode; self.gpxFilePath = gpxFilePath
        self.gpxURL = gpxURL
        self.maxLeanAngle = maxLeanAngle; self.analytics = analytics
        self.isGroupRide = isGroupRide; self.isLeader = isLeader; self.bikeId = bikeId
        self.trackName = trackName; self.lapTimes = lapTimes; self.lapStartTimestamps = lapStartTimestamps
    }

    enum CodingKeys: String, CodingKey {
        case id, date, distance, maxSpeed, duration, rideCode, gpxFilePath, gpxURL, maxLeanAngle, analytics, isGroupRide, isLeader, bikeId, trackName, lapTimes, lapStartTimestamps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        distance = try c.decode(Double.self, forKey: .distance)
        maxSpeed = try c.decode(Double.self, forKey: .maxSpeed)
        duration = try c.decode(String.self, forKey: .duration)
        rideCode = try c.decode(String.self, forKey: .rideCode)
        gpxFilePath = try c.decodeIfPresent(String.self, forKey: .gpxFilePath)
        gpxURL = try c.decodeIfPresent(String.self, forKey: .gpxURL)
        maxLeanAngle = try c.decodeIfPresent(Double.self, forKey: .maxLeanAngle) ?? 0
        analytics = try c.decodeIfPresent(RideAnalyticsSummary.self, forKey: .analytics)
        if let stored = try c.decodeIfPresent(Bool.self, forKey: .isGroupRide) {
            isGroupRide = stored
        } else {
            isGroupRide = (rideCode == "GROUP")
        }
        isLeader = try c.decodeIfPresent(Bool.self, forKey: .isLeader) ?? false
        bikeId = try c.decodeIfPresent(String.self, forKey: .bikeId)
        trackName = try c.decodeIfPresent(String.self, forKey: .trackName) ?? ""
        lapTimes = try c.decodeIfPresent([Double].self, forKey: .lapTimes) ?? []
        lapStartTimestamps = try c.decodeIfPresent([Int64].self, forKey: .lapStartTimestamps) ?? []
    }

    var hasGPX: Bool {
        guard let path = gpxFilePath else { return false }
        return GPXStorage.exists(path)
    }

    // hasGPX is "is there a local file right now" — hasRouteData is "is
    // there route data at all, even if it still needs to be downloaded from
    // Firebase Storage first." Buttons enable off this one; hasGPX alone is
    // what gates code that reads the file directly.
    var hasRouteData: Bool { hasGPX || !(gpxURL ?? "").isEmpty }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    var distanceString: String { MeasurementUnits.distanceMiles(distance) }
    var maxSpeedString: String { MeasurementUnits.speedMph(maxSpeed) }
    var typeLabel: String {
        if rideCode == "TRACK" || !trackName.isEmpty { return "Track Session" }
        return isGroupRide ? "Group Ride" : "Solo Ride"
    }
}

// MARK: - Ride History Manager
class RideHistoryManager: ObservableObject {
    @Published var rides: [RideRecord] = []
    private var cloudHistoryRef: DatabaseReference?
    private var cloudHistoryHandle: DatabaseHandle?

    deinit {
        if let cloudHistoryHandle { cloudHistoryRef?.removeObserver(withHandle: cloudHistoryHandle) }
    }

    init() {
        loadRides()
        // Pulls in any ride recorded on a DIFFERENT install of this same
        // account (or lost to a reinstall of this one) — see syncFromCloud()
        // below. Metadata only; GPX bytes are fetched lazily per-ride by
        // resolveGPXPath() so opening Ride History never has to download
        // route data for rides nobody's asked to view.
        syncFromCloud()
    }

    static func recordRide(distance: Double, maxSpeed: Double, duration: String, isGroupRide: Bool, rideCode: String = "", isLeader: Bool = false, gpxFilePath: String? = nil, maxLeanAngle: Double = 0, analytics: RideAnalyticsSummary? = nil, bikeId: String? = nil) {
        let ride = RideRecord(
            id: UUID().uuidString, date: Date(), distance: distance, maxSpeed: maxSpeed,
            duration: duration, rideCode: rideCode, gpxFilePath: gpxFilePath,
            maxLeanAngle: maxLeanAngle, analytics: analytics,
            isGroupRide: isGroupRide, isLeader: isLeader, bikeId: bikeId
        )
        var existing: [RideRecord] = []
        if let data = UserDefaults.standard.data(forKey: "rideHistory"),
           let decoded = try? JSONDecoder().decode([RideRecord].self, from: data) {
            existing = decoded
        }
        existing.insert(ride, at: 0)
        if let encoded = try? JSONEncoder().encode(existing) {
            UserDefaults.standard.set(encoded, forKey: "rideHistory")
        }
        syncRideToCloud(ride)
    }

    static func recordTrackSession(id: String, trackName: String, laps: [Double], lapStartTimestamps: [Int64], distance: Double, maxSpeed: Double, duration: String, gpxFilePath: String?, bikeId: String?) {
        let ride = RideRecord(id: id, date: Date(), distance: distance, maxSpeed: maxSpeed,
                              duration: duration, rideCode: "TRACK", gpxFilePath: gpxFilePath,
                              isGroupRide: false, bikeId: bikeId, trackName: trackName,
                              lapTimes: laps, lapStartTimestamps: lapStartTimestamps)
        var existing: [RideRecord] = []
        if let data = UserDefaults.standard.data(forKey: "rideHistory") {
            existing = (try? JSONDecoder().decode([RideRecord].self, from: data)) ?? []
        }
        existing.removeAll { $0.id == id }
        existing.insert(ride, at: 0)
        if let encoded = try? JSONEncoder().encode(existing) { UserDefaults.standard.set(encoded, forKey: "rideHistory") }
        syncRideToCloud(ride)
    }

    func addRide(_ ride: RideRecord) { rides.insert(ride, at: 0); saveRides() }

    func saveRides() {
        if let encoded = try? JSONEncoder().encode(rides) {
            UserDefaults.standard.set(encoded, forKey: "rideHistory")
        }
    }

    func loadRides() {
        if let data = UserDefaults.standard.data(forKey: "rideHistory"),
           let decoded = try? JSONDecoder().decode([RideRecord].self, from: data) {
            rides = decoded
        }
    }

    func deleteRide(id: String) {
        if let ride = rides.first(where: { $0.id == id }), let path = ride.gpxFilePath {
            GPXStorage.remove(path)
        }
        rides.removeAll { $0.id == id }
        saveRides()
        Self.deleteRideFromCloud(id: id)
    }

    // MARK: - Cloud sync (Aug 27, 2026)
    //
    // Ride records used to live only in UserDefaults, and GPX files only in
    // this install's local Documents folder — nothing about a past ride was
    // ever written anywhere tied to the account. Uninstalling (or logging
    // into the same account on a different phone) permanently lost every
    // ride, even though the account itself was never touched. This mirrors
    // the same shape already used for profile photos (FirebaseManager's
    // uploadProfileImage): ride METADATA (everything except the local-only
    // gpxFilePath) goes to Realtime Database at users/{uid}/rideHistory/{id};
    // the GPX file itself goes to Firebase Storage and its download URL is
    // stitched back onto that same record as gpxURL once the upload finishes.

    private static func syncRideToCloud(_ ride: RideRecord) {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        // gpxFilePath is a filename inside THIS install's local container —
        // meaningless (and potentially colliding) on another install, so the
        // cloud copy never carries it. gpxURL is what a fresh install uses
        // to fetch the real file back.
        var cloudRide = ride
        cloudRide.gpxFilePath = nil
        guard let data = try? JSONEncoder().encode(cloudRide),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let rideRef = Database.database().reference().child("users").child(uid).child("rideHistory").child(ride.id)
        rideRef.setValue(dict)

        guard let path = ride.gpxFilePath, GPXStorage.exists(path), let gpxData = GPXStorage.contents(path) else { return }
        let storageRef = Storage.storage().reference().child("users/\(uid)/rides/\(ride.id).gpx")
        let metadata = StorageMetadata()
        metadata.contentType = "application/gpx+xml"
        storageRef.putData(gpxData, metadata: metadata) { _, error in
            guard error == nil else { return }
            storageRef.downloadURL { url, _ in
                guard let urlString = url?.absoluteString else { return }
                rideRef.updateChildValues(["gpxURL": urlString])
            }
        }
    }

    private static func deleteRideFromCloud(id: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        Database.database().reference().child("users").child(uid).child("rideHistory").child(id).removeValue()
        Storage.storage().reference().child("users/\(uid)/rides/\(id).gpx").delete(completion: nil)
    }

    /// Live, cloud-canonical history. A one-shot read could see Android's
    /// metadata before its GPX upload callback attached `gpxURL`, leaving
    /// Replay/Telemetry/Export disabled for the lifetime of this screen. It
    /// also could not reflect a deletion performed on the other platform.
    func syncFromCloud() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        if let cloudHistoryHandle { cloudHistoryRef?.removeObserver(withHandle: cloudHistoryHandle) }
        let ref = Database.database().reference().child("users").child(uid).child("rideHistory")
        cloudHistoryRef = ref
        cloudHistoryHandle = ref.observe(.value) { [weak self] snapshot in
            guard let self else { return }
            let children = snapshot.value as? [String: Any] ?? [:]
            let localByID = Dictionary(uniqueKeysWithValues: self.rides.map { ($0.id, $0) })
            var remote: [RideRecord] = []
            for (id, value) in children {
                guard let dict = value as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: dict),
                      var ride = try? JSONDecoder().decode(RideRecord.self, from: data)
                else { continue }
                // Preserve only the device-local cache pointer. All shared
                // metadata, including gpxURL, is owned by Firebase.
                ride.gpxFilePath = localByID[id]?.gpxFilePath
                remote.append(ride)
            }
            // Keep only genuinely pending offline recordings. A downloaded
            // cross-platform GPX has a URL and therefore must disappear when
            // another device deletes its Firebase record.
            let pendingLocal = self.rides.filter {
                children[$0.id] == nil && $0.gpxURL == nil && $0.hasGPX
            }
            DispatchQueue.main.async {
                self.rides = (remote + pendingLocal).sorted { $0.date > $1.date }
                self.saveRides()
                self.recoverMissingCloudGPX(uid: uid)
            }
        }
    }

    /// Android uploads to a deterministic shared Storage path. If Android
    /// was backgrounded after upload but before its URL patch completed,
    /// recover that object and repair the record instead of hiding replay.
    private func recoverMissingCloudGPX(uid: String) {
        for ride in rides where !ride.hasRouteData {
            let storageRef = Storage.storage().reference().child("users/\(uid)/rides/\(ride.id).gpx")
            storageRef.downloadURL { url, _ in
                guard let url else { return }
                Database.database().reference()
                    .child("users").child(uid).child("rideHistory").child(ride.id)
                    .updateChildValues(["gpxURL": url.absoluteString])
            }
        }
    }

    /// Gets a ride's GPX onto local disk and returns the (now-valid) local
    /// filename — instantly if it's already local, otherwise downloads it
    /// from `ride.gpxURL` first and caches it so this only happens once per
    /// ride per install. Every screen that needs an actual GPX file (map,
    /// replay, telemetry, export) should go through this rather than reading
    /// `ride.gpxFilePath` directly, so a ride restored from the cloud works
    /// the same as one recorded on this install.
    func resolveGPXPath(for ride: RideRecord, completion: @escaping (String?) -> Void) {
        if let path = ride.gpxFilePath, GPXStorage.exists(path) {
            completion(path)
            return
        }
        guard let urlString = ride.gpxURL, let url = URL(string: urlString) else {
            completion(nil)
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data, let filename = GPXStorage.saveDownloaded(data, rideID: ride.id) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            DispatchQueue.main.async {
                if let idx = self.rides.firstIndex(where: { $0.id == ride.id }) {
                    self.rides[idx].gpxFilePath = filename
                    self.saveRides()
                }
                completion(filename)
            }
        }.resume()
    }

    var totalMiles: Double { rides.reduce(0) { $0 + $1.distance } }
    var totalRides: Int { rides.count }
    var bestSpeed: Double { rides.map { $0.maxSpeed }.max() ?? 0 }
    var soloRideCount: Int { rides.filter { !$0.isGroupRide }.count }
    var groupRideCount: Int { rides.filter { $0.isGroupRide }.count }
    var ledRideCount: Int { rides.filter { $0.isGroupRide && $0.isLeader }.count }
    var joinedRideCount: Int { rides.filter { $0.isGroupRide && !$0.isLeader }.count }
}

// MARK: - Ride History Filter
enum RideHistoryFilter: String, CaseIterable, Hashable {
    case all = "All"
    case solo = "Solo"
    case led = "Led"
    case joined = "Joined"

    func matches(_ ride: RideRecord) -> Bool {
        switch self {
        case .all: return true
        case .solo: return !ride.isGroupRide
        case .led: return ride.isGroupRide && ride.isLeader
        case .joined: return ride.isGroupRide && !ride.isLeader
        }
    }
}

// MARK: - Ride History View (Full Bleed Web Redesign)
struct RideHistoryView: View {
    @StateObject private var historyManager = RideHistoryManager()
    // Aug 27, 2026 — Grok re-review, small cleanup: was its own private
    // UserProfileManager() — a duplicate instance alongside PackRideApp's
    // app-wide one. RideHistoryView is only ever pushed from ContentView's
    // navigation tree, which already has the shared instance in its
    // environment.
    @EnvironmentObject private var profileManager: UserProfileManager
    @AppStorage("riderName") var riderName: String = ""
    @AppStorage("avatarURL") var avatarURL: String = ""

    @State private var selectedFilter: RideHistoryFilter = .all
    @State private var isSelectionMode = false
    @State private var selectedRideIDs: Set<String> = []
    @State private var showBulkDeleteConfirm = false
    @State private var showNotifications = false
    @State private var showNeedHelp = false

    var initials: String { riderName.isEmpty ? "R" : riderName.rideInitials }
    var filteredRides: [RideRecord] { historyManager.rides.filter { selectedFilter.matches($0) } }

    private func toggleSelection(_ id: String) {
        if selectedRideIDs.contains(id) { selectedRideIDs.remove(id) } else { selectedRideIDs.insert(id) }
    }

    private func enterSelectionMode(selecting id: String) {
        withAnimation(.easeOut(duration: 0.15)) {
            isSelectionMode = true
            selectedRideIDs = [id]
        }
    }

    private func exitSelectionMode() {
        withAnimation(.easeOut(duration: 0.15)) {
            isSelectionMode = false
            selectedRideIDs.removeAll()
        }
    }

    private func deleteSelectedRides() {
        withAnimation {
            for id in selectedRideIDs { historyManager.deleteRide(id: id) }
        }
        exitSelectionMode()
    }

    var body: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()

            VStack(spacing: 0) {
                // MARK: - Top Full-Bleed Web Navigation Header
                webHeaderBar

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {

                        // MARK: - All Time Stats Block (Web-Style Card)
                        VStack(alignment: .leading, spacing: 14) {
                            Text("ALL TIME STATS")
                                .font(.system(size: 10, weight: .heavy))
                                .foregroundColor(.prMuted)
                                .tracking(2)

                            HStack(spacing: 0) {
                                AllTimeCard(icon: "flag.checkered", value: "\(historyManager.totalRides)", label: "Total Rides", color: .prCoral)
                                Rectangle().fill(Color.prBorder).frame(width: 1)
                                AllTimeCard(
                                    icon: "road.lanes",
                                    value: MeasurementUnits.distanceMiles(historyManager.totalMiles, decimals: 0).components(separatedBy: " ").first ?? "0",
                                    label: MeasurementUnits.current == .metric ? "Total Kilometres" : "Total Miles",
                                    color: .prTeal
                                )
                                Rectangle().fill(Color.prBorder).frame(width: 1)
                                AllTimeCard(
                                    icon: "gauge.high",
                                    value: MeasurementUnits.speedMph(historyManager.bestSpeed).components(separatedBy: " ").first ?? "0",
                                    label: MeasurementUnits.current == .metric ? "Best km/h" : "Best mph",
                                    color: Color(red: 0.541, green: 0.4, blue: 0.694)
                                )
                            }
                            .background(Color.prFieldBg)

                            // MARK: - Repositioned Action Links Bar
                            HStack(spacing: 0) {
                                NavigationLink(destination: BadgesView()) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "trophy.fill")
                                            .font(.system(size: 12, weight: .semibold))
                                        Text("Badges")
                                            .font(.system(size: 13, weight: .semibold))
                                    }
                                    .foregroundColor(.prCoral)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 13)
                                    .background(Color.prFieldBg)
                                }
                                Rectangle().fill(Color.prBorder).frame(width: 1)

                                NavigationLink(destination: RidingDigestView()) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "calendar")
                                            .font(.system(size: 12, weight: .semibold))
                                        Text("Digest")
                                            .font(.system(size: 13, weight: .semibold))
                                    }
                                    .foregroundColor(.prCoral)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 13)
                                    .background(Color.prFieldBg)
                                }

                                if historyManager.rides.contains(where: { $0.analytics != nil }) {
                                    Rectangle().fill(Color.prBorder).frame(width: 1)
                                    NavigationLink(destination: RideTrendsView(rides: historyManager.rides)) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "chart.line.uptrend.xyaxis")
                                                .font(.system(size: 12, weight: .semibold))
                                            Text("Trends")
                                                .font(.system(size: 13, weight: .semibold))
                                        }
                                        .foregroundColor(.prCoral)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 13)
                                        .background(Color.prFieldBg)
                                    }
                                }
                            }
                            .overlay(Rectangle().fill(Color.prBorder).frame(height: 1), alignment: .top)
                            .overlay(Rectangle().fill(Color.prBorder).frame(height: 1), alignment: .bottom)
                        }
                        .padding(16)
                        .background(Color.prCardBg)

                        // MARK: - Recent Rides Section
                        VStack(alignment: .leading, spacing: 14) {
                            if isSelectionMode {
                                selectionToolbar.padding(.horizontal, 16).padding(.top, 14)
                            } else {
                                Text("RECENT RIDES")
                                    .font(.system(size: 10, weight: .heavy))
                                    .foregroundColor(.prMuted).tracking(2)
                                    .padding(.horizontal, 16)
                                    .padding(.top, 14)
                            }

                            if historyManager.groupRideCount > 0 && historyManager.soloRideCount > 0 {
                                HistoryFilterBar(selected: $selectedFilter, manager: historyManager)
                                    .padding(.horizontal, 16)
                            }

                            if historyManager.rides.isEmpty {
                                VStack(spacing: 14) {
                                    ZStack {
                                        Circle().fill(Color.prCoralSoft).frame(width: 74, height: 74)
                                        Image(systemName: "flag.checkered").font(.system(size: 26)).foregroundColor(.prCoral)
                                    }
                                    Text("No rides recorded yet").font(.system(size: 16, weight: .bold)).foregroundColor(.prInk)
                                    Text("Start a solo or group ride to view telemetry and routes here.")
                                        .font(.system(size: 13)).foregroundColor(.prMuted)
                                        .multilineTextAlignment(.center).padding(.horizontal, 32)
                                }
                                .padding(.vertical, 40)
                                .frame(maxWidth: .infinity)
                                .background(Color.prCardBg)
                            } else if filteredRides.isEmpty {
                                VStack(spacing: 10) {
                                    Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 26)).foregroundColor(.prMuted)
                                    Text("No \(selectedFilter.rawValue.lowercased()) rides yet")
                                        .font(.system(size: 13, weight: .medium)).foregroundColor(.prMuted)
                                }
                                .padding(.vertical, 30)
                                .frame(maxWidth: .infinity)
                                .background(Color.prCardBg)
                            } else {
                                // Aug 27, 2026 — flat full-bleed row list instead of a
                                // stack of separately-floating rounded cards: rows sit
                                // flush against each other on one continuous
                                // Color.prCardBg band, edge to edge, split by a hairline
                                // divider — reads as a web page table, not a stack of
                                // app "cards."
                                VStack(spacing: 0) {
                                    ForEach(Array(filteredRides.enumerated()), id: \.element.id) { index, ride in
                                        if index > 0 {
                                            Rectangle().fill(Color.prBorder).frame(height: 1)
                                        }
                                        RideHistoryCard(
                                            ride: ride,
                                            onDelete: {
                                                withAnimation { historyManager.deleteRide(id: ride.id) }
                                            },
                                            isSelectionMode: isSelectionMode,
                                            isSelected: selectedRideIDs.contains(ride.id),
                                            onToggleSelect: { toggleSelection(ride.id) },
                                            onEnterSelectionMode: { enterSelectionMode(selecting: ride.id) },
                                            resolveGPX: { completion in historyManager.resolveGPXPath(for: ride, completion: completion) }
                                        )
                                    }
                                }
                                .background(Color.prCardBg)
                            }
                        }
                        .padding(.bottom, 20)
                    }
                }

                AdBannerFooter()
            }
            .navigationBarHidden(true)
        }
        .sheet(isPresented: $showNotifications) {
            NotificationCenterView(profileManager: profileManager)
        }
        .fullScreenCover(isPresented: $showNeedHelp) {
            NeedHelpView()
        }
        .alert("Delete \(selectedRideIDs.count) Ride\(selectedRideIDs.count == 1 ? "" : "s")?", isPresented: $showBulkDeleteConfirm) {
            Button("Delete", role: .destructive) { deleteSelectedRides() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the selected rides and GPX data. This action cannot be undone.")
        }
    }

    // MARK: - Web Header Bar
    private var webHeaderBar: some View {
        HStack(spacing: 12) {
            Text("PACKRIDE")
                .font(.system(size: 13, weight: .heavy))
                .tracking(2.4)
                .foregroundColor(.prInk)
            Spacer()
            headerIconButton(system: "bell.fill", badge: profileManager.followRequests.count) {
                showNotifications = true
            }
            headerIconButton(system: "exclamationmark.triangle.fill") {
                showNeedHelp = true
            }
            ZStack {
                if !avatarURL.isEmpty, let url = URL(string: avatarURL) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Circle().fill(Color.prCoral)
                    }
                } else {
                    Circle().fill(Color.prCoral)
                    Text(initials).font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(Circle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.prCardBg)
        .overlay(Rectangle().fill(Color.prBorder).frame(height: 1), alignment: .bottom)
    }

    private func headerIconButton(system: String, badge: Int = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: system)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.prInk)
                    .frame(width: 32, height: 32)
                    .background(Color.prFieldBg)
                    .clipShape(Circle())
                if badge > 0 {
                    Text("\(min(badge, 9))")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 14, height: 14)
                        .background(Color(red: 0.827, green: 0.231, blue: 0.173))
                        .clipShape(Circle())
                        .offset(x: 2, y: -2)
                }
            }
        }
    }

    // MARK: - Selection Toolbar
    private var selectionToolbar: some View {
        HStack {
            Button(action: { exitSelectionMode() }) {
                Text("Cancel").font(.system(size: 13, weight: .semibold)).foregroundColor(.prMuted)
            }
            Spacer()
            Text("\(selectedRideIDs.count) Selected")
                .font(.system(size: 12, weight: .heavy)).foregroundColor(.prInk).tracking(1)
            Spacer()
            Button(action: { showBulkDeleteConfirm = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "trash").font(.system(size: 11))
                    Text("Delete").font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(selectedRideIDs.isEmpty ? .prMuted : Color(red: 0.827, green: 0.231, blue: 0.173))
            }
            .disabled(selectedRideIDs.isEmpty)
        }
    }
}

// MARK: - All Time Card
struct AllTimeCard: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    init(icon: String, value: String, label: String, color: Color = .prCoral) {
        self.icon = icon; self.value = value; self.label = label; self.color = color
    }

    // Aug 27, 2026 — no background/corner radius of its own anymore: these
    // sit flush in a shared stat bar (see the "ALL TIME STATS" HStack),
    // separated by hairline dividers instead of each being its own rounded
    // box, matching the flat/web-page pass across this screen.
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 18)).foregroundColor(color)
            Text(value).font(.system(size: 20, weight: .bold, design: .monospaced)).foregroundColor(.prInk)
            Text(label).font(.system(size: 10, weight: .medium)).foregroundColor(.prMuted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

// MARK: - History Filter Bar
struct HistoryFilterBar: View {
    @Binding var selected: RideHistoryFilter
    @ObservedObject var manager: RideHistoryManager

    func count(for filter: RideHistoryFilter) -> Int {
        switch filter {
        case .all: return manager.totalRides
        case .solo: return manager.soloRideCount
        case .led: return manager.ledRideCount
        case .joined: return manager.joinedRideCount
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(RideHistoryFilter.allCases, id: \.self) { filter in
                let isSelected = selected == filter
                Button(action: { withAnimation(.easeOut(duration: 0.15)) { selected = filter } }) {
                    HStack(spacing: 5) {
                        Text(filter.rawValue).font(.system(size: 12, weight: .semibold))
                        Text("\(count(for: filter))").font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(isSelected ? .white.opacity(0.85) : .prMuted)
                    }
                    .foregroundColor(isSelected ? .white : .prInk)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(isSelected ? Color.prCoral : Color.prCardBg)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.prBorder, lineWidth: isSelected ? 0 : 1))
                    .cornerRadius(10)
                }
            }
        }
    }
}

// MARK: - Ride History Card
struct RideHistoryCard: View {
    let ride: RideRecord
    var onDelete: (() -> Void)? = nil
    var isSelectionMode: Bool = false
    var isSelected: Bool = false
    var onToggleSelect: (() -> Void)? = nil
    var onEnterSelectionMode: (() -> Void)? = nil
    // Resolves this ride's GPX to a local filename, downloading it from
    // Firebase Storage first if it isn't cached on this install yet (see
    // RideHistoryManager.resolveGPXPath). Every action below that needs the
    // actual file goes through this instead of reading ride.gpxFilePath
    // directly, so a ride restored from the cloud works the same as one
    // recorded on this install.
    var resolveGPX: (@escaping (String?) -> Void) -> Void = { completion in completion(nil) }

    @AppStorage("riderName") var riderName: String = "Rider"
    @State private var isExpanded = false
    @State private var showRoute = false
    @State private var showReplay = false
    @State private var showDeleteConfirm = false
    @State private var showPostToFeed = false
    @State private var showParticipantStats = false
    @State private var showReplayModePicker = false
    @State private var showTelemetryMap = false
    @State private var isResolvingGPX = false

    @State private var swipeOffset: CGFloat = 0
    private let swipeRevealWidth: CGFloat = 76

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 15)
            .onChanged { value in
                guard !isSelectionMode, !isExpanded else { return }
                guard value.translation.width < 0 || swipeOffset < 0 else { return }
                swipeOffset = max(-swipeRevealWidth, min(0, value.translation.width))
            }
            .onEnded { value in
                guard !isSelectionMode, !isExpanded else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    swipeOffset = value.translation.width < -swipeRevealWidth / 2 ? -swipeRevealWidth : 0
                }
            }
    }

    // Resolves this ride's GPX (downloading it from the cloud first if this
    // install doesn't have it cached yet) and only then runs `action` — so a
    // sheet/cover never gets presented against a not-yet-downloaded ride.
    // The array-mutation that happens inside resolveGPXPath finishes before
    // its completion fires, so by the time `action` runs, `ride.gpxFilePath`
    // is already valid on the next render.
    private func withGPX(_ action: @escaping () -> Void) {
        guard !isResolvingGPX else { return }
        isResolvingGPX = true
        resolveGPX { path in
            isResolvingGPX = false
            guard path != nil else { return }
            action()
        }
    }

    // Same as above, but for actions (like the share sheet) that need the
    // resolved filename directly rather than relying on a re-render. Named
    // distinctly from withGPX(_:) rather than overloaded — a trailing
    // closure with no declared parameters type-checks against either an
    // () -> Void or a (String) -> Void overload, which would make every
    // call site ambiguous.
    private func withGPXPath(_ action: @escaping (String) -> Void) {
        guard !isResolvingGPX else { return }
        isResolvingGPX = true
        resolveGPX { path in
            isResolvingGPX = false
            guard let path else { return }
            action(path)
        }
    }

    private var deleteRevealButton: some View {
        HStack(spacing: 0) {
            Spacer()
            Button(action: {
                withAnimation(.spring()) { swipeOffset = 0 }
                showDeleteConfirm = true
            }) {
                VStack(spacing: 4) {
                    Image(systemName: "trash.fill").font(.system(size: 17))
                    Text("Delete").font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(width: swipeRevealWidth)
                .frame(maxHeight: .infinity)
            }
        }
        .background(Color(red: 0.827, green: 0.231, blue: 0.173))
    }

    var body: some View {
        ZStack {
            if !isSelectionMode { deleteRevealButton }

            VStack(spacing: 0) {
                Button(action: {
                    if swipeOffset != 0 { withAnimation(.spring()) { swipeOffset = 0 }; return }
                    if isSelectionMode { onToggleSelect?(); return }
                    withAnimation(.spring()) { isExpanded.toggle() }
                }) {
                    HStack(spacing: 14) {
                        if isSelectionMode {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20))
                                .foregroundColor(isSelected ? .prCoral : .prMuted)
                        }
                        ZStack {
                            Circle()
                                .fill(!ride.isGroupRide ? Color.prCoralSoft : Color(red: 0.906, green: 0.937, blue: 0.945))
                                .frame(width: 44, height: 44)
                            Image(systemName: !ride.isGroupRide ? "person.fill" : "person.3.fill")
                                .font(.system(size: 16))
                                .foregroundColor(!ride.isGroupRide ? .prCoral : .prTeal)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(ride.typeLabel)
                                    .font(.system(size: 14, weight: .semibold)).foregroundColor(.prInk)
                                if ride.isGroupRide {
                                    Text(ride.isLeader ? "LEADER" : "JOINED")
                                        .font(.system(size: 9, weight: .heavy)).tracking(0.5)
                                        .foregroundColor(ride.isLeader ? .prCoral : .prTeal)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(ride.isLeader ? Color.prCoralSoft : Color(red: 0.906, green: 0.937, blue: 0.945))
                                        .cornerRadius(5)
                                }
                                Spacer()
                                Text(ride.distanceString).font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundColor(.prCoral)
                            }
                            HStack {
                                Text(ride.formattedDate).font(.system(size: 12)).foregroundColor(.prMuted)
                                Spacer()
                                Text(ride.duration).font(.system(size: 12)).foregroundColor(.prMuted)
                            }
                        }

                        if !isSelectionMode {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 12)).foregroundColor(.prMuted)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }

                if isExpanded {
                    VStack(spacing: 12) {
                        Rectangle().fill(Color.prBorder).frame(height: 1)

                        HStack(spacing: 0) {
                            DetailStat(label: "Top Speed", value: ride.maxSpeedString)
                            DetailStat(label: "Duration", value: ride.duration)
                            DetailStat(label: "Distance", value: ride.distanceString)
                        }

                        if let analytics = ride.analytics {
                            Button(action: {
                                withGPX { showTelemetryMap = true }
                            }) {
                                RideScoreCard(analytics: analytics, maxLeanAngle: ride.maxLeanAngle, showChevron: ride.hasRouteData)
                            }
                            .disabled(!ride.hasRouteData || isResolvingGPX)
                        }

                        HStack(spacing: 8) {
                            RideActionIconButton(
                                icon: "square.and.arrow.up",
                                foreground: .prCoral,
                                background: Color.prCoralSoft,
                                accessibilityLabel: "Share Stats"
                            ) {
                                PackRideShareCard.shareRideStats(ride)
                            }

                            RideActionIconButton(
                                icon: "doc.badge.arrow.up",
                                foreground: ride.hasRouteData ? .white : .prMuted,
                                background: ride.hasRouteData ? Color.prCoral : Color(red: 0.941, green: 0.925, blue: 0.898),
                                accessibilityLabel: "Export GPX",
                                isDisabled: !ride.hasRouteData || isResolvingGPX
                            ) {
                                withGPXPath { path in
                                    let url = GPXStorage.resolve(path)
                                    let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                                    if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                                       let vc = scene.windows.first?.rootViewController { vc.present(av, animated: true) }
                                }
                            }

                            RideActionIconButton(
                                icon: "map.fill",
                                foreground: ride.hasRouteData ? .white : .prMuted,
                                background: ride.hasRouteData ? Color.prTeal : Color(red: 0.941, green: 0.925, blue: 0.898),
                                accessibilityLabel: ride.hasRouteData ? "View Route on Map" : "No route data recorded",
                                isDisabled: !ride.hasRouteData || isResolvingGPX
                            ) {
                                withGPX { showRoute = true }
                            }

                            if ride.hasRouteData {
                                RideActionIconButton(
                                    icon: "play.circle.fill",
                                    foreground: .prCoral,
                                    background: Color.prCoralSoft,
                                    accessibilityLabel: "Replay Ride",
                                    isDisabled: isResolvingGPX
                                ) {
                                    withGPX {
                                        ride.isGroupRide ? (showReplayModePicker = true) : (showReplay = true)
                                    }
                                }
                            }

                            RideActionIconButton(
                                icon: "newspaper.fill",
                                foreground: .white,
                                background: Color.prInkFixed,
                                accessibilityLabel: "Post to Feed"
                            ) {
                                showPostToFeed = true
                            }

                            RideActionIconButton(
                                icon: "trash",
                                foreground: Color(red: 0.827, green: 0.231, blue: 0.173),
                                background: Color(red: 0.988, green: 0.922, blue: 0.906),
                                accessibilityLabel: "Delete Ride"
                            ) {
                                showDeleteConfirm = true
                            }
                        }
                        .padding(.bottom, 4)

                        if ride.isGroupRide && !ride.rideCode.isEmpty {
                            Button(action: { showParticipantStats = true }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "person.3.fill").font(.system(size: 14))
                                    Text("View All Participants' Stats").font(.system(size: 14, weight: .semibold))
                                }
                                .foregroundColor(.prTeal)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color(red: 0.906, green: 0.937, blue: 0.945))
                                .cornerRadius(10)
                            }
                        }

                        HStack(spacing: 6) {
                            Image(systemName: "info.circle").font(.system(size: 10)).foregroundColor(.prMuted)
                            Text(ride.hasGPX ? "GPX includes route, speed, elevation & G-force." : "Rides recorded after this update will have full route data.")
                                .font(.system(size: 10)).foregroundColor(.prMuted)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
            .background(Color.prCardBg)
            .offset(x: isSelectionMode ? 0 : swipeOffset)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    guard !isSelectionMode, !isExpanded else { return }
                    onEnterSelectionMode?()
                }
            )
            .gesture(swipeGesture)
        }
        .alert("Delete this ride?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { onDelete?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove this ride and its GPX data.")
        }
        .fullScreenCover(isPresented: $showRoute) {
            if ride.hasGPX, let path = ride.gpxFilePath {
                GPXRouteMapView(gpxFilePath: path, rideName: ride.typeLabel, rideDate: ride.formattedDate)
            }
        }
        .fullScreenCover(isPresented: $showReplay) {
            if ride.hasGPX, let path = ride.gpxFilePath {
                RideReplayView(gpxFilePath: path, rideName: ride.typeLabel, rideDate: ride.formattedDate)
            }
        }
        .fullScreenCover(isPresented: $showTelemetryMap) {
            if ride.hasGPX, let path = ride.gpxFilePath {
                RideTelemetryMapView(gpxFilePath: path, rideName: ride.typeLabel, rideDate: ride.formattedDate)
            }
        }
        .sheet(isPresented: $showPostToFeed) {
            PostToFeedSheet(
                distance: ride.distance, duration: ride.duration, gpxFilePath: ride.gpxFilePath,
                defaultTitle: "\(riderName.rideInitials)'s Ride \(ride.formattedDate)"
            )
        }
        .sheet(isPresented: $showParticipantStats) {
            ParticipantsStatsView(rideCode: ride.rideCode, myGPXPath: ride.gpxFilePath, myName: riderName, myInitials: riderName.rideInitials)
        }
        .sheet(isPresented: $showReplayModePicker) {
            ReplayModeSheet(rideCode: ride.rideCode, myGPXPath: ride.gpxFilePath, myName: riderName, myInitials: riderName.rideInitials)
        }
    }
}

// MARK: - Ride Action Icon Button
struct RideActionIconButton: View {
    let icon: String
    let foreground: Color
    let background: Color
    let accessibilityLabel: String
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(foreground)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(background)
                .cornerRadius(10)
        }
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Detail Stat
struct DetailStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 15, weight: .bold, design: .monospaced)).foregroundColor(.prInk)
            Text(label).font(.system(size: 10, weight: .medium)).foregroundColor(.prMuted)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - GPX Route Map View
struct GPXRouteMapView: View {
    let gpxFilePath: String
    let rideName: String
    let rideDate: String
    @Environment(\.dismiss) var dismiss
    @State private var mapStyleIndex = 1 // Standard by default
    @State private var trackPoints: [(lat: Double, lng: Double, speed: Double, elevation: Double, gforce: Double)] = []
    @State private var timingPoint: CLLocationCoordinate2D?
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.3318, longitude: -122.0312),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )

    var maxSpeed: Double { trackPoints.map { $0.speed * 2.23694 }.max() ?? 0 }
    var maxElevation: Double { trackPoints.map { $0.elevation * 3.28084 }.max() ?? 0 }
    var maxGForce: Double { trackPoints.map { $0.gforce }.max() ?? 1.0 }

    var body: some View {
        ZStack {
            GPXMapRepresentable(trackPoints: trackPoints, region: $region, mapStyleIndex: mapStyleIndex, timingPoint: timingPoint)
                .ignoresSafeArea()

            LinearGradient(
                colors: [.black.opacity(0.58), .clear],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 38, height: 38)
                            .background(Color.black.opacity(0.34), in: Circle())
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("ROUTE MAP")
                            .font(.system(size: 10, weight: .heavy))
                            .tracking(2.2)
                            .foregroundColor(.white.opacity(0.72))
                        Text(rideName)
                            .font(.system(size: 19, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(rideDate)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.68))
                    }

                    Spacer()

                    Text("FULL ROUTE")
                        .font(.system(size: 10, weight: .heavy))
                        .tracking(1.4)
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.prCoral.opacity(0.88), in: Capsule())
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)

                HStack {
                    Spacer()
                    MapStylePickerView(selectedIndex: $mapStyleIndex)
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)

                Spacer()

                HStack(spacing: 10) {
                    RouteMetric(value: MeasurementUnits.speedMph(maxSpeed), unit: "", label: "TOP SPEED")
                    RouteMetric(value: String(format: "%.0f", maxElevation), unit: "ft", label: "MAX ELEV.")
                    RouteMetric(value: String(format: "%.1f", maxGForce), unit: "G", label: "MAX G")
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
        }
        .onAppear { parseGPX() }
    }

    func parseGPX() {
        guard let data = GPXStorage.contents(gpxFilePath),
              let xmlString = String(data: data, encoding: .utf8) else { return }

        var points: [(lat: Double, lng: Double, speed: Double, elevation: Double, gforce: Double)] = []

        if let waypoint = xmlString.range(of: #"<wpt lat="([\-\d.]+)" lon="([\-\d.]+)"><name>PackRide Start/Finish</name>"#, options: .regularExpression) {
            let text = String(xmlString[waypoint])
            let values = text.matches(of: /[-]?\d+(?:\.\d+)?/).compactMap { Double($0.output) }
            if values.count >= 2 { timingPoint = CLLocationCoordinate2D(latitude: values[0], longitude: values[1]) }
        }

        let blocks = xmlString.components(separatedBy: "<trkpt ")
        for block in blocks.dropFirst() {
            var lat = 0.0, lng = 0.0, ele = 0.0, spd = 0.0, gf = 1.0

            if let latRange = block.range(of: #"lat="([\-\d.]+)"# , options: .regularExpression),
               let lngRange = block.range(of: #"lon="([\-\d.]+)"# , options: .regularExpression) {
                let latStr = block[latRange].replacingOccurrences(of: "lat=", with: "").replacingOccurrences(of: "\"", with: "")
                let lngStr = block[lngRange].replacingOccurrences(of: "lon=", with: "").replacingOccurrences(of: "\"", with: "")
                lat = Double(latStr) ?? 0
                lng = Double(lngStr) ?? 0
            }

            if let eleRange = block.range(of: #"<ele>([\-\d.]+)</ele>"#, options: .regularExpression) {
                let eleStr = block[eleRange].replacingOccurrences(of: "<ele>", with: "").replacingOccurrences(of: "</ele>", with: "")
                ele = Double(eleStr) ?? 0
            }

            if let spdRange = block.range(of: #"<speed>([\-\d.]+)</speed>"#, options: .regularExpression) {
                let spdStr = block[spdRange].replacingOccurrences(of: "<speed>", with: "").replacingOccurrences(of: "</speed>", with: "")
                spd = Double(spdStr) ?? 0
            }

            if let gfRange = block.range(of: #"<packride:gforce>([\-\d.]+)</packride:gforce>"#, options: .regularExpression) {
                let gfStr = block[gfRange].replacingOccurrences(of: "<packride:gforce>", with: "").replacingOccurrences(of: "</packride:gforce>", with: "")
                gf = Double(gfStr) ?? 1.0
            }

            if lat != 0 && lng != 0 {
                points.append((lat: lat, lng: lng, speed: spd, elevation: ele, gforce: gf))
            }
        }

        trackPoints = points

        if let first = points.first {
            let lats = points.map { $0.lat }
            let lngs = points.map { $0.lng }
            let minLat = lats.min() ?? first.lat
            let maxLat = lats.max() ?? first.lat
            let minLng = lngs.min() ?? first.lng
            let maxLng = lngs.max() ?? first.lng
            region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2),
                span: MKCoordinateSpan(
                    latitudeDelta: max(maxLat - minLat, 0.001) * 1.25,
                    longitudeDelta: max(maxLng - minLng, 0.001) * 1.25
                )
            )
        }
    }
}

// MARK: - Route Metric Pill
struct RouteMetric: View {
    let value: String
    let unit: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Text(unit)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.68))
            }
            Text(label)
                .font(.system(size: 9, weight: .heavy))
                .tracking(1.2)
                .foregroundColor(.white.opacity(0.52))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(Color.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.16), lineWidth: 1))
    }
}

// MARK: - GPX Map (UIKit wrapper)
struct GPXMapRepresentable: UIViewRepresentable {
    let trackPoints: [(lat: Double, lng: Double, speed: Double, elevation: Double, gforce: Double)]
    @Binding var region: MKCoordinateRegion
    var mapStyleIndex: Int = 2
    var timingPoint: CLLocationCoordinate2D? = nil

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        mapView.applyStyleIndex(mapStyleIndex)
        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)

        guard trackPoints.count > 1 else {
            mapView.setRegion(region, animated: true)
            return
        }

        let coords = trackPoints.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }

        if coords.count > 10 {
            let polyline = MKPolyline(coordinates: coords, count: coords.count)
            mapView.addOverlay(polyline, level: .aboveRoads)
        } else {
            for i in 0..<(coords.count - 1) {
                let request = MKDirections.Request()
                // Aug 28, 2026 — MKMapItem(location:address:) is iOS 26+ only;
                // the MKPlacemark-based initializer works on every MapKit version.
                request.source = MKMapItem(placemark: MKPlacemark(coordinate: coords[i]))
                request.destination = MKMapItem(placemark: MKPlacemark(coordinate: coords[i + 1]))
                request.transportType = .automobile
                MKDirections(request: request).calculate { response, _ in
                    if let route = response?.routes.first {
                        mapView.addOverlay(route.polyline, level: .aboveRoads)
                    } else {
                        let segment = MKPolyline(coordinates: [coords[i], coords[i + 1]], count: 2)
                        mapView.addOverlay(segment, level: .aboveRoads)
                    }
                }
            }
        }

        let startPin = MKPointAnnotation()
        startPin.coordinate = timingPoint ?? coords.first!
        startPin.title = timingPoint == nil ? "Recording Start" : "Start/Finish"
        mapView.addAnnotation(startPin)

        if timingPoint == nil {
            let endPin = MKPointAnnotation()
            endPin.coordinate = coords.last!
            endPin.title = "Recording Finish"
            mapView.addAnnotation(endPin)
        }

        var routeRect = MKMapRect.null
        for coordinate in coords {
            let point = MKMapPoint(coordinate)
            routeRect = routeRect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
        }
        if !routeRect.isNull {
            mapView.setVisibleMapRect(
                routeRect,
                edgePadding: UIEdgeInsets(top: 150, left: 28, bottom: 190, right: 28),
                animated: true
            )
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor(red: 0.886, green: 0.278, blue: 0.165, alpha: 1)
                renderer.lineWidth = 4
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard !(annotation is MKUserLocation) else { return nil }
            let view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "pin")
            let isStart = annotation.title == "Recording Start" || annotation.title == "Start/Finish"
            view.markerTintColor = isStart ? UIColor(red: 0.180, green: 0.620, blue: 0.357, alpha: 1) : UIColor(red: 0.827, green: 0.231, blue: 0.173, alpha: 1)
            view.glyphImage = isStart ? UIImage(systemName: "flag.fill") : UIImage(systemName: "flag.checkered")
            return view
        }
    }
}

#Preview {
    NavigationView { RideHistoryView() }
        .environmentObject(UserProfileManager())
}
