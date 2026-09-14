import SwiftUI
import FirebaseDatabase
import Combine
import CoreLocation
import MapKit

struct GroupRideView: View {
    @AppStorage("riderName") var riderName: String = "Rider"
    @AppStorage("avatarURL") var avatarURL: String = ""
    @AppStorage("activeRideCode") var activeRideCode: String = ""
    @AppStorage("myCreatedRideCode") var myCreatedRideCode: String = ""
    @AppStorage("pendingWaypointRideCode") var pendingWaypointRideCode: String = ""
    @AppStorage("rideStartTimestamp") var rideStartTimestamp: Double = 0

    @State private var rideCode = ""
    @State private var joinCode = ""
    @State private var isRideStarted = false
    @State private var showCopied = false
    @State private var showRideComplete = false
    @State private var navigateToWaypoints = false
    @State private var selectedRider: LiveRider? = nil
    @State private var rideStartTime: Date? = nil
    @State private var appeared = false
    @State private var showScheduleSheet = false
    @State private var savedWaypointCount = 0
    @State private var savedWaypoints: [Waypoint] = []
    @State private var navigateToLiveMap = false
    @State private var lastCompletedRide: CompletedRideInfo? = nil
    @State private var isEndingRide = false

    @State private var waypointsHandle: DatabaseHandle? = nil
    @State private var waypointsListenRideCode: String = ""
    @State private var showNavigateToWaypoints = false
    @State private var showNotifications = false
    @State private var showNeedHelp = false
    @State private var showWaypointReminder = false
    @State private var waypointMapRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.33, longitude: -122.03),
        span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
    )

    @EnvironmentObject private var session: GroupRideSessionManager
    @EnvironmentObject private var deepLinkRouter: DeepLinkRouter
    // Aug 27, 2026 — was its own separate UserProfileManager() instance,
    // which meant this screen's bell badge never reflected a follow request
    // that arrived while you weren't on this tab (and NotificationCenterView
    // opened from here showed nothing even when one existed). Now the shared
    // app-wide instance — see PackRideApp.swift / ContentView's onAppear.
    @EnvironmentObject private var profileManager: UserProfileManager
    @ObservedObject private var locationManager = SharedLocationManager.shared

    var myInitials: String { riderName.rideInitials }
    var isLeader: Bool { !myCreatedRideCode.isEmpty && myCreatedRideCode == rideCode }
    var hasCode: Bool { !rideCode.isEmpty }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.prBg.ignoresSafeArea()

                if showRideComplete {
                    RideCompleteOverlay(
                        riders: session.groupRiders, myInitials: myInitials, myName: riderName,
                        completedRide: lastCompletedRide,
                        onDismiss: { showRideComplete = false }
                    )
                    .zIndex(1)
                }

                VStack(spacing: 0) {
                    // MARK: - Full-Bleed Web Navigation Header
                    webHeaderBar

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            
                            // MARK: - Section Title Bar (With Back Arrow when inside a room)
                            if hasCode {
                                rideRoomHero
                            } else {
                            HStack(alignment: .center, spacing: 10) {
                                if hasCode {
                                    Button(action: {
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            if !rideCode.isEmpty { session.firebase.leaveRide(rideCode: rideCode) }
                                            rideCode = ""
                                            if isLeader { myCreatedRideCode = "" }
                                        }
                                    }) {
                                        Image(systemName: "chevron.left")
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundColor(.prInk)
                                            .frame(width: 32, height: 32)
                                            .background(Color.prCardBg)
                                            .clipShape(Circle())
                                            .overlay(Circle().stroke(Color.prBorder, lineWidth: 1))
                                    }
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("THE PACK")
                                        .font(.system(size: 10, weight: .heavy))
                                        .foregroundColor(.prMuted)
                                        .tracking(2)
                                    Text(hasCode ? "Ride Room" : "Group Ride")
                                        .font(.system(size: 20, weight: .bold))
                                        .foregroundColor(.prInk)
                                }
                                Spacer()
                                if hasCode {
                                    HStack(spacing: 8) {
                                        PRWebLivePill(
                                            label: isRideStarted ? "LIVE RIDE" : (isLeader ? "LEADER" : "JOINED"),
                                            accent: isRideStarted ? Color(red: 0.180, green: 0.620, blue: 0.357) : (isLeader ? .prCoral : .prTeal)
                                        )
                                        if isRideStarted {
                                            Button(action: { navigateToLiveMap = true }) {
                                                HStack(spacing: 5) {
                                                    Image(systemName: "map.fill")
                                                    Text("LIVE MAP")
                                                }
                                                .font(.system(size: 10, weight: .heavy))
                                                .tracking(1)
                                                .foregroundColor(.prInk)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(Color.prCardBg)
                                                .cornerRadius(8)
                                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.prBorder, lineWidth: 1))
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .padding(.bottom, 10)
                            }

                            if !hasCode {
                                createOrJoinSection
                                scheduleRideButton
                                UpcomingRidesSection()
                            } else {
                                rideCodeCard
                                ridersSection
                                startEndButton
                            }

                            Spacer().frame(height: 36)
                        }
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 15)
                    }

                    AdBannerFooter()
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(isPresented: $navigateToWaypoints) {
                WaypointsView().onDisappear { navigateToWaypoints = false }
            }
            .navigationDestination(isPresented: $navigateToLiveMap) {
                MapView()
            }
            .sheet(isPresented: $showNotifications) {
                NotificationCenterView(profileManager: profileManager)
            }
            .fullScreenCover(isPresented: $showNeedHelp) {
                NeedHelpView()
            }
        }
        .sheet(item: $selectedRider) { rider in RiderProfileView(rider: rider) }
        .sheet(isPresented: $showScheduleSheet) {
            ScheduleRideSheet(rideCode: rideCode.isEmpty ? generateRideCode() : rideCode) {
                // On scheduled callback
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) { appeared = true }
            if let pendingCode = UserDefaults.standard.string(forKey: "pendingGroupRideCode"), !pendingCode.isEmpty {
                rideCode = pendingCode
                myCreatedRideCode = pendingCode
                UserDefaults.standard.removeObject(forKey: "pendingGroupRideCode")
            } else if !activeRideCode.isEmpty && rideCode.isEmpty {
                rideCode = activeRideCode
                isRideStarted = true
            }
            if let pending = deepLinkRouter.pendingRideCode {
                deepLinkRouter.pendingRideCode = nil
                if rideCode.isEmpty { rideCode = pending }
            }
            refreshWaypointCount()
            if !rideCode.isEmpty && !session.isActive {
                session.firebase.joinRide(
                    rideCode: rideCode,
                    riderName: riderName,
                    initials: myInitials,
                    isLeader: myCreatedRideCode == rideCode,
                    avatarURL: avatarURL
                )
            }
        }
        .onChange(of: navigateToWaypoints) { _, isNavigating in
            if !isNavigating { refreshWaypointCount() }
        }
        .onChange(of: rideCode) { _, newCode in
            refreshWaypointCount()
            // Deep links/pending joins can set rideCode without going through
            // the Join button, so make sure they also create membership.
            guard !newCode.isEmpty, !session.isActive else { return }
            session.firebase.joinRide(
                rideCode: newCode,
                riderName: riderName,
                initials: myInitials,
                isLeader: myCreatedRideCode == newCode,
                avatarURL: avatarURL
            )
        }
        .onDisappear { stopWaypointListening() }
        .fullScreenCover(isPresented: $showNavigateToWaypoints) {
            if let last = savedWaypoints.last {
                TurnByTurnView(
                    destination: last.coordinate,
                    destinationName: last.name,
                    waypoints: Array(savedWaypoints.dropLast().map { $0.coordinate })
                )
            }
        }
        .alert("No waypoints planned", isPresented: $showWaypointReminder) {
            if isLeader {
                Button("Set Waypoints") {
                    pendingWaypointRideCode = rideCode
                    navigateToWaypoints = true
                }
            }
            Button("Start Without Route", role: .destructive) { beginRide() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(isLeader ? "A planned route helps everyone in the pack know where to go. Set waypoints before starting, or start without a route." : "This ride has no planned route yet. You can ask the leader to add waypoints or start without one.")
        }
    }

    // MARK: - Ride room full-bleed hero
    private var rideRoomHero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button {
                    if !rideCode.isEmpty { session.firebase.leaveRide(rideCode: rideCode) }
                    rideCode = ""
                    if isLeader { myCreatedRideCode = "" }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.12)).clipShape(Circle())
                }
                .foregroundColor(.white)
                Spacer()
                PRWebLivePill(label: isRideStarted ? "LIVE RIDE" : (isLeader ? "LEADER" : "JOINED"), accent: isRideStarted ? Color(red: 0.180, green: 0.620, blue: 0.357) : .prCoral)
            }
            Text(isRideStarted ? "YOUR PACK IS ROLLING" : "READY TO RIDE")
                .font(.system(size: 10, weight: .heavy)).tracking(2.2).foregroundColor(.white.opacity(0.62))
            Text(rideCode)
                .font(.system(size: 36, weight: .heavy, design: .monospaced)).tracking(6).foregroundColor(.white)
            HStack(spacing: 8) {
                Label("\(session.groupRiders.count + 1) riders connected", systemImage: "person.2.fill")
                if savedWaypointCount > 0 { Label("\(savedWaypointCount) stops", systemImage: "mappin.and.ellipse") }
            }
            .font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.78))
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.prInkFixed)
    }

    // MARK: - Full-Bleed Web Navigation Header Bar
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
                    Text(myInitials).font(.system(size: 12, weight: .bold)).foregroundColor(.white)
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

    // MARK: - Create or Join
    private var createOrJoinSection: some View {
        VStack(spacing: 12) {
            Button(action: createNewRide) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(Color.prInkFixed).frame(width: 46, height: 46)
                        Image(systemName: "plus").font(.system(size: 20, weight: .bold)).foregroundColor(.white)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Create New Ride")
                            .font(.system(size: 16, weight: .bold)).foregroundColor(.prInk)
                        Text("Generate a code and invite your pack")
                            .font(.system(size: 12)).foregroundColor(.prMuted)
                    }
                    Spacer()
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 20)).foregroundColor(.prMuted)
                }
                .padding(16)
                .background(Color.prCardBg)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Or join an existing ride")
                    .font(.system(size: 13, weight: .medium)).foregroundColor(.prMuted)
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "number").foregroundColor(.prCoral)
                        TextField("", text: $joinCode, prompt: Text("Enter ride code").foregroundColor(.prMuted))
                            .font(.system(size: 16, weight: .medium, design: .monospaced))
                            .foregroundColor(.prInk)
                            .autocapitalization(.allCharacters)
                    }
                    .padding(14)
                    .background(Color.prFieldBg)
                    .cornerRadius(12)

                    Button(action: { joinRideRoom(code: joinCode.uppercased()); joinCode = "" }) {
                        Text("Join")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 20).padding(.vertical, 14)
                            .background(joinCode.isEmpty ? Color.prCoral.opacity(0.4) : Color.prCoral)
                            .cornerRadius(12)
                    }
                    .disabled(joinCode.isEmpty)
                }
            }
            .padding(16)
            .background(Color.prCardBg)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Schedule Ride Button
    private var scheduleRideButton: some View {
        Button(action: {
            if rideCode.isEmpty { rideCode = generateRideCode(); myCreatedRideCode = rideCode }
            showScheduleSheet = true
        }) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.prTeal).frame(width: 46, height: 46)
                    Image(systemName: "calendar.badge.clock").font(.system(size: 18, weight: .semibold)).foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Schedule a Ride")
                        .font(.system(size: 16, weight: .bold)).foregroundColor(.prInk)
                    Text("Plan a future ride and invite your pack")
                        .font(.system(size: 12)).foregroundColor(.prMuted)
                }
                Spacer()
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 20)).foregroundColor(.prMuted)
            }
            .padding(16)
            .background(Color.prCardBg)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Ride Code Card
    private var rideCodeCard: some View {
        VStack(spacing: 16) {
            HStack {
                if isLeader {
                    HStack(spacing: 5) {
                        Image(systemName: "crown.fill").font(.system(size: 10)).foregroundColor(.prCoral)
                        Text("LEADER").font(.system(size: 10, weight: .heavy))
                            .foregroundColor(.prCoral).tracking(1.5)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.prCoralSoft).cornerRadius(8)
                } else {
                    Text("JOINED").font(.system(size: 10, weight: .heavy))
                        .foregroundColor(.prTeal).tracking(1.5)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.prTealSoft).cornerRadius(8)
                }
                Spacer()
                if !isRideStarted {
                    Button(action: {
                        if !rideCode.isEmpty { session.firebase.leaveRide(rideCode: rideCode) }
                        rideCode = ""
                        if isLeader { myCreatedRideCode = "" }
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18)).foregroundColor(.prMuted)
                    }
                }
            }

            Text(rideCode)
                .font(.system(size: 40, weight: .heavy, design: .monospaced))
                .foregroundColor(.prInk)
                .tracking(8)

            HStack(spacing: 10) {
                Button(action: {
                    UIPasteboard.general.string = rideCode
                    showCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showCopied = false }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: showCopied ? "checkmark" : "doc.on.doc").font(.system(size: 13))
                        Text(showCopied ? "Copied!" : "Copy").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.prInk).frame(maxWidth: .infinity)
                    .padding(.vertical, 12).background(Color.prFieldBg).cornerRadius(12)
                }

                Button(action: shareCode) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 13))
                        Text("Share").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.white).frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.prCoral)
                    .cornerRadius(12)
                }
            }

            if savedWaypointCount > 0 {
                VStack(spacing: 0) {
                    Group {
                        if isLeader {
                            Button(action: { pendingWaypointRideCode = rideCode; navigateToWaypoints = true }) {
                                waypointPreviewMap(showEditBadge: true)
                            }
                        } else {
                            Button(action: { showNavigateToWaypoints = true }) {
                                waypointPreviewMap(showEditBadge: false)
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "mappin.and.ellipse").font(.system(size: 12)).foregroundColor(Color(red: 0.180, green: 0.620, blue: 0.357))
                        Text("\(savedWaypointCount) stop\(savedWaypointCount == 1 ? "" : "s") planned")
                            .font(.system(size: 12, weight: .semibold)).foregroundColor(.prInk)
                        Spacer()
                        ForEach(savedWaypoints.filter { !$0.isStartOverride }.prefix(5)) { wp in
                            Circle().fill(wp.type.color).frame(width: 8, height: 8)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Color.prRouteSoft)

                    if !isLeader {
                        Button(action: { showNavigateToWaypoints = true }) {
                            HStack(spacing: 6) {
                                Image(systemName: "location.fill.viewfinder").font(.system(size: 12))
                                Text("Navigate").font(.system(size: 12, weight: .bold))
                            }
                            .foregroundColor(.white).frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.prCoral)
                        }
                    }
                }
            } else if isLeader {
                Button(action: { pendingWaypointRideCode = rideCode; navigateToWaypoints = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "mappin.and.ellipse").font(.system(size: 14))
                        Text("Add Waypoints").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.prCoral).frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.prCoralSoft).cornerRadius(12)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "mappin.slash").font(.system(size: 12)).foregroundColor(.prMuted)
                    Text("Leader hasn't planned a route yet")
                        .font(.system(size: 12)).foregroundColor(.prMuted)
                }
                .padding(.vertical, 8)
            }
        }
        .padding(16)
        .background(Color.prBg)
    }

    private func waypointPreviewMap(showEditBadge: Bool) -> some View {
        ZStack(alignment: .topTrailing) {
            // Aug 28, 2026 — RouteMapView now takes currentLocation from the
            // shared location manager (see WaypointsView.swift) so it can
            // center on the rider even if this preview appears before a
            // GPS fix would otherwise have been available.
            //
            // Also Aug 28, 2026 — this preview used to always show the route
            // starting from whoever's VIEWING it right now, ignoring any
            // starting point the leader actually picked (Karthik: "the mini
            // display picks starting point as my current location"). The
            // leader's chosen start now rides along in savedWaypoints itself
            // (see Waypoint.isStartOverride/WaypointsManager.setStart), so
            // it's pulled out here the same way WaypointsView does, instead
            // of defaulting to the viewer's own location.
            RouteMapView(
                waypoints: savedWaypoints.filter { !$0.isStartOverride },
                region: $waypointMapRegion,
                mapStyleIndex: 2,
                currentLocation: locationManager.location,
                startOverride: savedWaypoints.first(where: { $0.isStartOverride })
            )
                .frame(height: 180)
                .cornerRadius(12)
                .allowsHitTesting(false)

            HStack(spacing: 4) {
                Image(systemName: showEditBadge ? "pencil" : "location.fill.viewfinder").font(.system(size: 10, weight: .bold))
                Text(showEditBadge ? "Edit" : "Navigate").font(.system(size: 11, weight: .bold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.prInkFixed.opacity(0.85))
            .cornerRadius(8)
            .padding(8)
        }
    }

    // MARK: - Riders Section
    private var ridersSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Pack")
                    .font(.system(size: 16, weight: .bold)).foregroundColor(.prInk)
                Text("\(session.groupRiders.count + 1)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.prTeal).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color(red: 0.906, green: 0.937, blue: 0.945)).cornerRadius(8)
                Spacer()
            }

            // Flush rider list — one shared field band, hairline dividers
            // between rows instead of individually-boxed "cards" (Aug 27, 2026).
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Color.prCoral).frame(width: 44, height: 44)
                        Text(myInitials)
                            .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(riderName).font(.system(size: 14, weight: .semibold)).foregroundColor(.prInk)
                            if isLeader { Image(systemName: "crown.fill").font(.system(size: 9)).foregroundColor(.prCoral) }
                        }
                        Text("You").font(.system(size: 11)).foregroundColor(.prMuted)
                    }
                    Spacer()
                    Circle().fill(Color(red: 0.180, green: 0.620, blue: 0.357)).frame(width: 8, height: 8)
                }
                .padding(12)

                if session.groupRiders.isEmpty {
                    Rectangle().fill(Color.prBorder).frame(height: 1)
                    HStack(spacing: 10) {
                        Image(systemName: "person.badge.plus").foregroundColor(.prMuted).font(.system(size: 16))
                        Text("Share your code to invite riders")
                            .font(.system(size: 13)).foregroundColor(.prMuted)
                    }
                    .padding(14)
                }

                ForEach(session.groupRiders) { rider in
                    Rectangle().fill(Color.prBorder).frame(height: 1)
                    Button(action: { selectedRider = rider }) {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(Color.prTeal).frame(width: 44, height: 44)
                                Text(rider.initials)
                                    .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rider.name).font(.system(size: 14, weight: .medium)).foregroundColor(.prInk)
                                Text(rider.speed > 0 ? MeasurementUnits.speedMph(rider.speed) : "Connected")
                                    .font(.system(size: 11)).foregroundColor(.prMuted)
                            }
                            Spacer()
                            Circle().fill(Color(red: 0.180, green: 0.620, blue: 0.357)).frame(width: 8, height: 8)
                        }
                        .padding(12)
                    }
                }
            }
            .background(Color.prFieldBg)
        }
        .padding(.horizontal, 16).padding(.vertical, 18)
        .background(Color.prBg)
    }

    // MARK: - Start / End Button
    private var startEndButton: some View {
        Button(action: { isRideStarted ? endRide() : startRide() }) {
            HStack(spacing: 12) {
                Image(systemName: isRideStarted ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 24))
                Text(isEndingRide ? "ENDING…" : (isRideStarted ? "END RIDE" : "START RIDE"))
                    .font(.system(size: 17, weight: .heavy)).tracking(2)
            }
            .foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 19)
            // prInk becomes nearly white in Dark Mode for text legibility;
            // this is an action surface, so keep the button's charcoal fixed.
            .background(isRideStarted ? Color(red: 0.827, green: 0.231, blue: 0.173) : Color.prInkFixed)
        }
        .padding(.top, 4)
        .disabled(isEndingRide)
        .opacity(isEndingRide ? 0.7 : 1)
    }

    // MARK: - Actions
    func refreshWaypointCount() {
        GroupWaypointSync.stopListening(rideCode: waypointsListenRideCode, handle: waypointsHandle)
        waypointsHandle = nil
        waypointsListenRideCode = rideCode
        guard !rideCode.isEmpty else { savedWaypointCount = 0; savedWaypoints = []; return }
        waypointsHandle = GroupWaypointSync.listen(rideCode: rideCode) { waypoints in
            // Aug 28, 2026 — excludes a rider-picked starting point override
            // (see Waypoint.isStartOverride) from the "N stops planned"
            // count and the "has a route" gate below — it isn't a stop.
            savedWaypointCount = waypoints.filter { !$0.isStartOverride }.count
            savedWaypoints = waypoints
        }
    }

    func stopWaypointListening() {
        GroupWaypointSync.stopListening(rideCode: waypointsListenRideCode, handle: waypointsHandle)
        waypointsHandle = nil
    }

    func createNewRide() {
        let code = generateRideCode()
        rideCode = code
        myCreatedRideCode = code
        joinRideRoom(code: code)
    }

    /// Joining a ride room is a membership action, not a start-ride action.
    /// Previously this only happened inside startSession(), so a rider who
    /// entered a code could see the room but had no Firebase presence/listener
    /// until the ride actually started. That made the Pack list incomplete.
    func joinRideRoom(code: String) {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else { return }
        rideCode = normalized
        session.firebase.joinRide(
            rideCode: normalized,
            riderName: riderName,
            initials: myInitials,
            isLeader: myCreatedRideCode == normalized,
            avatarURL: avatarURL
        )
    }

    func generateRideCode() -> String {
        JoinCodeGenerator.generate()
    }

    func shareCode() {
        PackRideShareCard.shareGroupRide(code: rideCode)
    }

    func startRide() {
        guard !isRideStarted else { return }
        guard savedWaypointCount > 0 else { showWaypointReminder = true; return }
        beginRide()
    }

    private func beginRide() {
        guard !isRideStarted else { return }
        isRideStarted = true; activeRideCode = rideCode; rideStartTime = Date()
        rideStartTimestamp = Date().timeIntervalSince1970
        session.startSession(rideCode: rideCode, riderName: riderName, initials: myInitials, isLeader: isLeader, avatarURL: avatarURL)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            navigateToLiveMap = true
        }
    }

    func endRide() {
        guard isRideStarted, session.isActive, !isEndingRide, !rideCode.isEmpty else { return }
        isEndingRide = true
        let wasLeader = isLeader
        let endedRideCode = rideCode
        isRideStarted = false; activeRideCode = ""; myCreatedRideCode = ""
        let result = session.endSession()
        if let start = rideStartTime {
            let totalSeconds = Int(Date().timeIntervalSince(start))
            let duration = String(format: "%02d:%02d:%02d", totalSeconds/3600, (totalSeconds%3600)/60, totalSeconds%60)
            RideHistoryManager.recordRide(distance: result.distance, maxSpeed: result.maxSpeed,
                                          duration: duration, isGroupRide: true, rideCode: endedRideCode,
                                          isLeader: wasLeader, gpxFilePath: result.gpxFilePath,
                                          bikeId: BikeManager.currentActiveBikeID())
            session.firebase.publishFinalStats(rideCode: endedRideCode, riderName: riderName, initials: myInitials,
                                                isLeader: wasLeader, distance: result.distance, maxSpeed: result.maxSpeed, duration: duration) { _ in
                session.firebase.leaveRide(rideCode: endedRideCode)
            }
            lastCompletedRide = CompletedRideInfo(rideCode: endedRideCode, distance: result.distance, maxSpeed: result.maxSpeed,
                                                   duration: duration, isLeader: wasLeader, gpxFilePath: result.gpxFilePath)
        }
        rideStartTime = nil; rideStartTimestamp = 0
        isEndingRide = false
        showRideComplete = true
    }
}

