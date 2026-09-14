import SwiftUI
import MapKit
import CoreLocation

struct FriendsMapView: View {
    private enum FriendsTab: String, CaseIterable { case following = "Following", followers = "Followers", discover = "Discover", map = "Map" }
    // Aug 27, 2026 — Grok re-review, small cleanup: was its own private
    // UserProfileManager() — a duplicate instance alongside PackRideApp's
    // app-wide one. FriendsMapView is only ever pushed from ContentView's
    // navigation tree, which already has the shared instance in its
    // environment.
    @EnvironmentObject private var profileManager: UserProfileManager
    @StateObject private var helpManager = HelpRequestManager()
    @StateObject private var locationVisibility = LocationVisibilitySettings()
    @ObservedObject private var locationManager = SharedLocationManager.shared
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.3318, longitude: -122.0312),
            span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
        )
    )
    @State private var selectedFriend: RiderProfile? = nil
    @State private var mapStyleIndex = 2 // Hybrid by default so street names are visible
    @State private var selectedTab: FriendsTab = .discover
    @AppStorage("riderName") private var riderName = ""

    var onlineFriends: [RiderProfile] { profileManager.followedUsers.compactMap { friend in
        guard let coordinate = profileManager.privateLocations[friend.id] else { return nil }
        return RiderProfile(id: friend.id, name: friend.name, initials: friend.initials, bike: friend.bike, city: friend.city, experience: friend.experience, avatarURL: friend.avatarURL, bannerURL: friend.bannerURL, isOnline: true, lastSeen: friend.lastSeen, latitude: coordinate.latitude, longitude: coordinate.longitude)
    } }
    var offlineFriends: [RiderProfile] { profileManager.followedUsers.filter { !$0.isOnline } }

    // A friend who tapped "Need Help" and chose you specifically — shown from
    // the help request's own live coordinate, not the friend's regular
    // location feed, since that only updates while they're on a ride (see
    // UserProfileManager.updateMyLocation) and someone needing help usually
    // isn't mid-ride.
    var friendHelpRequests: [HelpRequest] {
        helpManager.activeRequests.filter { $0.targetType == "friend" && $0.targetID == profileManager.myID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Friends").font(.system(size: 32, weight: .bold)).foregroundColor(.prCoral)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 14)

            HStack(spacing: 0) {
                ForEach(FriendsTab.allCases, id: \.self) { tab in
                    Button(action: { selectedTab = tab }) {
                        VStack(spacing: 10) {
                            Text(tab.rawValue).font(.system(size: 14, weight: .semibold))
                            Rectangle().fill(selectedTab == tab ? Color.prCoral : Color.clear).frame(height: 3)
                        }
                        .foregroundColor(selectedTab == tab ? .prCoral : .prMuted)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .overlay(Divider(), alignment: .bottom)

            Group {
                switch selectedTab {
                case .following: riderList(profileManager.followedUsers, emptyTitle: "Not following anyone yet")
                case .followers: riderList(profileManager.followers, emptyTitle: "No followers yet")
                case .discover: discoverList
                case .map: friendsMap
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.prBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            locationManager.startUpdating(reason: "friendsMap")
            profileManager.listenForFollowedUsers()
            profileManager.listenForFollowerCount()
            profileManager.listenForAllUsers()
            profileManager.listenForPrivateLocations()
            helpManager.listenForActiveRequests()
            locationVisibility.load()
            if let loc = locationManager.location {
                centerMap(on: loc)
            }
        }
        .onChange(of: locationManager.location) { _, location in
            if let location { centerMap(on: location) }
        }
        .onChange(of: locationVisibility.nearbyRadiusMiles) { _, _ in
            if let location = locationManager.location { centerMap(on: location) }
        }
        .onDisappear {
            locationManager.stopUpdating(reason: "friendsMap")
            profileManager.stopListeningForFollowedUsers()
            profileManager.stopListeningForFollowerCount()
            profileManager.stopListeningForAllUsers()
            profileManager.stopListeningForPrivateLocations()
            helpManager.stopListening()
        }
        .sheet(item: $selectedFriend) { friend in
            FriendDetailSheet(friend: friend, profileManager: profileManager)
        }
    }

    private var friendsMap: some View {
        ZStack(alignment: .bottom) {
            Map(position: $cameraPosition) {
                UserAnnotation()
                if let coordinate = locationManager.location?.coordinate {
                    MapCircle(center: coordinate, radius: locationVisibility.nearbyRadiusMiles * 1_609.344)
                        .foregroundStyle(Color.prCoral.opacity(0.08))
                        .stroke(Color.prCoral.opacity(0.45), lineWidth: 2)
                }
                ForEach(onlineFriends) { friend in
                    Annotation(friend.name, coordinate: friend.coordinate, anchor: .bottom) {
                        FriendMapPin(friend: friend)
                            .onTapGesture { selectedFriend = friend }
                    }
                }
                ForEach(friendHelpRequests) { request in
                    Annotation(request.requesterName, coordinate: request.coordinate, anchor: .bottom) {
                        FriendHelpPin(request: request)
                    }
                }
            }
            .mapStyle(.fromIndex(mapStyleIndex))
            .ignoresSafeArea()

            VStack {
                if let firstRequest = friendHelpRequests.first { helpBanner(for: firstRequest) }
                HStack {
                    Text(MeasurementUnits.distanceMiles(locationVisibility.nearbyRadiusMiles, decimals: 0) + " radius")
                        .font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 8).background(.black.opacity(0.55)).clipShape(Capsule())
                    Spacer()
                    MapStylePickerView(selectedIndex: $mapStyleIndex)
                }
                .padding(.horizontal, 16).padding(.top, friendHelpRequests.isEmpty ? 12 : 8)
                Spacer()
            }

            if !profileManager.followedUsers.isEmpty {
                friendsList
            } else {
                Text("Your location is centered. Friends who share while riding will appear here.")
                    .font(.system(size: 12, weight: .medium)).foregroundColor(.prInk)
                    .multilineTextAlignment(.center).padding(14).background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14)).padding(16)
            }
        }
    }

    private var discoverList: some View {
        VStack(spacing: 0) {
            Text("Public PackRide profiles you do not follow yet. Precise live location is never used for discovery.")
                .font(.system(size: 12)).foregroundColor(.prMuted).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 12).background(Color.prCardBg)
            riderList(profileManager.suggestedUsers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }, emptyTitle: "No new riders to discover", allowsFollow: true)
        }
    }

    private func riderList(_ riders: [RiderProfile], emptyTitle: String, allowsFollow: Bool = false) -> some View {
        ScrollView {
            if riders.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "person.2.slash").font(.system(size: 42)).foregroundColor(.prMuted)
                    Text(emptyTitle).font(.system(size: 17, weight: .semibold)).foregroundColor(.prInk)
                }
                .frame(maxWidth: .infinity).padding(.top, 80)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(riders) { rider in
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(Color.prCoralSoft).frame(width: 48, height: 48)
                                Text(rider.initials).font(.system(size: 14, weight: .bold)).foregroundColor(.prCoral)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(rider.name).font(.system(size: 15, weight: .bold)).foregroundColor(.prInk)
                                Text([rider.city, rider.bike, rider.experience].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.system(size: 12)).foregroundColor(.prMuted).lineLimit(2)
                            }
                            Spacer()
                            if allowsFollow { followButton(for: rider) }
                            else {
                                Button { selectedFriend = rider } label: {
                                    Image(systemName: "chevron.right").foregroundColor(.prMuted)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .background(Color.prCardBg)
                        .overlay(Rectangle().fill(Color.prBorder).frame(height: 1), alignment: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder private func followButton(for rider: RiderProfile) -> some View {
        let status = profileManager.followStatus[rider.id] ?? .notFollowing
        switch status {
        case .notFollowing:
            Button("Follow") {
                profileManager.sendFollowRequest(to: rider.id, myName: riderName.isEmpty ? "PackRide Rider" : riderName, myInitials: (riderName.isEmpty ? "PR" : riderName.rideInitials))
            }
            .font(.system(size: 13, weight: .bold)).foregroundColor(.prCoral)
            .onAppear { profileManager.checkFollowStatus(for: rider.id) }
        case .requested:
            Button("Cancel") { profileManager.cancelFollowRequest(to: rider.id) }
                .font(.system(size: 12, weight: .semibold)).foregroundColor(.prCoral)
        case .following:
            Text("Following").font(.system(size: 12, weight: .semibold)).foregroundColor(.prCoral)
        case .isMe:
            EmptyView()
        }
    }

    private func centerMap(on location: CLLocation) {
        // Show the full rider-selected radius with a little breathing room.
        let miles = max(1, locationVisibility.nearbyRadiusMiles)
        let latitudeDelta = max(0.03, (miles * 2.25) / 69.0)
        cameraPosition = .region(MKCoordinateRegion(
            center: location.coordinate,
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: latitudeDelta)
        ))
    }

    // MARK: - Needs Help Banner
    private func helpBanner(for request: HelpRequest) -> some View {
        Button(action: {
            withAnimation {
                cameraPosition = .region(MKCoordinateRegion(
                    center: request.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                ))
            }
        }) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 15))
                Text("\(request.requesterName) needs help — tap to view").font(.system(size: 13, weight: .bold))
                Spacer()
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color(red: 0.827, green: 0.231, blue: 0.173))
            .cornerRadius(14)
            .padding(.horizontal, 16).padding(.top, 50)
        }
    }

    // MARK: - Empty State
    private var emptyState: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()
            VStack(spacing: 20) {
                ZStack {
                    Circle().fill(Color.prCoralSoft).frame(width: 100, height: 100)
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 44)).foregroundColor(.prCoral)
                }
                Text("No Friends Yet").font(.system(size: 22, weight: .bold)).foregroundColor(.prInk)
                Text("Join a group ride and tap on riders to follow them. Their live location will appear here when they're riding.")
                    .font(.system(size: 14)).foregroundColor(.prMuted)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
            }
        }
    }

    // MARK: - Friends List Panel
    private var friendsList: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3).fill(Color.prBorder)
                .frame(width: 40, height: 5).padding(.top, 10).padding(.bottom, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(profileManager.followedUsers) { friend in
                        let isSharingLocation = profileManager.privateLocations[friend.id] != nil
                        Button(action: {
                            if let coordinate = profileManager.privateLocations[friend.id] {
                                cameraPosition = .region(MKCoordinateRegion(
                                    center: coordinate,
                                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                                ))
                            }
                            selectedFriend = isSharingLocation ? RiderProfile(id: friend.id, name: friend.name, initials: friend.initials, bike: friend.bike, city: friend.city, experience: friend.experience, avatarURL: friend.avatarURL, bannerURL: friend.bannerURL, isOnline: true, lastSeen: friend.lastSeen, latitude: profileManager.privateLocations[friend.id]?.latitude ?? 0, longitude: profileManager.privateLocations[friend.id]?.longitude ?? 0) : friend
                        }) {
                            VStack(spacing: 6) {
                                ZStack(alignment: .bottomTrailing) {
                                    Circle()
                                        .fill(isSharingLocation ? Color.prCoral : Color(red: 0.847, green: 0.824, blue: 0.780))
                                        .frame(width: 44, height: 44)
                                    Text(friend.initials)
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(isSharingLocation ? .white : .prMuted)
                                    Circle()
                                        .fill(isSharingLocation ? Color(red: 0.180, green: 0.620, blue: 0.357) : Color.prBorder)
                                        .frame(width: 12, height: 12)
                                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                                        .offset(x: 2, y: 2)
                                }
                                Text(friend.name.components(separatedBy: " ").first ?? friend.name)
                                    .font(.system(size: 11)).foregroundColor(isSharingLocation ? .prInk : .prMuted)
                                Text(isSharingLocation ? "Sharing" : "Not sharing")
                                    .font(.system(size: 10))
                                    .foregroundColor(isSharingLocation ? Color(red: 0.180, green: 0.620, blue: 0.357) : .prMuted)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 20)
        }
        .background(
            RoundedRectangle(cornerRadius: 24).fill(Color.prCardBg)
                .ignoresSafeArea(edges: .bottom)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24).stroke(Color.prBorder, lineWidth: 1).ignoresSafeArea(edges: .bottom),
            alignment: .top
        )
    }
}

