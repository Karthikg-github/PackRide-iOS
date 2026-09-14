import Foundation
import UIKit
import Combine
import FirebaseDatabase
import FirebaseAuth
import FirebaseStorage
import CoreLocation

// MARK: - Feed Route Point (decimated, for map preview only — not the full GPX track)
struct FeedRoutePoint: Codable {
    let lat: Double
    let lng: Double
}

// MARK: - Feed Post Model
struct FeedPost: Identifiable {
    let id: String
    let authorID: String
    let authorName: String
    let authorInitials: String
    let timestamp: TimeInterval
    let title: String
    let distance: Double
    let duration: String
    let route: [FeedRoutePoint]
    // Replaced the old boolean like with a small set of emoji reactions
    // (fire/heart/thumbs-up/rock-on) — each person has at most one reaction
    // on a post, myReaction is nil if you haven't reacted at all.
    var reactionCount: Int
    var myReaction: String?
    var commentCount: Int
    var photoURL: String? = nil
    var bookmarkedByMe: Bool = false
    // Track/Lap Mode fields — added Aug 2026. A lap-session post reuses this
    // same FeedPost/feedPosts table rather than a separate one (simpler rules,
    // one listener), it's just flagged and carries a few extra fields. Old
    // posts from before this existed simply don't have these keys in Firebase,
    // which is why every one of them has a safe default below.
    var isLapSession: Bool = false
    var trackName: String = ""
    var lapTimes: [Double] = []
    var bestLapTime: Double = 0
    // Aug 24, 2026 — "Post Anonymously" privacy toggle. When true, authorName/
    // authorInitials were written as the literal placeholders "Anonymous
    // Rider"/"?" at post time (see postRide below) — the real identity is
    // never written anywhere a feed viewer, or a raw read of the database,
    // could recover it. authorID is unchanged (still needed for delete/
    // ownership and reaction/comment permission checks), it just never
    // surfaces in the feed UI for an anonymous post.
    var isAnonymous: Bool = false

    var distanceString: String { MeasurementUnits.distanceMiles(distance) }

    var dateString: String {
        let date = Date(timeIntervalSince1970: timestamp)
        let f = DateFormatter()
        f.dateFormat = "M/d/yy • h:mm a"
        return f.string(from: date)
    }

    var routeCoordinates: [CLLocationCoordinate2D] {
        route.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
    }
}

// MARK: - Feed Comment Model
struct FeedComment: Identifiable {
    let id: String
    let userID: String
    let userName: String
    let text: String
    let timestamp: TimeInterval
}

// MARK: - Ride Feed Manager
// Posts live in Firebase Realtime Database under "feedPosts". Route previews render
// client-side from a decimated set of GPS points (~60 max) rather than a stored
// image, so that part still works with no Storage cost regardless of photo. Photos
// are optional — added Aug 17, 2026 once the project moved to the Blaze plan, which
// Firebase Storage requires. A post can have a route, a photo, both, or (rarely)
// neither. The feed itself isn't fanned out server-side (no Cloud Functions needed
// either) — the client pulls the most recent posts and filters to people you follow.
class RideFeedManager: ObservableObject {
    private let db = Database.database().reference()

    @Published var posts: [FeedPost] = []
    @Published var isLoading = false
    @Published var comments: [String: [FeedComment]] = [:]

    private var feedRef: DatabaseQuery?
    private var feedHandle: DatabaseHandle?
    private var commentHandles: [String: (DatabaseReference, DatabaseHandle)] = [:]

    var myID: String { Auth.auth().currentUser?.uid ?? UIDevice.current.identifierForVendor?.uuidString ?? "" }