// MARK: - Completed Ride Info
struct CompletedRideInfo {
    let rideCode: String
    let distance: Double
    let maxSpeed: Double
    let duration: String
    let isLeader: Bool
    let gpxFilePath: String?

    var distanceString: String { MeasurementUnits.distanceMiles(distance) }
    var maxSpeedString: String { MeasurementUnits.speedMph(maxSpeed) }
}

struct RideCompleteOverlay: View {
    let riders: [LiveRider]; let myInitials: String; let myName: String
    let completedRide: CompletedRideInfo?
    let onDismiss: () -> Void
    @State private var animate = false
    @State private var showParticipantStats = false
    @State private var showReplayModePicker = false

    var body: some View {
        ZStack {
            Color.prInk.opacity(0.97).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    ZStack {
                        Circle().fill(Color.prCoral.opacity(0.15)).frame(width: 120, height: 120)
                            .scaleEffect(animate ? 1.1 : 1.0)
                            .animation(.easeInOut(duration: 1).repeatForever(), value: animate)
                        Text("\u{1F3CD}").font(.system(size: 54))
                    }
                    .onAppear { animate = true }
                    .padding(.top, 40)

                    VStack(spacing: 8) {
                        Text("Ride Complete!")
                            .font(.system(size: 30, weight: .bold)).foregroundColor(.white)
                        Text("Everyone made it safe")
                            .font(.system(size: 15)).foregroundColor(.white.opacity(0.5))
                    }

                    HStack(spacing: -10) {
                        ZStack {
                            Circle().fill(Color.prCoral)
                                .frame(width: 44, height: 44).overlay(Circle().stroke(Color.prInk, lineWidth: 2))
                            Text(myInitials).font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                        }
                        ForEach(riders) { rider in
                            ZStack {
                                Circle().fill(Color.prTeal).frame(width: 44, height: 44)
                                    .overlay(Circle().stroke(Color.prInk, lineWidth: 2))
                                Text(rider.initials).font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                            }
                        }
                        ZStack {
                            Circle().fill(Color(red: 0.180, green: 0.620, blue: 0.357)).frame(width: 44, height: 44)
                                .overlay(Circle().stroke(Color.prInk, lineWidth: 2))
                            Image(systemName: "checkmark").font(.system(size: 16, weight: .bold)).foregroundColor(.white)
                        }
                    }

                    if let ride = completedRide {
                        HStack(spacing: 0) {
                            CompletedStat(label: "Distance", value: ride.distanceString)
                            CompletedStat(label: "Top Speed", value: ride.maxSpeedString)
                            CompletedStat(label: "Duration", value: ride.duration)
                        }
                        .padding(.vertical, 16)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(16)
                        .padding(.horizontal, 24)
                    }

                    VStack(spacing: 12) {
                        if let ride = completedRide {
                            Button(action: { showParticipantStats = true }) {
                                HStack(spacing: 10) {
                                    Image(systemName: "person.3.fill")
                                    Text("View All Participants' Stats").font(.system(size: 16, weight: .bold))
                                }
                                .foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 16)
                                .background(Color.prCoral)
                                .cornerRadius(16)
                            }

                            HStack(spacing: 10) {
                                Button(action: { showReplayModePicker = true }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "play.circle.fill")
                                        Text("Replay Ride").font(.system(size: 14, weight: .semibold))
                                    }
                                    .foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 13)
                                    .background(Color.white.opacity(0.1))
                                    .cornerRadius(14)
                                }
                                Button(action: {
                                    guard let path = ride.gpxFilePath else { return }
                                    let av = UIActivityViewController(activityItems: [GPXStorage.resolve(path)], applicationActivities: nil)
                                    if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                                       let vc = scene.windows.first?.rootViewController { vc.present(av, animated: true) }
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "doc.badge.arrow.up")
                                        Text("Export GPX").font(.system(size: 14, weight: .semibold))
                                    }
                                    .foregroundColor(ride.gpxFilePath != nil ? .white : .white.opacity(0.3))
                                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                                    .background(Color.white.opacity(0.1))
                                    .cornerRadius(14)
                                }
                                .disabled(ride.gpxFilePath == nil)
                            }
                        }
                        Button(action: onDismiss) {
                            Text("Done").font(.system(size: 15)).foregroundColor(.white.opacity(0.5))
                        }
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
        }
        .sheet(isPresented: $showParticipantStats) {
            if let ride = completedRide {
                ParticipantsStatsView(rideCode: ride.rideCode, myGPXPath: ride.gpxFilePath, myName: myName, myInitials: myInitials)
            }
        }
        .sheet(isPresented: $showReplayModePicker) {
            if let ride = completedRide {
                ReplayModeSheet(rideCode: ride.rideCode, myGPXPath: ride.gpxFilePath, myName: myName, myInitials: myInitials)
            }
        }
    }
}

