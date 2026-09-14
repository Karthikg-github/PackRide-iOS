import SwiftUI
import MapKit
import UIKit

// MARK: - Schedule Ride Sheet
struct ScheduleRideSheet: View {
    let rideCode: String
    let onScheduled: () -> Void
    @AppStorage("riderName") var riderName: String = "Rider"
    @StateObject private var scheduleManager = ScheduledRideManager()
    @Environment(\.dismiss) var dismiss
    @State private var showDeleteConfirm = false

    @State private var title = ""
    @State private var description = ""
    @State private var scheduledDate = Date().addingTimeInterval(3600)
    @State private var meetupLocation = ""
    @EnvironmentObject var communityStore: CommunityMembershipStore
    // Which single community (if any) to share this ride with — a scheduled
    // ride's Firebase record only ever carries one communityID (unchanged
    // schema), so with multiple communities this is a pick-one, not a
    // multi-select like the solo-ride live-share flow.
    @State private var selectedCommunityID: String? = nil
    @State private var isCreating = false

    var body: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.prBorder)
                        .frame(width: 40, height: 5).padding(.top, 12)

                    VStack(spacing: 6) {
                        Image(systemName: "calendar.badge.clock").font(.system(size: 34)).foregroundColor(.prTeal)
                        Text("Schedule a Ride").font(.system(size: 22, weight: .bold)).foregroundColor(.prInk)
                        Text("Plan ahead and invite your pack").font(.system(size: 13)).foregroundColor(.prMuted)
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "number").foregroundColor(.prCoral).font(.system(size: 12))
                        Text("Ride Code: \(rideCode)").font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundColor(.prCoral)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.prCoralSoft).cornerRadius(10)

                    VStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("RIDE TITLE").font(.system(size: 10, weight: .heavy)).foregroundColor(.prMuted).tracking(1.5)
                            HStack(spacing: 10) {
                                Image(systemName: "arrowtriangle.up.fill").foregroundColor(.prCoral).frame(width: 20)
                                TextField("", text: $title, prompt: Text("e.g. Sunday Coast Cruise").foregroundColor(.prMuted)).font(.system(size: 15)).foregroundColor(.prInk)
                            }
                            .padding(14).background(Color.prCardBg).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, lineWidth: 1)).cornerRadius(14)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("DESCRIPTION").font(.system(size: 10, weight: .heavy)).foregroundColor(.prMuted).tracking(1.5)
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "text.alignleft").foregroundColor(.prTeal).frame(width: 20).padding(.top, 2)
                                TextField("", text: $description, prompt: Text("Route details, what to bring...").foregroundColor(.prMuted), axis: .vertical)
                                    .font(.system(size: 14)).foregroundColor(.prInk).lineLimit(3...6)
                            }
                            .padding(14).background(Color.prCardBg).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, lineWidth: 1)).cornerRadius(14)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("DATE & TIME").font(.system(size: 10, weight: .heavy)).foregroundColor(.prMuted).tracking(1.5)
                            DatePicker("", selection: $scheduledDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                                .datePickerStyle(.compact)
                                .labelsHidden()
                                .tint(.prCoral)
                                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.prCardBg).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, lineWidth: 1)).cornerRadius(14)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("MEETUP POINT").font(.system(size: 10, weight: .heavy)).foregroundColor(.prMuted).tracking(1.5)
                            HStack(spacing: 10) {
                                Image(systemName: "mappin.circle.fill").foregroundColor(Color(red: 0.180, green: 0.620, blue: 0.357)).frame(width: 20)
                                TextField("", text: $meetupLocation, prompt: Text("e.g. Starbucks on Main St").foregroundColor(.prMuted)).font(.system(size: 15)).foregroundColor(.prInk)
                            }
                            .padding(14).background(Color.prCardBg).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, lineWidth: 1)).cornerRadius(14)
                        }
                    }
                    .padding(.horizontal, 20)

                    if !communityStore.myCommunities.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("SHARE TO COMMUNITY").font(.system(size: 10, weight: .heavy)).foregroundColor(.prMuted).tracking(1.5)
                                .padding(.horizontal, 20)

                            // A single joined community keeps the original one-tap
                            // toggle. Belonging to more than one needs an actual
                            // pick-one instead — tapping a row selects it, tapping
                            // the already-selected row clears it back to "don't share."
                            if communityStore.myCommunities.count == 1, let only = communityStore.myCommunities.first {
                                communityToggleRow(only)
                            } else {
                                VStack(spacing: 8) {
                                    ForEach(communityStore.myCommunities) { community in
                                        communityToggleRow(community)
                                    }
                                }
                            }
                        }
                    }

                    Button(action: scheduleRide) {
                        HStack(spacing: 10) {
                            if isCreating { ProgressView().tint(.white) }
                            else { Image(systemName: "calendar.badge.plus").font(.system(size: 18)) }
                            Text(isCreating ? "Scheduling..." : "Schedule Ride").font(.system(size: 16, weight: .bold))
                        }
                        .foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(canSchedule ? Color.prTeal : Color.prTeal.opacity(0.4))
                        .cornerRadius(16)
                    }
                    .disabled(!canSchedule || isCreating)
                    .padding(.horizontal, 20)

                    Button(action: { dismiss() }) {
                        Text("Cancel").font(.system(size: 14)).foregroundColor(.prMuted)
                    }

                    Spacer().frame(height: 40)
                }
            }
        }
    }

    var canSchedule: Bool { !title.isEmpty && scheduledDate > Date() }

    @ViewBuilder
    private func communityToggleRow(_ community: Community) -> some View {
        let isSelected = selectedCommunityID == community.id
        Button(action: {
            withAnimation { selectedCommunityID = isSelected ? nil : community.id }
        }) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(isSelected ? Color(red: 0.541, green: 0.4, blue: 0.694) : Color(red: 0.941, green: 0.925, blue: 0.898)).frame(width: 42, height: 42)
                    Image(systemName: "person.3.fill").font(.system(size: 16)).foregroundColor(isSelected ? .white : .prMuted)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(community.name).font(.system(size: 15, weight: .semibold)).foregroundColor(.prInk)
                    Text(isSelected ? "All members will see this ride" : "Tap to share with this community")
                        .font(.system(size: 11)).foregroundColor(.prMuted)
                }
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isSelected ? Color(red: 0.541, green: 0.4, blue: 0.694) : Color(red: 0.941, green: 0.925, blue: 0.898))
                        .frame(width: 48, height: 28)
                    Circle().fill(Color.white).frame(width: 22, height: 22)
                        .offset(x: isSelected ? 10 : -10)
                        .animation(.spring(response: 0.3), value: isSelected)
                }
            }
            .padding(14)
            .background(Color.prCardBg)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, lineWidth: 1))
            .cornerRadius(14)
        }
        .padding(.horizontal, 20)
    }

    func scheduleRide() {
        isCreating = true
        scheduleManager.createScheduledRide(
            title: title, description: description, rideCode: rideCode,
            scheduledDate: scheduledDate, meetupLocation: meetupLocation,
            meetupLat: 0, meetupLng: 0, creatorName: riderName,
            communityID: selectedCommunityID
        ) { success in
            isCreating = false
            if success { onScheduled(); dismiss() }
        }
    }
}

