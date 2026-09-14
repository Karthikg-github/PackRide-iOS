import SwiftUI
import Combine
import FirebaseAuth
import FirebaseDatabase
import FirebaseFunctions

struct RideCommsMember: Identifiable {
    let id: String
    let name: String
    let role: String
}

struct RideCommsRequest: Identifiable {
    let id: String
    let name: String
}

@MainActor
final class RideCommsManager: ObservableObject {
    @Published var code = ""
    @Published var title = "Ride Comms"
    @Published var status = "idle"
    @Published var isHost = false
    @Published var members: [RideCommsMember] = []
    @Published var requests: [RideCommsRequest] = []
    @Published var errorMessage: String?

    private let functions = Functions.functions()
    private var roomRef: DatabaseReference?
    private var roomHandle: DatabaseHandle?

    func create(name: String, title: String) {
        status = "working"
        functions.httpsCallable("createVoiceRoom").call(["name": name, "title": title]) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let error { self.fail(error.localizedDescription); return }
                guard let data = result?.data as? [String: Any], let code = data["code"] as? String else {
                    self.fail("The voice server returned an invalid room."); return
                }
                self.code = code; self.status = "accepted"; self.isHost = true; self.listen(code)
            }
        }
    }

    func requestJoin(code rawCode: String, name: String) {
        let clean = String(rawCode.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(6))
        status = "working"
        functions.httpsCallable("requestVoiceRoomJoin").call(["code": clean, "name": name]) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let error { self.fail(error.localizedDescription); return }
                self.code = clean
                self.status = ((result?.data as? [String: Any])?["status"] as? String) ?? "pending"
                self.listen(clean)
            }
        }
    }

    func respond(to uid: String, approve: Bool) {
        functions.httpsCallable("respondVoiceRoomJoin").call([
            "code": code, "requesterUID": uid, "approve": approve
        ]) { [weak self] _, error in
            if let error { Task { @MainActor in self?.errorMessage = error.localizedDescription } }
        }
    }

    func leave(voice: VoiceChatManager) {
        voice.leave()
        stopListening()
        let leavingCode = code
        if !leavingCode.isEmpty {
            functions.httpsCallable("leaveVoiceRoom").call(["code": leavingCode]) { _, _ in }
        }
        reset()
    }

    private func listen(_ code: String) {
        stopListening()
        let ref = Database.database().reference().child("voiceRooms").child(code)
        roomRef = ref
        roomHandle = ref.observe(.value) { [weak self] snapshot in
            Task { @MainActor in
                guard let self, let room = snapshot.value as? [String: Any] else { return }
                let myUID = Auth.auth().currentUser?.uid ?? ""
                self.title = room["title"] as? String ?? "Ride Comms"
                self.isHost = room["hostUID"] as? String == myUID
                let roomStatus = room["status"] as? String ?? "ended"
                let memberData = room["members"] as? [String: [String: Any]] ?? [:]
                let myStatus = memberData[myUID]?["status"] as? String
                self.status = roomStatus == "active" ? (myStatus ?? "pending") : "ended"
                self.members = memberData.compactMap { uid, value in
                    guard value["status"] as? String == "accepted" else { return nil }
                    return RideCommsMember(id: uid, name: value["name"] as? String ?? "Rider", role: value["role"] as? String ?? "rider")
                }.sorted { $0.role == "host" && $1.role != "host" }
                let pending = room["joinRequests"] as? [String: [String: Any]] ?? [:]
                self.requests = self.isHost ? pending.map { RideCommsRequest(id: $0.key, name: $0.value["name"] as? String ?? "Rider") } : []
            }
        }
    }

    private func stopListening() {
        if let roomRef, let roomHandle { roomRef.removeObserver(withHandle: roomHandle) }
        roomRef = nil; roomHandle = nil
    }

    private func fail(_ message: String) { status = "idle"; errorMessage = message }
    private func reset() { code = ""; title = "Ride Comms"; status = "idle"; isHost = false; members = []; requests = [] }
    deinit { if let roomRef, let roomHandle { roomRef.removeObserver(withHandle: roomHandle) } }
}