    /// Posts are authored under whichever ID scheme was active at the moment
    /// they were created — the signed-in Firebase uid if logged in at the
    /// time, or this device's identifierForVendor if not. Since that can
    /// differ from whichever one `myID` resolves to right now (e.g. signing
    /// in after posting anonymously), ownership checks (like showing the
    /// delete button) compare against both possible IDs rather than just the
    /// current one, so a post you made doesn't stop being recognized as
    /// yours just because your auth state changed since.
    var myKnownIDs: Set<String> {
        var ids: Set<String> = []
        if let uid = Auth.auth().currentUser?.uid { ids.insert(uid) }
        if let deviceID = UIDevice.current.identifierForVendor?.uuidString { ids.insert(deviceID) }
        return ids
    }

    deinit {
        stopListening()
        for (_, (ref, handle)) in commentHandles { ref.removeObserver(withHandle: handle) }
    }

    // MARK: - Feed listening
    // followingIDs comes from UserProfileManager.followedUsers — the feed always
    // includes your own posts too, so "Ride Feed" and "My Rides" share one listener.
    func listenForFeed(followingIDs: [String]) {
        stopListening()
        guard !myID.isEmpty else { return }
        isLoading = true
        let allowedIDs = Set(followingIDs + [myID])

        let ref = db.child("feedPosts").queryLimited(toLast: 100)
        feedRef = ref
        feedHandle = ref.observe(.value) { [weak self] snapshot in
            guard let self else { return }
            var loaded: [FeedPost] = []
            for child in snapshot.children {
                guard let snap = child as? DataSnapshot,
                      let post = Self.parsePost(snap, myID: self.myID),
                      allowedIDs.contains(post.authorID) else { continue }
                loaded.append(post)
            }
            DispatchQueue.main.async {
                self.posts = loaded.sorted { $0.timestamp > $1.timestamp }
                self.isLoading = false
            }
        }
    }

    func stopListening() {
        if let feedHandle { feedRef?.removeObserver(withHandle: feedHandle) }
        feedHandle = nil
        feedRef = nil
    }

    private static func parsePost(_ snap: DataSnapshot, myID: String) -> FeedPost? {
        guard let data = snap.value as? [String: Any],
              let authorID = data["authorID"] as? String,
              let authorName = data["authorName"] as? String,
              let authorInitials = data["authorInitials"] as? String,
              let timestamp = data["timestamp"] as? TimeInterval,
              let title = data["title"] as? String,
              let distance = data["distance"] as? Double,
              let duration = data["duration"] as? String
        else { return nil }

        var route: [FeedRoutePoint] = []
        if let routeArray = data["route"] as? [[String: Any]] {
            route = routeArray.compactMap {
                guard let lat = $0["lat"] as? Double, let lng = $0["lng"] as? Double else { return nil }
                return FeedRoutePoint(lat: lat, lng: lng)
            }
        }

        // "reactions" replaces the old boolean "likes" node. Old posts
        // liked before this change only have "likes", so fall back to
        // reading that (treating a plain old like as a 🔥 reaction) rather
        // than silently losing their count.
        let reactionsRaw = data["reactions"] as? [String: Any] ?? [:]
        let legacyLikes = data["likes"] as? [String: Any] ?? [:]
        let reactionCount = reactionsRaw.isEmpty ? legacyLikes.count : reactionsRaw.count
        let myReaction = (reactionsRaw[myID] as? String) ?? (legacyLikes[myID] != nil ? "🔥" : nil)
        let bookmarks = data["bookmarks"] as? [String: Any] ?? [:]
        let commentCount = (data["comments"] as? [String: Any])?.count ?? 0

        // Firebase can hand back a numeric array as [Double] or as [Any]
        // (NSNumber-boxed) depending on the exact values — handle both so lap
        // times don't silently disappear.
        var lapTimes: [Double] = []
        if let direct = data["lapTimes"] as? [Double] {
            lapTimes = direct
        } else if let boxed = data["lapTimes"] as? [Any] {
            lapTimes = boxed.compactMap { ($0 as? NSNumber)?.doubleValue }
        }

        return FeedPost(
            id: snap.key, authorID: authorID, authorName: authorName, authorInitials: authorInitials,
            timestamp: timestamp, title: title, distance: distance, duration: duration,
            route: route, reactionCount: reactionCount, myReaction: myReaction, commentCount: commentCount,
            photoURL: data["photoURL"] as? String,
            bookmarkedByMe: bookmarks[myID] != nil,
            isLapSession: data["isLapSession"] as? Bool ?? false,
            trackName: data["trackName"] as? String ?? "",
            lapTimes: lapTimes,
            bestLapTime: data["bestLapTime"] as? Double ?? 0,
            isAnonymous: data["isAnonymous"] as? Bool ?? false
        )
    }

