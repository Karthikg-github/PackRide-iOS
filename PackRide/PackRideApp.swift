import SwiftUI
import FirebaseCore
import Combine

// MARK: - Deep Link Router
// Holds a ride code parsed from an incoming `packride://join?code=XXXX` link
// (tapped from a group ride's Share/SMS invite — see GroupRideView.shareCode())
// until ContentView/GroupRideView can consume it. URL-scheme only for now —
// this only opens the app if PackRide is already installed. A real Universal
// Link (opens the App Store first if it isn't) would need a hosted domain and
// an apple-app-site-association file; worth revisiting if/when PackRide has
// a website.
// Aug 22, 2026 — a community join carries two values (id + passcode), unlike
// a group ride's single code, so it gets its own small struct rather than
// reusing pendingRideCode's single-String shape. Equatable so CommunityListView
// can .onChange(of:) it the same way GroupRideView already does for pendingRideCode.
struct PendingCommunityJoin: Equatable {
    let id: String
    let passcode: String
}

final class DeepLinkRouter: ObservableObject {
    @Published var pendingRideCode: String? = nil
    // packride://joincommunity?id=XXXX&passcode=YYYY — see CommunityDetailView's
    // shareLink() in CommunityView.swift for where this is generated and shared from.
    @Published var pendingCommunityJoin: PendingCommunityJoin? = nil

    func handle(url: URL) {
        guard url.scheme == "packride" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        switch url.host {
        case "join":
            if let code = components?.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty {
                pendingRideCode = code.uppercased()
            }
        case "joincommunity":
            let id = components?.queryItems?.first(where: { $0.name == "id" })?.value ?? ""
            let passcode = components?.queryItems?.first(where: { $0.name == "passcode" })?.value ?? ""
            if !id.isEmpty, !passcode.isEmpty {
                pendingCommunityJoin = PendingCommunityJoin(id: id.uppercased(), passcode: passcode)
            }
        default:
            break
        }
    }
}

@main
struct PackRideApp: App {
    // Handles push notification setup + Firebase configuration — see
    // NotificationManager.swift. FirebaseApp.configure() now happens inside
    // the delegate's didFinishLaunching instead of here.
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding = false
    // Aug 2026: added for the Dark Mode toggle in Profile. Defaults to false
    // (light) since that's how the app has always looked — switching this to
    // true is an explicit choice the rider makes, not something that changes
    // on its own if their phone's system setting changes.
    @AppStorage("darkModeOn") var darkModeOn = false
    @StateObject private var auth = AuthManager()
    @StateObject private var deepLinkRouter = DeepLinkRouter()

    // App-wide singletons for anything that has to keep running regardless of
    // which screen is currently on top — voice chat, an active group ride's
    // location broadcast/GPX recording, an active "Need Help" share. Injected
    // as environment objects (rather than passed through each view's init)
    // so EVERY place MapView/GroupRideView/NeedHelpView get presented from —
    // the persistent tab bar, but also WaypointsView's "Plan first" flow and
    // Community's map preview — shares the same instance instead of each
    // accidentally spinning up its own, which is what silently broke group
    // ride tracking whenever you navigated away from wherever it started.
    @StateObject private var voiceChat = VoiceChatManager()
    @StateObject private var groupRideSession = GroupRideSessionManager()
    @StateObject private var helpSharing = HelpRequestManager()
    // Aug 21, 2026 — which communities this device belongs to (now more than
    // one is possible; see CommunityMembershipStore in CommunityView.swift).
    // App-wide for the same reason as the three above: Need Help's share
    // targets, a solo ride's live-share picker, and Schedule Ride's
    // share-to-community picker all need the same list, not their own copy.
    @StateObject private var communityStore = CommunityMembershipStore()
    // Aug 27, 2026 — was previously a fresh UserProfileManager() created
    // separately inside HomeView, GroupRideView, RideFeedView, ProfileView,
    // and half a dozen other screens, each with its own copy of
    // followRequests. Whichever screen wasn't the one currently listening
    // (or wasn't listening at all) showed a stale/empty notification bell —
    // a follow request would silently not show up unless you happened to be
    // on the one tab whose own instance had picked it up. Same bug class,
    // same fix shape, as helpSharing/communityStore/voiceChat above: one
    // shared instance, listened to continuously from ContentView regardless
    // of tab (see ContentView's onAppear).
    @StateObject private var profileManager = UserProfileManager()

    var body: some Scene {
        WindowGroup {
            Group {
                if auth.isLoading {
                    ZStack {
                        Color.prTabBar.ignoresSafeArea()
                        VStack(spacing: 20) {
                            Image("PackRideLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 110, height: 110)
                                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                                .accessibilityHidden(true)
                            Text("PackRide")
                                .font(.system(size: 32, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                } else if !auth.isLoggedIn {
                    LoginView()
                        .environmentObject(auth)
                } else if !hasCompletedOnboarding {
                    OnboardingView()
                } else {
                    ContentView()
                        .environmentObject(auth)
                        .environmentObject(deepLinkRouter)
                        .environmentObject(voiceChat)
                        .environmentObject(groupRideSession)
                        .environmentObject(helpSharing)
                        .environmentObject(communityStore)
                        .environmentObject(profileManager)
                        .onAppear {
                            // Restore the signed-in account's community list
                            // before Need Help, solo sharing, or scheduling
                            // asks for it; this is not limited to opening the
                            // Community tab after a reinstall.
                            communityStore.backfillCurrentUsersMembershipIndexes()
                        }
                }
            }
            // Aug 2026: was hardcoded to `.light` always — the app's colors
            // (.prBg/.prInk/.prMuted/.prBorder/.prCardBg, all defined in
            // LoginView.swift) used to be fixed values, so forcing light mode
            // was the only way to avoid invisible white-on-white text on a
            // phone set to system Dark Mode. Those tokens are now adaptive
            // (they read the current light/dark trait and pick a color
            // accordingly), so this can safely follow the rider's own choice
            // from the Dark Mode toggle in Profile instead of being forced.
            .preferredColorScheme(darkModeOn ? .dark : .light)
            .onOpenURL { url in deepLinkRouter.handle(url: url) }
        }
    }
}
