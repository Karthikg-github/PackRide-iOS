import SwiftUI
import PhotosUI
import ContactsUI
import UIKit
import FirebaseAuth
import FirebaseDatabase

// MARK: - Emergency Contact Model
struct EmergencyContact: Codable, Identifiable {
    var id = UUID()
    var name: String
    var phone: String
    var relationship: String
    // Sep 12, 2026 — links this contact to another PackRide account so a
    // crash alert can notify them in-app (CrashDetectionView's
    // primaryResponderUIDs), not just by phone/SMS. Optional: contacts
    // added before this existed, or never linked, decode fine with nil.
    var linkedUserID: String? = nil
}

/// iOS counterpart to Android's SafetyHubScreen. The hub reuses the real
/// CrashDetectionView and NeedHelpView so monitoring, contacts and active help
/// sharing continue to have one source of truth throughout the app.
struct SafetyHubView: View {
    private enum SafetyTab: String, CaseIterable, Identifiable {
        case crash = "Crash"
        case needHelp = "Need Help"
        var id: Self { self }
    }

    @State private var selectedTab: SafetyTab = .crash

    var body: some View {
        VStack(spacing: 0) {
            Picker("Safety", selection: $selectedTab) {
                ForEach(SafetyTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.prCardBg)

            switch selectedTab {
            case .crash:
                CrashDetectionView()
            case .needHelp:
                NeedHelpView()
            }
        }
        .background(Color.prBg.ignoresSafeArea())
        .navigationTitle("Safety")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PrivacyDataView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
                privacySection("WHAT PACKRIDE COLLECTS", rows: [
                    "Account details and optional rider profile photos.",
                    "Precise location while recording, navigating, riding in a group, using Need Help, or enabling crash protection.",
                    "Ride records, GPX routes and optional motion telemetry.",
                    "Communities, follows, posts, reactions, comments and invitations you create.",
                    "Microphone audio only while you deliberately join Ride Comms. PackRide does not record calls."
                ])
                Color.prBg.frame(height: 10)
                privacySection("HOW IT IS USED", rows: [
                    "Firebase provides authentication, synchronized data, files, notifications and safety-alert delivery.",
                    "Apple Maps provides maps, routing and place search.",
                    "Agora carries live voice audio and Google AdMob provides advertising."
                ])
                Color.prBg.frame(height: 10)
                privacySection("YOUR CONTROLS", rows: [
                    "Follower and community location sharing stays off unless you enable it.",
                    "Need Help and crash information goes only to the audience or emergency contacts you choose.",
                    "You can change permissions in iOS Settings and delete your account from Profile."
                ])
                Color.prBg.frame(height: 10)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "hand.raised.fill").foregroundColor(.prCoral).frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("iOS Permissions").font(.system(size: 17, weight: .semibold)).foregroundColor(.prInk)
                            Text("Location, notifications, microphone and motion access").font(.system(size: 13)).foregroundColor(.prMuted)
                        }
                        Spacer(); Image(systemName: "arrow.up.right").foregroundColor(.prMuted)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 18).background(Color.prCardBg)
                }
                Color.clear.frame(height: 30)
            }
        }
        .background(Color.prBg.ignoresSafeArea())
        .navigationTitle("Privacy & Data")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.foregroundColor(.prCoral) } }
    }

    private func privacySection(_ title: String, rows: [String]) -> some View {
        VStack(spacing: 0) {
            HStack { Text(title).font(.system(size: 11, weight: .heavy)).tracking(2).foregroundColor(.prMuted); Spacer() }
                .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 10)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, text in
                    HStack(alignment: .top, spacing: 12) {
                        Circle().fill(Color.prCoral).frame(width: 6, height: 6).padding(.top, 7)
                        Text(text).font(.system(size: 14)).foregroundColor(.prInk).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 20).padding(.vertical, 13)
                    if index < rows.count - 1 { Divider().padding(.leading, 38) }
                }
            }.background(Color.prCardBg)
        }
    }
}

struct ProfileView: View {
    @EnvironmentObject private var auth: AuthManager
    @StateObject private var profileManager = UserProfileManager()
    @StateObject private var firebaseManager = FirebaseManager()
    @StateObject private var locationVisibility = LocationVisibilitySettings()
    // Only needed here to backfill authorName/authorInitials on your own
    // existing Feed posts when you rename yourself — see saveProfile() below.
    @StateObject private var feedManager = RideFeedManager()
    // Aug 2026: was @AppStorage("totalRides")/@AppStorage("totalMiles") — two
    // separate counters that nothing in the app ever actually wrote to, so
    // they sat stuck at 0 forever regardless of how many rides got recorded.
    // Ride History already computes these correctly, live, straight from the
    // real saved rides (RideHistoryManager.totalRides/.totalMiles below) — so
    // instead of trying to keep a second, separate counter in sync (and
    // risking the same bug again), Profile now just reads the same live
    // numbers Ride History does. Since ProfileView gets recreated fresh each
    // time you switch to the Profile tab (see ContentView's tab logic), this
    // reloads from the real saved data every time, no extra refresh needed.
    @StateObject private var historyManager = RideHistoryManager()
    @AppStorage("riderName") var riderName = ""
    @AppStorage("riderBike") var riderBike = ""
    @AppStorage("riderCity") var riderCity = ""
    @AppStorage("riderExperience") var riderExperience = "Intermediate"
    @AppStorage("bloodType") var bloodType = ""
    @AppStorage("allergies") var allergies = ""
    @AppStorage("darkModeOn") var darkModeOn = false
    @AppStorage(MeasurementUnits.preferenceKey) private var measurementSystemRaw = MeasurementSystem.imperial.rawValue
    @AppStorage("avatarURL") var avatarURL = ""
    @AppStorage("bannerURL") var bannerURL = ""

    @State private var selectedAvatarItem: PhotosPickerItem?
    @State private var selectedBannerItem: PhotosPickerItem?
    @State private var localAvatarImage: UIImage?
    @State private var localBannerImage: UIImage?
    @State private var isUploadingAvatar = false
    @State private var isUploadingBanner = false
    @State private var showLocationAudience = false

    @State private var isEditing = false
    @State private var tempName = ""
    @State private var tempBike = ""
    @State private var tempCity = ""
    @State private var selectedExperience = "Intermediate"

    @State private var emergencyContacts: [EmergencyContact] = []
    @State private var showAddContact = false
    @State private var editingContact: EmergencyContact? = nil
    @State private var isEditingEmergency = false
    @State private var tempBloodType = ""
    @State private var tempAllergies = ""
    @State private var showCopiedDeviceID = false
    @State private var showDeleteAccountAlert = false
    @State private var isDeletingAccount = false
    @State private var deleteAccountError: String? = nil
    @State private var showFeedbackSheet = false
    @State private var feedbackSentConfirmation = false
    @State private var showNotifications = false
    @State private var showNeedHelp = false
    @State private var showSafetyHub = false

    // Same value CommunityManager uses as "myID" — needed only if you ever have to
    // manually correct a community's stored createdBy field in the Firebase console
    // (e.g. for a community created before the creator/delete fix shipped).
    var deviceID: String { UIDevice.current.identifierForVendor?.uuidString ?? "Unavailable" }

    let experienceLevels = ["Beginner", "Intermediate", "Advanced", "Expert"]
    let bloodTypes = ["A+", "A-", "B+", "B-", "AB+", "AB-", "O+", "O-", "Unknown"]