struct CompletedStat: View {
    let label: String; let value: String
    var body: some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 16, weight: .bold, design: .monospaced)).foregroundColor(.white)
            Text(label).font(.system(size: 10, weight: .medium)).foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - All Participants' Stats
struct ParticipantsStatsView: View {
    let rideCode: String
    let myGPXPath: String?
    let myName: String
    let myInitials: String
    @Environment(\.dismiss) var dismiss
    @State private var stats: [ParticipantStat] = []
    @State private var isLoading = true
    private let firebase = FirebaseManager()

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Full-Bleed Web Sub-Screen Header
            // Aug 27, 2026 — replaces the default .navigationTitle/.toolbar
            // "Done" chrome, which was the one spot in Group Ride still
            // using native nav-bar styling instead of matching the rest of
            // the app's custom header treatment (see GroupRideView's own
            // webHeaderBar / Section Title Bar).
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("THE PACK")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundColor(.prMuted)
                        .tracking(2)
                    Text("Participants' Stats")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.prInk)
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.prInk)
                        .frame(width: 32, height: 32)
                        .background(Color.prFieldBg)
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.prCardBg)
            .overlay(Rectangle().fill(Color.prBorder).frame(height: 1), alignment: .bottom)

            ZStack {
                Color.prBg.ignoresSafeArea()
                if isLoading {
                    ProgressView().tint(.prCoral)
                } else if stats.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "person.3").font(.system(size: 30)).foregroundColor(.prMuted)
                        Text("No participant stats saved for this ride yet").font(.system(size: 13)).foregroundColor(.prMuted)
                            .multilineTextAlignment(.center).padding(.horizontal, 40)
                    }
                } else {
                    ScrollView {
                        // Flush list — one shared background, hairline dividers
                        // between rows instead of individually-boxed cards.
                        VStack(spacing: 0) {
                            ForEach(Array(stats.enumerated()), id: \.element.id) { index, stat in
                                if index > 0 {
                                    Rectangle().fill(Color.prBorder).frame(height: 1)
                                }
                                ParticipantStatCard(stat: stat, isMe: stat.name == myName && stat.initials == myInitials)
                            }
                        }
                        .background(Color.prCardBg)
                        .padding(16)
                    }
                }
            }
        }
        .background(Color.prBg.ignoresSafeArea())
        .onAppear {
            firebase.fetchFinalStats(rideCode: rideCode) { results in
                self.stats = results
                self.isLoading = false
            }
        }
    }
}

