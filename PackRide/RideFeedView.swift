import SwiftUI
import MapKit
import CoreLocation
import PhotosUI

// MARK: - Ride Feed View
struct RideFeedView: View {
    @AppStorage("riderName") var riderName: String = "Rider"
    @AppStorage("avatarURL") var avatarURL: String = ""
    @StateObject private var feedManager = RideFeedManager()
    // Aug 27, 2026 — was its own separate UserProfileManager() instance,
    // same stale-bell bug as GroupRideView/ProfileView/HomeView each having
    // their own copy. Now the shared app-wide instance — see
    // PackRideApp.swift / ContentView's onAppear (which is what actually
    // starts listenForFollowRequests()).
    @EnvironmentObject private var profileManager: UserProfileManager
    @State private var feedMode: FeedMode = .feed
    @State private var showNotifications = false
    @State private var showNeedHelp = false

    var myInitials: String { riderName.rideInitials }

    // Aug 2026: added .myLaps for Track Mode sessions. Lap sessions are
    // deliberately kept out of "Ride Feed"/"My Rides" — they're a different
    // content shape (lap times, not distance/duration/route) that needs its
    // own card layout, so mixing them in would look inconsistent. They only
    // ever show up under "My Laps".
    enum FeedMode { case feed, mine, myLaps }

    var displayedPosts: [FeedPost] {
        switch feedMode {
        case .feed: return feedManager.posts.filter { !$0.isLapSession }
        case .mine: return feedManager.posts.filter { feedManager.myKnownIDs.contains($0.authorID) && !$0.isLapSession }
        case .myLaps: return feedManager.posts.filter { feedManager.myKnownIDs.contains($0.authorID) && $0.isLapSession }
        }
    }

    // "Recommended Ride" — the single most-liked photo post in your feed (from
    // anyone you follow, or you). There's no curation/admin system, so this is a
    // simple stand-in: it just needs a photo (the whole point of the card is a big
    // cover image) and at least one like so an empty feed doesn't show a random post.
    var recommendedRide: FeedPost? {
        feedManager.posts
            .filter { $0.photoURL != nil && $0.reactionCount > 0 }
            .max { $0.reactionCount < $1.reactionCount }
    }