struct RideCommsView: View {
    @EnvironmentObject private var voice: VoiceChatManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("riderName") private var riderName = "Rider"
    @StateObject private var rooms = RideCommsManager()
    @State private var roomTitle = "Ride Comms"
    @State private var joinCode = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("RIDE COMMS").font(.system(size: 13, weight: .black)).tracking(4).foregroundColor(.prCoral)
                    Text("Private rider voice").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundColor(.prInk)
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 22)
                if rooms.status == "idle" || rooms.status == "working" { entryView } else { roomView }
            }
        }
        .background(Color.prBg.ignoresSafeArea())
        .navigationTitle("Ride Comms")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Ride Comms", isPresented: Binding(get: { rooms.errorMessage != nil }, set: { if !$0 { rooms.errorMessage = nil } })) {
            Button("OK") { rooms.errorMessage = nil }
        } message: { Text(rooms.errorMessage ?? "") }
        .onChange(of: rooms.status) { _, state in
            if state == "ended" { voice.leave() }
        }
    }

    private var entryView: some View {
        VStack(spacing: 8) {
            commsSection {
                Text("Start a room").font(.headline)
                TextField("Room name", text: $roomTitle).textFieldStyle(.roundedBorder)
                Button("Create Ride Comms") { rooms.create(name: riderName, title: roomTitle) }.prPrimaryButton()
            }
            commsSection {
                Text("Join with a code").font(.headline)
                TextField("6-character code", text: $joinCode)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                    .onChange(of: joinCode) { _, newCode in
                        joinCode = String(newCode.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(6))
                    }
                Button("Request to Join") { rooms.requestJoin(code: joinCode, name: riderName) }
                    .buttonStyle(.bordered).disabled(joinCode.count != 6 || rooms.status == "working")
            }
            Text("Anyone with the code can request access, including riders who are not friends. The host must approve them. Joining voice never shares location.")
                .font(.footnote).foregroundColor(.prMuted)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
        }
    }

    private var roomView: some View {
        VStack(alignment: .leading, spacing: 14) {
            commsSection {
                Text(rooms.title).font(.title2.bold())
                Text("ROOM \(rooms.code)").font(.system(.headline, design: .monospaced)).foregroundColor(.prCoral)
                if rooms.isHost {
                    ShareLink(item: "Join my PackRide Ride Comms room: \(rooms.code)") { Label("Invite / Share Code", systemImage: "square.and.arrow.up") }
                }
                if rooms.status == "pending" { Text("Waiting for the host to approve you…") }
                if rooms.status == "rejected" { Text("The host declined this request. You can leave and request again later.") }
                if rooms.status == "ended" { Text("This room has ended.") }
                if rooms.status == "accepted" {
                    Button(voice.isConnected ? (voice.isMuted ? "Unmute" : "Mute") : "Join Voice") {
                        if voice.isConnected { voice.toggleMute() } else { voice.join(channelName: "VC\(rooms.code)") }
                    }.prPrimaryButton()
                    if voice.isConnected {
                        Button("Audio: \(voice.audioRouteName)") { voice.toggleSpeaker() }.buttonStyle(.bordered)
                    }
                }
            }
            if rooms.isHost && !rooms.requests.isEmpty {
                Text("Waiting room").font(.headline)
                ForEach(rooms.requests) { request in
                    HStack { Text(request.name); Spacer(); Button("Decline") { rooms.respond(to: request.id, approve: false) }; Button("Approve") { rooms.respond(to: request.id, approve: true) }.buttonStyle(.borderedProminent) }
                }
            }
            Text("Riders (\(rooms.members.count))").font(.headline)
            ForEach(rooms.members) { member in Text((member.role == "host" ? "★ " : "") + member.name).padding(.vertical, 5) }
            Button(rooms.isHost ? "End Room" : "Leave Room", role: .destructive) { rooms.leave(voice: voice); dismiss() }.buttonStyle(.bordered)
        }
    }

    private func commsSection<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(.horizontal, 18)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.prCardBg)
            .overlay(Rectangle().fill(Color.prBorder).frame(height: 1), alignment: .top)
            .overlay(Rectangle().fill(Color.prBorder).frame(height: 1), alignment: .bottom)
    }
}

private extension View {
    func prPrimaryButton() -> some View {
        self.font(.headline).foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 12).background(Color.prCoral).cornerRadius(12)
    }
}