    // MARK: - Post a ride to the feed
    // completion passes back an error message on failure (nil on success) so the
    // UI can show *why* a post didn't go through — e.g. "Permission denied" almost
    // always means the feedPosts rules haven't been pasted into the Firebase
    // console yet (see handover doc).
    //
    // photoData is optional JPEG data (already resized/compressed by the caller —
    // see PostToFeedSheet). If present, it's uploaded to Firebase Storage first and
    // the post only gets written once that succeeds, so we never end up with a feed
    // post that silently lost its photo.
    func postRide(title: String, distance: Double, duration: String, gpxFilePath: String?,
                  authorName: String, authorInitials: String, photoData: Data? = nil,
                  isAnonymous: Bool = false,
                  completion: @escaping (String?) -> Void) {
        guard !myID.isEmpty else { completion("Not signed in — try logging out and back in."); return }

        let postID = db.child("feedPosts").childByAutoId().key ?? UUID().uuidString

        // Aug 24, 2026 — "Post Anonymously": when set, the real name/initials
        // are never written at all, only these literal placeholders — this is
        // a real privacy boundary, not a UI hide, since FeedPostCard only ever
        // renders whatever authorName/authorInitials the database actually
        // holds. authorID is still written normally (delete/ownership and
        // reaction/comment-permission checks need it), none of which surface
        // another user's identity in the feed UI.
        var data: [String: Any] = [
            "authorID": myID,
            "authorName": isAnonymous ? "Anonymous Rider" : authorName,
            "authorInitials": isAnonymous ? "?" : authorInitials,
            "timestamp": Date().timeIntervalSince1970,
            "title": title.trimmingCharacters(in: .whitespaces),
            "distance": distance,
            "duration": duration
        ]
        if isAnonymous { data["isAnonymous"] = true }

        let route = Self.decimatedRoute(fromGPX: gpxFilePath)
        if !route.isEmpty {
            data["route"] = route.map { ["lat": $0.lat, "lng": $0.lng] }
        }

        guard let photoData else {
            db.child("feedPosts").child(postID).setValue(data) { error, _ in
                DispatchQueue.main.async { completion(error?.localizedDescription) }
            }
            return
        }

        let photoRef = Storage.storage().reference().child("feedPhotos/\(postID).jpg")
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"
        metadata.customMetadata = ["ownerUid": myID]
        photoRef.putData(photoData, metadata: metadata) { [weak self] _, error in
            if let error {
                DispatchQueue.main.async { completion(error.localizedDescription) }
                return
            }
            photoRef.downloadURL { url, error in
                if let error {
                    DispatchQueue.main.async { completion(error.localizedDescription) }
                    return
                }
                data["photoURL"] = url?.absoluteString
                self?.db.child("feedPosts").child(postID).setValue(data) { error, _ in
                    DispatchQueue.main.async { completion(error?.localizedDescription) }
                }
            }
        }
    }

