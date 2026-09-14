import SwiftUI
import MapKit
import CoreLocation
import Combine
import UIKit
import FirebaseDatabase

// MARK: - Rider Annotation
class RiderAnnotation: NSObject, MKAnnotation, Identifiable {
    let id: String
    let riderName: String
    let initials: String
    let speed: Double
    let isLeader: Bool
    let avatarURL: String
    dynamic var coordinate: CLLocationCoordinate2D

    init(id: String, riderName: String, initials: String, speed: Double, coordinate: CLLocationCoordinate2D,
         isLeader: Bool = false, avatarURL: String = "") {
        self.id = id
        self.riderName = riderName
        self.initials = initials
        self.speed = speed
        self.coordinate = coordinate
        self.isLeader = isLeader
        self.avatarURL = avatarURL
    }
}

// MARK: - Map View
// Aug 27, 2026 — Grok battery/perf audit, fix #1: this used to be preceded by
// its own MapLocationManager class (private CLLocationManager, requestPermission/
// locationManagerDidChangeAuthorization duplicating the exact same auto-start
// pattern fixed in SharedLoactionManager.swift). It was never actually
// instantiated anywhere — MapView below already uses
// SharedLocationManager.shared — so it was dead code sitting alongside a real
// GPS instance the whole app shares. Removed rather than fixed in place.
struct MapView: View {
    @AppStorage("riderName") var riderName: String = "Rider"
    @AppStorage("activeRideCode") var activeRideCode: String = ""
    @AppStorage("myCreatedRideCode") var myCreatedRideCode: String = ""
    @AppStorage("rideStartTimestamp") var rideStartTimestamp: Double = 0

