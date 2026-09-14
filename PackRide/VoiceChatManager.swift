import Foundation
import Combine
import AgoraRtcKit
import FirebaseFunctions

// MARK: - Voice Chat Manager (group ride intercom)
// Wraps the Agora Voice SDK for a single, simple job: join the voice channel
// for the current group ride (channel name = the ride code, which already
// works as a shared invite secret the same way it does everywhere else in the
// app), let riders mute/unmute, and show who's currently talking.
//
// Security note: this class never holds the Agora App Certificate. It only
// holds the App ID (not secret — required just to initialize the SDK) and
// asks a Firebase Cloud Function (generateAgoraToken, see
// packride-functions/functions/index.js) for a short-lived join token each
// time it connects. The certificate itself lives only in that function's
// server-side .env file. Embedding the certificate here instead would let
// anyone pull it out of the compiled app and join/eavesdrop on any channel.
final class VoiceChatManager: NSObject, ObservableObject {
    @Published var isConnected = false
    @Published var isMuted = false
    @Published var connectionError: String? = nil
    @Published var speakingUIDs: Set<UInt> = []
    @Published var isConnecting = false
    @Published var audioRouteName = "Automatic"
    @Published var isSpeakerEnabled = false

    private var agoraKit: AgoraRtcEngineKit?
    private var currentChannel: String?

    // Replace with your real Agora App ID from console.agora.io — Project
    // Management → your project → App ID. Not secret (unlike the App
    // Certificate), safe to ship in the client.
    private let appId = "e863d891fe1f4bbf8f02fef6c6802501"

    // MARK: - Join / Leave
    func join(channelName: String) {
        guard !channelName.isEmpty, currentChannel != channelName, !isConnecting else { return }
        connectionError = nil
        isConnecting = true

        if agoraKit == nil {
            let engine = AgoraRtcEngineKit.sharedEngine(withAppId: appId, delegate: self)
            engine.setChannelProfile(.communication)
            engine.enableAudio()
            // Strong real-time AI suppression for wind/road noise. This can
            // affect voice character slightly, which is preferable to wind
            // masking speech during a ride.
            // The Agora Objective-C enum is imported without named Swift
            // cases in SDK 4.6.2; raw value 1 is AINS_MODE_AGGRESSIVE.
            engine.setAINSMode(true, mode: AUDIO_AINS_MODE(rawValue: 1)!)
            engine.enableAudioVolumeIndication(200, smooth: 3, reportVad: true)
            // Prefer AirPods, a helmet/intercom headset, or wired audio when
            // present. Riders can explicitly switch to the phone speaker.
            engine.setDefaultAudioRouteToSpeakerphone(false)
            agoraKit = engine
        }

        fetchToken(channelName: channelName) { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    self.isConnecting = false
                    self.connectionError = "Couldn't reach the voice server: \(error.localizedDescription)"
                case .success(let token):
                    let options = AgoraRtcChannelMediaOptions()
                    options.channelProfile = .communication
                    options.clientRoleType = .broadcaster
                    options.publishMicrophoneTrack = true
                    options.autoSubscribeAudio = true
                    let joinResult = self.agoraKit?.joinChannel(
                        byToken: token, channelId: channelName, uid: 0, mediaOptions: options
                    )
                    if joinResult == 0 {
                        self.currentChannel = channelName
                    } else {
                        self.isConnecting = false
                        self.connectionError = "Couldn't join voice chat (code \(joinResult ?? -1))."
                    }
                }
            }
        }
    }

    func leave() {
        agoraKit?.leaveChannel(nil)
        currentChannel = nil
        isConnected = false
        isMuted = false
        speakingUIDs = []
        audioRouteName = "Automatic"
        isSpeakerEnabled = false
    }

    func toggleMute() {
        isMuted.toggle()
        agoraKit?.muteLocalAudioStream(isMuted)
    }

    func toggleSpeaker() {
        guard let agoraKit else { return }
        let result = agoraKit.setEnableSpeakerphone(!isSpeakerEnabled)
        if result != 0 {
            connectionError = "Couldn't change the voice audio output (code \(result))."
        }
    }

    // MARK: - Token fetch (via Cloud Function, see header note above)
    private func fetchToken(channelName: String, completion: @escaping (Result<String, Error>) -> Void) {
        Functions.functions().httpsCallable("generateAgoraToken").call(["channelName": channelName]) { result, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data = result?.data as? [String: Any], let token = data["token"] as? String else {
                completion(.failure(NSError(
                    domain: "VoiceChatManager", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "The voice server returned an unexpected response."]
                )))
                return
            }
            completion(.success(token))
        }
    }
}

// MARK: - AgoraRtcEngineDelegate
extension VoiceChatManager: AgoraRtcEngineDelegate {
    func rtcEngine(_ engine: AgoraRtcEngineKit, tokenPrivilegeWillExpire token: String) {
        guard let channel = currentChannel else { return }
        fetchToken(channelName: channel) { [weak self, weak engine] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let freshToken):
                    if engine?.renewToken(freshToken) != 0 {
                        self?.connectionError = "Voice authorization couldn't be renewed. Tap the microphone to reconnect."
                    }
                case .failure(let error):
                    self?.connectionError = "Voice authorization couldn't be renewed: \(error.localizedDescription)"
                }
            }
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinChannel channel: String, withUid uid: UInt, elapsed: Int) {
        DispatchQueue.main.async {
            self.currentChannel = channel
            self.isConnecting = false
            self.isConnected = true
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, connectionChangedTo state: AgoraConnectionState, reason: AgoraConnectionChangedReason) {
        DispatchQueue.main.async {
            switch state {
            case .connecting, .reconnecting:
                self.isConnecting = true
            case .connected:
                self.isConnecting = false
                self.isConnected = true
            case .disconnected:
                self.isConnecting = false
                self.isConnected = false
            case .failed:
                self.isConnecting = false
                self.isConnected = false
                self.connectionError = "Voice chat disconnected (reason \(reason.rawValue)). Tap the microphone to retry."
            @unknown default:
                break
            }
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didAudioRouteChanged routing: AgoraAudioOutputRouting) {
        let name: String
        switch routing {
        case .bluetoothDeviceHfp: name = "Bluetooth headset"
        case .bluetoothDeviceA2dp: name = "Bluetooth audio"
        case .headset: name = "Wired headset"
        case .headsetNoMic: name = "Wired headphones"
        case .earpiece: name = "Phone earpiece"
        case .speakerphone, .loudspeaker: name = "Phone speaker"
        case .usb: name = "USB headset"
        case .hdmi: name = "HDMI"
        case .displayPort: name = "DisplayPort"
        case .airPlay: name = "AirPlay"
        default: name = "Automatic"
        }
        DispatchQueue.main.async {
            self.audioRouteName = name
            self.isSpeakerEnabled = routing == .speakerphone || routing == .loudspeaker
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didOccurError errorCode: AgoraErrorCode) {
        DispatchQueue.main.async {
            self.connectionError = "Voice chat error (code \(errorCode.rawValue))."
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didOfflineOfUid uid: UInt, reason: AgoraUserOfflineReason) {
        DispatchQueue.main.async {
            self.speakingUIDs.remove(uid)
        }
    }

    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        reportAudioVolumeIndicationOfSpeakers speakers: [AgoraRtcAudioVolumeInfo],
        totalVolume: Int
    ) {
        // A little above zero, so normal background hiss/road noise doesn't
        // constantly light up the "speaking" indicator for everyone.
        let speaking = Set(speakers.filter { $0.volume > 5 }.map { $0.uid })
        DispatchQueue.main.async {
            self.speakingUIDs = speaking
        }
    }
}
