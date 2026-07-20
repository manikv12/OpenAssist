import AVFoundation
import Foundation
import whisper

private struct HelperError: Error, LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

private struct DecodedSegment {
    let text: String
    let noSpeechProbability: Float
}

private func argumentValue(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

private func jsonString(_ payload: [String: Any]) -> String {
    guard
        let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
        let line = String(data: data, encoding: .utf8)
    else {
        return "{\"ok\":false,\"error\":\"Could not encode helper response.\"}"
    }
    return line
}

private func finish(ok: Bool, text: String = "", error: String = "", code: Int32) -> Never {
    let payload: [String: Any] = ok
        ? ["ok": true, "text": text]
        : ["ok": false, "error": error]
    print(jsonString(payload))
    fflush(stdout)
    exit(code)
}

private func decodeAudioSamples(from audioURL: URL) throws -> [Float] {
    let inputFile = try AVAudioFile(forReading: audioURL)
    let sourceFormat = inputFile.processingFormat
    let sourceFrameCount = AVAudioFrameCount(min(inputFile.length, AVAudioFramePosition(UInt32.max)))

    guard sourceFrameCount > 0 else {
        throw HelperError(message: "Captured audio is empty.")
    }

    guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: sourceFrameCount) else {
        throw HelperError(message: "Could not allocate audio input buffer.")
    }
    try inputFile.read(into: sourceBuffer)

    guard sourceBuffer.frameLength > 0 else {
        throw HelperError(message: "Captured audio did not contain readable samples.")
    }

    guard let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    ) else {
        throw HelperError(message: "Could not create whisper audio format.")
    }

    guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
        throw HelperError(message: "Could not convert captured audio for whisper.cpp.")
    }

    let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
    let targetCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 1_024
    guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else {
        throw HelperError(message: "Could not allocate whisper audio buffer.")
    }

    var conversionError: NSError?
    var didProvideInput = false
    let status = converter.convert(to: targetBuffer, error: &conversionError) { _, outStatus in
        if didProvideInput {
            outStatus.pointee = .noDataNow
            return nil
        }
        didProvideInput = true
        outStatus.pointee = .haveData
        return sourceBuffer
    }

    if let conversionError {
        throw conversionError
    }
    if status == .error || targetBuffer.frameLength == 0 {
        throw HelperError(message: "Could not convert captured audio for whisper.cpp.")
    }
    guard let channel = targetBuffer.floatChannelData?[0] else {
        throw HelperError(message: "Converted audio did not contain float samples.")
    }

    return Array(UnsafeBufferPointer(start: channel, count: Int(targetBuffer.frameLength)))
}

private func hasLikelySpeech(_ samples: [Float]) -> Bool {
    guard samples.count >= 320 else { return false }

    let peakAmplitude = samples.reduce(Float(0)) { max($0, abs($1)) }
    guard peakAmplitude >= 0.003 else { return false }

    let frameLength = 320
    let hopLength = 160
    var frameRMS: [Float] = []
    frameRMS.reserveCapacity(max(1, samples.count / hopLength))

    var frameStart = 0
    while frameStart + frameLength <= samples.count {
        var sumSquares: Float = 0
        for index in frameStart..<(frameStart + frameLength) {
            let sample = samples[index]
            sumSquares += sample * sample
        }
        frameRMS.append(sqrtf(max(sumSquares / Float(frameLength), 1e-12)))
        frameStart += hopLength
    }

    guard !frameRMS.isEmpty else { return false }
    let sortedRMS = frameRMS.sorted()
    let noiseFloorIndex = max(0, Int(Float(sortedRMS.count - 1) * 0.20))
    let noiseFloor = sortedRMS[noiseFloorIndex]
    let activeThreshold = max(noiseFloor * 2.2, 0.0025)
    let activeFrameCount = frameRMS.reduce(0) { partialResult, value in
        partialResult + (value >= activeThreshold ? 1 : 0)
    }
    let activeRatio = Float(activeFrameCount) / Float(frameRMS.count)
    let activeDurationSeconds = TimeInterval(activeFrameCount * hopLength) / 16_000

    return activeRatio >= 0.03 && activeDurationSeconds >= 0.16
}

