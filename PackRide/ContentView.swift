import SwiftUI
import FirebaseAuth

// MARK: - Content View (tab shell)
// Rebuilt Aug 17, 2026: previously each tab (Feed/Map/Group/Profile) was reached
// via a NavigationLink pushed from Home, and only Home itself had a bottom tab
// bar — meaning once you left Home, there was no way to jump to another tab
// without going back first, and no swipe gesture either. Now there's a single
// persistent tab bar driven by `selectedTab`, present on all 5 screens, plus a
// left/right swipe to move between them. Track added Aug 19, 2026 — TrackModeView
// already hides its own nav bar (full-screen map layout), so it slots in here
// the same way Feed/Profile do.
//
// Map tab removed Aug 21, 2026 — it was really only ever the live-tracking
// screen for an active group ride (see GroupRideView's navigationDestination)
// plus a general "see nearby riders" browse screen; it wasn't earning a
// permanent slot in the bar. It's still reachable: GroupRideView pushes it
// automatically when a ride starts and now has its own "LIVE · view map"
// button to reopen it any time after that (see headerView in GroupRideView.swift),
// and Home's "LIVE" banner still jumps straight to the Group tab. The
// standalone "Need Help" access that used to live inside MapView's UI moved to
// a persistent icon in Home's header instead — see HomeView.header below.
//
// Each tab keeps its own NavigationStack so pushes inside one tab (e.g. Ride
// History from Home) don't affect the others. GroupRideView already wraps
// itself in its own NavigationStack (built that way earlier), so it's used
// directly here rather than double-wrapped.
struct ContentView: View {
    @State private var selectedTab: Int = 0
    // Aug 24, 2026 — bumped every time the Home tab bar button is tapped
    // (see tabBar below), regardless of whether we're already on tab 0.
    // HomeView's own NavigationStack keeps whatever was pushed onto it
    // (WaypointsView, SoloRideView, RideHistoryView, etc.) even while
    // another tab is showing — switching selectedTab back to 0 alone just
    // re-reveals wherever that stack was left, it doesn't pop it. HomeView
    // applies .id(homeResetToken) to its NavigationStack only (not the
    // whole view), so bumping this forces just that stack back to its root
    // without losing HomeView's own @StateObjects (heroHistory, etc.).
    @State private var homeResetToken = 0
    @EnvironmentObject private var deepLinkRouter: DeepLinkRouter

    // App-wide singletons (see PackRideApp.swift) — read here only for the
    // Group tab's badge dot; MapView/GroupRideView/NeedHelpView pull the same
    // instance straight from the environment themselves. helpSharing's own
    // "I am sharing" badge lives on Home's header Help icon (see HomeView
    // below); helpSharing is ALSO read here, separately, for the incoming
    // alert banner just below — someone ELSE sharing with me.
    @EnvironmentObject private var voiceChat: VoiceChatManager
    @EnvironmentObject private var helpSharing: HelpRequestManager
    @EnvironmentObject private var communityStore: CommunityMembershipStore
    @EnvironmentObject private var profileManager: UserProfileManager
    @AppStorage("activeRideCode") private var activeRideCode: String = ""
    @State private var showIncomingHelp = false

    private let tabIcons = ["house.fill", "newspaper.fill", "person.3.fill", "stopwatch.fill", "person.circle.fill"]
    private let tabLabels = ["Home", "Feed", "Group", "Track", "Profile"]

    private var myDeviceID: String { UIDevice.current.identifierForVendor?.uuidString ?? "" }

