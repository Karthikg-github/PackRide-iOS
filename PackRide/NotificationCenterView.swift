import SwiftUI

// Restores the notification-bell sheet referenced by ContentView, GroupRideView,
// RideHistoryView, and RideFeedView (see PackRide_Handover_Document.md's
// "Bug 1 — follow requests going nowhere" entry) after the source file that
// defined it went missing from the project. Same accept/decline follow-request
// list, same visual pattern already used inline in ProfileView's own Follow
// Requests card, so it doesn't introduce a new look.
struct NotificationCenterView: View {
    @ObservedObject var profileManager: UserProfileManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ZStack {
                Color.prBg.ignoresSafeArea()

                if profileManager.followRequests.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 32))
                            .foregroundColor(.prMuted)
                        Text("No notifications right now")
                            .font(.system(size: 14))
                            .foregroundColor(.prMuted)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(profileManager.followRequests) { request in
                                FollowRequestRow(
                                    request: request,
                                    onAccept: {
                                        profileManager.acceptFollowRequest(
                                            requesterID: request.id,
                                            requesterName: request.name,
                                            requesterInitials: request.initials
                                        )
                                    },
                                    onDecline: {
                                        profileManager.declineFollowRequest(requesterID: request.id)
                                    }
                                )
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct FollowRequestRow: View {
    let request: FollowRequest
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.prCoralSoft).frame(width: 44, height: 44)
                Text(request.initials).font(.system(size: 14, weight: .bold)).foregroundColor(.prCoral)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(request.name).font(.system(size: 14, weight: .medium)).foregroundColor(.prInk)
                Text("Wants to follow you").font(.system(size: 12)).foregroundColor(.prMuted)
            }
            Spacer()
            HStack(spacing: 8) {
                Button(action: onAccept) {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                        .frame(width: 34, height: 34).background(Color(red: 0.180, green: 0.620, blue: 0.357)).cornerRadius(10)
                }
                Button(action: onDecline) {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                        .frame(width: 34, height: 34).background(Color.prMuted).cornerRadius(10)
                }
            }
        }
        .padding(12)
        .background(Color.prFieldBg)
        .cornerRadius(14)
    }
}