    var body: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()
            ScrollView {
                LazyVStack(spacing: 0) {
                    profileHero
                    webSectionGap
                    webPrivacySection
                    webSectionGap
                    webRadiusSection
                    webSectionGap
                    webRiderProfileSection
                    webGarageRow
                    webSectionGap
                    webEmergencySection
                    webSectionGap
                    webSystemSection
                    webSectionGap
                    webAccountActions
                    AdBannerFooter()
                    Text(appVersionFooter)
                        .font(.system(size: 12)).foregroundColor(.prMuted)
                        .padding(.top, 18).padding(.bottom, 30)
                }
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
        }
        .onAppear {
            loadEmergencyContacts()
            profileManager.listenForFollowRequests()
            profileManager.fetchMyProfile()
            profileManager.listenForFollowedUsers()
            profileManager.listenForFollowerCount()
            locationVisibility.load()
        }
        .onDisappear {
            profileManager.stopListeningForFollowRequests()
            profileManager.stopListeningForMyProfile()
        }
        .onChange(of: profileManager.avatarURL) { _, value in if !value.isEmpty { avatarURL = value } }
        .onChange(of: profileManager.bannerURL) { _, value in if !value.isEmpty { bannerURL = value } }
        .onChange(of: selectedAvatarItem) { _, item in uploadPickedImage(item, type: "avatar") }
        .onChange(of: selectedBannerItem) { _, item in uploadPickedImage(item, type: "banner") }
        .sheet(isPresented: $showAddContact) {
            AddContactSheet(existing: editingContact, followedUsers: profileManager.followedUsers, onSave: { contact in
                if let idx = emergencyContacts.firstIndex(where: { $0.id == contact.id }) { emergencyContacts[idx] = contact }
                else { emergencyContacts.append(contact) }
                saveEmergencyContacts(); showAddContact = false
            }, onCancel: { showAddContact = false })
        }
        .alert("Delete Account?", isPresented: $showDeleteAccountAlert) {
            Button("Delete Account", role: .destructive) { deleteAccount() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This permanently deletes your PackRide account and profile. This can't be undone.") }
        .sheet(isPresented: $showFeedbackSheet) {
            FeedbackSheet(senderName: riderName, onSent: {
                showFeedbackSheet = false; feedbackSentConfirmation = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { feedbackSentConfirmation = false }
            }, onCancel: { showFeedbackSheet = false })
        }
        .sheet(isPresented: $showLocationAudience) {
            FollowerLocationAudienceSheet(settings: locationVisibility, profileManager: profileManager)
        }
        .sheet(isPresented: $showNotifications) { NotificationCenterView(profileManager: profileManager) }
        .fullScreenCover(isPresented: $showNeedHelp) { NeedHelpView() }
        .navigationDestination(isPresented: $showSafetyHub) { SafetyHubView() }
    }

    // Kept temporarily as a compile-checked reference while the recovered
    // card layout is replaced by the exact full-width Profile above.
    private var recoveredBody: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: 0) {

                    profileHero

                    privacyControls

                    VStack(alignment: .leading, spacing: 0) {
                        NavigationLink(destination: GarageView()) {
                            HStack(spacing: 14) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12).fill(Color.prCoralSoft)
                                        .frame(width: 48, height: 48)
                                    Image(systemName: "motorcycle")
                                        .font(.system(size: 21, weight: .semibold)).foregroundColor(.prCoral)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Garage").font(.system(size: 16, weight: .bold)).foregroundColor(.prInk)
                                    Text("Motorcycles, maintenance and service records")
                                        .font(.system(size: 11)).foregroundColor(.prMuted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundColor(.prMuted)
                            }
                            .padding(.horizontal, 20).padding(.vertical, 18)
                            .background(Color.prCardBg)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .overlay(Divider(), alignment: .bottom)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("DISPLAY UNITS")
                                    .font(.system(size: 10, weight: .heavy)).tracking(2).foregroundColor(.prMuted)
                                Text("Distance, speed, temperature and elevation")
                                    .font(.system(size: 11)).foregroundColor(.prMuted)
                            }
                            Spacer()
                            Image(systemName: "ruler.fill").foregroundColor(.prCoral)
                        }
                        Picker("Units", selection: $measurementSystemRaw) {
                            Text("Imperial · mi, mph, °F").tag(MeasurementSystem.imperial.rawValue)
                            Text("Metric · km, km/h, °C").tag(MeasurementSystem.metric.rawValue)
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 20)
                    .background(Color.prCardBg)
                    .frame(maxWidth: .infinity)
                    .overlay(Divider(), alignment: .bottom)

                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("My Bike").font(.system(size: 15, weight: .semibold)).foregroundColor(.prInk)
                            Spacer()
                            if isEditing {
                                Button("Save") { saveProfile() }.font(.system(size: 14, weight: .semibold)).foregroundColor(.prCoral)
                            } else {
                                Button("Edit") { startEditing() }.font(.system(size: 14, weight: .semibold)).foregroundColor(.prCoral)
                            }
                        }

                        if isEditing {
                            VStack(spacing: 12) {
                                ProfileField(icon: "person.fill", label: "Name", text: $tempName)
                                ProfileField(icon: "arrowtriangle.up.fill", label: "Bike", text: $tempBike)
                                ProfileField(icon: "location.fill", label: "City", text: $tempCity)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Experience Level").font(.system(size: 13)).foregroundColor(.prMuted)
                                    HStack(spacing: 8) {
                                        ForEach(experienceLevels, id: \.self) { level in
                                            Button(action: { selectedExperience = level }) {
                                                Text(level)
                                                    .font(.system(size: 12, weight: .medium))
                                                    .foregroundColor(selectedExperience == level ? .white : .prMuted)
                                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                                    .background(selectedExperience == level ? Color.prCoral : Color.prCardBg)
                                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.prBorder, lineWidth: selectedExperience == level ? 0 : 1))
                                                    .cornerRadius(8)
                                            }
                                        }
                                    }
                                }
                            }
                        } else {
                            VStack(spacing: 12) {
                                ProfileInfoRow(icon: "arrowtriangle.up.fill", label: "Bike", value: riderBike.isEmpty ? "Add your bike" : riderBike)
                                ProfileInfoRow(icon: "location.fill", label: "City", value: riderCity.isEmpty ? "Add your city" : riderCity)
                                ProfileInfoRow(icon: "star.fill", label: "Experience", value: riderExperience)
                            }
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 22)
                    .background(Color.prCardBg)
                    .frame(maxWidth: .infinity)
                    .overlay(Divider(), alignment: .bottom)

                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "cross.fill").foregroundColor(Color(red: 0.827, green: 0.231, blue: 0.173))
                            Text("Emergency Info").font(.system(size: 15, weight: .semibold)).foregroundColor(.prInk)
                            Spacer()
                            if isEditingEmergency {
                                Button("Save") { saveEmergencyInfo() }.font(.system(size: 14, weight: .semibold)).foregroundColor(.prCoral)
                            } else {
                                Button("Edit") { startEditingEmergency() }.font(.system(size: 14, weight: .semibold)).foregroundColor(.prCoral)
                            }
                        }

                        if isEditingEmergency {
                            VStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Blood Type").font(.system(size: 13)).foregroundColor(.prMuted)
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 8) {
                                            ForEach(bloodTypes, id: \.self) { type in
                                                Button(action: { tempBloodType = type }) {
                                                    Text(type)
                                                        .font(.system(size: 13, weight: .medium))
                                                        .foregroundColor(tempBloodType == type ? .white : .prMuted)
                                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                                        .background(tempBloodType == type ? Color(red: 0.827, green: 0.231, blue: 0.173) : Color.prCardBg)
                                                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.prBorder, lineWidth: tempBloodType == type ? 0 : 1))
                                                        .cornerRadius(10)
                                                }
                                            }
                                        }
                                    }
                                }

                                HStack(spacing: 12) {
                                    Image(systemName: "allergens").foregroundColor(.prCoral).frame(width: 20)
                                    TextField("", text: $tempAllergies, prompt: Text("Allergies (e.g. penicillin, nuts)").foregroundColor(.prMuted))
                                        .foregroundColor(.prInk).font(.system(size: 14))
                                }
                                .padding(12)
                                .background(Color.prCardBg)
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.prBorder, lineWidth: 1))
                                .cornerRadius(12)
                            }
                        } else {
                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Blood Type").font(.system(size: 11)).foregroundColor(.prMuted)
                                    Text(bloodType.isEmpty ? "Not set" : bloodType)
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundColor(bloodType.isEmpty ? .prMuted : Color(red: 0.827, green: 0.231, blue: 0.173))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 12)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Allergies").font(.system(size: 11)).foregroundColor(.prMuted)
                                    Text(allergies.isEmpty ? "None listed" : allergies)
                                        .font(.system(size: 13))
                                        .foregroundColor(allergies.isEmpty ? .prMuted : .prInk)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 12)
                            }
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Emergency Contacts").font(.system(size: 14, weight: .medium)).foregroundColor(.prMuted)

                            if emergencyContacts.isEmpty {
                                HStack(spacing: 10) {
                                    Image(systemName: "person.crop.circle.badge.plus").foregroundColor(.prCoral)
                                    Text("No emergency contacts added yet").font(.system(size: 13)).foregroundColor(.prMuted)
                                }
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                ForEach(emergencyContacts) { contact in
                                    EmergencyContactRow(
                                        contact: contact,
                                        onEdit: { editingContact = contact; showAddContact = true },
                                        onDelete: { deleteContact(contact) }
                                    )
                                }
                            }

                            if emergencyContacts.count < 3 {
                                Button(action: { editingContact = nil; showAddContact = true }) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "plus.circle.fill").foregroundColor(.prCoral)
                                        Text("Add Emergency Contact").font(.system(size: 14, weight: .medium)).foregroundColor(.prCoral)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 14)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 22)
                    .background(Color.prCardBg)
                    .frame(maxWidth: .infinity)
                    .overlay(Divider(), alignment: .bottom)

                    if !profileManager.followRequests.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Image(systemName: "person.badge.plus").foregroundColor(.prCoral)
                                Text("Follow Requests").font(.system(size: 15, weight: .semibold)).foregroundColor(.prInk)
                                Spacer()
                                Text("\(profileManager.followRequests.count)")
                                    .font(.system(size: 13, weight: .bold)).foregroundColor(.prCoral)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Color.prCoralSoft).cornerRadius(10)
                            }

                            ForEach(profileManager.followRequests) { request in
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
                                        Button(action: {
                                            profileManager.acceptFollowRequest(requesterID: request.id, requesterName: request.name, requesterInitials: request.initials)
                                        }) {
                                            Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                                                .frame(width: 34, height: 34).background(Color(red: 0.180, green: 0.620, blue: 0.357)).cornerRadius(10)
                                        }
                                        Button(action: { profileManager.declineFollowRequest(requesterID: request.id) }) {
                                            Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                                                .frame(width: 34, height: 34).background(Color.prMuted).cornerRadius(10)
                                        }
                                    }
                                }
                                .padding(12).background(Color.prFieldBg).cornerRadius(14)
                            }
                        }
                        .padding(.horizontal, 20).padding(.vertical, 22).background(Color.prCardBg)
                        .frame(maxWidth: .infinity).overlay(Divider(), alignment: .bottom)
                    }

                    // Dark Mode toggle — Aug 2026. A manual switch rather than following
                    // the phone's system setting, so a rider's choice here doesn't
                    // silently flip on/off depending on time of day or their phone's
                    // own Dark Mode schedule.
                    HStack(spacing: 12) {
                        Image(systemName: darkModeOn ? "moon.fill" : "sun.max.fill")
                            .font(.system(size: 16)).foregroundColor(.prCoral).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Dark Mode").font(.system(size: 14, weight: .semibold)).foregroundColor(.prInk)
                            Text("Applies right away, no restart needed").font(.system(size: 11)).foregroundColor(.prMuted)
                        }
                        Spacer()
                        Toggle("", isOn: $darkModeOn).labelsHidden().tint(.prCoral)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 18)
                    .background(Color.prCardBg)
                    .frame(maxWidth: .infinity)
                    .overlay(Divider(), alignment: .bottom)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Device ID").font(.system(size: 13, weight: .semibold)).foregroundColor(.prInk)
                        Text("Only needed if you're manually fixing a community's creator in the Firebase console.")
                            .font(.system(size: 11)).foregroundColor(.prMuted)

                        HStack(spacing: 10) {
                            Text(deviceID)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.prMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()

                            Button(action: {
                                UIPasteboard.general.string = deviceID
                                showCopiedDeviceID = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showCopiedDeviceID = false }
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: showCopiedDeviceID ? "checkmark" : "doc.on.doc")
                                    Text(showCopiedDeviceID ? "Copied!" : "Copy")
                                }
                                .font(.system(size: 12, weight: .semibold)).foregroundColor(.prCoral)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color.prCoralSoft).cornerRadius(8)
                            }
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 18)
                    .background(Color.prCardBg)
                    .frame(maxWidth: .infinity)
                    .overlay(Divider(), alignment: .bottom)

                    Button(action: { showFeedbackSheet = true }) {
                        HStack(spacing: 12) {
                            Image(systemName: "bubble.left.and.exclamationmark.bubble.right.fill")
                                .foregroundColor(.prCoral).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Send Feedback").font(.system(size: 14, weight: .semibold)).foregroundColor(.prInk)
                                Text("Report a bug or request a feature").font(.system(size: 11)).foregroundColor(.prMuted)
                            }
                            Spacer()
                            if feedbackSentConfirmation {
                                Text("Sent!").font(.system(size: 12, weight: .semibold)).foregroundColor(Color(red: 0.180, green: 0.620, blue: 0.357))
                            } else {
                                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundColor(.prMuted)
                            }
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 18)
                    .background(Color.prCardBg)
                    .frame(maxWidth: .infinity)
                    .overlay(Divider(), alignment: .bottom)

                    Button(action: { auth.signOut() }) {
                        HStack(spacing: 10) {
                            Image(systemName: "rectangle.portrait.and.arrow.right").foregroundColor(Color(red: 0.827, green: 0.231, blue: 0.173))
                            Text("Sign Out").font(.system(size: 14, weight: .semibold)).foregroundColor(Color(red: 0.827, green: 0.231, blue: 0.173))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Color(red: 0.988, green: 0.922, blue: 0.906))
                        .cornerRadius(14)
                    }
                    .padding(.horizontal, 16)

                    Button(action: { showDeleteAccountAlert = true }) {
                        Group {
                            if isDeletingAccount {
                                ProgressView().tint(.prMuted)
                            } else {
                                Text("Delete Account").font(.system(size: 13)).foregroundColor(.prMuted)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .disabled(isDeletingAccount)
                    .padding(.horizontal, 16)

                    if let deleteAccountError {
                        Text(deleteAccountError)
                            .font(.system(size: 12)).foregroundColor(Color(red: 0.827, green: 0.231, blue: 0.173))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                    }

                    // Profile is a before/after-the-ride screen, never seen
                    // mid-ride — see AdManager.swift for why ad placement is
                    // confined here.
                    AdBannerFooter()

                    Text(appVersionFooter)
                        .font(.system(size: 12)).foregroundColor(.prMuted).padding(.bottom, 30)
                }
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
        }
        .onAppear {
            loadEmergencyContacts()
            profileManager.listenForFollowRequests()
            profileManager.fetchMyProfile()
            profileManager.listenForFollowedUsers()
            profileManager.listenForFollowerCount()
            locationVisibility.load()
        }
        .onDisappear {
            profileManager.stopListeningForFollowRequests()
            profileManager.stopListeningForMyProfile()
        }
        .onChange(of: profileManager.avatarURL) { _, value in if !value.isEmpty { avatarURL = value } }
        .onChange(of: profileManager.bannerURL) { _, value in if !value.isEmpty { bannerURL = value } }
        .onChange(of: selectedAvatarItem) { _, item in uploadPickedImage(item, type: "avatar") }
        .onChange(of: selectedBannerItem) { _, item in uploadPickedImage(item, type: "banner") }
        .sheet(isPresented: $showAddContact) {
            AddContactSheet(
                existing: editingContact,
                onSave: { contact in
                    if let idx = emergencyContacts.firstIndex(where: { $0.id == contact.id }) {
                        emergencyContacts[idx] = contact
                    } else {
                        emergencyContacts.append(contact)
                    }
                    saveEmergencyContacts()
                    showAddContact = false
                },
                onCancel: { showAddContact = false }
            )
        }
        .alert("Delete Account?", isPresented: $showDeleteAccountAlert) {
            Button("Delete Account", role: .destructive) { deleteAccount() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your PackRide account and profile. This can't be undone.")
        }
        .sheet(isPresented: $showFeedbackSheet) {
            FeedbackSheet(
                senderName: riderName,
                onSent: {
                    showFeedbackSheet = false
                    feedbackSentConfirmation = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { feedbackSentConfirmation = false }
                },
                onCancel: { showFeedbackSheet = false }
            )
        }
        .sheet(isPresented: $showLocationAudience) {
            FollowerLocationAudienceSheet(settings: locationVisibility, profileManager: profileManager)
        }
        .sheet(isPresented: $showNotifications) {
            NotificationCenterView(profileManager: profileManager)
        }
        .fullScreenCover(isPresented: $showNeedHelp) {
            NeedHelpView()
        }
    }

    private var webSectionGap: some View {
        Color.prBg.frame(height: 10)
    }

    private var webPrivacySection: some View {
        VStack(spacing: 0) {
            webSectionTitle("LIVE LOCATION PRIVACY")
            HStack {
                Text("Share while riding with followers").font(.system(size: 16, weight: .medium)).foregroundColor(.prInk)
                Spacer(); Toggle("", isOn: $locationVisibility.shareWithFollowers).labelsHidden().tint(.prCoral)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)

            if locationVisibility.shareWithFollowers {
                Divider().padding(.leading, 58)
                Button { showLocationAudience = true } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.badge.checkmark").font(.system(size: 23)).foregroundColor(.prCoral).frame(width: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Choose followers").font(.system(size: 16, weight: .semibold)).foregroundColor(.prInk)
                            Text(locationVisibility.usesSelectedFollowers ? "\(locationVisibility.selectedFollowerIDs.count) selected" : "All followers")
                                .font(.system(size: 13)).foregroundColor(.prMuted)
                        }
                        Spacer(); Image(systemName: "chevron.right").font(.system(size: 15, weight: .bold)).foregroundColor(.prMuted)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 14)
                }
            }

            Divider()
            HStack {
                Text("Share while riding with communities").font(.system(size: 16, weight: .medium)).foregroundColor(.prInk)
                Spacer(); Toggle("", isOn: $locationVisibility.shareWithCommunities).labelsHidden().tint(.prCoral)
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 10)
            Text("Group Ride members can always see one another during that active ride. Need Help is shared only with the people you choose.")
                .font(.system(size: 13)).foregroundColor(.prMuted).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20).padding(.bottom, 18)
        }
        .background(Color.prCardBg)
    }

    private var webRadiusSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("NEARBY RIDER RADIUS").font(.system(size: 11, weight: .heavy)).tracking(2.6).foregroundColor(.prMuted)
                Spacer()
                Text(MeasurementUnits.distanceMiles(locationVisibility.nearbyRadiusMiles, decimals: 0))
                    .font(.system(size: 15, weight: .bold)).foregroundColor(.prCoral)
            }
            Slider(value: $locationVisibility.nearbyRadiusMiles, in: 1...50, step: 1).tint(.prCoral)
            Text("Show and alert for riders within this distance while you are on a solo ride.")
                .font(.system(size: 13)).foregroundColor(.prMuted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20).padding(.vertical, 20)
        .background(Color.prCardBg)
    }

    private var webRiderProfileSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("RIDER PROFILE").font(.system(size: 11, weight: .heavy)).tracking(2.6).foregroundColor(.prMuted)
                Spacer()
                Button(isEditing ? "Save" : "Edit") { isEditing ? saveProfile() : startEditing() }
                    .font(.system(size: 15, weight: .medium)).foregroundColor(.prCoral)
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 10)

            if isEditing {
                VStack(spacing: 12) {
                    ProfileField(icon: "person.fill", label: "Name", text: $tempName)
                    ProfileField(icon: "arrowtriangle.up.fill", label: "Bike", text: $tempBike)
                    ProfileField(icon: "location.fill", label: "City", text: $tempCity)
                    Picker("Experience", selection: $selectedExperience) {
                        ForEach(experienceLevels, id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.segmented)
                }
                .padding(.horizontal, 20).padding(.bottom, 18)
            } else {
                webProfileRow(icon: "person.fill", label: "Name", value: riderName.isEmpty ? "Add your name" : riderName)
                Divider().padding(.leading, 58)
                webProfileRow(icon: "arrowtriangle.up.fill", label: "Bike", value: riderBike.isEmpty ? "Add your bike" : riderBike)
                Divider().padding(.leading, 58)
                webProfileRow(icon: "location.fill", label: "City", value: riderCity.isEmpty ? "Add your city" : riderCity)
                Divider().padding(.leading, 58)
                webProfileRow(icon: "star.fill", label: "Experience", value: riderExperience)
            }
        }
        .background(Color.prCardBg)
    }

    private func webProfileRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 19, weight: .semibold)).foregroundColor(.prCoral).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 13)).foregroundColor(.prMuted)
                Text(value).font(.system(size: 17, weight: .semibold)).foregroundColor(value.hasPrefix("Add your") ? .prMuted : .prInk)
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var webGarageRow: some View {
        NavigationLink(destination: GarageView()) {
            HStack(spacing: 14) {
                Image(systemName: "motorcycle").font(.system(size: 23, weight: .semibold)).foregroundColor(.prCoral).frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Garage").font(.system(size: 17, weight: .semibold)).foregroundColor(.prInk)
                    Text("Track mileage & maintenance per bike").font(.system(size: 13)).foregroundColor(.prMuted)
                }
                Spacer(); Image(systemName: "chevron.right").font(.system(size: 15, weight: .bold)).foregroundColor(.prMuted)
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
        }
        .background(Color.prCardBg).overlay(Divider(), alignment: .top)
    }

    private var webEmergencySection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 10).fill(Color.prCoralSoft).frame(width: 42, height: 42)
                    .overlay(Image(systemName: "cross.fill").font(.system(size: 18)).foregroundColor(.prCoral))
                VStack(alignment: .leading, spacing: 2) {
                    Text("SAFETY").font(.system(size: 10, weight: .heavy)).tracking(2).foregroundColor(.prCoral)
                    Text("Emergency Info").font(.system(size: 20, weight: .bold)).foregroundColor(.prInk)
                }
                Spacer()
                Button(isEditingEmergency ? "Save" : "Edit") { isEditingEmergency ? saveEmergencyInfo() : startEditingEmergency() }
                    .font(.system(size: 15, weight: .medium)).foregroundColor(.prCoral)
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            Divider()

            if isEditingEmergency {
                VStack(spacing: 12) {
                    Picker("Blood Type", selection: $tempBloodType) { ForEach(bloodTypes, id: \.self) { Text($0).tag($0) } }
                    TextField("Allergies", text: $tempAllergies).textFieldStyle(.roundedBorder)
                }.padding(20)
            } else {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("BLOOD TYPE").font(.system(size: 10, weight: .heavy)).tracking(2).foregroundColor(.prMuted)
                        Text(bloodType.isEmpty ? "NOT SET" : bloodType.uppercased()).font(.system(size: 22, weight: .bold)).foregroundColor(.prMuted)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Divider().frame(height: 55)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("ALLERGIES").font(.system(size: 10, weight: .heavy)).tracking(2).foregroundColor(.prMuted)
                        Text(allergies.isEmpty ? "NONE LISTED" : allergies.uppercased()).font(.system(size: 16, weight: .bold)).foregroundColor(.prMuted)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 20)
                }.padding(.horizontal, 20).padding(.vertical, 20)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("EMERGENCY CONTACTS").font(.system(size: 10, weight: .heavy)).tracking(2).foregroundColor(.prMuted)
                    Text("Used for crash alerts and emergency outreach").font(.system(size: 12)).foregroundColor(.prMuted)
                }
                Spacer(); Text("\(emergencyContacts.count)/3").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundColor(.prMuted)
            }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 10)

            if emergencyContacts.isEmpty {
                HStack(spacing: 14) {
                    Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 23)).foregroundColor(.prCoral).frame(width: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Add your first emergency contact").font(.system(size: 16, weight: .semibold)).foregroundColor(.prInk)
                        Text("Someone PackRide can reach if something goes wrong").font(.system(size: 13)).foregroundColor(.prMuted)
                    }
                    Spacer(); Image(systemName: "chevron.right").foregroundColor(.prMuted)
                }.padding(.horizontal, 20).padding(.vertical, 16)
            } else {
                ForEach(emergencyContacts) { contact in
                    EmergencyContactRow(contact: contact, onEdit: { editingContact = contact; showAddContact = true }, onDelete: { deleteContact(contact) })
                        .padding(.horizontal, 8)
                }
            }
            if emergencyContacts.count < 3 {
                Button { editingContact = nil; showAddContact = true } label: {
                    HStack { Image(systemName: "plus"); Text("Add Emergency Contact"); Spacer(); Image(systemName: "arrow.up.right") }
                        .font(.system(size: 14, weight: .semibold)).foregroundColor(.prCoral)
                        .padding(.horizontal, 20).padding(.vertical, 18)
                }
            }
        }.background(Color.prCardBg)
    }

    private var webSystemSection: some View {
        VStack(spacing: 0) {
            webSectionTitle("SYSTEM")
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 10).fill(Color.prFieldBg).frame(width: 42, height: 42)
                    .overlay(Image(systemName: darkModeOn ? "moon.fill" : "sun.max.fill").foregroundColor(.prTeal))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dark Mode").font(.system(size: 17, weight: .semibold)).foregroundColor(.prInk)
                    Text("Use the lighter PackRide palette").font(.system(size: 13)).foregroundColor(.prMuted)
                }
                Spacer(); Toggle("", isOn: $darkModeOn).labelsHidden().tint(.prCoral)
            }.padding(.horizontal, 20).padding(.vertical, 14)
            Divider().padding(.leading, 58)
            HStack(spacing: 14) {
                Image(systemName: "ruler.fill").foregroundColor(.prCoral).frame(width: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Display Units").font(.system(size: 17, weight: .semibold)).foregroundColor(.prInk)
                    Text(MeasurementSystem(rawValue: measurementSystemRaw) == .metric ? "Metric · km, km/h, °C" : "Imperial · mi, mph, °F")
                        .font(.system(size: 13)).foregroundColor(.prMuted)
                }
                Spacer()
                Picker("Units", selection: $measurementSystemRaw) {
                    Text("US").tag(MeasurementSystem.imperial.rawValue); Text("Metric").tag(MeasurementSystem.metric.rawValue)
                }.pickerStyle(.menu).tint(.prCoral)
            }.padding(.horizontal, 20).padding(.vertical, 14)
            Divider().padding(.leading, 58)
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 10).fill(Color.prFieldBg).frame(width: 42, height: 42)
                    .overlay(Image(systemName: "iphone").foregroundColor(.prInk))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Device ID").font(.system(size: 17, weight: .semibold)).foregroundColor(.prInk)
                    Text("For advanced support and Firebase maintenance").font(.system(size: 13)).foregroundColor(.prMuted)
                }
                Spacer()
                Button { UIPasteboard.general.string = deviceID; showCopiedDeviceID = true } label: {
                    Label(showCopiedDeviceID ? "Copied" : "Copy", systemImage: "doc.on.doc").font(.system(size: 13, weight: .semibold)).foregroundColor(.prCoral)
                }
            }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8)
            Text(deviceID).font(.system(size: 11, design: .monospaced)).foregroundColor(.prInk)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Color.prFieldBg)
                .padding(.horizontal, 20).padding(.bottom, 18)
            Divider().padding(.leading, 58)
            NavigationLink(destination: PrivacyDataView()) {
                HStack(spacing: 14) {
                    Image(systemName: "hand.raised.fill").foregroundColor(.prCoral).frame(width: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Privacy & Data").font(.system(size: 17, weight: .semibold)).foregroundColor(.prInk)
                        Text("What PackRide collects and your controls").font(.system(size: 13)).foregroundColor(.prMuted)
                    }
                    Spacer(); Image(systemName: "chevron.right").font(.system(size: 14, weight: .bold)).foregroundColor(.prMuted)
                }.padding(.horizontal, 20).padding(.vertical, 16)
            }
        }.background(Color.prCardBg)
    }

    private var webAccountActions: some View {
        VStack(spacing: 12) {
            Button { showFeedbackSheet = true } label: {
                HStack { Image(systemName: "bubble.left.and.exclamationmark.bubble.right.fill"); Text("Send Feedback"); Spacer(); Image(systemName: "chevron.right") }
                    .font(.system(size: 15, weight: .semibold)).foregroundColor(.prCoral).padding(.vertical, 8)
            }
            Button { auth.signOut() } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 17, weight: .semibold)).foregroundColor(Color(red: 0.827, green: 0.231, blue: 0.173))
                    .frame(maxWidth: .infinity).padding(.vertical, 17).background(Color(red: 0.988, green: 0.922, blue: 0.906)).clipShape(RoundedRectangle(cornerRadius: 14))
            }
            Button { showDeleteAccountAlert = true } label: { Text("Delete Account").font(.system(size: 14)).foregroundColor(.prMuted) }
        }.padding(.horizontal, 20).padding(.vertical, 20).background(Color.prCardBg)
    }

    private func webSectionTitle(_ title: String) -> some View {
        HStack { Text(title).font(.system(size: 11, weight: .heavy)).tracking(2.6).foregroundColor(.prMuted); Spacer() }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 8)
    }

    private var profileHero: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image = localBannerImage {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if let url = URL(string: profileManager.bannerURL.isEmpty ? bannerURL : profileManager.bannerURL),
                          !(profileManager.bannerURL.isEmpty && bannerURL.isEmpty) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                        else { profileHeroFallback }
                    }
                } else { profileHeroFallback }
            }
            .frame(height: 327)
            .frame(maxWidth: .infinity)
            .clipped()

            LinearGradient(colors: [.black.opacity(0.25), .clear, .black.opacity(0.92)], startPoint: .top, endPoint: .bottom)

            HStack(alignment: .center) {
                Text("PACKRIDE")
                    .font(.system(size: 14, weight: .black)).tracking(4)
                    .foregroundColor(.white)
                Spacer()
                profileHeroButton(system: "bell.fill", badge: profileManager.followRequests.count) {
                    showNotifications = true
                }
                profileHeroButton(system: "exclamationmark.triangle.fill") {
                    showSafetyHub = true
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 55)
            .frame(maxHeight: .infinity, alignment: .top)

            PhotosPicker(selection: $selectedBannerItem, matching: .images) {
                Label(isUploadingBanner ? "Uploading" : "Edit Cover", systemImage: "camera.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(.black.opacity(0.55)).clipShape(Capsule())
            }
            .padding(.top, 108)
            .padding(.trailing, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            HStack(alignment: .bottom, spacing: 14) {
                    PhotosPicker(selection: $selectedAvatarItem, matching: .images) {
                        ZStack(alignment: .bottomTrailing) {
                            Group {
                                if let image = localAvatarImage { Image(uiImage: image).resizable().scaledToFill() }
                                else if let url = URL(string: profileManager.avatarURL.isEmpty ? avatarURL : profileManager.avatarURL),
                                        !(profileManager.avatarURL.isEmpty && avatarURL.isEmpty) {
                                    AsyncImage(url: url) { phase in
                                        if let image = phase.image { image.resizable().scaledToFill() }
                                        else { avatarFallback }
                                    }
                                } else { avatarFallback }
                            }
                            .frame(width: 70, height: 70).clipShape(Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 3))
                            Circle().fill(Color.prCoral).frame(width: 24, height: 24)
                                .overlay(Image(systemName: isUploadingAvatar ? "arrow.triangle.2.circlepath" : "camera.fill").font(.system(size: 11)).foregroundColor(.white))
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(riderExperience.uppercased())
                            .font(.system(size: 10, weight: .black)).tracking(1)
                            .foregroundColor(.white)
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .background(Color.prCoral).clipShape(Capsule())

                        HStack(spacing: 10) {
                            Text("\(historyManager.totalRides) Rides")
                            Text("·")
                            Text(MeasurementUnits.distanceMiles(historyManager.totalMiles, decimals: 0))
                            Text("·")
                        }
                        .font(.system(size: 13, weight: .medium)).foregroundColor(.white.opacity(0.86))

                        HStack(spacing: 12) {
                            Text("\(profileManager.followerCount) Followers")
                            Text("·").foregroundColor(.white.opacity(0.55))
                            Text("\(profileManager.followingCount) Following")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .font(.system(size: 13, weight: .medium)).foregroundColor(.white.opacity(0.9))
                    }
                    Spacer()
            }
            .padding(.horizontal, 20).padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(height: 327)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private func profileHeroButton(system: String, badge: Int = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Circle().fill(.black.opacity(0.55)).frame(width: 44, height: 44)
                    .overlay(Image(systemName: system).font(.system(size: 15, weight: .bold)).foregroundColor(.white))
                if badge > 0 {
                    Text("\(min(badge, 99))")
                        .font(.system(size: 8, weight: .black)).foregroundColor(.white)
                        .frame(minWidth: 16, minHeight: 16).background(Color.prCoral).clipShape(Circle())
                }
            }
        }
    }

    private var appVersionFooter: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "PackRide v\(version) (\(build)) — Built for Riders"
    }

    private var profileHeroFallback: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.08, green: 0.09, blue: 0.11), Color(red: 0.18, green: 0.19, blue: 0.22)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "motorcycle").font(.system(size: 72, weight: .thin)).foregroundColor(.white.opacity(0.16))
        }
    }

    private var avatarFallback: some View {
        ZStack {
            Circle().fill(Color.prCoral)
            Text(riderName.isEmpty ? "R" : riderName.rideInitials).font(.system(size: 27, weight: .bold)).foregroundColor(.white)
        }
    }

    private var privacyControls: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("PRIVACY & DISCOVERY").font(.system(size: 10, weight: .heavy)).tracking(2).foregroundColor(.prCoral)
                    Text("You control who sees you").font(.system(size: 16, weight: .bold)).foregroundColor(.prInk)
                }
                Spacer()
                Image(systemName: "hand.raised.fill").foregroundColor(.prCoral)
            }.padding(16)

            Divider()
            Toggle("Share while riding with followers", isOn: $locationVisibility.shareWithFollowers)
                .font(.system(size: 14, weight: .medium)).padding(.horizontal, 16).padding(.vertical, 12)
            if locationVisibility.shareWithFollowers {
                Divider().padding(.leading, 16)
                Button(action: { showLocationAudience = true }) {
                    HStack {
                        Image(systemName: "person.crop.circle.badge.checkmark").foregroundColor(.prCoral)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Choose followers").font(.system(size: 14, weight: .medium)).foregroundColor(.prInk)
                            Text(locationVisibility.usesSelectedFollowers ? "\(locationVisibility.selectedFollowerIDs.count) selected" : "All followers")
                                .font(.system(size: 11)).foregroundColor(.prMuted)
                        }
                        Spacer(); Image(systemName: "chevron.right").foregroundColor(.prMuted)
                    }.padding(.horizontal, 16).padding(.vertical, 12)
                }
            }
            Divider().padding(.leading, 16)
            Toggle("Share while riding with communities", isOn: $locationVisibility.shareWithCommunities)
                .font(.system(size: 14, weight: .medium)).padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("NEARBY RIDER RADIUS").font(.system(size: 10, weight: .heavy)).tracking(2).foregroundColor(.prMuted)
                    Spacer()
                    Text(MeasurementUnits.distanceMiles(locationVisibility.nearbyRadiusMiles, decimals: 0))
                        .font(.system(size: 13, weight: .bold)).foregroundColor(.prCoral)
                }
                Slider(value: $locationVisibility.nearbyRadiusMiles, in: 1...50, step: 1).tint(.prCoral)
                Text("Show and alert for riders within this distance while you are on a solo ride.")
                    .font(.system(size: 11)).foregroundColor(.prMuted)
            }.padding(16)
        }
        .background(Color.prCardBg)
        .frame(maxWidth: .infinity)
        .overlay(Divider(), alignment: .bottom)
    }

    private func uploadPickedImage(_ item: PhotosPickerItem?, type: String) {
        guard let item else { return }
        if type == "avatar" { isUploadingAvatar = true } else { isUploadingBanner = true }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                await MainActor.run { isUploadingAvatar = false; isUploadingBanner = false }
                return
            }
            await MainActor.run {
                if type == "avatar" { localAvatarImage = image } else { localBannerImage = image }
            }
            firebaseManager.uploadProfileImage(image, type: type) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let url):
                        if type == "avatar" { avatarURL = url; profileManager.avatarURL = url; isUploadingAvatar = false }
                        else { bannerURL = url; profileManager.bannerURL = url; isUploadingBanner = false }
                        profileManager.publishProfile(name: riderName, bike: riderBike, city: riderCity, experience: riderExperience, avatarURL: avatarURL, bannerURL: bannerURL)
                    case .failure:
                        isUploadingAvatar = false; isUploadingBanner = false
                    }
                }
            }
        }
    }

    private func deleteAccount() {
        isDeletingAccount = true
        deleteAccountError = nil
        auth.deleteAccount { failure in
            isDeletingAccount = false
            if let failure {
                deleteAccountError = failure
            }
            // On success, AuthManager's own state-change listener flips
            // isLoggedIn to false and PackRideApp swaps back to the login
            // screen automatically — nothing else to do here.
        }
    }

    func startEditing() {
        tempName = riderName; tempBike = riderBike
        tempCity = riderCity; selectedExperience = riderExperience
        isEditing = true
    }
    func saveProfile() {
        riderName = tempName; riderBike = tempBike
        riderCity = tempCity; riderExperience = selectedExperience
        isEditing = false

        // Push to Firebase — this used to only update the local @AppStorage
        // values, so nothing under your profile in Firebase ever changed,
        // which is why a rename never showed up for anyone else (Friends
        // list, Feed, etc.).
        profileManager.publishProfile(name: riderName, bike: riderBike, city: riderCity, experience: riderExperience)

        // Feed posts snapshot the author's name/initials at post time rather
        // than looking it up live, so existing posts need to be patched too
        // or they'd keep showing the old name forever. Runs on every Save
        // (not just when the name text actually changed) — it's a cheap,
        // idempotent no-op if nothing's different, and this way tapping Save
        // is always a reliable way to force a re-sync if something's out of
        // date, rather than depending on exact change-detection.
        if !riderName.isEmpty {
            feedManager.renameMyPosts(to: riderName, newInitials: riderName.rideInitials)
        }
    }

    func startEditingEmergency() {
        tempBloodType = bloodType; tempAllergies = allergies
        isEditingEmergency = true
    }
    func saveEmergencyInfo() {
        bloodType = tempBloodType; allergies = tempAllergies
        isEditingEmergency = false
    }
    func loadEmergencyContacts() {
        if let data = UserDefaults.standard.data(forKey: "emergencyContacts"),
           let decoded = try? JSONDecoder().decode([EmergencyContact].self, from: data) {
            emergencyContacts = decoded
        }
    }
    func saveEmergencyContacts() {
        if let encoded = try? JSONEncoder().encode(emergencyContacts) {
            UserDefaults.standard.set(encoded, forKey: "emergencyContacts")
        }
    }
    func deleteContact(_ contact: EmergencyContact) {
        emergencyContacts.removeAll { $0.id == contact.id }
        saveEmergencyContacts()
    }
}