// MARK: - Friend Map Pin
struct FriendMapPin: View {
    let friend: RiderProfile
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(Color.prCoral).frame(width: 40, height: 40)
                Text(friend.initials)
                    .font(.system(size: 13, weight: .bold)).foregroundColor(.white)
            }
            Triangle().fill(Color.prCoral).frame(width: 10, height: 6)
        }
    }
}

// MARK: - Friend Needs Help Pin
struct FriendHelpPin: View {
    let request: HelpRequest
    @State private var pulse = false
    var body: some View {
        VStack(spacing: 0) {
            NeedsHelpBadge().padding(.bottom, 4)
            ZStack {
                Circle()
                    .stroke(Color(red: 0.827, green: 0.231, blue: 0.173).opacity(0.5), lineWidth: 3)
                    .frame(width: pulse ? 60 : 40, height: pulse ? 60 : 40)
                    .opacity(pulse ? 0 : 0.9)
                Circle().fill(Color(red: 0.827, green: 0.231, blue: 0.173)).frame(width: 40, height: 40)
                Text(request.requesterInitials)
                    .font(.system(size: 13, weight: .bold)).foregroundColor(.white)
            }
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
            }
            Triangle().fill(Color(red: 0.827, green: 0.231, blue: 0.173)).frame(width: 10, height: 6)
        }
    }
}