    var body: some View {
        VStack(spacing: 0) {
            webHeaderBar

            topToggle

            if feedManager.isLoading && feedManager.posts.isEmpty {
                Spacer()
                ProgressView().tint(.prCoral)
                Spacer()
            } else if displayedPosts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if feedMode == .feed, let recommended = recommendedRide {
                            RecommendedRideCard(post: recommended, manager: feedManager)
                        }
                        if feedMode == .feed && !profileManager.suggestedUsers.isEmpty {
                            SuggestedFriendsRow(
                                users: profileManager.suggestedUsers,
                                manager: profileManager,
                                riderName: riderName
                            )
                        }
                        ForEach(displayedPosts) { post in
                            if feedMode == .myLaps {
                                LapFeedPostCard(
                                    post: post,
                                    isMine: feedManager.myKnownIDs.contains(post.authorID),
                                    onReact: { emoji in feedManager.setReaction(postID: post.id, emoji: emoji) },
                                    manager: feedManager
                                )
                            } else {
                                FeedPostCard(
                                    post: post,
                                    isMine: feedManager.myKnownIDs.contains(post.authorID),
                                    onReact: { emoji in feedManager.setReaction(postID: post.id, emoji: emoji) },
                                    onBookmark: { feedManager.toggleBookmark(postID: post.id, currentlyBookmarked: post.bookmarkedByMe) },
                                    manager: feedManager
                                )
                            }
                        }
                    }
                    .padding(.bottom, 16)
                }
            }

            // Feed is a before/after-the-ride screen, never seen mid-ride —
            // see AdManager.swift for why ad placement is confined here.
            AdBannerFooter()
        }
        .background(Color.prBg.ignoresSafeArea())
        .navigationBarHidden(true)
        .onAppear {
            profileManager.listenForFollowedUsers()
            profileManager.listenForAllUsers()
            feedManager.listenForFeed(followingIDs: profileManager.followedUsers.map { $0.id })
        }
        .onChange(of: profileManager.followedUsers.map { $0.id }) { _, ids in
            feedManager.listenForFeed(followingIDs: ids)
        }
        .onDisappear {
            profileManager.stopListeningForFollowedUsers()
            profileManager.stopListeningForAllUsers()
            feedManager.stopListening()
        }
        .sheet(isPresented: $showNotifications) {
            NotificationCenterView(profileManager: profileManager)
        }
        .fullScreenCover(isPresented: $showNeedHelp) {
            NeedHelpView()
        }
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

    // MARK: - Top Toggle
    private var topToggle: some View {
        HStack(spacing: 0) {
            toggleButton(title: "Ride Feed", mode: .feed)
            toggleButton(title: "My Rides", mode: .mine)
            toggleButton(title: "My Laps", mode: .myLaps)
        }
        .padding(.horizontal, 16).padding(.top, 4)
        .background(Color.prCardBg)
        .overlay(Rectangle().fill(Color.prBorder).frame(height: 1), alignment: .bottom)
    }

    private func toggleButton(title: String, mode: FeedMode) -> some View {
        Button(action: { withAnimation(.spring(response: 0.3)) { feedMode = mode } }) {
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(feedMode == mode ? .prInk : .prMuted)
                Rectangle()
                    .fill(feedMode == mode ? Color.prCoral : Color.clear)
                    .frame(height: 3)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Empty State
    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            ZStack {
                Circle().fill(Color.prCoralSoft).frame(width: 80, height: 80)
                Image(systemName: "flag.checkered").font(.system(size: 30)).foregroundColor(.prCoral)
            }
            Text(feedMode == .feed ? "No rides yet" : feedMode == .mine ? "You haven't posted any rides" : "No lap sessions posted yet")
                .font(.system(size: 16, weight: .bold)).foregroundColor(.prInk)
            Text(feedMode == .feed
                 ? "Follow riders from their profile to see their rides here."
                 : feedMode == .mine
                 ? "Finish a ride and choose \"Post to Feed\" to share it, or share a past ride from Ride History."
                 : "Finish a Track Mode session and choose \"Post to Feed\" to share your lap times here.")
                .font(.system(size: 13)).foregroundColor(.prMuted)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Spacer()
        }
    }
}

// MARK: - Reaction Emoji Picker
// Shared by FeedPostCard and LapFeedPostCard — shown as a long-press context
// menu on the React button. Four options rather than a single fixed emoji,
// so riders can pick whichever fits (fire, heart, thumbs-up, or "rock on").
private let reactionEmojiOptions = ["🔥", "❤️", "👍", "🤘"]

struct ReactionMenuItems: View {
    let current: String?
    let onReact: (String?) -> Void

    var body: some View {
        ForEach(reactionEmojiOptions, id: \.self) { emoji in
            Button(emoji) { onReact(emoji) }
        }
        if current != nil {
            Button("Remove Reaction", role: .destructive) { onReact(nil) }
        }
    }
}

// MARK: - Feed Post Card
struct FeedPostCard: View {
    let post: FeedPost
    let isMine: Bool
    let onReact: (String?) -> Void
    let onBookmark: () -> Void
    @ObservedObject var manager: RideFeedManager

