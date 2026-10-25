import Foundation
import AVFoundation

/// Builds the audio files the alarm needs at runtime:
/// a silent loop that keeps the app alive in the background,
/// a fallback chime when no track is chosen, and a 29-second
/// clip of the chosen track for backup notifications.
enum SoundFactory {
    static var soundsDirectory: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("Sounds", isDirectory: true)
    }

    // MARK: Silent loop

    static func silentLoopURL() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("brooke-silence.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let sampleRate = 22_050
        let samples = [Int16](repeating: 0, count: sampleRate * 2)
        try? wav(samples: samples, sampleRate: sampleRate).write(to: url, options: .atomic)
        return url
    }

    // MARK: Fallback chime

    static func fallbackToneURL() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("brooke-chime.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let sampleRate = 44_100
        var samples = [Int16](repeating: 0, count: sampleRate * 2)
        let notes: [(start: Double, freq: Double)] = [(0.0, 880), (0.32, 1174.66), (0.64, 1318.51)]
        let noteLength = 0.30
        for note in notes {
            let first = Int(note.start * Double(sampleRate))
            let count = Int(noteLength * Double(sampleRate))
            for i in 0..<count where first + i < samples.count {
                let t = Double(i) / Double(sampleRate)
                let attack = min(1, t / 0.01)
                let release = max(0, 1 - t / noteLength)
                let value = sin(2 * .pi * note.freq * t) * attack * release * 0.6
                samples[first + i] = Int16(value * Double(Int16.max))
            }
        }
        try? wav(samples: samples, sampleRate: sampleRate).write(to: url, options: .atomic)
        return url
    }

    private static func wav(samples: [Int16], sampleRate: Int) -> Data {
        var data = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let dataSize = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append32(36 + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)
        append16(1)
        append16(1)
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))
        append16(2)
        append16(16)
        data.append(contentsOf: Array("data".utf8))
        append32(dataSize)
        for sample in samples { append16(UInt16(bitPattern: sample)) }
        return data
    }

    // MARK: Notification clip

    /// Cuts the first 29 seconds of the track into a CAF file in Library/Sounds
    /// (the only place a notification can play a custom sound from).
    /// Returns the file name to use with UNNotificationSound(named:).
    static func makeNotificationClip(from source: URL) -> String? {
        let fm = FileManager.default
        try? fm.createDirectory(at: soundsDirectory, withIntermediateDirectories: true)
        if let old = try? fm.contentsOfDirectory(at: soundsDirectory, includingPropertiesForKeys: nil) {
            for file in old where file.lastPathComponent.hasPrefix("brooke-") {
                try? fm.removeItem(at: file)
            }
        }

        // A new name every time: iOS caches notification sounds by name.
        let name = "brooke-\(Int(Date().timeIntervalSince1970)).caf"
        let destination = soundsDirectory.appendingPathComponent(name)

        do {
            let input = try AVAudioFile(forReading: source)
            let format = input.processingFormat
            let limit = AVAudioFramePosition(format.sampleRate * 29)
            var remaining = min(input.length, limit)

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let output = try AVAudioFile(
                forWriting: destination,
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )

            let chunk: AVAudioFrameCount = 16_384
            while remaining > 0 {
                let count = AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { break }
                try input.read(into: buffer, frameCount: count)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
                remaining -= AVAudioFramePosition(buffer.frameLength)
            }
            return name
        } catch {
            try? fm.removeItem(at: destination)
            return nil
        }
    }
}