struct ParticipantStatCard: View {
    let stat: ParticipantStat
    let isMe: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(stat.isLeader ? Color.prCoralSoft : Color(red: 0.906, green: 0.937, blue: 0.945)).frame(width: 44, height: 44)
                Text(stat.initials).font(.system(size: 13, weight: .bold)).foregroundColor(stat.isLeader ? .prCoral : .prTeal)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(isMe ? "\(stat.name) (You)" : stat.name).font(.system(size: 14, weight: .semibold)).foregroundColor(.prInk)
                    if stat.isLeader {
                        Text("LEADER").font(.system(size: 9, weight: .heavy)).tracking(0.5).foregroundColor(.prCoral)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Color.prCoralSoft).cornerRadius(5)
                    }
                }
                HStack(spacing: 12) {
                    Text(stat.distanceString).font(.system(size: 12, design: .monospaced)).foregroundColor(.prMuted)
                    Text(stat.maxSpeedString).font(.system(size: 12, design: .monospaced)).foregroundColor(.prMuted)
                    Text(stat.duration).font(.system(size: 12, design: .monospaced)).foregroundColor(.prMuted)
                }
            }
            Spacer()
        }
        .padding(14)
    }
}

// MARK: - Replay Mode Picker
struct ReplayModeSheet: View {
    let rideCode: String
    let myGPXPath: String?
    let myName: String
    let myInitials: String
    @Environment(\.dismiss) var dismiss
    @State private var navigateToIndividualPicker = false
    @State private var navigateToGroupReplay = false

