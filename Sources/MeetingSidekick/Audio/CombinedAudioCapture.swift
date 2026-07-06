import Foundation

@available(macOS 13.0, *)
final class CombinedAudioCapture: AudioCapture {
    var onFrame: ((Data) -> Void)? {
        didSet {
            mixer.onFrame = onFrame
        }
    }

    private let mixer = PCM16AudioMixer()
    private var microphone: MicrophoneAudioCapture?
    private var systemAudio: SystemAudioCapture?

    func start() async throws {
        guard await MicrophoneAudioCapture.requestPermission() else {
            throw AudioCaptureError.microphoneDenied
        }

        let microphone = MicrophoneAudioCapture()
        let systemAudio = SystemAudioCapture()

        microphone.onFrame = { [weak mixer] data in
            mixer?.append(data, source: .microphone)
        }
        systemAudio.onFrame = { [weak mixer] data in
            mixer?.append(data, source: .systemAudio)
        }

        do {
            try microphone.start()
            try await systemAudio.start()
        } catch {
            microphone.stop()
            systemAudio.stop()
            throw error
        }

        self.microphone = microphone
        self.systemAudio = systemAudio
        mixer.onFrame = onFrame
        mixer.start()
    }

    func stop() {
        microphone?.stop()
        microphone = nil
        systemAudio?.stop()
        systemAudio = nil
        mixer.stop()
    }
}