// MARK: - Scheduled Ride Detail View
struct ScheduledRideDetailView: View {
    let ride: ScheduledRide
    @AppStorage("riderName") var riderName: String = "Rider"
    @StateObject private var scheduleManager = ScheduledRideManager()
    @Environment(\.dismiss) var dismiss
    @State private var showDeleteConfirm = false
    @State private var showCommunityPicker = false
    @State private var selectedCommunityID: String?
    @State private var savedWaypoints: [Waypoint] = []
    @EnvironmentObject private var communityStore: CommunityMembershipStore
    @State private var showRouteMap = false
    // Aug 28, 2026 — stops + destination only, excluding a rider-picked
    // starting point override that may now be mixed into savedWaypoints
    // (see Waypoint.isStartOverride).
    private var routeWaypoints: [Waypoint] { savedWaypoints.filter { !$0.isStartOverride } }

    init(ride: ScheduledRide) {
        self.ride = ride
        _selectedCommunityID = State(initialValue: ride.communityID?.isEmpty == false ? ride.communityID : nil)
    }

    var isCreator: Bool { ride.creatorID == (Auth.auth().currentUser?.uid ?? "") }

    var body: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    PRWebPageHeader(
                        eyebrow: "Ride Details",
                        title: ride.title,
                        subtitle: "\(ride.formattedDateTime) · \(ride.timeUntil)",
                        accent: .prTeal
                    )