    // MARK: - Full-Bleed Web Sub-Screen Header
    // Aug 27, 2026 — replaces the default .navigationTitle/.toolbar "Cancel"
    // chrome, matching the custom header treatment used everywhere else in
    // this screen instead of leaving one native-looking modal in the flow.
    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("THE PACK")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(.prMuted)
                    .tracking(2)
                Text("Replay Ride")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.prInk)
            }
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.prInk)
                    .frame(width: 32, height: 32)
                    .background(Color.prFieldBg)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.prCardBg)
        .overlay(Rectangle().fill(Color.prBorder).frame(height: 1), alignment: .bottom)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header

                VStack(spacing: 14) {
                    Text("Replay this ride for one rider, or watch the whole group move together?")
                        .font(.system(size: 14)).foregroundColor(.prMuted)
                        .multilineTextAlignment(.center).padding(.horizontal, 24).padding(.top, 20)

                    // Flush option list — one shared background, hairline divider
                    // between rows instead of two separately-boxed cards.
                    VStack(spacing: 0) {
                        Button(action: { navigateToIndividualPicker = true }) {
                            HStack(spacing: 12) {
                                Image(systemName: "person.fill").font(.system(size: 18)).foregroundColor(.prCoral)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Individual Rider").font(.system(size: 15, weight: .bold)).foregroundColor(.prInk)
                                    Text("Pick one rider to replay").font(.system(size: 12)).foregroundColor(.prMuted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundColor(.prMuted)
                            }
                            .padding(16)
                        }
                        Rectangle().fill(Color.prBorder).frame(height: 1)
                        Button(action: { navigateToGroupReplay = true }) {
                            HStack(spacing: 12) {
                                Image(systemName: "person.3.fill").font(.system(size: 18)).foregroundColor(.prTeal)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Whole Group").font(.system(size: 15, weight: .bold)).foregroundColor(.prInk)
                                    Text("Watch everyone move together").font(.system(size: 12)).foregroundColor(.prMuted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundColor(.prMuted)
                            }
                            .padding(16)
                        }
                    }
                    .background(Color.prCardBg)
                    Spacer()
                }
                .padding(.horizontal, 16)
            }
            .background(Color.prBg.ignoresSafeArea())
            .navigationBarHidden(true)
            .navigationDestination(isPresented: $navigateToIndividualPicker) {
                IndividualReplayPickerView(rideCode: rideCode, myGPXPath: myGPXPath, myName: myName, myInitials: myInitials)
            }
            .navigationDestination(isPresented: $navigateToGroupReplay) {
                GroupReplayView(rideCode: rideCode, myGPXPath: myGPXPath, myName: myName, myInitials: myInitials)
            }
        }
    }
}