private struct FollowerLocationAudienceSheet: View {
    @ObservedObject var settings: LocationVisibilitySettings
    @ObservedObject var profileManager: UserProfileManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Live-location audience") {
                    audienceRow(title: "All followers", subtitle: "Every follower can see you while you ride", selected: !settings.usesSelectedFollowers) {
                        settings.shareWithAllFollowers()
                    }
                    audienceRow(title: "Only selected followers", subtitle: "Choose exactly who can see your location", selected: settings.usesSelectedFollowers) {
                        settings.usesSelectedFollowers = true
                    }
                }
                if settings.usesSelectedFollowers {
                    Section("Selected followers") {
                        if profileManager.followers.isEmpty {
                            Text("You do not have followers yet.").foregroundColor(.prMuted)
                        } else {
                            ForEach(profileManager.followers) { follower in
                                Button { settings.toggleFollower(follower.id) } label: {
                                    HStack(spacing: 12) {
                                        Circle().fill(Color.prCoralSoft).frame(width: 38, height: 38)
                                            .overlay(Text(follower.initials).font(.system(size: 12, weight: .bold)).foregroundColor(.prCoral))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(follower.name).foregroundColor(.prInk)
                                            Text(follower.city.isEmpty ? "Follower" : follower.city).font(.caption).foregroundColor(.prMuted)
                                        }
                                        Spacer()
                                        Image(systemName: settings.selectedFollowerIDs.contains(follower.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(settings.selectedFollowerIDs.contains(follower.id) ? .prCoral : .prMuted)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden).background(Color.prBg)
            .navigationTitle("Share with").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { profileManager.listenForFollowerCount() }
        }
    }

    private func audienceRow(title: String, subtitle: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).foregroundColor(.prInk)
                    Text(subtitle).font(.caption).foregroundColor(.prMuted)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundColor(selected ? .prCoral : .prMuted)
            }
        }
    }
}