// MARK: - Friend Detail Sheet
struct FriendDetailSheet: View {
    let friend: RiderProfile
    @ObservedObject var profileManager: UserProfileManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()
            VStack(spacing: 20) {
                RoundedRectangle(cornerRadius: 3).fill(Color.prBorder)
                    .frame(width: 40, height: 5).padding(.top, 12)

                ZStack {
                    Circle().fill(friend.isOnline ? Color.prCoral : Color(red: 0.847, green: 0.824, blue: 0.780))
                        .frame(width: 80, height: 80)
                    Text(friend.initials)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(friend.isOnline ? .white : .prMuted)
                }

                VStack(spacing: 6) {
                    Text(friend.name).font(.system(size: 22, weight: .bold)).foregroundColor(.prInk)
                    HStack(spacing: 6) {
                        Circle().fill(friend.isOnline ? Color(red: 0.180, green: 0.620, blue: 0.357) : Color.prMuted).frame(width: 7, height: 7)
                        Text(friend.isOnline ? "Online now" : "Offline")
                            .font(.system(size: 13))
                            .foregroundColor(friend.isOnline ? Color(red: 0.180, green: 0.620, blue: 0.357) : .prMuted)
                    }
                }

                VStack(spacing: 10) {
                    InfoRow(icon: "arrowtriangle.up.fill", label: "Bike", value: friend.bike)
                    InfoRow(icon: "location.fill", label: "City", value: friend.city)
                    InfoRow(icon: "star.fill", label: "Experience", value: friend.experience)
                }
                .padding(16).background(Color.prCardBg).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.prBorder, lineWidth: 1)).cornerRadius(16).padding(.horizontal, 24)

                Button(action: {
                    profileManager.unfollowUser(targetUserID: friend.id)
                    dismiss()
                }) {
                    Text("Unfollow").font(.system(size: 15)).foregroundColor(Color(red: 0.827, green: 0.231, blue: 0.173))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Color(red: 0.988, green: 0.922, blue: 0.906)).cornerRadius(12)
                }
                .padding(.horizontal, 24)

                Spacer()
            }
        }
    }
}

struct InfoRow: View {
    let icon: String
    let label: String
    let value: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundColor(.prCoral).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 11)).foregroundColor(.prMuted)
                Text(value.isEmpty ? "Not set" : value)
                    .font(.system(size: 14)).foregroundColor(value.isEmpty ? .prMuted : .prInk)
            }
            Spacer()
        }
    }
}
