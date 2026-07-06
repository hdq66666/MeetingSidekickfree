import AVFoundation
import Foundation

final class PCM16Converter {
    static let sampleRate: Double = 16_000

    private struct FormatKey: Equatable {
        let sampleRate: Double
        let channelCount: AVAudioChannelCount
        let commonFormat: AVAudioCommonFormat
        let isInterleaved: Bool

        init(_ format: AVAudioFormat) {
            sampleRate = format.sampleRate
            channelCount = format.channelCount
            commonFormat = format.commonFormat
            isInterleaved = format.isInterleaved
        }
    }

    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var converterInputFormat: FormatKey?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: PCM16Converter.sampleRate,
        channels: 1,
        interleaved: true
    )

    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        guard let targetFormat else { return nil }
        let inputFormat = buffer.format
        let inputFormatKey = FormatKey(inputFormat)
        let ratio = Self.sampleRate / inputFormat.sampleRate
        let frameCapacity = max(1, AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 8)

        if converter == nil || converterInputFormat != inputFormatKey {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            converterInputFormat = inputFormatKey
        }

        guard let converter,
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
            return nil
        }

        converter.reset()
        var didProvideInput = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if didProvideInput {
                status.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            status.pointee = .haveData
            return buffer
        }

        guard conversionError == nil else { return nil }
        let audioBuffer = output.audioBufferList.pointee.mBuffers
        guard let bytes = audioBuffer.mData else { return nil }
        return Data(bytes: bytes, count: Int(audioBuffer.mDataByteSize))
    }
}