                    VStack(spacing: 20) {
                    VStack(spacing: 12) {
                        InfoCard(icon: "number", label: "Ride Code", value: ride.rideCode, color: .prCoral)
                        InfoCard(icon: "person.fill", label: "Organizer", value: ride.creatorName, color: .prTeal)

                        if !ride.meetupLocation.isEmpty {
                            InfoCard(icon: "mappin.circle.fill", label: "Meetup Point", value: ride.meetupLocation, color: Color(red: 0.180, green: 0.620, blue: 0.357))
                        }

                        // Aug 28, 2026 — savedWaypoints comes from the same
                        // GroupWaypointSync feed WaypointsView/GroupRideView
                        // use, which can now include a rider-picked starting
                        // point override (Waypoint.isStartOverride) at index
                        // 0 — filtered out here the same way, so it renders
                        // as the map's start rather than an extra numbered
                        // stop or the initial camera center.
                        if !routeWaypoints.isEmpty {
                            Button(action: { showRouteMap = true }) {
                                ZStack(alignment: .topTrailing) {
                                    RouteMapView(waypoints: routeWaypoints, region: .constant(MKCoordinateRegion(
                                        center: routeWaypoints.first!.coordinate,
                                        span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
                                    )), mapStyleIndex: 2, startOverride: savedWaypoints.first(where: { $0.isStartOverride }))
                                    .frame(height: 160)
                                    .cornerRadius(14)
                                    .allowsHitTesting(false)

                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10, weight: .bold))
                                        Text("View Map").font(.system(size: 11, weight: .bold))
                                    }
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Color.prInkFixed.opacity(0.85))
                                    .cornerRadius(8)
                                    .padding(8)
                                }
                            }
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, lineWidth: 1))
                        }

                        if !ride.description.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Image(systemName: "text.alignleft").foregroundColor(Color(red: 0.541, green: 0.4, blue: 0.694)).font(.system(size: 14))
                                    Text("Details").font(.system(size: 12, weight: .semibold)).foregroundColor(.prMuted)
                                }
                                Text(ride.description).font(.system(size: 14)).foregroundColor(.prInk).lineSpacing(3)
                            }
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.prCardBg).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, lineWidth: 1)).cornerRadius(14)
                        }
                    }
                    .padding(.horizontal, 20)

                    // Share the scheduled ride externally (Messages, WhatsApp,
                    // social apps, AirDrop, etc.) and optionally attach it to one
                    // of the rider's PackRide communities after scheduling.
                    VStack(spacing: 10) {
                        ShareLink(item: shareMessage) {
                            HStack(spacing: 10) {
                                Image(systemName: "square.and.arrow.up.fill")
                                Text("Share Ride")
                            }
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(Color.prCoral)
                            .cornerRadius(15)
                        }

                        if isCreator && !communityStore.myCommunities.isEmpty {
                            Button(action: { showCommunityPicker = true }) {
                                HStack(spacing: 10) {
                                    Image(systemName: selectedCommunityID == nil ? "person.3" : "person.3.fill")
                                    Text(selectedCommunityID == nil ? "Share to a Community" : "Change Community")
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                                }
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.prInk)
                                .padding(14)
                                .frame(maxWidth: .infinity)
                                .background(Color.prFieldBg)
                                .cornerRadius(13)
                                .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.prBorder, lineWidth: 1))
                            }
                        }
                    }
                    .padding(.horizontal, 20)

                    ScheduledRideRidersSection(rsvps: scheduleManager.rsvpList)
                        .padding(.horizontal, 20)

                    if !isCreator {
                        VStack(spacing: 10) {
                            if scheduleManager.myRSVPStatus == .going {
                                Button(action: { scheduleManager.cancelRSVP(rideID: ride.id) }) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "checkmark.circle.fill").foregroundColor(Color(red: 0.180, green: 0.620, blue: 0.357))
                                        Text("You're Going!").font(.system(size: 16, weight: .bold))
                                    }
                                    .foregroundColor(Color(red: 0.180, green: 0.620, blue: 0.357)).frame(maxWidth: .infinity).padding(.vertical, 16)
                                    .background(Color(red: 0.891, green: 0.965, blue: 0.918)).cornerRadius(16)
                                }

                                Text("Tap to cancel RSVP").font(.system(size: 11)).foregroundColor(.prMuted)
                            } else {
                                Button(action: { scheduleManager.rsvp(rideID: ride.id, status: .going, name: riderName) }) {
                                    HStack(spacing: 10) {
                                        Image(systemName: "hand.thumbsup.fill").font(.system(size: 18))
                                        Text("I'm In!").font(.system(size: 17, weight: .bold))
                                    }
                                    .foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 16)
                                    .background(Color(red: 0.180, green: 0.620, blue: 0.357))
                                    .cornerRadius(16)
                                }

                                Button(action: { scheduleManager.rsvp(rideID: ride.id, status: .maybe, name: riderName) }) {
                                    Text("Maybe").font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.prMuted).frame(maxWidth: .infinity).padding(.vertical, 14)
                                        .background(Color.prCardBg).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, lineWidth: 1)).cornerRadius(14)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }

                    // Delete option for creator
                    if isCreator {
                        Button(action: { showDeleteConfirm = true }) {
                            HStack(spacing: 8) {
                                Image(systemName: "trash").font(.system(size: 14))
                                Text("Delete This Ride").font(.system(size: 14, weight: .semibold))
                            }
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Color.red.opacity(0.08)).cornerRadius(14)
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.red.opacity(0.2), lineWidth: 1))
                        }
                        .padding(.horizontal, 20)
                    }

                    Spacer().frame(height: 40)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .alert("Delete Scheduled Ride?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                scheduleManager.deleteRide(rideID: ride.id, communityID: ride.communityID)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove this ride and notify all RSVPs.")
        }
        .sheet(isPresented: $showCommunityPicker) {
            ScheduledRideCommunityPicker(
                communities: communityStore.myCommunities,
                selectedCommunityID: selectedCommunityID,
                onSelect: { community in
                    let oldID = selectedCommunityID
                    let newID = community?.id
                    scheduleManager.shareToCommunity(
                        rideID: ride.id,
                        newCommunityID: newID,
                        oldCommunityID: oldID
                    ) { success in
                        if success {
                            selectedCommunityID = newID
                            showCommunityPicker = false
                        }
                    }
                }
            )
        }
        .onAppear {
            scheduleManager.loadRSVPs(rideID: ride.id)
            loadWaypoints()
        }
        .navigationBarHidden(true)
        .fullScreenCover(isPresented: $showRouteMap) {
            RidePlannedRouteView(waypoints: savedWaypoints, rideTitle: ride.title)
        }
    }

    private var shareMessage: String {
        var message = "Join my PackRide scheduled ride! 🏍️\n\n\(ride.title)\n\(ride.formattedDateTime)"
        if !ride.meetupLocation.isEmpty { message += "\nMeetup: \(ride.meetupLocation)" }
        message += "\nRide code: \(ride.rideCode)"
        message += "\n\nOpen PackRide and enter the ride code to join."
        return message
    }

    // Aug 22, 2026 — bug #9: this used to read the LOCAL "waypoints_{code}"
    // key, which only ever existed on whichever phone actually set the
    // route — for anyone who wasn't that device (i.e. every RSVP'd
    // participant looking at "View Planned Route" before the ride even
    // starts), this silently found nothing. Now reads the same
    // Firebase-synced copy the live ride uses (see GroupWaypointSync).
    func loadWaypoints() {
        GroupWaypointSync.fetchOnce(rideCode: ride.rideCode) { waypoints in
            savedWaypoints = waypoints
        }
    }
}