// MARK: - Individual Rider Picker
struct IndividualReplayPickerView: View {
    let rideCode: String
    let myGPXPath: String?
    let myName: String
    let myInitials: String
    @Environment(\.dismiss) var dismiss
    @State private var others: [ParticipantStat] = []
    @State private var isLoading = true
    @State private var isFetchingTrack = false
    @State private var selectedGPXPath: String? = nil
    @State private var selectedName = ""
    @State private var showReplay = false
    private let firebase = FirebaseManager()

    // MARK: - Full-Bleed Web Sub-Screen Header
    // Aug 27, 2026 — replaces the default .navigationTitle back-chevron
    // chrome with the same custom back-circle + eyebrow/title pattern used
    // for GroupRideView's own in-room header.
    private var header: some View {
        HStack(spacing: 12) {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.prInk)
                    .frame(width: 32, height: 32)
                    .background(Color.prCardBg)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.prBorder, lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("THE PACK")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(.prMuted)
                    .tracking(2)
                Text("Pick a Rider")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.prInk)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.prCardBg)
        .overlay(Rectangle().fill(Color.prBorder).frame(height: 1), alignment: .bottom)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ZStack {
                Color.prBg.ignoresSafeArea()
                if isLoading {
                    ProgressView().tint(.prCoral)
                } else {
                    ScrollView {
                        // Flush list — one shared background, hairline dividers
                        // between rows instead of individually-boxed cards.
                        VStack(spacing: 0) {
                            Button(action: { pickLocal() }) {
                                pickerRow(initials: myInitials, name: "\(myName) (You)", enabled: myGPXPath != nil)
                            }
                            .disabled(myGPXPath == nil)

                            ForEach(others) { stat in
                                Rectangle().fill(Color.prBorder).frame(height: 1)
                                Button(action: { fetchAndPick(stat) }) {
                                    pickerRow(initials: stat.initials, name: stat.name, enabled: true)
                                }
                            }
                        }
                        .background(Color.prCardBg)
                        .padding(16)
                    }
                }
                if isFetchingTrack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    VStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text("Loading route\u{2026}").font(.system(size: 13)).foregroundColor(.white)
                    }
                    .padding(20).background(Color.prInkFixed).cornerRadius(14)
                }
            }
        }
        .background(Color.prBg.ignoresSafeArea())
        .navigationBarHidden(true)
        .onAppear {
            firebase.fetchFinalStats(rideCode: rideCode) { results in
                self.others = results.filter { !($0.name == myName && $0.initials == myInitials) }
                self.isLoading = false
            }
        }
        .fullScreenCover(isPresented: $showReplay) {
            if let path = selectedGPXPath {
                RideReplayView(gpxFilePath: path, rideName: selectedName, rideDate: "")
            }
        }
    }

    func pickerRow(initials: String, name: String, enabled: Bool) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.prCoralSoft).frame(width: 40, height: 40)
                Text(initials).font(.system(size: 12, weight: .bold)).foregroundColor(.prCoral)
            }
            Text(name).font(.system(size: 15, weight: .semibold)).foregroundColor(enabled ? .prInk : .prMuted)
            Spacer()
            if enabled {
                Image(systemName: "play.circle.fill").font(.system(size: 20)).foregroundColor(.prCoral)
            } else {
                Text("No route saved").font(.system(size: 11)).foregroundColor(.prMuted)
            }
        }
        .padding(14)
    }

    func pickLocal() {
        guard let path = myGPXPath else { return }
        selectedName = "\(myName) (You)"; selectedGPXPath = path; showReplay = true
    }

    func fetchAndPick(_ stat: ParticipantStat) {
        isFetchingTrack = true
        firebase.fetchTrack(rideCode: rideCode, deviceID: stat.deviceID) { points in
            isFetchingTrack = false
            guard let filename = GPXStorage.synthesizeGPX(from: points, rideName: "\(stat.name)_\(rideCode)") else { return }
            selectedName = stat.name; selectedGPXPath = filename; showReplay = true
        }
    }
}

