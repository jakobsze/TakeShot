import Foundation
import AVFoundation
import Speech

/// Offline audio analysis/processing: waveform peaks for the timeline,
/// silence detection, microphone enhancement and extraction for transcription.
enum AudioTools {
    static let enhancedMicFileName = "mic-enhanced.m4a"
    static let peaksPerSecond: Double = 50

    /// Reads an audio track as mono float samples at `sampleRate`.
    static func readMono(url: URL, sampleRate: Double) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate,
        ])
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        reader.startReading()
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / 4)
            chunk.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            samples.append(contentsOf: chunk)
        }
        return samples
    }

    /// Peak amplitude per 1/peaksPerSecond bin, in the file's own time.
    static func peaks(url: URL) async -> [Float] {
        let rate = 8000.0
        guard let samples = try? await readMono(url: url, sampleRate: rate), !samples.isEmpty else { return [] }
        let bin = Int(rate / peaksPerSecond)
        var result: [Float] = []
        result.reserveCapacity(samples.count / bin + 1)
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + bin)
            var peak: Float = 0
            for j in i..<end { peak = max(peak, abs(samples[j])) }
            result.append(peak)
            i = end
        }
        return result
    }

    /// Spans (in the peaks' time base) quieter than `thresholdDb` for at least `minDuration`.
    static func silences(peaks: [Float], thresholdDb: Double, minDuration: Double) -> [(Double, Double)] {
        let threshold = Float(pow(10, thresholdDb / 20))
        var result: [(Double, Double)] = []
        var start: Int?
        for (i, p) in peaks.enumerated() {
            if p < threshold {
                if start == nil { start = i }
            } else if let s = start {
                let a = Double(s) / peaksPerSecond, b = Double(i) / peaksPerSecond
                if b - a >= minDuration { result.append((a, b)) }
                start = nil
            }
        }
        if let s = start {
            let a = Double(s) / peaksPerSecond, b = Double(peaks.count) / peaksPerSecond
            if b - a >= minDuration { result.append((a, b)) }
        }
        return result
    }

    /// Extracts a track's audio to an uncompressed .caf for AVAudioEngine/Speech.
    static func extractAudio(from url: URL, to output: URL) async throws {
        let samples = try await readMono(url: url, sampleRate: 44100)
        guard !samples.isEmpty else { throw NSError(domain: "AudioTools", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio to process"]) }
        try? FileManager.default.removeItem(at: output)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: output, settings: format.settings)
        let chunk = 44100
        var i = 0
        while i < samples.count {
            let n = min(chunk, samples.count - i)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buffer.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { src in
                buffer.floatChannelData![0].update(from: src.baseAddress! + i, count: n)
            }
            try file.write(from: buffer)
            i += n
        }
    }

    /// "Improve microphone audio": high-pass + presence EQ, a gentle
    /// downward expander (reduces background hiss between words),
    /// compression with makeup gain, and a peak limiter. Rendered offline
    /// into mic-enhanced.m4a next to the recording.
    static func enhanceMicrophone(folder: URL, micFileName: String) async throws {
        let source = folder.appendingPathComponent(micFileName)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: temp) }
        try await extractAudio(from: source, to: temp)

        let input = try AVAudioFile(forReading: temp)
        let format = input.processingFormat
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ(numberOfBands: 3)
        eq.bands[0].filterType = .highPass
        eq.bands[0].frequency = 85
        eq.bands[0].bypass = false
        eq.bands[1].filterType = .parametric
        eq.bands[1].frequency = 250
        eq.bands[1].bandwidth = 1.2
        eq.bands[1].gain = -2.5
        eq.bands[1].bypass = false
        eq.bands[2].filterType = .highShelf
        eq.bands[2].frequency = 4500
        eq.bands[2].gain = 3
        eq.bands[2].bypass = false

        let dynamicsDesc = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
                                                     componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        let limiterDesc = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        let dynamics = AVAudioUnitEffect(audioComponentDescription: dynamicsDesc)
        let limiter = AVAudioUnitEffect(audioComponentDescription: limiterDesc)
        let du = dynamics.audioUnit
        AudioUnitSetParameter(du, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, -24, 0)
        AudioUnitSetParameter(du, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, 6, 0)
        AudioUnitSetParameter(du, kDynamicsProcessorParam_ExpansionRatio, kAudioUnitScope_Global, 0, 2.5, 0)
        AudioUnitSetParameter(du, kDynamicsProcessorParam_ExpansionThreshold, kAudioUnitScope_Global, 0, -52, 0)
        AudioUnitSetParameter(du, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, 0.004, 0)
        AudioUnitSetParameter(du, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, 0.12, 0)
        AudioUnitSetParameter(du, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, 8, 0)

        [player, eq, dynamics, limiter].forEach { engine.attach($0) }
        engine.connect(player, to: eq, format: format)
        engine.connect(eq, to: dynamics, format: format)
        engine.connect(dynamics, to: limiter, format: format)
        engine.connect(limiter, to: engine.mainMixerNode, format: format)

        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        player.scheduleFile(input, at: nil, completionHandler: nil)
        player.play()

        let outURL = folder.appendingPathComponent(enhancedMicFileName)
        try? FileManager.default.removeItem(at: outURL)
        let output = try AVAudioFile(forWriting: outURL, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 160_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)!
        let total = input.length
        while engine.manualRenderingSampleTime < total {
            let remaining = total - engine.manualRenderingSampleTime
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), remaining))
            let status = try engine.renderOffline(frames, to: buffer)
            if status == .success {
                try output.write(from: buffer)
            } else if status == .error {
                break
            }
        }
        player.stop()
        engine.stop()
    }
}

