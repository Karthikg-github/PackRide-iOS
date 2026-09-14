import SwiftUI
import FirebaseAuth

// MARK: - Rider Profile Sheet (shown when tapping a rider in group ride)
struct RiderProfileView: View {
    let rider: LiveRider
    @StateObject private var profileManager = UserProfileManager()
    @AppStorage("riderName") var myName: String = "Rider"
    @Environment(\.dismiss) var dismiss

    var myInitials: String { myName.rideInitials }
    var myID: String { Auth.auth().currentUser?.uid ?? UIDevice.current.identifierForVendor?.uuidString ?? "" }

    var followStatus: FollowStatus {
        profileManager.followStatus[rider.id] ?? .notFollowing
    }

    var body: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 3).fill(Color.prBorder)
                    .frame(width: 40, height: 5).padding(.top, 12).padding(.bottom, 20)

                ZStack {
                    Circle().fill(Color.prCoral).frame(width: 80, height: 80)
                    Text(rider.initials).font(.system(size: 28, weight: .bold)).foregroundColor(.white)
                }

                Text(rider.name)
                    .font(.system(size: 22, weight: .bold)).foregroundColor(.prInk).padding(.top, 12)

                HStack(spacing: 6) {
                    Circle().fill(Color(red: 0.180, green: 0.620, blue: 0.357)).frame(width: 7, height: 7)
                    Text("Riding now").font(.system(size: 13)).foregroundColor(Color(red: 0.180, green: 0.620, blue: 0.357))
                }
                .padding(.top, 4)

                if rider.speed > 0 {
                    Text(MeasurementUnits.speedMph(rider.speed))
                        .font(.system(size: 15, weight: .medium)).foregroundColor(.prCoral)
                        .padding(.top, 4)
                }

                Spacer().frame(height: 32)

                followButton.padding(.horizontal, 24)

                Spacer()
            }
        }
        .onAppear { profileManager.checkFollowStatus(for: rider.id) }
    }

    @ViewBuilder
    private var followButton: some View {
        switch followStatus {
        case .isMe:
            EmptyView()

        case .notFollowing:
            Button(action: {
                profileManager.sendFollowRequest(to: rider.id, myName: myName, myInitials: myInitials)
            }) {
                HStack(spacing: 10) {
                    Image(systemName: "person.badge.plus").font(.system(size: 18))
                    Text("Follow").font(.system(size: 17, weight: .semibold))
                }
                .foregroundColor(.white).frame(maxWidth: .infinity)
                .padding(.vertical, 16).background(Color.prCoral).cornerRadius(14)
            }

        case .requested:
            HStack(spacing: 10) {
                Image(systemName: "clock").font(.system(size: 18))
                Text("Request Sent").font(.system(size: 17, weight: .semibold))
            }
            .foregroundColor(.prCoral).frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.prCoralSoft)
            .cornerRadius(14)

        case .following:
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundColor(Color(red: 0.180, green: 0.620, blue: 0.357))
                    Text("Following").font(.system(size: 17, weight: .semibold)).foregroundColor(Color(red: 0.180, green: 0.620, blue: 0.357))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(Color(red: 0.891, green: 0.965, blue: 0.918)).cornerRadius(14)

                Button(action: { profileManager.unfollowUser(targetUserID: rider.id) }) {
                    Text("Unfollow").font(.system(size: 14)).foregroundColor(.prMuted)
                }
            }
        }
    }
}
