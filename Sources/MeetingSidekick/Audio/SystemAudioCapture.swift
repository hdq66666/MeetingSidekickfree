import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import ScreenCaptureKit

@available(macOS 13.0, *)
final class SystemAudioCapture: NSObject, AudioCapture, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((Data) -> Void)?

    private var stream: SCStream?
    private let converter = PCM16Converter()
    private let outputQueue = DispatchQueue(label: "MeetingSidekickfree.SystemAudio.output")
    private let restartQueue = DispatchQueue(label: "MeetingSidekickfree.SystemAudio.restart")
    private var defaultDeviceObserver: DefaultAudioDeviceObserver?
    private var isRunning = false
    private var isRestartScheduled = false

    func start() async throws {
        isRunning = true
        installDefaultDeviceObserver()
        try await startStream()
    }

    private func startStream() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw AudioCaptureError.noSystemDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = Int(PCM16Converter.sampleRate)
        configuration.channelCount = 1

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() {
        isRunning = false
        defaultDeviceObserver?.stop()
        defaultDeviceObserver = nil
        let stream = stream
        self.stream = nil
        Task {
            try? await stream?.stopCapture()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let buffer = makePCMBuffer(from: sampleBuffer),
              let data = converter.convert(buffer),
              !data.isEmpty else {
            return
        }
        onFrame?(data)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard isRunning else { return }
        scheduleRestart()
    }

    private func installDefaultDeviceObserver() {
        guard defaultDeviceObserver == nil else { return }
        let observer = DefaultAudioDeviceObserver(
            label: "MeetingSidekickfree.SystemAudio.defaultDevice",
            selectors: [kAudioHardwarePropertyDefaultOutputDevice]
        ) { [weak self] in
            self?.scheduleRestart()
        }
        observer.start()
        defaultDeviceObserver = observer
    }

    private func scheduleRestart() {
        restartQueue.async { [weak self] in
            guard let self, self.isRunning, !self.isRestartScheduled else { return }
            self.isRestartScheduled = true
            self.restartQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                self.isRestartScheduled = false
                guard self.isRunning else { return }
                Task { [weak self] in
                    await self?.restartStream()
                }
            }
        }
    }

    private func restartStream(attempt: Int = 0) async {
        let oldStream = stream
        stream = nil
        try? await oldStream?.stopCapture()
        guard isRunning else { return }
        do {
            try await startStream()
        } catch {
            guard attempt < 6 else { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
            await restartStream(attempt: attempt + 1)
        }
    }

    private func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        var asbd = streamDescription.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            return nil
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        pcmBuffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )

        guard status == noErr else { return nil }
        return pcmBuffer
    }
}