    @State private var showComments = false
    @State private var showDeleteConfirm = false
    @State private var deleteError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(post.isAnonymous ? Color.prFieldBg : Color.prCoral).frame(width: 40, height: 40)
                    if post.isAnonymous {
                        Image(systemName: "eye.slash.fill").font(.system(size: 14)).foregroundColor(.prMuted)
                    } else {
                        Text(post.authorInitials).font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(post.authorName).font(.system(size: 15, weight: .semibold)).foregroundColor(.prInk)
                    Text(post.dateString).font(.system(size: 11)).foregroundColor(.prMuted)
                }
                Spacer()
                if isMine {
                    Button(action: { showDeleteConfirm = true }) {
                        Image(systemName: "ellipsis").font(.system(size: 14, weight: .bold)).foregroundColor(.prMuted)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 4) {
                Text(post.title).font(.system(size: 20, weight: .bold)).foregroundColor(.prInk)
                HStack(spacing: 6) {
                    Text(post.distanceString)
                    Text("·").foregroundColor(.prMuted)
                    Text(post.duration)
                }
                .font(.system(size: 13)).foregroundColor(.prMuted)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            if let photoURLString = post.photoURL, let photoURL = URL(string: photoURLString) {
                AsyncImage(url: photoURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Rectangle().fill(Color.prFieldBg)
                            .overlay(Image(systemName: "photo").foregroundColor(.prMuted))
                    default:
                        Rectangle().fill(Color.prFieldBg)
                            .overlay(ProgressView().tint(.prCoral))
                    }
                }
                .frame(height: 240)
                .frame(maxWidth: .infinity)
                .clipped()
            } else if !post.route.isEmpty {
                FeedRouteMapView(route: post.routeCoordinates)
                    .frame(height: 200)
                    .allowsHitTesting(false)
            }

            HStack(spacing: 0) {
                Button(action: { onReact(post.myReaction != nil ? nil : "👍") }) {
                    HStack(spacing: 6) {
                        Image(systemName: post.myReaction != nil ? "hand.thumbsup.fill" : "hand.thumbsup")
                        Text(post.reactionCount > 0 ? "\(post.reactionCount)" : "")
                    }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(post.myReaction != nil ? .prCoral : .prMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .contextMenu { ReactionMenuItems(current: post.myReaction, onReact: onReact) }
                Button(action: { showComments = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "bubble.left")
                        Text(post.commentCount > 0 ? "\(post.commentCount)" : "")
                    }
                    .font(.system(size: 15, weight: .medium)).foregroundColor(.prMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                Button(action: shareRide) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .medium)).foregroundColor(.prMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                Button(action: onBookmark) {
                    Image(systemName: post.bookmarkedByMe ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(post.bookmarkedByMe ? .prCoral : .prMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
            .overlay(Rectangle().fill(Color.prBorder).frame(height: 1), alignment: .top)
        }
        .background(Color.prCardBg)
        .overlay(Rectangle().fill(Color.prBorder).frame(height: 1), alignment: .bottom)
        .alert("Delete this post?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                manager.deletePost(postID: post.id) { error in
                    if let error { deleteError = error }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn't Delete Post", isPresented: Binding(
            get: { deleteError != nil }, set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
        .sheet(isPresented: $showComments) {
            FeedCommentsSheet(post: post, manager: manager)
        }
    }

    private func shareRide() {
        let text = "\(post.authorName)'s ride: \(post.title) — \(post.distanceString), \(post.duration) on PackRide!"
        let av = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let vc = scene.windows.first?.rootViewController {
            vc.present(av, animated: true)
        }
    }
}

// MARK: - Lap Feed Post Card
// Track Mode's equivalent of FeedPostCard — no route map/photo (a lap session
// isn't really about the route, it's about the times), so this shows lap
// count/best lap/distance instead. Reuses the same like/share/delete plumbing
// as regular posts since it's still just a FeedPost under the hood.
struct LapFeedPostCard: View {
    let post: FeedPost
    let isMine: Bool
    let onReact: (String?) -> Void
    @ObservedObject var manager: RideFeedManager

    @State private var showDeleteConfirm = false
    @State private var deleteError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.prCoral).frame(width: 44, height: 44)
                    Text(post.authorInitials).font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(post.authorName).font(.system(size: 15, weight: .bold)).foregroundColor(.prInk)
                    Text(post.dateString).font(.system(size: 11)).foregroundColor(.prMuted)
                }
                Spacer()
                if isMine {
                    Button(action: { showDeleteConfirm = true }) {
                        Image(systemName: "trash").font(.system(size: 13)).foregroundColor(.prMuted)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(post.title).font(.system(size: 18, weight: .bold)).foregroundColor(.prInk)
                HStack(spacing: 6) {
                    Image(systemName: "flag.checkered").font(.system(size: 11))
                    Text(post.trackName.isEmpty ? "Track Session" : post.trackName)
                }
                .font(.system(size: 13, weight: .medium)).foregroundColor(.prMuted)
            }


            HStack(spacing: 10) {
                LapStatBox(value: "\(post.lapTimes.count)", label: "Laps")
                LapStatBox(value: post.bestLapTime > 0 ? LapEngine.formatLapTime(post.bestLapTime) : "--:--", label: "Best Lap")
                LapStatBox(value: MeasurementUnits.distanceMiles(post.distance), label: "Distance")
            }

            Divider().background(Color.prBorder)

            HStack(spacing: 0) {
                Button(action: { onReact(post.myReaction != nil ? nil : "❤️") }) {
                    HStack(spacing: 6) {
                        Text(post.myReaction ?? "🤍").font(.system(size: 14))
                        Text(post.reactionCount > 0 ? "\(post.reactionCount)" : "React").lineLimit(1)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(post.myReaction != nil ? .prCoral : .prMuted)
                    .frame(maxWidth: .infinity)
                }
                .contextMenu { ReactionMenuItems(current: post.myReaction, onReact: onReact) }
                Button(action: shareSession) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Share").lineLimit(1)
                    }
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(.prMuted)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)
        }
        .padding(16)
        .background(Color.prCardBg)
        .cornerRadius(20)
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.prBorder, lineWidth: 1))
        .alert("Delete this post?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                manager.deletePost(postID: post.id) { error in
                    if let error { deleteError = error }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn't Delete Post", isPresented: Binding(
            get: { deleteError != nil }, set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    private func shareSession() {
        let best = post.bestLapTime > 0 ? LapEngine.formatLapTime(post.bestLapTime) : "--:--"
        let text = "\(post.authorName)'s track session: \(post.title) — \(post.lapTimes.count) laps, best \(best) on PackRide!"
        let av = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let vc = scene.windows.first?.rootViewController {
            vc.present(av, animated: true)
        }
    }
}

struct LapStatBox: View {
    let value: String
    let label: String
    var body: some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 16, weight: .bold, design: .monospaced)).foregroundColor(.prInk)
            Text(label).font(.system(size: 10)).foregroundColor(.prMuted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(Color.prFieldBg).cornerRadius(12)
    }
}

// MARK: - Suggested Friends Row
// Sits above the feed posts, matches REVER's pattern: horizontal scroll of
// avatar + name + Follow button. Backed by everyone with a published profile
// in Firebase, minus you and anyone you already follow.
struct SuggestedFriendsRow: View {
    let users: [RiderProfile]
    @ObservedObject var manager: UserProfileManager
    let riderName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Suggested Friends")
                .font(.system(size: 15, weight: .bold)).foregroundColor(.prInk)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(users) { user in
                        SuggestedFriendCard(user: user, manager: manager, riderName: riderName)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(16)
        .background(Color.prCardBg)
        .cornerRadius(20)
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.prBorder, lineWidth: 1))
    }
}