    // Aug 22, 2026 — Need Help previously only reached anyone if they
    // happened to already be on the one screen that filters for their
    // specific target (MapView for "group", FriendsMapView for "friend",
    // CommunityDashboard for "community") — otherwise the alert genuinely
    // showed up nowhere, on any tab. This filters the same shared
    // helpSharing.activeRequests list (now listened to continuously at the
    // app level below, not just per-screen) down to requests actually meant
    // for you, so a banner can surface it regardless of which tab is open.
    // The push-notification half of this fix lives server-side — see
    // notifyOnHelpRequestStart in packride-functions.
    private var relevantHelpRequests: [HelpRequest] {
        let myUID = Auth.auth().currentUser?.uid ?? ""
        return helpSharing.activeRequests.filter { req in
            guard req.requesterUID != myUID, req.requesterDeviceID != myDeviceID else { return false }
            // The server now writes only requests that target this account.
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !relevantHelpRequests.isEmpty {
                incomingHelpBanner
            }
            ZStack {
                HomeView(switchTab: goToTab, resetSignal: homeResetToken)
                    .opacity(selectedTab == 0 ? 1 : 0)
                    .allowsHitTesting(selectedTab == 0)

                if selectedTab == 1 {
                    NavigationStack { RideFeedView() }
                }
                if selectedTab == 2 {
                    GroupRideView()
                }
                if selectedTab == 3 {
                    NavigationStack { TrackModeView() }
                }
                if selectedTab == 4 {
                    NavigationStack { ProfileView() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onReceive(NotificationCenter.default.publisher(for: .packRideCrashIncidentOpened)) { _ in
                // Profile owns the responder inbox, so a tapped urgent push
                // lands on its acknowledgement action instead of a generic tab.
                withAnimation(.easeInOut(duration: 0.2)) { selectedTab = 4 }
            }
            // Swipe left/right to change tabs. Track Mode is deliberately
            // excluded: its full-screen map uses drags/taps to position timing
            // gates, and a horizontal map gesture must never navigate to an
            // adjacent tab (especially Profile).
            // Uses `simultaneousGesture` rather
            // than `gesture` so it doesn't steal touches away from the map's own
            // pan/zoom or the horizontal Suggested Friends scroll row — both can
            // still recognize their own gestures normally. Only fires on release,
            // and only for drags that are clearly more horizontal than vertical,
            // to avoid misfiring during normal up/down scrolling.
            .simultaneousGesture(
                DragGesture(minimumDistance: 50)
                    .onEnded { value in
                        guard selectedTab != 3 else { return }
                        let dx = value.translation.width
                        let dy = value.translation.height
                        guard abs(dx) > abs(dy) * 1.5, abs(dx) > 70 else { return }
                        goToTab(selectedTab + (dx < 0 ? 1 : -1))
                    }
            )

            tabBar
        }
        .background(Color.prBg.ignoresSafeArea())
        // Only reached once login + onboarding are done, so this can't fire
        // before the rider has actually seen the app — see AdManager.swift.
        .onAppear {
            AdPrivacyManager.requestTrackingIfNeeded()
            // Runs continuously from here on, regardless of tab — previously
            // this only ever started from inside MapView/FriendsMapView/
            // CommunityDashboard's own onAppear, so nothing was listening at
            // all whenever you were on Home, Feed, Track, or Profile.
            helpSharing.listenForActiveRequests()
            // Aug 27, 2026 — same fix, same reason: follow requests used to
            // only be listened to by whichever screen's own UserProfileManager
            // instance happened to call listenForFollowRequests() in its own
            // onAppear (Home, Group, Profile each had a separate copy), so
            // the notification bell was wrong on every tab except whichever
            // one was currently listening. Now there's one shared instance
            // (see PackRideApp.swift) and it listens continuously from here.
            profileManager.listenForFollowRequests()
        }
        // A join link (packride://join?code=XXXX) switches straight to the
        // Group tab so GroupRideView's own onAppear can pick up the code —
        // see DeepLinkRouter in PackRideApp.swift.
        .onChange(of: deepLinkRouter.pendingRideCode) { _, code in
            if code != nil { goToTab(2) }
        }
        .sheet(isPresented: $showIncomingHelp) {
            IncomingHelpAlertsView(requests: relevantHelpRequests)
        }
    }

    // MARK: - Incoming Need Help banner
    // Pinned above the tab content (not inside any one tab) so it stays
    // visible across tab switches — unlike the per-screen filtering this
    // replaces, someone needing help doesn't stop being relevant just
    // because you're looking at Feed instead of the map.
    private var incomingHelpBanner: some View {
        Button(action: { showIncomingHelp = true }) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 14, weight: .bold))
                Text(bannerText).font(.system(size: 13, weight: .bold))
                Spacer()
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color(red: 0.827, green: 0.231, blue: 0.173))
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.25), value: relevantHelpRequests.count)
    }

    private var bannerText: String {
        if relevantHelpRequests.count == 1, let name = relevantHelpRequests.first?.requesterName {
            return "\(name) needs help — tap to view"
        }
        return "\(relevantHelpRequests.count) riders need help — tap to view"
    }

    private func goToTab(_ index: Int) {
        guard index >= 0, index < tabLabels.count, index != selectedTab else { return }
        withAnimation(.easeInOut(duration: 0.2)) { selectedTab = index }
    }

    // MARK: - Tab bar
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(0..<tabLabels.count, id: \.self) { index in
                Button(action: {
                    // Home always resets to its own root, whether you're
                    // switching onto the Home tab from elsewhere or you're
                    // already on it but pushed deep into Plan Route/Ride
                    // History/etc. — tapping Home should never just leave
                    // you wherever that stack happened to be.
                    if index == 0 { homeResetToken += 1 }
                    goToTab(index)
                }) {
                    // A dot on the Group tab while voice chat is connected —
                    // easy to forget it's still live while browsing another
                    // tab. The "Need Help" dot lives on Home's header icon
                    // now instead (see HomeView.header) since that's its
                    // entry point.
                    BottomTab(
                        icon: tabIcons[index], label: tabLabels[index], isActive: selectedTab == index,
                        showBadge: index == 2 && voiceChat.isConnected,
                        badgeColor: Color(red: 0.180, green: 0.620, blue: 0.357)
                    )
                }
            }
        }
        .padding(.top, 8).padding(.bottom, 22).padding(.horizontal, 8)
        .background(Color.prTabBar)
        .overlay(Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5), alignment: .top)
    }
}