// MARK: - Group Replay
struct GroupReplayRider: Identifiable {
    let id: String
    let name: String
    let initials: String
    let isLeader: Bool
    let points: [(coordinate: CLLocationCoordinate2D, timestamp: Date, speed: Double)]

    func position(at absoluteTime: Date) -> CLLocationCoordinate2D? {
        guard let first = points.first, let last = points.last else { return nil }
        if absoluteTime <= first.timestamp { return first.coordinate }
        if absoluteTime >= last.timestamp { return last.coordinate }
        var best = first
        for p in points {
            if p.timestamp > absoluteTime { break }
            best = p
        }
        return best.coordinate
    }

    func speed(at absoluteTime: Date) -> Double {
        guard let first = points.first else { return 0 }
        var best = first
        for p in points {
            if p.timestamp > absoluteTime { break }
            best = p
        }
        return best.speed
    }
}

struct GroupReplayView: View {
    let rideCode: String
    let myGPXPath: String?
    let myName: String
    let myInitials: String
    @Environment(\.dismiss) var dismiss

    @State private var riders: [GroupReplayRider] = []
    @State private var isLoading = true
    @State private var rideStart = Date()
    @State private var rideEnd = Date()
    @State private var elapsed: Double = 0
    @State private var isPlaying = false
    @State private var timer: Timer?
    @State private var speedMultiplier: Double = 20
    @State private var cameraPosition: MapCameraPosition = .automatic
    private let firebase = FirebaseManager()