struct SuggestedFriendCard: View {
    let user: RiderProfile
    @ObservedObject var manager: UserProfileManager
    let riderName: String

    var status: FollowStatus { manager.followStatus[user.id] ?? .notFollowing }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(Color.prCoral).frame(width: 52, height: 52)
                Text(user.initials).font(.system(size: 15, weight: .bold)).foregroundColor(.white)
            }
            Text(user.name)
                .font(.system(size: 12, weight: .semibold)).foregroundColor(.prInk)
                .lineLimit(1)

            Button(action: {
                let myInitials = riderName.rideInitials
                manager.sendFollowRequest(to: user.id, myName: riderName, myInitials: myInitials)
            }) {
                Text(status == .requested ? "Requested" : "Follow")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(status == .requested ? .prMuted : .white)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .frame(minWidth: 74)
                    .background(status == .requested ? Color.prCoralSoft : Color.prCoral)
                    .cornerRadius(10)
            }
            .disabled(status == .requested)
        }
        .frame(width: 84)
        .onAppear { manager.checkFollowStatus(for: user.id) }
    }
}

// MARK: - Recommended Ride Card
// Full-width photo card, the "Recommended Ride" item from the Month 3-4 roadmap.
// There's no editorial/curation system behind this — it's simply the post with a
// photo that has the most likes right now, computed client-side in RideFeedView.
struct RecommendedRideCard: View {
    let post: FeedPost
    @ObservedObject var manager: RideFeedManager

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: URL(string: post.photoURL ?? "")) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Rectangle().fill(Color.prCoralSoft)
                }
            }
            .frame(height: 220)
            .frame(maxWidth: .infinity)
            .clipped()

            LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .bottom, endPoint: .top)
                .frame(height: 130)

            VStack(alignment: .leading, spacing: 4) {
                Text("RECOMMENDED RIDE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.85))
                Text(post.title)
                    .font(.system(size: 18, weight: .bold)).foregroundColor(.white)
                Text("\(post.authorName) • \(post.distanceString)")
                    .font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.9))
            }
            .padding(16)

            // Bookmark overlay, top-right — matches REVER's Recommended Ride card.
            VStack {
                HStack {
                    Spacer()
                    Button(action: {
                        manager.toggleBookmark(postID: post.id, currentlyBookmarked: post.bookmarkedByMe)
                    }) {
                        Image(systemName: post.bookmarkedByMe ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(10)
                            .background(Color.black.opacity(0.35))
                            .clipShape(Circle())
                    }
                }
                Spacer()
            }
            .padding(12)
        }
        .clipShape(Rectangle())
    }
}