// MARK: - Feedback Sheet
// Writes to the shared `feedback/{feedbackID}` RTDB path (append-only, no
// client read access — see database.rules.json). A Cloud Function
// (sendFeedbackEmail in packride-functions/functions/index.js) watches that
// path and emails the text straight to Developer; nothing else in the app
// reads this data back.
struct FeedbackSheet: View {
    let senderName: String
    let onSent: () -> Void
    let onCancel: () -> Void

    @State private var message = ""
    @State private var isSending = false
    @State private var errorMessage: String? = nil

    var body: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()
            VStack(spacing: 20) {
                RoundedRectangle(cornerRadius: 3).fill(Color.prBorder)
                    .frame(width: 40, height: 5).padding(.top, 12)

                VStack(spacing: 6) {
                    Text("Send Feedback").font(.system(size: 19, weight: .bold)).foregroundColor(.prInk)
                    Text("A bug you hit, or a feature you'd like — this goes straight to Developer.")
                        .font(.system(size: 13)).foregroundColor(.prMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }

                ZStack(alignment: .topLeading) {
                    if message.isEmpty {
                        Text("Tell us what's going on…")
                            .font(.system(size: 14)).foregroundColor(.prMuted)
                            .padding(.horizontal, 16).padding(.vertical, 14)
                    }
                    TextEditor(text: $message)
                        .font(.system(size: 14))
                        .foregroundColor(.prInk)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(height: 160)
                }
                .background(Color.prCardBg)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, lineWidth: 1))
                .cornerRadius(14)
                .padding(.horizontal, 24)

