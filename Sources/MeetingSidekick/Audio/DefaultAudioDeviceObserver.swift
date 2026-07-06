import CoreAudio
import Foundation

enum DefaultAudioDeviceResolver {
    static func defaultInputDeviceID() -> AudioDeviceID? {
        audioDeviceID(for: kAudioHardwarePropertyDefaultInputDevice)
    }

    private static func audioDeviceID(for selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }
}

final class DefaultAudioDeviceObserver {
    private struct Listener {
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private let queue: DispatchQueue
    private let selectors: [AudioObjectPropertySelector]
    private let onChange: () -> Void
    private var listeners: [Listener] = []

    init(
        label: String,
        selectors: [AudioObjectPropertySelector],
        onChange: @escaping () -> Void
    ) {
        self.queue = DispatchQueue(label: label)
        self.selectors = selectors
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        guard listeners.isEmpty else { return }

        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.onChange()
            }
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                block
            )
            guard status == noErr else { continue }
            listeners.append(Listener(address: address, block: block))
        }
    }

    func stop() {
        for listener in listeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                listener.block
            )
        }
        listeners.removeAll()
    }
}