// MARK: - Comments Sheet
struct FeedCommentsSheet: View {
    let post: FeedPost
    @ObservedObject var manager: RideFeedManager
    @AppStorage("riderName") var riderName: String = "Rider"
    @State private var commentText = ""
    @State private var commentPendingDelete: FeedComment? = nil
    @State private var deleteCommentError: String? = nil
    @Environment(\.dismiss) var dismiss

    // Either the person who wrote the comment, or the person whose post it's
    // on, can remove it — same moderation model as most feeds.
    private func canDelete(_ comment: FeedComment) -> Bool {
        manager.myKnownIDs.contains(comment.userID) || manager.myKnownIDs.contains(post.authorID)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        let list = manager.comments[post.id] ?? []
                        if list.isEmpty {
                            Text("No comments yet").font(.system(size: 13)).foregroundColor(.prMuted).padding(.top, 40)
                        } else {
                            ForEach(list) { comment in
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(comment.userName).font(.system(size: 13, weight: .bold)).foregroundColor(.prInk)
                                        Text(comment.text).font(.system(size: 14)).foregroundColor(.prInk)
                                    }
                                    Spacer(minLength: 8)
                                    if canDelete(comment) {
                                        Button(action: { commentPendingDelete = comment }) {
                                            Image(systemName: "trash").font(.system(size: 12)).foregroundColor(.prMuted)
                                        }
                                    }
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.prCardBg)
                                .cornerRadius(12)
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.prBorder, lineWidth: 1))
                            }
                        }
                    }
                    .padding(16)
                }

                HStack(spacing: 10) {
                    TextField("Add a comment...", text: $commentText)
                        .foregroundColor(.prInk)
                        .padding(12).background(Color.prCardBg).cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.prBorder, lineWidth: 1))
                    Button(action: {
                        manager.addComment(postID: post.id, text: commentText, userName: riderName)
                        commentText = ""
                    }) {
                        Image(systemName: "paperplane.fill").foregroundColor(.white)
                            .frame(width: 44, height: 44).background(Color.prCoral).cornerRadius(12)
                    }
                    .disabled(commentText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(16)
            }
            .background(Color.prBg.ignoresSafeArea())
            .navigationTitle(post.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { manager.listenForComments(postID: post.id) }
        .alert("Delete this comment?", isPresented: Binding(
            get: { commentPendingDelete != nil }, set: { if !$0 { commentPendingDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let comment = commentPendingDelete {
                    manager.deleteComment(postID: post.id, commentID: comment.id) { error in
                        if let error { deleteCommentError = error }
                    }
                }
                commentPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { commentPendingDelete = nil }
        }
        .alert("Couldn't Delete Comment", isPresented: Binding(
            get: { deleteCommentError != nil }, set: { if !$0 { deleteCommentError = nil } }
        )) {
            Button("OK", role: .cancel) { deleteCommentError = nil }
        } message: {
            Text(deleteCommentError ?? "")
        }
    }
}

// MARK: - Feed Route Map (lightweight, non-interactive preview)
private class FeedPinAnnotation: MKPointAnnotation {
    var isStart: Bool = true
}

struct FeedRouteMapView: UIViewRepresentable {
    let route: [CLLocationCoordinate2D]

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.isScrollEnabled = false
        mapView.isZoomEnabled = false
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        // Matches the hybrid style used everywhere else in the app (Home,
        // Group Ride, Track Mode, etc.) — this small preview map was still
        // hardcoded to plain .standard, which is why it looked like it had
        // "reverted" even though every interactive map with its own toggle
        // was working fine.
        mapView.mapType = .hybrid
        mapView.showsTraffic = false
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)
        guard !route.isEmpty else { return }

        if route.count > 1 {
            let polyline = MKPolyline(coordinates: route, count: route.count)
            mapView.addOverlay(polyline, level: .aboveRoads)
            let rect = polyline.boundingMapRect
            mapView.setVisibleMapRect(
                rect.insetBy(dx: -rect.size.width * 0.15, dy: -rect.size.height * 0.15),
                animated: false
            )

            let startPin = FeedPinAnnotation(); startPin.coordinate = route.first!; startPin.isStart = true
            let endPin = FeedPinAnnotation(); endPin.coordinate = route.last!; endPin.isStart = false
            mapView.addAnnotations([startPin, endPin])
        } else {
            let region = MKCoordinateRegion(center: route[0], span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
            mapView.setRegion(region, animated: false)
            let pin = FeedPinAnnotation(); pin.coordinate = route[0]; pin.isStart = true
            mapView.addAnnotation(pin)
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
            guard let pin = annotation as? FeedPinAnnotation else { return nil }
            let view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "feedPin")
            view.markerTintColor = pin.isStart ? UIColor.systemGreen : UIColor.systemRed
            view.canShowCallout = false
            return view
        }
    }
}