// MARK: - Scheduled Ride Riders Section
private struct ScheduledRideRidersSection: View {
    let rsvps: [RSVPEntry]

    private var goingCount: Int {
        rsvps.filter { $0.status == .going }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("RIDERS")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundColor(.prMuted)
                    .tracking(2)
                Spacer()
                Text("\(goingCount) going")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(red: 0.180, green: 0.620, blue: 0.357))
            }

            ForEach(rsvps) { rsvp in
                ScheduledRideRSVPRow(rsvp: rsvp)
            }
        }
        .padding(16)
        .background(Color.prCardBg)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.prBorder, lineWidth: 1))
        .cornerRadius(18)
    }
}

private struct ScheduledRideRSVPRow: View {
    let rsvp: RSVPEntry

    private var isGoing: Bool {
        rsvp.status == .going
    }

    private var statusColor: Color {
        isGoing ? Color(red: 0.180, green: 0.620, blue: 0.357) : .prMuted
    }

    private var statusBackground: Color {
        isGoing ? Color(red: 0.891, green: 0.965, blue: 0.918) : Color(red: 0.941, green: 0.925, blue: 0.898)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusBackground)
                    .frame(width: 40, height: 40)
                Text(rsvp.initials)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(statusColor)
            }

            Text(rsvp.name)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.prInk)

            Spacer()

            Text(rsvp.status.rawValue.capitalized)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(statusColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(statusBackground)
                .cornerRadius(8)
        }
        .padding(10)
        .background(Color.prFieldBg)
        .cornerRadius(12)
    }
}

