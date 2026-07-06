import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

enum AudioCaptureError: Error, LocalizedError {
    case microphoneDenied
    case noAudioInputFormat
    case noSystemDisplay
    case unsupportedSystemAudio

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone permission is denied."
        case .noAudioInputFormat:
            return "No usable microphone input format is available."
        case .noSystemDisplay:
            return "No display is available for system audio capture."
        case .unsupportedSystemAudio:
            return "System audio capture requires macOS 13 or newer."
        }
    }
}

final class MicrophoneAudioCapture: AudioCapture {
    var onFrame: ((Data) -> Void)?

    private var engine = AVAudioEngine()
    private let converter = PCM16Converter()
    private let lockInputDevice: Bool
    private let restartQueue = DispatchQueue(label: "MeetingSidekickfree.Microphone.restart")
    private var configurationObserver: NSObjectProtocol?
    private var defaultDeviceObserver: DefaultAudioDeviceObserver?
    private var lockedInputDeviceID: AudioDeviceID?
    private var isRunning = false
    private var isRestartScheduled = false

    init(lockInputDevice: Bool = false) {
        self.lockInputDevice = lockInputDevice
    }

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    func start() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AudioCaptureError.microphoneDenied
        }

        isRunning = true
        if lockInputDevice {
            lockedInputDeviceID = DefaultAudioDeviceResolver.defaultInputDeviceID()
        }
        try startEngine()
        if !lockInputDevice {
            installConfigurationObserver()
            installDefaultDeviceObserver()
        }
    }

    func stop() {
        isRunning = false
        isRestartScheduled = false
        removeConfigurationObserver()
        defaultDeviceObserver?.stop()
        defaultDeviceObserver = nil
        restartQueue.async { [weak self] in
            guard let self else { return }
            self.stopEngine(self.engine)
            self.engine = AVAudioEngine()
            self.lockedInputDeviceID = nil
        }
    }

    private func stopEngine(_ engine: AVAudioEngine) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
    }

    private func removeConfigurationObserver() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }

    private func startEngine() throws {
        let input = engine.inputNode
        applyLockedInputDevice(to: input)
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw AudioCaptureError.noAudioInputFormat
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self,
                  let data = self.converter.convert(buffer),
                  !data.isEmpty else {
                return
            }
            self.onFrame?(data)
        }

        engine.prepare()
        try engine.start()
    }

    private func installConfigurationObserver() {
        guard configurationObserver == nil else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.scheduleRestart()
        }
    }

    private func installDefaultDeviceObserver() {
        guard defaultDeviceObserver == nil else { return }
        let observer = DefaultAudioDeviceObserver(
            label: "MeetingSidekickfree.Microphone.defaultDevice",
            selectors: [
                kAudioHardwarePropertyDefaultInputDevice,
                kAudioHardwarePropertyDefaultOutputDevice
            ]
        ) { [weak self] in
            self?.scheduleRestart()
        }
        observer.start()
        defaultDeviceObserver = observer
    }

    private func scheduleRestart() {
        guard !lockInputDevice else { return }
        restartQueue.async { [weak self] in
            guard let self, self.isRunning, !self.isRestartScheduled else { return }
            self.isRestartScheduled = true
            self.restartQueue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                self.isRestartScheduled = false
                self.restartEngine()
            }
        }
    }

    private func restartEngine(attempt: Int = 0) {
        guard isRunning else { return }
        removeConfigurationObserver()
        stopEngine(engine)
        engine = AVAudioEngine()

        do {
            try startEngine()
            installConfigurationObserver()
        } catch {
            guard attempt < 6 else { return }
            restartQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.restartEngine(attempt: attempt + 1)
            }
        }
    }

    private func applyLockedInputDevice(to input: AVAudioInputNode) {
        guard lockInputDevice else { return }
        guard var deviceID = lockedInputDeviceID ?? DefaultAudioDeviceResolver.defaultInputDeviceID() else { return }
        guard let audioUnit = input.audioUnit else { return }
        lockedInputDeviceID = deviceID

        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            retryLockedInputDeviceFallback(on: audioUnit, failedDeviceID: deviceID)
        }
    }

    private func retryLockedInputDeviceFallback(on audioUnit: AudioUnit, failedDeviceID: AudioDeviceID) {
        guard var fallbackID = DefaultAudioDeviceResolver.defaultInputDeviceID(),
              fallbackID != failedDeviceID else {
            lockedInputDeviceID = nil
            return
        }

        let retryStatus = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &fallbackID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        lockedInputDeviceID = retryStatus == noErr ? fallbackID : nil
    }
}