    // MARK: - Post a lap/track session to the feed
    // Same feedPosts table as postRide() above, just flagged isLapSession and
    // carrying lap-specific fields instead of a route/photo. No Firebase rules
    // change needed — the existing feedPosts rule doesn't validate individual
    // fields, so these new ones are accepted automatically.
    func postLapSession(title: String, trackName: String, laps: [Double], bestLapTime: Double, distance: Double,
                         authorName: String, authorInitials: String, completion: @escaping (String?) -> Void) {
        guard !myID.isEmpty else { completion("Not signed in — try logging out and back in."); return }

        let postID = db.child("feedPosts").childByAutoId().key ?? UUID().uuidString
        let data: [String: Any] = [
            "authorID": myID,
            "authorName": authorName,
            "authorInitials": authorInitials,
            "timestamp": Date().timeIntervalSince1970,
            "title": title.trimmingCharacters(in: .whitespaces),
            "distance": distance,
            "duration": "",
            "isLapSession": true,
            "trackName": trackName,
            "bestLapTime": bestLapTime,
            "lapTimes": laps
        ]
        db.child("feedPosts").child(postID).setValue(data) { error, _ in
            DispatchQueue.main.async { completion(error?.localizedDescription) }
        }
    }

    // completion passes back an error message on failure (nil on success), same
    // pattern as postRide() — a delete that silently no-ops (e.g. blocked by the
    // Firebase rules) previously looked identical to a delete that worked, from
    // the tapper's point of view. Deleting a post only ever touches this Firebase
    // node — it never reaches into local Ride History, so the underlying ride's
    // own record (and its GPX file) is untouched either way.
    func deletePost(postID: String, completion: @escaping (String?) -> Void = { _ in }) {
        guard !myID.isEmpty else { completion("Not signed in — try logging out and back in."); return }
        db.child("feedPosts").child(postID).removeValue { error, _ in
            if error == nil {
                Storage.storage().reference().child("feedPhotos/\(postID).jpg").delete(completion: nil)
            }
            DispatchQueue.main.async { completion(error?.localizedDescription) }
        }
    }

    // MARK: - Reactions
    // Replaces the old single boolean "like" with a small set of emoji
    // reactions (🔥 ❤️ 👍 🤘) — each person can have at most one reaction on
    // a post at a time, stored as reactions/{uid}: "❤️". Picking a new emoji
    // just overwrites your previous one; passing nil removes your reaction
    // entirely. Old posts liked before this change still show a count and
    // still recognize you as having reacted (see parsePost's legacy-likes
    // fallback), they just display as a 🔥 until you pick something else.
    func setReaction(postID: String, emoji: String?) {
        guard !myID.isEmpty else { return }
        let ref = db.child("feedPosts").child(postID).child("reactions").child(myID)
        if let emoji {
            ref.setValue(emoji)
        } else {
            ref.removeValue()
        }
    }

    // MARK: - Bookmarks
    // Stored the same way as likes (a `bookmarks/{userID}: true` child under the
    // post), so it's covered by the existing feedPosts write rule — no separate
    // Firebase console step needed. Personal/private (no public count shown), a
    // simple "did I save this ride to look at later" flag.
    func toggleBookmark(postID: String, currentlyBookmarked: Bool) {
        guard !myID.isEmpty else { return }
        let ref = db.child("feedPosts").child(postID).child("bookmarks").child(myID)
        if currentlyBookmarked {
            ref.removeValue()
        } else {
            ref.setValue(true)
        }
    }

    // MARK: - Comments
    func listenForComments(postID: String) {
        if let existing = commentHandles[postID] { existing.0.removeObserver(withHandle: existing.1) }
        let ref = db.child("feedPosts").child(postID).child("comments")
        let handle = ref.observe(.value) { [weak self] snapshot in
            var loaded: [FeedComment] = []
            for child in snapshot.children {
                guard let snap = child as? DataSnapshot,
                      let data = snap.value as? [String: Any],
                      let userID = data["userID"] as? String,
                      let userName = data["userName"] as? String,
                      let text = data["text"] as? String,
                      let timestamp = data["timestamp"] as? TimeInterval
                else { continue }
                loaded.append(FeedComment(id: snap.key, userID: userID, userName: userName, text: text, timestamp: timestamp))
            }
            DispatchQueue.main.async {
                self?.comments[postID] = loaded.sorted { $0.timestamp < $1.timestamp }
            }
        }
        commentHandles[postID] = (ref, handle)
    }

