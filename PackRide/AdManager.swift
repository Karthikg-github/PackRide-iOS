import SwiftUI
import GoogleMobileAds
import AppTrackingTransparency

// MARK: - Ad Unit IDs
// PackRide's real AdMob banner ad unit (app: PackRide App (iOS),
// publisher: pub-2444709882752151). Live ads will start showing here —
// new ad units can take up to an hour to start serving after creation.
enum AdUnitID {
    static let banner = "ca-app-pub-2444709882752151/7022028289"
}

// MARK: - App Tracking Transparency
// AdMob works without this — it just serves lower-paying, non-personalized
// ads instead. Asking once (and only once) gives a shot at the
// higher-paying personalized kind if the rider says yes. Needs
// NSUserTrackingUsageDescription in Info.plist or the system prompt won't
// appear at all.
enum AdPrivacyManager {
    static func requestTrackingIfNeeded() {
        guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else { return }
        // A brief delay after the screen appears reads as more intentional
        // than a prompt firing the instant the app opens, and keeps it from
        // racing with any other startup UI (login/onboarding checks, etc.).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            ATTrackingManager.requestTrackingAuthorization { _ in }
        }
    }
}

// MARK: - Banner Ad View
// Wraps Google Mobile Ads SDK's BannerView for use in SwiftUI. Fixed at the
// classic 320x50 size rather than a screen-width-adaptive size — simpler and
// reliable, at the cost of a little unused margin on wider phones. Revisit
// with `largeAnchoredAdaptiveBanner(width:)` later if that margin bothers you.
//
// Deliberately placed ONLY on screens used before/after a ride — Ride Feed,
// Ride History, Profile — never on any active-ride screen (ActiveSoloRideView,
// ActiveLapView, GroupRideView's live map, TrackModeView's setup/live map).
// A rider shouldn't be looking at an ad while riding.
struct BannerAdView: UIViewRepresentable {
    var adUnitID: String = AdUnitID.banner

    func makeUIView(context: Context) -> BannerView {
        let banner = BannerView(adSize: AdSizeBanner)
        banner.adUnitID = adUnitID
        banner.rootViewController = Self.rootViewController()
        banner.delegate = context.coordinator
        banner.load(Request())
        return banner
    }

    func updateUIView(_ uiView: BannerView, context: Context) {}

    func makeCoordinator() -> BannerAdCoordinator { BannerAdCoordinator() }

    private static func rootViewController() -> UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .rootViewController
    }
}

final class BannerAdCoordinator: NSObject, BannerViewDelegate {
    func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        // Quiet on success — only logging failures below, so Xcode's
        // console isn't noisy with an "ad loaded" line every refresh cycle.
    }
    func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        print("PackRide: banner ad failed to load — \(error.localizedDescription)")
    }
}

// MARK: - Ad Banner Footer
// Drop this at the bottom of a screen's scrollable content — centered,
// fixed-size, with a little breathing room above/below so it doesn't feel
// glued to whatever's directly above it.
struct AdBannerFooter: View {
    var body: some View {
        BannerAdView()
            .frame(width: 320, height: 50)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }
}