// MARK: - Home View
struct HomeView: View {
    let switchTab: (Int) -> Void
    // Aug 24, 2026 — bumped by ContentView's tabBar whenever the Home
    // button is tapped. Applied as .id() to the NavigationStack only (see
    // body below) — changing a view's id forces SwiftUI to tear down and
    // recreate it, which for a NavigationStack means its internal push
    // history resets to empty (back to root). Scoped to just the
    // NavigationStack, not this whole HomeView struct, so heroHistory/
    // notifManager and the rest of HomeView's own state survive the reset
    // instead of being needlessly recreated too.
    var resetSignal: Int = 0

    @AppStorage("riderName") var riderName: String = ""
    @AppStorage("riderBike") var riderBike: String = ""
    @AppStorage("riderCity") var riderCity: String = ""
    @AppStorage("riderExperience") var riderExperience: String = "Intermediate"
    @AppStorage("activeRideCode") var activeRideCode: String = ""
    @AppStorage("myCreatedRideCode") var myCreatedRideCode: String = ""
    @AppStorage("rideStartTimestamp") var rideStartTimestamp: Double = 0

    // Backs the notification bell below — a follow request used to only ever
    // show up buried in Profile, with no badge or alert anywhere telling you
    // one had arrived. This gives it a visible, always-reachable home-screen
    // indicator instead.
    // Aug 27, 2026 — was its own separate UserProfileManager() instance;
    // now the shared app-wide one (see PackRideApp.swift / ContentView's own
    // onAppear, which is what actually starts listenForFollowRequests()) so
    // the badge here always agrees with every other tab's bell.
    @EnvironmentObject private var notifManager: UserProfileManager
    @State private var showNotifications = false