// MARK: - Scheduled Ride Community Picker
private struct ScheduledRideCommunityPicker: View {
    let communities: [Community]
    let selectedCommunityID: String?
    let onSelect: (Community?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button {
                    onSelect(nil)
                } label: {
                    HStack {
                        Label("No Community", systemImage: "person.3")
                        Spacer()
                        if selectedCommunityID == nil { Image(systemName: "checkmark") }
                    }
                }
                ForEach(communities) { community in
                    Button {
                        onSelect(community)
                    } label: {
                        HStack {
                            Label(community.name, systemImage: "person.3.fill")
                            Spacer()
                            if selectedCommunityID == community.id { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            .navigationTitle("Share to Community")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

// MARK: - Ride Planned Route View (full-screen map: route + live location)
struct RidePlannedRouteView: View {
    let waypoints: [Waypoint]
    let rideTitle: String
    @Environment(\.dismiss) var dismiss
    @State private var showDeleteConfirm = false
    @State private var mapStyleIndex = 2 // Hybrid by default so street names are visible
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.33, longitude: -122.03),
        span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
    )

    var body: some View {
        ZStack(alignment: .top) {
            // Aug 28, 2026 — waypoints (from the Firebase-synced route) can
            // include a rider-picked starting point override — pulled out
            // and passed separately so it renders as the map's actual
            // start, same as WaypointsView/GroupRideView.
            RouteMapView(
                waypoints: waypoints.filter { !$0.isStartOverride },
                region: $region,
                mapStyleIndex: mapStyleIndex,
                startOverride: waypoints.first(where: { $0.isStartOverride })
            )
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 26)).foregroundColor(.prMuted)
                    }
                    Spacer()
                    Text(rideTitle).font(.system(size: 15, weight: .bold)).foregroundColor(.prInk)
                    Spacer()
                    Text("\(waypoints.count) stop\(waypoints.count == 1 ? "" : "s")")
                        .font(.system(size: 11)).foregroundColor(.prMuted)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.prCardBg).cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.prBorder, lineWidth: 1))
                }
                .padding(.horizontal, 16).padding(.top, 50).padding(.bottom, 12)
                .background(Color.prCardBg)

                HStack {
                    Spacer()
                    MapStylePickerView(selectedIndex: $mapStyleIndex).padding(.trailing, 16).padding(.top, 8)
                }

                Spacer()
            }
        }
    }
}