    func addComment(postID: String, text: String, userName: String) {
        guard !myID.isEmpty, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let data: [String: Any] = [
            "userID": myID, "userName": userName,
            "text": text.trimmingCharacters(in: .whitespaces),
            "timestamp": Date().timeIntervalSince1970
        ]
        db.child("feedPosts").child(postID).child("comments").childByAutoId().setValue(data)
    }

    // Either the comment's own author OR the post's author can remove a
    // comment (moderation, same as most feeds) — the Firebase rules need to
    // grant both of those, not just an exact match on the comment's userID,
    // see the updated "feedPosts" rules block in the handover doc.
    func deleteComment(postID: String, commentID: String, completion: @escaping (String?) -> Void = { _ in }) {
        guard !myID.isEmpty else { completion("Not signed in — try logging out and back in."); return }
        db.child("feedPosts").child(postID).child("comments").child(commentID).removeValue { error, _ in
            DispatchQueue.main.async { completion(error?.localizedDescription) }
        }
    }

    // MARK: - Rename my posts (profile name changed)
    // FeedPost.authorName/authorInitials are captured at post time rather than
    // joined live from the profile, so editing your name in Profile wouldn't
    // otherwise show up on posts you already made. Queries only this
    // account's own posts (indexed by authorID — see the ".indexOn" added to
    // the feedPosts rules) and patches just those two fields on each one.
    // Known limitation: existing comments' own userName snapshots are left
    // as-is, same as authorName was before this fix.
    func renameMyPosts(to newName: String, newInitials: String) {
        guard !myID.isEmpty else { return }
        db.child("feedPosts").queryOrdered(byChild: "authorID").queryEqual(toValue: myID)
            .observeSingleEvent(of: .value) { snapshot in
                for child in snapshot.children {
                    guard let snap = child as? DataSnapshot else { continue }
                    // Aug 24, 2026 — a post made with "Post Anonymously" must
                    // stay anonymous even after you later rename yourself in
                    // Profile — otherwise a later rename would silently
                    // de-anonymize it by overwriting the "Anonymous Rider"/"?"
                    // placeholders with your real current name.
                    let isAnonymous = (snap.value as? [String: Any])?["isAnonymous"] as? Bool ?? false
                    guard !isAnonymous else { continue }
                    snap.ref.updateChildValues(["authorName": newName, "authorInitials": newInitials])
                }
            }
    }

    // MARK: - GPX parsing + decimation
    // Reads the same local GPX file GPXRecorder writes, then keeps only ~60 evenly
    // spaced points (always including the first and last) so a ride with thousands
    // of recorded points doesn't turn into a huge Realtime Database write.
    private static func decimatedRoute(fromGPX path: String?, maxPoints: Int = 60) -> [FeedRoutePoint] {
        guard let path,
              let data = GPXStorage.contents(path),
              let xmlString = String(data: data, encoding: .utf8) else { return [] }

        var points: [FeedRoutePoint] = []
        let blocks = xmlString.components(separatedBy: "<trkpt ")
        for block in blocks.dropFirst() {
            guard let latRange = block.range(of: #"lat="([\-\d.]+)""#, options: .regularExpression),
                  let lngRange = block.range(of: #"lon="([\-\d.]+)""#, options: .regularExpression) else { continue }
            let latStr = block[latRange].replacingOccurrences(of: "lat=", with: "").replacingOccurrences(of: "\"", with: "")
            let lngStr = block[lngRange].replacingOccurrences(of: "lon=", with: "").replacingOccurrences(of: "\"", with: "")
            guard let lat = Double(latStr), let lng = Double(lngStr), lat != 0, lng != 0 else { continue }
            points.append(FeedRoutePoint(lat: lat, lng: lng))
        }

        guard points.count > maxPoints else { return points }

        let stride = Double(points.count - 1) / Double(maxPoints - 1)
        var result: [FeedRoutePoint] = []
        for i in 0..<maxPoints {
            let index = Int((Double(i) * stride).rounded())
            result.append(points[min(index, points.count - 1)])
        }
        return result
    }
}