    var totalDuration: Double { max(rideEnd.timeIntervalSince(rideStart), 1) }
    var currentAbsoluteTime: Date { rideStart.addingTimeInterval(elapsed) }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.prBg.ignoresSafeArea()
            if isLoading {
                ProgressView("Loading everyone's route\u{2026}").tint(.prCoral)
            } else if riders.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "person.3").font(.system(size: 30)).foregroundColor(.prMuted)
                    Text("No synced routes for this ride yet").font(.system(size: 13)).foregroundColor(.prMuted)
                        .multilineTextAlignment(.center).padding(.horizontal, 40)
                }
            } else {
                Map(position: $cameraPosition) {
                    ForEach(riders) { rider in
                        if let coord = rider.position(at: currentAbsoluteTime) {
                            Annotation(rider.name, coordinate: coord, anchor: .bottom) {
                                RiderMapPin(initials: rider.initials, name: rider.name, speed: rider.speed(at: currentAbsoluteTime) * 2.23694)
                            }
                        }
                    }
                }
                .mapStyle(.hybrid(elevation: .realistic, showsTraffic: false))
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    controls
                }
            }
        }
        .onAppear { loadAllTracks() }
        .onDisappear { timer?.invalidate() }
    }

    private var topBar: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 26)).foregroundColor(.prMuted)
            }
            Spacer()
            Text("GROUP REPLAY").font(.system(size: 10, weight: .heavy)).foregroundColor(.prCoral).tracking(1.5)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.prCoralSoft).cornerRadius(8)
            Spacer()
            Text("\(riders.count) riders").font(.system(size: 11, design: .monospaced)).foregroundColor(.prMuted)
        }
        .padding(.horizontal, 16).padding(.top, 50).padding(.bottom, 12)
        .background(Color.prCardBg)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Slider(value: Binding(
                get: { elapsed },
                set: { newVal in
                    elapsed = newVal
                    recenterCamera()
                }
            ), in: 0...totalDuration)
            .tint(.prCoral)

            HStack(spacing: 20) {
                Button(action: { speedMultiplier = max(5, speedMultiplier - 15) }) {
                    Image(systemName: "backward.fill").font(.system(size: 16)).foregroundColor(.prInk)
                }
                Button(action: togglePlay) {
                    ZStack {
                        Circle().fill(Color.prCoral).frame(width: 56, height: 56)
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22)).foregroundColor(.white)
                    }
                }
                Button(action: { speedMultiplier = min(120, speedMultiplier + 15) }) {
                    Image(systemName: "forward.fill").font(.system(size: 16)).foregroundColor(.prInk)
                }
                Text("\(Int(speedMultiplier))x").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundColor(.prMuted)
            }
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 34)
        .background(Color.prCardBg)
    }

    func togglePlay() {
        isPlaying.toggle()
        if isPlaying {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                if elapsed < totalDuration {
                    elapsed = min(totalDuration, elapsed + (speedMultiplier * 0.5))
                    recenterCamera()
                } else {
                    isPlaying = false
                    timer?.invalidate()
                }
            }
        } else {
            timer?.invalidate()
        }
    }

    func recenterCamera() {
        let coords = riders.compactMap { $0.position(at: currentAbsoluteTime) }
        guard !coords.isEmpty else { return }
        let lats = coords.map { $0.latitude }, lngs = coords.map { $0.longitude }
        guard let minLat = lats.min(), let maxLat = lats.max(), let minLng = lngs.min(), let maxLng = lngs.max() else { return }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.6, 0.008),
            longitudeDelta: max((maxLng - minLng) * 1.6, 0.008)
        )
        withAnimation(.linear(duration: 0.4)) {
            cameraPosition = .region(MKCoordinateRegion(center: center, span: span))
        }
    }

    func loadAllTracks() {
        firebase.fetchFinalStats(rideCode: rideCode) { stats in
            var loaded: [GroupReplayRider] = []
            let group = DispatchGroup()

            if let path = myGPXPath, let points = parseGPXWithTimestamps(path) {
                let myStat = stats.first(where: { $0.name == myName && $0.initials == myInitials })
                loaded.append(GroupReplayRider(id: "me", name: "\(myName) (You)", initials: myInitials, isLeader: myStat?.isLeader ?? false, points: points))
            }

            for stat in stats where !(stat.name == myName && stat.initials == myInitials) {
                group.enter()
                firebase.fetchTrack(rideCode: rideCode, deviceID: stat.deviceID) { fbPoints in
                    let pts = fbPoints.map {
                        (coordinate: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng),
                         timestamp: Date(timeIntervalSince1970: $0.timestamp), speed: $0.speed)
                    }
                    if !pts.isEmpty {
                        loaded.append(GroupReplayRider(id: stat.deviceID, name: stat.name, initials: stat.initials, isLeader: stat.isLeader, points: pts))
                    }
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                self.riders = loaded
                if let start = loaded.compactMap({ $0.points.first?.timestamp }).min(),
                   let end = loaded.compactMap({ $0.points.last?.timestamp }).max(), end > start {
                    self.rideStart = start
                    self.rideEnd = end
                }
                self.isLoading = false
                self.recenterCamera()
            }
        }
    }

    func parseGPXWithTimestamps(_ path: String) -> [(coordinate: CLLocationCoordinate2D, timestamp: Date, speed: Double)]? {
        guard let data = GPXStorage.contents(path), let xmlString = String(data: data, encoding: .utf8) else { return nil }
        var points: [(coordinate: CLLocationCoordinate2D, timestamp: Date, speed: Double)] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let blocks = xmlString.components(separatedBy: "<trkpt ")
        for block in blocks.dropFirst() {
            var lat = 0.0, lng = 0.0, spd = 0.0
            var ts: Date? = nil
            if let latRange = block.range(of: #"lat="([\-\d.]+)""#, options: .regularExpression),
               let lngRange = block.range(of: #"lon="([\-\d.]+)""#, options: .regularExpression) {
                lat = Double(block[latRange].replacingOccurrences(of: "lat=", with: "").replacingOccurrences(of: "\"", with: "")) ?? 0
                lng = Double(block[lngRange].replacingOccurrences(of: "lon=", with: "").replacingOccurrences(of: "\"", with: "")) ?? 0
            }
            if let timeRange = block.range(of: #"<time>([^<]+)</time>"#, options: .regularExpression) {
                let timeStr = block[timeRange].replacingOccurrences(of: "<time>", with: "").replacingOccurrences(of: "</time>", with: "")
                ts = iso.date(from: timeStr)
            }
            if let spdRange = block.range(of: #"<speed>([\-\d.]+)</speed>"#, options: .regularExpression) {
                spd = Double(block[spdRange].replacingOccurrences(of: "<speed>", with: "").replacingOccurrences(of: "</speed>", with: "")) ?? 0
            }
            if lat != 0 && lng != 0, let t = ts {
                points.append((coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng), timestamp: t, speed: spd))
            }
        }
        return points.isEmpty ? nil : points
    }
}