                if let errorMessage {
                    Text(errorMessage).font(.system(size: 12)).foregroundColor(Color(red: 0.827, green: 0.231, blue: 0.173))
                        .padding(.horizontal, 24)
                }

                Spacer()

                VStack(spacing: 12) {
                    Button(action: send) {
                        Group {
                            if isSending {
                                ProgressView().tint(.white)
                            } else {
                                Text("Send").font(.system(size: 16, weight: .bold)).foregroundColor(.white)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.prCoral.opacity(0.4) : Color.prCoral)
                        .cornerRadius(14)
                    }
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)

                    Button(action: onCancel) {
                        Text("Cancel").font(.system(size: 14)).foregroundColor(.prMuted)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    private func send() {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSending = true
        errorMessage = nil
        let ref = Database.database().reference().child("feedback").childByAutoId()
        let payload: [String: Any] = [
            "senderUID": Auth.auth().currentUser?.uid ?? "unknown",
            "senderName": senderName.isEmpty ? "A PackRide rider" : senderName,
            "senderEmail": Auth.auth().currentUser?.email ?? "",
            "platform": "ios",
            "message": trimmed,
            "createdAt": ServerValue.timestamp()
        ]
        ref.setValue(payload) { error, _ in
            isSending = false
            if let error {
                errorMessage = "Couldn't send that — \(error.localizedDescription)"
            } else {
                message = ""
                onSent()
            }
        }
    }
}

// MARK: - Emergency Contact Row
struct EmergencyContactRow: View {
    let contact: EmergencyContact
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color(red: 0.988, green: 0.922, blue: 0.906)).frame(width: 44, height: 44)
                Image(systemName: "person.fill").foregroundColor(Color(red: 0.827, green: 0.231, blue: 0.173))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(contact.name).font(.system(size: 14, weight: .semibold)).foregroundColor(.prInk)
                Text("\(contact.relationship) · \(contact.phone)").font(.system(size: 12)).foregroundColor(.prMuted)
            }
            Spacer()
            if let url = URL(string: "tel://\(contact.phone.filter { $0.isNumber })") {
                Link(destination: url) {
                    Image(systemName: "phone.fill").foregroundColor(Color(red: 0.180, green: 0.620, blue: 0.357))
                        .padding(8).background(Color(red: 0.891, green: 0.965, blue: 0.918)).cornerRadius(8)
                }
            }
            Button(action: onEdit) {
                Image(systemName: "pencil").foregroundColor(.prCoral)
                    .padding(8).background(Color.prCoralSoft).cornerRadius(8)
            }
            Button(action: onDelete) {
                Image(systemName: "trash").foregroundColor(Color(red: 0.827, green: 0.231, blue: 0.173))
                    .padding(8).background(Color(red: 0.988, green: 0.922, blue: 0.906)).cornerRadius(8)
            }
        }
        .padding(12)
        .background(Color.prFieldBg)
        .cornerRadius(12)
    }
}