    // Aug 21, 2026 — the Help icon between the bell and the avatar below.
    // Previously "Need Help" only had an entry point buried inside the Map
    // tab (which has now been removed from the bottom bar entirely), so it
    // needed a new, always-reachable home. helpSharing is read here for the
    // red dot only — NeedHelpView reads the same instance from the
    // environment itself once presented.
    @EnvironmentObject private var helpSharing: HelpRequestManager
    @State private var showNeedHelp = false

    // Aug 27, 2026 — hidden easter egg: tap the "PACKRIDE" wordmark below to
    // open Moto Run (MotoRunView.swift), our take on Chrome's offline dino
    // game. motoRunHighScore mirrors the same @AppStorage key MotoRunView
    // writes its high score to, read here only so the hero card can show it
    // under "Top speed ever" once there's a score worth showing.
    @State private var showMotoRun = false
    @AppStorage("motoRunHighScore") private var motoRunHighScore: Int = 0

    // Aug 22, 2026 — a tapped packride://joincommunity link (see
    // CommunityDetailView.shareCommunity()) needs to land on My Communities
    // with Join Community already open and prefilled, via the
    // .navigationDestination(isPresented:) below. That modifier only reliably
    // attaches to a NavigationStack's own path (see the Aug 22 GroupRideView
    // fix for exactly what goes wrong when it's used somewhere that isn't
    // one), which is part of why HomeView is on NavigationStack rather than
    // the older NavigationView.
    @EnvironmentObject private var deepLinkRouter: DeepLinkRouter
    @State private var navigateToCommunities = false

    // Aug 24, 2026 — backs the hero card's floating stat pill below (see
    // heroCard). A dedicated RideHistoryManager instance rather than piping
    // one down from elsewhere in the app, matching how RideHistoryView
    // itself already owns its own @StateObject instance. Loads once from
    // UserDefaults when HomeView first mounts (RideHistoryManager.init calls
    // loadRides() synchronously, and it's a small JSON array, so this is
    // cheap) — note this means a ride recorded later in the same app session
    // won't bump the hero pill's total until HomeView is remounted (app
    // relaunch), since HomeView stays alive (just hidden) across tab
    // switches rather than reappearing. Flagged in the pass report rather
    // than wiring a shared/live instance across the app, which would mean
    // touching PackRideApp.swift's environment objects — out of scope here.
    @StateObject private var heroHistory = RideHistoryManager()

    var firstName: String {
        let trimmed = riderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "Rider"
    }
    var initials: String { riderName.rideInitials }
    var isGroupLeader: Bool { !myCreatedRideCode.isEmpty && myCreatedRideCode == activeRideCode }
    var hasActiveRide: Bool { !activeRideCode.isEmpty }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.prBg.ignoresSafeArea()