/// On-device speech-to-text for captions.
enum Transcriber {
    enum TranscribeError: LocalizedError {
        case notAuthorized, unavailable, noAudio
        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "Speech recognition permission was denied (System Settings › Privacy & Security › Speech Recognition)."
            case .unavailable: return "Speech recognition isn't available for your language on this Mac."
            case .noAudio: return "This recording has no microphone or system audio to transcribe."
            }
        }
    }

    static func authorize() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Returns caption segments in *source* (screen) time.
    static func transcribe(project: Project, folder: URL) async throws -> [CaptionSegment] {
        guard await authorize() else { throw TranscribeError.notAuthorized }
        let sourceURL: URL
        let offset: Double
        if let mic = project.micSource {
            sourceURL = folder.appendingPathComponent(mic.fileName)
            offset = mic.offset
        } else if project.hasSystemAudio {
            sourceURL = folder.appendingPathComponent(project.screenFileName)
            offset = 0
        } else {
            throw TranscribeError.noAudio
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: temp) }
        try await AudioTools.extractAudio(from: sourceURL, to: temp)

        guard let recognizer = SFSpeechRecognizer() ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable else {
            throw TranscribeError.unavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: temp)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.addsPunctuation = true

        let segments: [SFTranscriptionSegment] = try await withCheckedThrowingContinuation { continuation in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    continuation.resume(returning: result.bestTranscription.segments)
                } else if let error {
                    finished = true
                    continuation.resume(throwing: error)
                }
            }
        }

        // Group words into short caption lines.
        var captions: [CaptionSegment] = []
        var words: [String] = []
        var start = 0.0
        var end = 0.0
        func flush() {
            guard !words.isEmpty else { return }
            captions.append(CaptionSegment(start: start + offset, end: end + offset + 0.25, text: words.joined(separator: " ")))
            words = []
        }
        for seg in segments {
            if words.isEmpty { start = seg.timestamp }
            else if seg.timestamp - end > 0.8 || words.count >= 8 || seg.timestamp + seg.duration - start > 3.5 {
                flush()
                start = seg.timestamp
            }
            words.append(seg.substring)
            end = seg.timestamp + seg.duration
            if let last = seg.substring.last, ".?!".contains(last) { flush() }
        }
        flush()
        // Avoid overlap from the trailing padding.
        for i in 0..<max(0, captions.count - 1) where captions[i].end > captions[i + 1].start {
            captions[i].end = captions[i + 1].start
        }
        return captions
    }
}