// MARK: - Post To Feed Sheet
// Used from the solo ride summary screen and from Ride History to share a
// completed ride. Posts text stats + a decimated route, plus an optional photo
// (uploaded to Firebase Storage — added Aug 17, 2026 once the project moved to
// the Blaze plan, which Storage requires).
struct PostToFeedSheet: View {
    let distance: Double
    let duration: String
    let gpxFilePath: String?
    let defaultTitle: String

    @AppStorage("riderName") var riderName: String = "Rider"
    @StateObject private var feedManager = RideFeedManager()
    @State private var title: String = ""
    @State private var isPosting = false
    @State private var posted = false
    @State private var errorMessage: String? = nil
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var selectedPhotoImage: Image? = nil
    @State private var selectedPhotoData: Data? = nil
    // Aug 24, 2026 — "Post Anonymously" privacy toggle, off by default. See
    // RideFeedManager.postRide's header comment for what this actually does
    // (never writes your real name/initials at all, not just hides them).
    @State private var isAnonymous: Bool = false
    @Environment(\.dismiss) var dismiss

    var myInitials: String { riderName.rideInitials }

    var body: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()
            VStack(spacing: 20) {
                RoundedRectangle(cornerRadius: 3).fill(Color.prBorder)
                    .frame(width: 40, height: 5).padding(.top, 12)

                if posted {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 44)).foregroundColor(Color(red: 0.180, green: 0.620, blue: 0.357))
                        Text("Posted to Feed!").font(.system(size: 18, weight: .bold)).foregroundColor(.prInk)
                    }
                    .padding(.top, 40)

                    Button(action: { dismiss() }) {
                        Text("Done").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(Color.prCoral).cornerRadius(16)
                    }
                    .padding(.horizontal, 20)
                } else {
                    VStack(spacing: 6) {
                        Text("Share to Feed?").font(.system(size: 20, weight: .bold)).foregroundColor(.prInk)
                        Text("Riders who follow you will see this ride with its route map.")
                            .font(.system(size: 13)).foregroundColor(.prMuted)
                            .multilineTextAlignment(.center).padding(.horizontal, 30)
                    }

                    TextField("Ride title", text: $title)
                        .foregroundColor(.prInk)
                        .padding(14).background(Color.prCardBg).cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.prBorder, lineWidth: 1))
                        .padding(.horizontal, 20)

                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        if let selectedPhotoImage {
                            selectedPhotoImage
                                .resizable().scaledToFill()
                                .frame(height: 160)
                                .frame(maxWidth: .infinity)
                                .clipped()
                                .cornerRadius(14)
                        } else {
                            VStack(spacing: 8) {
                                Image(systemName: "photo.badge.plus").font(.system(size: 24)).foregroundColor(.prCoral)
                                Text("Add a photo (optional)").font(.system(size: 13, weight: .medium)).foregroundColor(.prMuted)
                            }
                            .frame(height: 100)
                            .frame(maxWidth: .infinity)
                            .background(Color.prCardBg)
                            .cornerRadius(14)
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, style: StrokeStyle(lineWidth: 1, dash: [6])))
                        }
                    }
                    .padding(.horizontal, 20)
                    .onChange(of: selectedPhotoItem) { _, newItem in
                        Task {
                            guard let newItem, let rawData = try? await newItem.loadTransferable(type: Data.self) else { return }
                            let resized = Self.resizedJPEG(from: rawData)
                            await MainActor.run {
                                selectedPhotoData = resized
                                if let resized, let uiImage = UIImage(data: resized) {
                                    selectedPhotoImage = Image(uiImage: uiImage)
                                }
                            }
                        }
                    }

                    HStack(spacing: 20) {
                        Text(MeasurementUnits.distanceMiles(distance))
                        Text(duration)
                    }
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(.prMuted)

                    // Aug 24, 2026 — "Post Anonymously": a ride's route always
                    // shows the real path ridden (including where it started —
                    // that trimming idea was raised and deliberately left for
                    // later), which can expose where a rider lives. This
                    // toggle at least keeps the *name* off it. Off by default.
                    HStack {
                        Image(systemName: "eye.slash").font(.system(size: 14)).foregroundColor(.prMuted)
                        Text("Post Anonymously").font(.system(size: 14, weight: .medium)).foregroundColor(.prInk)
                        Spacer()
                        Toggle("", isOn: $isAnonymous).labelsHidden().tint(.prCoral)
                    }
                    .padding(14).background(Color.prCardBg).cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.prBorder, lineWidth: 1))
                    .padding(.horizontal, 20)

                    Button(action: post) {
                        Group {
                            if isPosting {
                                ProgressView().tint(.white)
                            } else {
                                Text("Post to Feed").font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.vertical, 16).background(Color.prCoral).cornerRadius(16)
                    .padding(.horizontal, 20)
                    .disabled(isPosting || title.trimmingCharacters(in: .whitespaces).isEmpty)

                    if let errorMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(errorMessage)
                        }
                        .font(.system(size: 12)).foregroundColor(Color(red: 0.827, green: 0.231, blue: 0.173))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                    }

                    Button(action: { dismiss() }) {
                        Text("Not Now").font(.system(size: 14)).foregroundColor(.prMuted)
                    }
                }
                Spacer()
            }
        }
        .onAppear { if title.isEmpty { title = defaultTitle } }
    }

    func post() {
        isPosting = true
        errorMessage = nil
        feedManager.postRide(
            title: title, distance: distance, duration: duration, gpxFilePath: gpxFilePath,
            authorName: riderName, authorInitials: myInitials, photoData: selectedPhotoData,
            isAnonymous: isAnonymous
        ) { failure in
            isPosting = false
            if let failure {
                errorMessage = failure
            } else {
                withAnimation { posted = true }
            }
        }
    }

    // Downscales to a max 1600px edge and re-encodes as JPEG at 0.75 quality
    // before upload — keeps Firebase Storage usage (and cost) small; a full-res
    // photo straight from the camera is unnecessary for a feed thumbnail.
    private static func resizedJPEG(from data: Data, maxDimension: CGFloat = 1600, quality: CGFloat = 0.75) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let scale = min(1.0, maxDimension / max(size.width, size.height))
        guard scale < 1.0 else { return image.jpegData(compressionQuality: quality) }
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        return resized.jpegData(compressionQuality: quality)
    }
}

#Preview { NavigationView { RideFeedView() } }