                VStack(spacing: 0) {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            webHero
                            if hasActiveRide { liveBanner }
                            rideSection
                            packSection
                            youSection
                            Spacer().frame(height: 24)
                        }
                    }

                    AdBannerFooter()
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(isPresented: $navigateToCommunities) {
                CommunityListView()
            }
        }
        .id(resetSignal)
        .onChange(of: deepLinkRouter.pendingCommunityJoin) { _, pending in
            if pending != nil { navigateToCommunities = true }
        }
        .onAppear {
            // Firebase is authoritative. Publishing a default/local name here
            // could overwrite a name saved on the other platform before it was
            // downloaded. ProfileView publishes deliberate edits instead.
            notifManager.fetchMyProfile()
        }
        .sheet(isPresented: $showNotifications) {
            NotificationCenterView(profileManager: notifManager)
        }
        .fullScreenCover(isPresented: $showNeedHelp) {
            NeedHelpView()
        }
        .fullScreenCover(isPresented: $showMotoRun) {
            MotoRunView()
        }
    }

    // MARK: - Full-bleed web hero
    private var webHero: some View {
        ZStack(alignment: .bottomLeading) {
            Color.prCover
            HeroRouteIllustration()
                .opacity(0.9)
            LinearGradient(
                colors: [.black.opacity(0.15), .black.opacity(0.55)],
                startPoint: .top, endPoint: .bottom
            )

            // Live animated WeatherStrip in the upper-right corner of the hero
            // card, with the required WeatherKit attribution directly beneath
            // it. Aug 27, 2026 — WeatherAttributionView already existed (see
            // WeatherView.swift) and was wired into the two dedicated weather
            // screens, but never into this compact hero badge — the one
            // weather surface every rider sees on every app launch. Apple
            // requires the "Weather" attribution + link on every screen that
            // shows WeatherKit data, so this was a real App Store rejection
            // risk, not just a cosmetic gap.
            VStack {
                HStack {
                    Spacer()
                    // Trailing padding matches the header row's own
                    // .padding(.horizontal, 20) below, so this sits flush
                    // under the avatar's trailing edge rather than floating
                    // toward center.
                    VStack(alignment: .trailing, spacing: 4) {
                        WeatherStrip()
                        WeatherAttributionView(compact: true)
                    }
                    .padding(.trailing, 20)
                    .padding(.top, 56)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text("PACKRIDE")
                        .font(.system(size: 13, weight: .heavy))
                        .tracking(2.4)
                        .foregroundColor(.white)
                        .contentShape(Rectangle())
                        .onTapGesture { showMotoRun = true }
                    Spacer()
                    heroIconButton(system: "bell.fill", badge: notifManager.followRequests.count) {
                        showNotifications = true
                    }
                    heroIconButton(system: "exclamationmark.triangle.fill", showDot: helpSharing.isSharing) {
                        showNeedHelp = true
                    }
                    Button(action: { switchTab(4) }) {
                        ZStack {
                            Circle().fill(Color.prCoral).frame(width: 34, height: 34)
                            if let url = URL(string: notifManager.avatarURL), !notifManager.avatarURL.isEmpty {
                                AsyncImage(url: url) { phase in
                                    if let image = phase.image {
                                        image.resizable().scaledToFill()
                                    } else {
                                        Text(initials)
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundColor(.white)
                                    }
                                }
                                .frame(width: 34, height: 34)
                                .clipShape(Circle())
                            } else {
                                Text(initials).font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                            }
                        }
                        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Spacer()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Hey, \(firstName)")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.white)
                    Text(heroStatText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.78))
                    
                    // Display Top Speed Ever in place of city location
                    Text("Top speed ever: \(MeasurementUnits.speedMph(heroHistory.bestSpeed))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.70))

                    // Aug 27, 2026 — Moto Run's high score, once there is one.
                    // Hidden until the player has scored at least once so the
                    // line doesn't show "Moto Run best: 0" to everyone who's
                    // never found the easter egg.
                    if motoRunHighScore > 0 {
                        Text("Moto Run best: \(motoRunHighScore)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.70))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 14)

                NavigationLink(destination: SoloRideView()) {
                    HStack {
                        Image(systemName: "play.fill").font(.system(size: 14, weight: .bold))
                        Text("Record Ride").font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.prCoral)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .frame(height: 312)
    }

    private func heroIconButton(system: String, badge: Int = 0, showDot: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: system)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.16))
                    .clipShape(Circle())
                if badge > 0 {
                    Text("\(min(badge, 9))")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 15, height: 15)
                        .background(Color(red: 0.827, green: 0.231, blue: 0.173))
                        .clipShape(Circle())
                        .offset(x: 3, y: -3)
                } else if showDot {
                    Circle()
                        .fill(Color(red: 0.827, green: 0.231, blue: 0.173))
                        .frame(width: 9, height: 9)
                        .offset(x: 2, y: -2)
                }
            }
        }
    }

    // MARK: - Live ride banner
    private var liveBanner: some View {
        Button(action: { switchTab(2) }) {
            HStack(spacing: 10) {
                Circle().fill(Color(red: 0.373, green: 0.851, blue: 0.541)).frame(width: 8, height: 8)
                Text("LIVE")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundColor(Color(red: 0.373, green: 0.851, blue: 0.541))
                    .tracking(1.5)
                Text(activeRideCode)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
                if isGroupLeader {
                    Image(systemName: "crown.fill").font(.system(size: 11)).foregroundColor(.prCoral)
                }
                Text("Open group")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.5))
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .background(Color.prInkFixed)
        }
    }

    private var heroStatText: String {
        let miles = heroHistory.totalMiles
        let rides = heroHistory.totalRides
        if rides == 0 { return "Ready for your first ride" }
        return "\(rides) rides  ·  \(MeasurementUnits.distanceMiles(miles, decimals: 0)) on the road"
    }

    // MARK: - Sections (web list, not tile grid)
    private var rideSection: some View {
        VStack(spacing: 0) {
            HomeSectionLabel(title: "Ride")
            NavigationLink(destination: WaypointsView()) {
                HomeWebRow(icon: "point.topleft.down.to.point.bottomright.curvepath", title: "Plan Route", subtitle: "Build a curvy road and navigate")
            }
            HomeDivider()
            Button(action: { switchTab(3) }) {
                HomeWebRow(icon: "stopwatch", title: "Track Mode", subtitle: "Automatic lap timing with GPS")
            }
            .buttonStyle(.plain)
        }
        .background(Color.prCardBg)
        .padding(.top, 10)
    }

    private var packSection: some View {
        VStack(spacing: 0) {
            HomeSectionLabel(title: "The Pack")
            Button(action: { switchTab(2) }) {
                HomeWebRow(icon: "person.3.fill", title: "Group Ride", subtitle: "Ride together, live on the map")
            }
            .buttonStyle(.plain)
            HomeDivider()
            NavigationLink(destination: RideCommsView()) {
                HomeWebRow(icon: "headphones", title: "Ride Comms", subtitle: "Private voice with any rider")
            }
            HomeDivider()
            NavigationLink(destination: FriendsMapView()) {
                HomeWebRow(icon: "location.fill", title: "Friends Nearby", subtitle: "See who's out riding")
            }
            HomeDivider()
            NavigationLink(destination: CommunityListView()) {
                HomeWebRow(icon: "flame.fill", title: "Communities", subtitle: "Find your local riders")
            }
        }
        .background(Color.prCardBg)
        .padding(.top, 10)
    }

    private var youSection: some View {
        VStack(spacing: 0) {
            HomeSectionLabel(title: "You")
            NavigationLink(destination: RideHistoryView()) {
                HomeWebRow(icon: "chart.bar.fill", title: "Ride History", subtitle: "Maps, stats, and replays")
            }
            HomeDivider()
            NavigationLink(destination: SafetyHubView()) {
                HomeWebRow(icon: "shield.fill", title: "Safety", subtitle: "Crash detection & Need Help")
            }
        }
        .background(Color.prCardBg)
        .padding(.top, 10)
    }
}