// MARK: - Add Contact Sheet
struct AddContactSheet: View {
    let existing: EmergencyContact?
    var followedUsers: [RiderProfile] = []
    let onSave: (EmergencyContact) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var phone = ""
    @State private var relationship = ""
    @State private var linkedUserID: String? = nil
    @State private var showContactPicker = false

    let relationships = ["Spouse", "Partner", "Parent", "Sibling", "Child", "Friend", "Other"]

    var body: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 3).fill(Color.prBorder)
                    .frame(width: 40, height: 5).padding(.top, 12).padding(.bottom, 20)

                Text(existing == nil ? "Add Emergency Contact" : "Edit Contact")
                    .font(.system(size: 19, weight: .bold)).foregroundColor(.prInk).padding(.bottom, 16)

                if existing == nil {
                    Button(action: { showContactPicker = true }) {
                        HStack(spacing: 10) {
                            Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 18))
                            Text("Pick from Contacts").font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.prTeal)
                        .cornerRadius(14)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)

                    HStack {
                        Rectangle().fill(Color.prBorder).frame(height: 1)
                        Text("or enter manually").font(.system(size: 11)).foregroundColor(.prMuted)
                        Rectangle().fill(Color.prBorder).frame(height: 1)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                }

                VStack(spacing: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "person.fill").foregroundColor(.prCoral).frame(width: 20)
                        TextField("", text: $name, prompt: Text("Full name").foregroundColor(.prMuted)).foregroundColor(.prInk)
                    }
                    .padding(16).background(Color.prCardBg).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, lineWidth: 1)).cornerRadius(14)

                    HStack(spacing: 12) {
                        Image(systemName: "phone.fill").foregroundColor(.prCoral).frame(width: 20)
                        TextField("", text: $phone, prompt: Text("Phone number").foregroundColor(.prMuted)).foregroundColor(.prInk).keyboardType(.phonePad)
                    }
                    .padding(16).background(Color.prCardBg).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, lineWidth: 1)).cornerRadius(14)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Relationship").font(.system(size: 13)).foregroundColor(.prMuted)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(relationships, id: \.self) { rel in
                                    Button(action: { relationship = rel }) {
                                        Text(rel)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundColor(relationship == rel ? .white : .prMuted)
                                            .padding(.horizontal, 14).padding(.vertical, 8)
                                            .background(relationship == rel ? Color.prCoral : Color.prCardBg)
                                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.prBorder, lineWidth: relationship == rel ? 0 : 1))
                                            .cornerRadius(10)
                                    }
                                }
                            }
                        }
                    }

                    if !followedUsers.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Link to a PackRide rider you follow (optional)").font(.system(size: 13)).foregroundColor(.prMuted)
                            Text("If something happens, they'll get an in-app alert too — not just a phone call.").font(.system(size: 11)).foregroundColor(.prMuted)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(followedUsers) { rider in
                                        Button(action: { linkedUserID = (linkedUserID == rider.id) ? nil : rider.id }) {
                                            VStack(spacing: 6) {
                                                ZStack {
                                                    Circle().fill(linkedUserID == rider.id ? Color.prCoral : Color.prCoralSoft).frame(width: 44, height: 44)
                                                    Text(rider.initials).font(.system(size: 13, weight: .bold)).foregroundColor(linkedUserID == rider.id ? .white : .prCoral)
                                                }
                                                Text(rider.name).font(.system(size: 11)).foregroundColor(.prMuted).lineLimit(1)
                                            }
                                            .frame(width: 64)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)

                Spacer()

                VStack(spacing: 12) {
                    Button(action: {
                        var contact = existing ?? EmergencyContact(name: "", phone: "", relationship: "")
                        contact.name = name; contact.phone = phone; contact.relationship = relationship
                        contact.linkedUserID = linkedUserID
                        onSave(contact)
                    }) {
                        Text("Save Contact")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(!name.isEmpty && !phone.isEmpty && !relationship.isEmpty ? Color.prCoral : Color.prCoral.opacity(0.4))
                            .cornerRadius(14)
                    }
                    .disabled(name.isEmpty || phone.isEmpty || relationship.isEmpty)

                    Button(action: onCancel) {
                        Text("Cancel").font(.system(size: 14)).foregroundColor(.prMuted)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 36)
            }
        }
        .onAppear {
            if let c = existing { name = c.name; phone = c.phone; relationship = c.relationship; linkedUserID = c.linkedUserID }
        }
        .sheet(isPresented: $showContactPicker) {
            ContactPickerView { selectedName, selectedPhone in
                name = selectedName
                phone = selectedPhone
            }
        }
    }
}