// MARK: - Info Card
struct InfoCard: View {
    let icon: String; let label: String; let value: String; let color: Color
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundColor(color).font(.system(size: 16)).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 10, weight: .medium)).foregroundColor(.prMuted)
                Text(value).font(.system(size: 15, weight: .semibold)).foregroundColor(.prInk)
            }
            Spacer()
        }
        .padding(14).background(Color.prCardBg).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, lineWidth: 1)).cornerRadius(14)
    }
}

// MARK: - Upcoming Rides Card (for GroupRideView)
struct UpcomingRidesSection: View {
    @StateObject private var scheduleManager = ScheduledRideManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "calendar.badge.clock").foregroundColor(.prTeal)
                Text("Upcoming Rides").font(.system(size: 16, weight: .bold)).foregroundColor(.prInk)
                Spacer()
                if !scheduleManager.communityRides.isEmpty {
                    Text("\(scheduleManager.communityRides.count)")
                        .font(.system(size: 11, weight: .bold)).foregroundColor(.prTeal)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color(red: 0.906, green: 0.937, blue: 0.945)).cornerRadius(8)
                }
            }

            if scheduleManager.communityRides.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "calendar").foregroundColor(.prMuted)
                    Text("No upcoming rides scheduled").font(.system(size: 13)).foregroundColor(.prMuted)
                }
                .padding(14)
            } else {
                // Flush list — one shared field band, hairline dividers
                // between rows instead of individually-boxed cards (Aug 27,
                // 2026 — matches the rest of the Group Ride flow).
                VStack(spacing: 0) {
                    ForEach(Array(scheduleManager.communityRides.prefix(3).enumerated()), id: \.element.id) { index, ride in
                        if index > 0 {
                            Rectangle().fill(Color.prBorder).frame(height: 1)
                        }
                        NavigationLink(destination: ScheduledRideDetailView(ride: ride)) {
                            HStack(spacing: 12) {
                                VStack(spacing: 2) {
                                    Text(ride.formattedDate.components(separatedBy: " ").first ?? "")
                                        .font(.system(size: 11, weight: .bold)).foregroundColor(.prTeal)
                                    Text(ride.formattedDate.components(separatedBy: " ").dropFirst().first ?? "")
                                        .font(.system(size: 18, weight: .bold)).foregroundColor(.prInk)
                                }
                                .frame(width: 48)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(ride.title).font(.system(size: 14, weight: .semibold)).foregroundColor(.prInk).lineLimit(1)
                                    HStack(spacing: 6) {
                                        Text(ride.formattedTime).font(.system(size: 11)).foregroundColor(.prMuted)
                                        Text("by \(ride.creatorName)").font(.system(size: 11)).foregroundColor(.prMuted)
                                    }
                                }

                                Spacer()

                                VStack(spacing: 2) {
                                    Text("\(ride.rsvpCount)").font(.system(size: 14, weight: .bold)).foregroundColor(Color(red: 0.180, green: 0.620, blue: 0.357))
                                    Text("going").font(.system(size: 9)).foregroundColor(Color(red: 0.180, green: 0.620, blue: 0.357))
                                }

                                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundColor(.prMuted)
                            }
                            .padding(12)
                        }
                    }
                }
                .background(Color.prFieldBg)
            }
        }
        .padding(20)
        .background(Color.prCardBg)
        .padding(.horizontal, 16)
        .onAppear { scheduleManager.listenForUpcomingRides() }
    }
}