private struct HomeSectionLabel: View {
    let title: String
    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.prMuted)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }
}

private struct HomeDivider: View {
    var body: some View {
        Rectangle().fill(Color.prBorder).frame(height: 1).padding(.leading, 56)
    }
}

private struct HomeStatCell: View {
    let value: String
    let label: String
    var body: some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 20, weight: .bold)).foregroundColor(.prInk)
            Text(label).font(.system(size: 11)).foregroundColor(.prMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

struct HomeWebRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.prCoral)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundColor(.prInk)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundColor(.prMuted).lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.prMuted.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

// MARK: - Home Action Tile (kept for any leftover callers)
struct HomeActionTile: View {
    let icon: String
    let iconColor: Color
    let title: String
    var subtitle: String? = nil
    var isPrimary: Bool = false

    var body: some View {
        HomeWebRow(icon: icon, title: title, subtitle: subtitle)
    }
}

// MARK: - Hero Route Illustration
// Aug 24, 2026 — purely decorative curved-road brand illustration for
// HomeView's heroCard above, drawn as a plain SwiftUI Path rather than a real
// MapKit map (there's no single "current route" on Home the way there is on
// a ride summary — see RideSummaryView's real GPX hero map in
// SoloRideView.swift for that). A small motorcycle marker loops along the
// path forever via TimelineView(.animation), using Path.trimmedPath(from:to:)
// .currentPoint to read the marker's position at a given fraction of the
// curve — the standard SwiftUI technique for "move a view along a path"
// rather than hand-rolled Bezier point math.
private struct HeroRouteIllustration: View {
    // Loop period for one full pass along the road, in seconds.
    private let loopDuration: TimeInterval = 5.5