// MARK: - Contact Picker (UIKit wrapper)
struct ContactPickerView: UIViewControllerRepresentable {
    let onContactSelected: (String, String) -> Void

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        picker.displayedPropertyKeys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey]
        return picker
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onContactSelected: onContactSelected) }

    class Coordinator: NSObject, CNContactPickerDelegate {
        let onContactSelected: (String, String) -> Void
        init(onContactSelected: @escaping (String, String) -> Void) { self.onContactSelected = onContactSelected }
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            let fullName = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            let phoneNumber = contact.phoneNumbers.first?.value.stringValue ?? ""
            onContactSelected(fullName, phoneNumber)
        }
        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {}
    }
}

// MARK: - Profile Field
struct ProfileField: View {
    let icon: String
    let label: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundColor(.prCoral).frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.system(size: 11)).foregroundColor(.prMuted)
                TextField("", text: $text, prompt: Text("Enter \(label.lowercased())").foregroundColor(.prMuted)).font(.system(size: 14)).foregroundColor(.prInk)
            }
        }
        .padding(12)
        .background(Color.prCardBg)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.prBorder, lineWidth: 1))
        .cornerRadius(12)
    }
}

// MARK: - Profile Info Row
struct ProfileInfoRow: View {
    let icon: String
    let label: String
    let value: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundColor(.prCoral).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 11)).foregroundColor(.prMuted)
                Text(value).font(.system(size: 14)).foregroundColor(value.contains("Add") ? .prMuted : .prInk)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.prFieldBg)
        .cornerRadius(12)
    }
}

#Preview {
    NavigationView { ProfileView() }
}