private func filteredTranscript(from segments: [DecodedSegment]) -> String {
    struct CandidateSegment {
        let text: String
        let noSpeechProbability: Float
        let wordCount: Int
    }

    let candidates = segments.compactMap { segment -> CandidateSegment? in
        let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return CandidateSegment(
            text: trimmed,
            noSpeechProbability: max(0, min(1, segment.noSpeechProbability)),
            wordCount: trimmed.split { $0.isWhitespace || $0.isNewline }.count
        )
    }

    guard !candidates.isEmpty else { return "" }

    let averageNoSpeechProbability =
        candidates.reduce(Float(0)) { $0 + $1.noSpeechProbability } / Float(candidates.count)
    let strongSpeechSegmentCount = candidates.reduce(0) { partialResult, candidate in
        partialResult + (candidate.noSpeechProbability < 0.55 ? 1 : 0)
    }
    let totalWordCount = candidates.reduce(0) { $0 + $1.wordCount }
    let totalCharacterCount = candidates.reduce(0) { $0 + $1.text.count }

    if strongSpeechSegmentCount == 0,
       averageNoSpeechProbability >= 0.78,
       (totalWordCount <= 8 || totalCharacterCount <= 48) {
        return ""
    }

    return candidates
        .filter { !($0.noSpeechProbability > 0.92 && $0.wordCount <= 2 && $0.text.count <= 12) }
        .map(\.text)
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func transcribe(samples: [Float], modelPath: String, language: String, useCoreML: Bool) throws -> String {
    var contextParams = whisper_context_default_params()
    contextParams.use_gpu = useCoreML
    contextParams.flash_attn = false

    guard let context = whisper_init_from_file_with_params(modelPath, contextParams) else {
        throw HelperError(message: "Failed to load whisper.cpp model.")
    }
    defer {
        whisper_free(context)
    }

    var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
    params.print_realtime = false
    params.print_progress = false
    params.print_timestamps = false
    params.print_special = false
    params.translate = false
    params.no_context = true
    params.single_segment = false
    params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
    params.offset_ms = 0
    params.suppress_nst = true
    params.no_speech_thold = max(params.no_speech_thold, Float(0.65))

    let runResult: Int32 = language.withCString { languageCString in
        params.language = languageCString
        params.carry_initial_prompt = false
        params.initial_prompt = nil
        return samples.withUnsafeBufferPointer { buffer in
            whisper_full(context, params, buffer.baseAddress, Int32(samples.count))
        }
    }

    guard runResult == 0 else {
        throw HelperError(message: "whisper.cpp transcription failed.")
    }

    let segmentCount = whisper_full_n_segments(context)
    var segments: [DecodedSegment] = []
    segments.reserveCapacity(Int(segmentCount))

    for index in 0..<segmentCount {
        guard let rawText = whisper_full_get_segment_text(context, index) else { continue }
        segments.append(
            DecodedSegment(
                text: String(cString: rawText),
                noSpeechProbability: whisper_full_get_segment_no_speech_prob(context, index)
            )
        )
    }

    return filteredTranscript(from: segments)
}

let audioPath = argumentValue("--audio")
let modelPath = argumentValue("--model")
let language = argumentValue("--language") ?? "en"
let useCoreML = (argumentValue("--coreml") ?? "false").lowercased() == "true"

guard let audioPath, !audioPath.isEmpty else {
    finish(ok: false, error: "Missing --audio path.", code: 2)
}
guard let modelPath, !modelPath.isEmpty else {
    finish(ok: false, error: "Missing --model path.", code: 2)
}

guard FileManager.default.fileExists(atPath: audioPath) else {
    finish(ok: false, error: "Captured audio file was not found.", code: 2)
}
guard FileManager.default.fileExists(atPath: modelPath) else {
    finish(ok: false, error: "Selected whisper.cpp model is not installed.", code: 2)
}

do {
    let samples = try decodeAudioSamples(from: URL(fileURLWithPath: audioPath))
    guard hasLikelySpeech(samples) else {
        finish(ok: true, text: "", code: 0)
    }
    let transcript = try transcribe(
        samples: samples,
        modelPath: modelPath,
        language: language,
        useCoreML: useCoreML
    )
    finish(ok: true, text: transcript, code: 0)
} catch {
    finish(ok: false, error: error.localizedDescription, code: 2)
}