    @ObservedObject private var locationManager = SharedLocationManager.shared
    // App-wide singletons (see PackRideApp.swift) — keeps voice chat, the
    // active group ride's location broadcast/GPX recording, and an active
    // "Need Help" share all running no matter which screen MapView happens to
    // be presented from (the persistent Map tab, pushed from GroupRideView
    // after starting a ride, or Community's map preview all share the same
    // instances instead of each getting a private one).
    @EnvironmentObject var voiceChat: VoiceChatManager
    @EnvironmentObject var session: GroupRideSessionManager
    @EnvironmentObject var helpSharing: HelpRequestManager

    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.3318, longitude: -122.0312),
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )
    ))
    @State private var showNeedHelp = false
    @State private var mapStyleIndex = 2 // Hybrid by default so street names are visible
    @State private var boundWaypoints: [Waypoint] = []
    @State private var waypointsHandle: DatabaseHandle? = nil
    @State private var waypointsListenRideCode: String = ""
    @State private var showNavigateToWaypoints = false
    @State private var showEndRideConfirm = false
    @State private var selectedRider: LiveRider? = nil
    @Environment(\.dismiss) var dismiss

    var myInitials: String { riderName.rideInitials }
    var isLeader: Bool { !myCreatedRideCode.isEmpty && myCreatedRideCode == activeRideCode }

    var riderAnnotations: [RiderAnnotation] {
        session.groupRiders.map {
            RiderAnnotation(id: $0.id, riderName: $0.name, initials: $0.initials,
                            speed: $0.speed, coordinate: $0.coordinate,
                            isLeader: $0.isLeader, avatarURL: $0.avatarURL)
        }
    }

    // Group ride membership uses plain device IDs (see FirebaseManager.joinRide),
    // not the Firebase-UID-preferring scheme HelpRequestManager keys its own
    // node by — matching against requesterDeviceID instead of requesterUID is
    // what makes this line up correctly.
    func riderNeedsHelp(_ riderID: String) -> Bool {
        helpSharing.activeRequests.contains {
            $0.targetType == "group" && $0.targetID == activeRideCode && $0.requesterDeviceID == riderID
        }
    }

    // MARK: - Distance from Leader (Aug 27, 2026)
    // session.groupRiders never includes this device's own entry (see
    // FirebaseManager.listenForRiders' `id != myID` filter) — so when THIS
    // device is the leader, the leader's position is simply this device's
    // own live location; otherwise the leader is whichever entry in
    // groupRiders carries isLeader == true (there's exactly one leader per
    // ride, matching the "one Create New Ride" flow).
    var leaderLocation: CLLocation? {
        if isLeader { return locationManager.location }
        guard let leaderRider = session.groupRiders.first(where: { $0.isLeader }) else { return nil }
        return CLLocation(latitude: leaderRider.coordinate.latitude, longitude: leaderRider.coordinate.longitude)
    }

    /// "2.3 mi from leader" for a follower, nil for the leader's own pin or
    /// if the leader's position isn't known yet (they haven't started
    /// broadcasting, or just joined).
    func distanceFromLeaderString(for rider: RiderAnnotation) -> String? {
        guard !rider.isLeader, let leaderLocation else { return nil }
        let riderLocation = CLLocation(latitude: rider.coordinate.latitude, longitude: rider.coordinate.longitude)
        return "\(MeasurementUnits.distanceMeters(leaderLocation.distance(from: riderLocation))) from leader"
    }

    var body: some View {
        ZStack {
            // Full screen map
            Map(position: $cameraPosition) {
                UserAnnotation()
                ForEach(riderAnnotations) { rider in
                    Annotation(rider.riderName, coordinate: rider.coordinate, anchor: .bottom) {
                        RiderMapPin(initials: rider.initials, name: rider.riderName, speed: rider.speed,
                                    avatarURL: rider.avatarURL, isLeader: rider.isLeader,
                                    distanceFromLeader: distanceFromLeaderString(for: rider),
                                    needsHelp: riderNeedsHelp(rider.id))
                    }
                }
                ForEach(boundWaypoints) { waypoint in
                    Annotation(waypoint.name, coordinate: waypoint.coordinate, anchor: .bottom) {
                        waypointPin(waypoint)
                    }
                }
            }
            .mapStyle(.fromIndex(mapStyleIndex))
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomPanel
            }
        }
        .fullScreenCover(isPresented: $showNeedHelp) {
            NeedHelpView()
        }
        .alert(isLeader ? "End Group Ride?" : "Leave Group Ride?", isPresented: $showEndRideConfirm) {
            Button(isLeader ? "End Ride" : "Leave Ride", role: .destructive) {
                let code = activeRideCode
                let wasLeader = isLeader // read before myCreatedRideCode is cleared below
                let result = session.endSession()
                if rideStartTimestamp > 0 {
                    let totalSeconds = Int(Date().timeIntervalSince1970 - rideStartTimestamp)
                    let duration = String(format: "%02d:%02d:%02d", totalSeconds/3600, (totalSeconds%3600)/60, totalSeconds%60)
                    RideHistoryManager.recordRide(
                        distance: result.distance, maxSpeed: result.maxSpeed,
                        duration: duration, isGroupRide: true,
                        rideCode: code, isLeader: wasLeader, gpxFilePath: result.gpxFilePath,
                        bikeId: BikeManager.currentActiveBikeID()
                    )
                    // bug #11 — see GroupRideView.endRide() for the matching
                    // call and full explanation; this is the other place a
                    // rider can end/leave a ride from (End/Leave Ride here on
                    // the live map itself), so it needs the same publish or
                    // "View All Participants' Stats" would silently miss
                    // anyone who left this way.
                    session.firebase.publishFinalStats(rideCode: code, riderName: riderName, initials: myInitials,
                                                        isLeader: wasLeader, distance: result.distance, maxSpeed: result.maxSpeed, duration: duration)
                }
                rideStartTimestamp = 0
                activeRideCode = ""
                myCreatedRideCode = ""
                dismiss()
            }
            Button("Keep Riding", role: .cancel) {}
        } message: {
            Text(isLeader ? "This will end your ride and save it to your Ride History." : "This will end your ride and save it to your Ride History. The ride continues for everyone else.")
        }
        .sheet(item: $selectedRider) { rider in
            RiderProfileView(rider: rider)
        }
        .onAppear {
            locationManager.startUpdating(reason: "mapView")
            helpSharing.listenForActiveRequests()
            if !activeRideCode.isEmpty {
                session.ensureListening(rideCode: activeRideCode, myID: UIDevice.current.identifierForVendor?.uuidString ?? "")
                loadBoundWaypoints(for: activeRideCode)
            }
        }
        .onDisappear {
            locationManager.stopUpdating(reason: "mapView")
            helpSharing.stopListening()
            stopWaypointListening()
        }
        .onChange(of: activeRideCode) { _, newCode in
            if !newCode.isEmpty {
                session.ensureListening(rideCode: newCode, myID: UIDevice.current.identifierForVendor?.uuidString ?? "")
                loadBoundWaypoints(for: newCode)
            } else {
                stopWaypointListening()
                boundWaypoints = []
                if voiceChat.isConnected {
                    // Ride ended — don't leave a mic connected to a channel that's over.
                    voiceChat.leave()
                }
            }
        }
        .fullScreenCover(isPresented: $showNavigateToWaypoints) {
            if let last = boundWaypoints.last {
                TurnByTurnView(
                    destination: last.coordinate,
                    destinationName: last.name,
                    waypoints: Array(boundWaypoints.dropLast().map { $0.coordinate })
                )
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Top Bar
    private var topBar: some View {
        VStack(spacing: 8) {
            if helpSharing.isSharing {
                Button(action: { showNeedHelp = true }) {
                    HStack(spacing: 8) {
                        Circle().fill(Color.white).frame(width: 7, height: 7)
                        Text("Sharing your location — tap to manage")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(red: 0.827, green: 0.231, blue: 0.173))
                    .cornerRadius(12)
                }
                .padding(.horizontal, 16)
            }
            topBarRow
        }
    }

    private var topBarRow: some View {
        HStack {
            if !activeRideCode.isEmpty {
                HStack(spacing: 8) {
                    Circle().fill(Color(red: 0.373, green: 0.851, blue: 0.541)).frame(width: 8, height: 8)
                    Text(activeRideCode)
                        .font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundColor(.prInk)
                    if isLeader {
                        Image(systemName: "crown.fill").font(.system(size: 9)).foregroundColor(.prCoral)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.prCardBg)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.prBorder, lineWidth: 1))
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)

                voiceChatButton
            }

            Spacer()

            VStack(spacing: 2) {
                MapStyleBtn(icon: "globe.americas.fill", label: "SAT", isActive: mapStyleIndex == 0) { mapStyleIndex = 0 }
                MapStyleBtn(icon: "map.fill", label: "MAP", isActive: mapStyleIndex == 1) { mapStyleIndex = 1 }
                MapStyleBtn(icon: "car.fill", label: "HYB", isActive: mapStyleIndex == 2) { mapStyleIndex = 2 }
            }
            .padding(4)
            .background(Color.prCardBg)
            .cornerRadius(14)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    // MARK: - Voice Chat Button
    // Tap once to join (asks for mic permission the first time — a system
    // prompt, not something we can pre-empt). Once connected, tap again to
    // mute/unmute. Deliberately opt-in rather than auto-joining when a group
    // ride starts, so nobody's mic goes live without them choosing it.
    private var voiceChatButton: some View {
        HStack(spacing: 5) {
            if voiceChat.isConnected {
                Button(action: { voiceChat.toggleSpeaker() }) {
                    HStack(spacing: 3) {
                        Image(systemName: voiceChat.isSpeakerEnabled ? "speaker.wave.2.fill" : "headphones")
                        Text(voiceChat.audioRouteName)
                            .lineLimit(1)
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.prInk)
                    .padding(.horizontal, 7).frame(height: 34)
                    .background(Color.prCardBg)
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.prBorder, lineWidth: 1))
                }
            }

            Button(action: {
                if voiceChat.isConnected {
                    voiceChat.toggleMute()
                } else {
                    voiceChat.join(channelName: activeRideCode)
                }
            }) {
                HStack(spacing: 6) {
                    if voiceChat.isConnecting {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Image(systemName: voiceIconName)
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .foregroundColor(voiceChat.isConnected && !voiceChat.isMuted ? .white : .prInk)
                .frame(width: 34, height: 34)
                .background(voiceChat.isConnected && !voiceChat.isMuted ? Color(red: 0.180, green: 0.620, blue: 0.357) : Color.prCardBg)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.prBorder, lineWidth: 1))
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            }
        }
        .alert("Voice Chat", isPresented: .constant(voiceChat.connectionError != nil), actions: {
            Button("OK") { voiceChat.connectionError = nil }
        }, message: {
            Text(voiceChat.connectionError ?? "")
        })
    }

    private var voiceIconName: String {
        guard voiceChat.isConnected else { return "mic.slash.fill" }
        return voiceChat.isMuted ? "mic.slash.fill" : "mic.fill"
    }

    // MARK: - Bottom Panel
    private var bottomPanel: some View {
        VStack(spacing: 12) {
            riderScrollView

            // Aug 22, 2026 — bug #9: previously the only way to get
            // turn-by-turn to the leader's planned stops was through the
            // pre-ride Waypoints screen itself, which only the leader could
            // even open. Now that boundWaypoints is live-synced from
            // Firebase (see loadBoundWaypoints above), everyone in the ride
            // gets a real Navigate button once a route exists.
            if !boundWaypoints.isEmpty {
                Button(action: { showNavigateToWaypoints = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "location.fill.viewfinder").font(.system(size: 15))
                        Text("Navigate to \(boundWaypoints.count) stop\(boundWaypoints.count == 1 ? "" : "s")")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Color.prTeal).cornerRadius(14)
                }
                .padding(.horizontal, 16)
            }

            HStack(spacing: 10) {
                Button(action: { showNeedHelp = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 16))
                        Text("Need Help").font(.system(size: 14, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Color(red: 0.827, green: 0.231, blue: 0.173))
                    .cornerRadius(14)
                }

                if !activeRideCode.isEmpty {
                    Button(action: { showEndRideConfirm = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.circle.fill").font(.system(size: 16))
                            Text(isLeader ? "End" : "Leave").font(.system(size: 14, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 20).padding(.vertical, 14)
                        .background(Color.prInkFixed)
                        .cornerRadius(14)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 30)
        }
        .padding(.top, 12)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.prCardBg)
                .ignoresSafeArea(edges: .bottom)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.prBorder, lineWidth: 1)
                .ignoresSafeArea(edges: .bottom),
            alignment: .top
        )
    }

    // MARK: - Rider Scroll View
    private var riderScrollView: some View {
        Group {
            if activeRideCode.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "person.3.fill").foregroundColor(.prMuted)
                    Text("Start a group ride to see your pack")
                        .font(.system(size: 13)).foregroundColor(.prMuted)
                }
                .padding(.horizontal, 20).padding(.bottom, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        VStack(spacing: 5) {
                            ZStack(alignment: .bottomTrailing) {
                                Circle().fill(Color.prCoral).frame(width: 48, height: 48)
                                Text(myInitials)
                                    .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                                    .frame(width: 48, height: 48)
                                Circle().fill(Color(red: 0.180, green: 0.620, blue: 0.357)).frame(width: 12, height: 12)
                                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                                    .offset(x: 2, y: 2)
                            }
                            Text("You")
                                .font(.system(size: 10, weight: .semibold)).foregroundColor(.prInk)
                            if isLeader {
                                Image(systemName: "crown.fill").font(.system(size: 8)).foregroundColor(.prCoral)
                            }
                        }

                        ForEach(session.groupRiders) { rider in
                            Button(action: { selectedRider = rider }) {
                                VStack(spacing: 5) {
                                    ZStack(alignment: .bottomTrailing) {
                                        Circle().fill(Color.prTeal).frame(width: 48, height: 48)
                                        Text(rider.initials)
                                            .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                                            .frame(width: 48, height: 48)
                                        Circle().fill(Color(red: 0.180, green: 0.620, blue: 0.357)).frame(width: 12, height: 12)
                                            .overlay(Circle().stroke(Color.white, lineWidth: 2))
                                            .offset(x: 2, y: 2)
                                    }
                                    Text(rider.name.components(separatedBy: " ").first ?? rider.name)
                                        .font(.system(size: 10, weight: .medium)).foregroundColor(.prInk)
                                    Text(rider.speed > 0 ? MeasurementUnits.speedMph(rider.speed) : "")
                                        .font(.system(size: 9)).foregroundColor(.prMuted)
                                }
                            }
                        }

                        if session.groupRiders.isEmpty {
                            VStack(spacing: 4) {
                                Image(systemName: "person.badge.plus")
                                    .font(.system(size: 18)).foregroundColor(.prMuted)
                                Text("Waiting...")
                                    .font(.system(size: 10)).foregroundColor(.prMuted)
                            }
                            .padding(.horizontal, 8)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    // MARK: - Helpers
    private func waypointPin(_ waypoint: Waypoint) -> some View {
        WaypointMapPin(waypoint: waypoint)
    }

    // Aug 22, 2026 — bug #9: used to read the LOCAL "waypoints_{code}" key,
    // which only ever existed on the leader's own phone — every
    // participant's copy of this key was always empty, so they never saw a
    // single waypoint the leader had planned. Now a live Firebase listener
    // (GroupWaypointSync — see WaypointsView.swift), so waypoints show up
    // for everyone and stay current if the leader edits the plan mid-ride.
    func loadBoundWaypoints(for code: String) {
        stopWaypointListening()
        waypointsListenRideCode = code
        waypointsHandle = GroupWaypointSync.listen(rideCode: code) { waypoints in
            boundWaypoints = waypoints
        }
    }

    func stopWaypointListening() {
        GroupWaypointSync.stopListening(rideCode: waypointsListenRideCode, handle: waypointsHandle)
        waypointsHandle = nil
    }
}

// MARK: - Rider Map Pin
struct RiderMapPin: View {
    let initials: String
    let name: String
    let speed: Double
    // Aug 27, 2026 — actual profile photo (was initials-only before), a
    // leader marker, and a "how far from the leader" readout on tap, so a
    // live group ride actually shows where everyone is relative to whoever
    // is out front.
    var avatarURL: String = ""
    var isLeader: Bool = false
    var distanceFromLeader: String? = nil
    var needsHelp: Bool = false
    @State private var showInfo = false

    private var pinColor: Color {
        needsHelp ? Color(red: 0.827, green: 0.231, blue: 0.173) : (isLeader ? .prCoral : .prTeal)
    }

    var body: some View {
        VStack(spacing: 0) {
            if needsHelp {
                NeedsHelpBadge().padding(.bottom, 4)
            }
            if showInfo {
                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        if isLeader {
                            Image(systemName: "crown.fill").font(.system(size: 9)).foregroundColor(.prCoral)
                        }
                        Text(name).font(.system(size: 11, weight: .semibold)).foregroundColor(.prInk)
                    }
                    Text(speed > 0 ? MeasurementUnits.speedMph(speed) : "Connected")
                        .font(.system(size: 10)).foregroundColor(.prCoral)
                    if let distanceFromLeader {
                        Text(distanceFromLeader)
                            .font(.system(size: 10, weight: .medium)).foregroundColor(.prMuted)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.prCardBg).cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.prBorder, lineWidth: 1))
                .padding(.bottom, 4)
            }
            Button(action: { showInfo.toggle() }) {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        Circle().fill(pinColor).frame(width: 36, height: 36)
                        if !avatarURL.isEmpty, let url = URL(string: avatarURL) {
                            AsyncImage(url: url) { image in
                                image.resizable().scaledToFill()
                                    .frame(width: 36, height: 36)
                                    .clipShape(Circle())
                            } placeholder: {
                                Text(initials).font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                            }
                        } else {
                            Text(initials).font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                        }
                    }
                    .overlay(Circle().stroke(Color.white, lineWidth: isLeader ? 2 : 0))

                    if isLeader {
                        ZStack {
                            Circle().fill(Color.white).frame(width: 16, height: 16)
                            Image(systemName: "crown.fill").font(.system(size: 8)).foregroundColor(.prCoral)
                        }
                        .offset(x: 4, y: -4)
                    }
                }
            }
            Triangle().fill(pinColor)
                .frame(width: 10, height: 6)
        }
    }
}

// MARK: - Triangle Shape
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

#Preview {
    NavigationView { MapView() }
        .environmentObject(VoiceChatManager())
        .environmentObject(GroupRideSessionManager())
        .environmentObject(HelpRequestManager())
        .environmentObject(CommunityMembershipStore())
}