// MARK: - Community Scheduled Rides Section (for CommunityDashboard)
struct CommunityScheduledRidesSection: View {
    let communityID: String
    // When true, renders just the section content with no card chrome of its
    // own — used by CommunityDashboard, which now merges this into one
    // bordered card alongside the community's identity/passcode, Riding Now,
    // and Members sections (see CommunityView.swift, Aug 21, 2026). Standalone
    // use (default false) keeps its own card exactly as before.
    var embedded: Bool = false
    @StateObject private var scheduleManager = ScheduledRideManager()
    @AppStorage("riderName") var riderName: String = "Rider"

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                content
                    .padding(20)
                    .background(Color.prCardBg)
                    .cornerRadius(22)
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.prBorder, lineWidth: 1))
                    .padding(.horizontal, 16)
            }
        }
        .onAppear {
            if !communityID.isEmpty { scheduleManager.listenForCommunityRides(communityID: communityID) }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.clock").foregroundColor(.prTeal)
                    Text("Scheduled Rides").font(.system(size: 16, weight: .bold)).foregroundColor(.prInk)
                }
                Spacer()
                if !scheduleManager.communityRides.isEmpty {
                    Text("\(scheduleManager.communityRides.count)")
                        .font(.system(size: 11, weight: .bold)).foregroundColor(.prTeal)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color(red: 0.906, green: 0.937, blue: 0.945)).cornerRadius(8)
                }
            }

            if scheduleManager.communityRides.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "calendar").font(.system(size: 26)).foregroundColor(.prMuted)
                    Text("No upcoming rides").font(.system(size: 14, weight: .medium)).foregroundColor(.prMuted)
                    Text("Schedule a group ride and share it here").font(.system(size: 12)).foregroundColor(.prMuted)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 20)
            } else {
                VStack(spacing: 0) {
                    ForEach(scheduleManager.communityRides) { ride in
                        NavigationLink(destination: ScheduledRideDetailView(ride: ride)) {
                            CommunityRideCard(ride: ride)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Community Ride Card
struct CommunityRideCard: View {
    let ride: ScheduledRide

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 1) {
                Text(monthStr).font(.system(size: 10, weight: .heavy)).foregroundColor(.prTeal).tracking(1)
                Text(dayStr).font(.system(size: 22, weight: .bold)).foregroundColor(.prInk)
            }
            .frame(width: 50, height: 54)
            .background(Color(red: 0.906, green: 0.937, blue: 0.945))
            .cornerRadius(12)

            VStack(alignment: .leading, spacing: 4) {
                Text(ride.title).font(.system(size: 14, weight: .semibold)).foregroundColor(.prInk).lineLimit(1)
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock").font(.system(size: 10))
                        Text(ride.formattedTime)
                    }
                    .font(.system(size: 11)).foregroundColor(.prMuted)

                    if !ride.meetupLocation.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "mappin").font(.system(size: 10))
                            Text(ride.meetupLocation).lineLimit(1)
                        }
                        .font(.system(size: 11)).foregroundColor(.prMuted)
                    }
                }
                HStack(spacing: 4) {
                    Image(systemName: "person.fill").font(.system(size: 9))
                    Text("by \(ride.creatorName)").font(.system(size: 10)).foregroundColor(.prMuted)
                }
            }

            Spacer()

            VStack(spacing: 3) {
                Text("\(ride.rsvpCount)").font(.system(size: 15, weight: .bold)).foregroundColor(Color(red: 0.180, green: 0.620, blue: 0.357))
                Text("going").font(.system(size: 9, weight: .medium)).foregroundColor(Color(red: 0.180, green: 0.620, blue: 0.357))
            }

            Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundColor(.prMuted)
        }
        .padding(.vertical, 12)
        .overlay(Rectangle().fill(Color.prBorder).frame(height: 1), alignment: .bottom)
    }

    private var monthStr: String {
        let f = DateFormatter(); f.dateFormat = "MMM"
        return f.string(from: ride.date).uppercased()
    }
    private var dayStr: String {
        let f = DateFormatter(); f.dateFormat = "d"
        return f.string(from: ride.date)
    }
}

import FirebaseAuth