    var body: some View {
        GeometryReader { geo in
            let road = Self.roadPath(in: geo.size)
            ZStack {
                road.stroke(Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 20, lineCap: .round))
                road.stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [8, 9]))

                TimelineView(.animation) { context in
                    let elapsed = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: loopDuration)
                    let progress = max(CGFloat(elapsed / loopDuration), 0.001)
                    let trimmed = road.trimmedPath(from: 0, to: progress)
                    let point = trimmed.currentPoint ?? CGPoint(x: 0, y: geo.size.height * 0.72)
                    ZStack {
                        Circle().fill(Color.white).frame(width: 28, height: 28)
                            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                        // "motorcycle" (no .fill variant confirmed available in this
                        // SDK — see pass report) already used elsewhere in this app
                        // (WaypointsView.swift, GarageView.swift, ProfileView.swift,
                        // PackRideApp.swift), so it's known to exist here.
                        Image(systemName: "motorcycle").font(.system(size: 13, weight: .bold)).foregroundColor(.prCoral)
                    }
                    .position(point)
                }
            }
        }
    }

    // A gentle S-curve across the card, well clear of the edges so the
    // marker circle never clips. Purely decorative — no data behind it.
    private static func roadPath(in size: CGSize) -> Path {
        var path = Path()
        let w = size.width, h = size.height
        path.move(to: CGPoint(x: -10, y: h * 0.72))
        path.addCurve(
            to: CGPoint(x: w * 0.42, y: h * 0.22),
            control1: CGPoint(x: w * 0.08, y: h * 0.95),
            control2: CGPoint(x: w * 0.22, y: h * 0.05)
        )
        path.addCurve(
            to: CGPoint(x: w + 10, y: h * 0.58),
            control1: CGPoint(x: w * 0.66, y: h * 0.42),
            control2: CGPoint(x: w * 0.88, y: h * 0.88)
        )
        return path
    }
}

// MARK: - Map Style Button (used by MapView/WaypointsView)
struct MapStyleBtn: View {
    let icon: String
    let label: String
    let isActive: Bool
    let action: () -> Void
    var body: some View {
        Button(action: { withAnimation(.spring(response: 0.3)) { action() } }) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                Text(label).font(.system(size: 8, weight: .bold)).tracking(0.5)
            }
            .foregroundColor(isActive ? .prCoral : .prMuted)
            .frame(width: 48, height: 40)
            .background(isActive ? Color.prCoralSoft : Color.clear)
            .cornerRadius(10)
        }
    }
}

// MARK: - Bottom Tab
struct BottomTab: View {
    let icon: String; let label: String; let isActive: Bool
    var showBadge: Bool = false
    var badgeColor: Color = Color(red: 0.180, green: 0.620, blue: 0.357)
    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon).font(.system(size: 20, weight: isActive ? .semibold : .regular))
                    .foregroundColor(isActive ? Color.prCoral : Color.white.opacity(0.45))
                if showBadge {
                    Circle().fill(badgeColor)
                        .frame(width: 7, height: 7)
                        .offset(x: 7, y: -3)
                }
            }
            Text(label).font(.system(size: 10, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? Color.prCoral : Color.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    ContentView()
        .environmentObject(AuthManager())
        .environmentObject(DeepLinkRouter())
        .environmentObject(VoiceChatManager())
        .environmentObject(GroupRideSessionManager())
        .environmentObject(HelpRequestManager())
        .environmentObject(CommunityMembershipStore())
}
