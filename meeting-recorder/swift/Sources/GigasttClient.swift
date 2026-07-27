import AVFoundation
import Foundation
import PropellerPure

/// Codable ASR segment used across checkpointing and diarization merge.
/// Segment from gigastt ASR (`/v1/transcribe?segments=true`).
/// Only start/end/text are needed for FluidAudio merge.
struct ASRSegment: Codable, Equatable {
    var start: Float
    var end: Float
    var text: String
}

/// Thin HTTP client for a local `gigastt serve` instance (loopback).
/// Process lifecycle is owned by `GigasttSidecar`.
enum GigasttClient {
    static let defaultBaseURL = URL(string: "http://127.0.0.1:9876")!

    struct Health: Decodable {
        let status: String?
        let model: String?
        let variant: String?
        let version: String?
    }

    struct TranscribeResponse: Decodable {
        let text: String?
        let duration: Double?
        let confidence: Float?
        let segments: [Segment]?
        let words: [Word]?
        // Error envelope
        let error: String?
        let code: String?

        struct Segment: Decodable {
            let start: Double
            let end: Double
            let text: String
        }

        struct Word: Decodable {
            let word: String?
            let start: Double?
            let end: Double?
        }
    }

    enum ClientError: LocalizedError {
        case notReachable(String)
        case badStatus(Int, String)
        case apiError(String)
        case emptyResult
        case readFailed(String)
        case chunkFailed(String)

        var errorDescription: String? {
            switch self {
            case .notReachable(let detail):
                return "gigastt is not reachable. \(detail)"
            case .badStatus(let code, let body):
                return "gigastt HTTP \(code): \(body.prefix(200))"
            case .apiError(let msg):
                return "gigastt error: \(msg)"
            case .emptyResult:
                return "gigastt returned no segments."
            case .readFailed(let path):
                return "Could not read audio file: \(path)"
            case .chunkFailed(let detail):
                return "Could not split audio for transcription: \(detail)"
            }
        }
    }

    static func health(baseURL: URL = defaultBaseURL) async throws -> Health {
        var req = URLRequest(url: baseURL.appendingPathComponent("health"))
        req.timeoutInterval = 5
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw ClientError.notReachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ClientError.notReachable("health HTTP \(code)")
        }
        return try JSONDecoder().decode(Health.self, from: data)
    }

    /// Transcribe a local audio file. Uses e2e_rnnt-friendly query (segments only;
    /// do NOT request punctuation add-on — e2e has it natively).
    /// Streams the WAV from disk via `upload(fromFile:)` so a long meeting never
    /// has to sit fully in RAM (plan-optimization S1).
    ///
    /// Long files are split client-side: gigastt's default body limit (~50 MiB)
    /// and ~30 min duration cap otherwise yield HTTP 413 / "too long".
    static func transcribe(
        audioURL: URL,
        baseURL: URL = defaultBaseURL,
        timeout: TimeInterval = 600,
        progressCallback: ((String) -> Void)? = nil
    ) async throws -> (segments: [ASRSegment], rawText: String) {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw ClientError.readFailed(audioURL.path)
        }

        let fileBytes = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int64) ?? 0
        let duration = WavHeader.duration(url: audioURL)

        if GigasttChunking.needsChunking(fileBytes: fileBytes, durationSeconds: duration) {
            NSLog(
                "[GigasttClient] chunking ASR fileBytes=%lld duration=%.1fs (limits bytes=%lld secs=%.0f)",
                fileBytes, duration, GigasttChunking.maxSingleShotBytes, GigasttChunking.maxSingleShotSeconds
            )
            return try await transcribeChunked(
                audioURL: audioURL,
                duration: duration,
                baseURL: baseURL,
                timeout: timeout,
                progressCallback: progressCallback
            )
        }

        return try await transcribeSingle(
            audioURL: audioURL,
            baseURL: baseURL,
            timeout: timeout
        )
    }

    private static func transcribeSingle(
        audioURL: URL,
        baseURL: URL,
        timeout: TimeInterval
    ) async throws -> (segments: [ASRSegment], rawText: String) {
        var comps = URLComponents(url: baseURL.appendingPathComponent("v1/transcribe"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "segments", value: "true"),
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue(contentType(for: audioURL), forHTTPHeaderField: "Content-Type")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.upload(for: req, fromFile: audioURL)
        } catch {
            throw ClientError.notReachable(error.localizedDescription)
        }

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? -1
        if !(200..<300).contains(status) {
            let body = String(data: data, encoding: .utf8) ?? ""
            if let env = try? JSONDecoder().decode(TranscribeResponse.self, from: data),
               let msg = env.error ?? env.code {
                throw ClientError.apiError(msg)
            }
            throw ClientError.badStatus(status, body)
        }

        return try decodeTranscription(data)
    }

    private static func transcribeChunked(
        audioURL: URL,
        duration: Double,
        baseURL: URL,
        timeout: TimeInterval,
        progressCallback: ((String) -> Void)?
    ) async throws -> (segments: [ASRSegment], rawText: String) {
        let source: AVAudioFile
        do {
            source = try AVAudioFile(forReading: audioURL)
        } catch {
            throw ClientError.chunkFailed(error.localizedDescription)
        }

        let rate = source.processingFormat.sampleRate
        guard rate > 0, source.length > 0 else {
            throw ClientError.chunkFailed("empty or invalid audio")
        }

        let chunkFrames = AVAudioFrameCount(GigasttChunking.chunkSeconds * rate)
        let totalFrames = AVAudioFramePosition(source.length)
        let chunkCount = Int(ceil(Double(totalFrames) / Double(chunkFrames)))
        guard chunkCount > 0 else { throw ClientError.emptyResult }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("propeller-asr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var merged: [(offset: Float, segments: [GigasttChunking.Segment])] = []
        var texts: [String] = []

        var startFrame: AVAudioFramePosition = 0
        var index = 0
        while startFrame < totalFrames {
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), totalFrames - startFrame))
            let offsetSec = Float(Double(startFrame) / rate)
            let chunkURL = tmpDir.appendingPathComponent(String(format: "chunk-%02d.wav", index))

            progressCallback?("Расшифровка \(index + 1)/\(chunkCount)…")
            do {
                try writeWAVChunk(from: source, startFrame: startFrame, frameCount: frames, to: chunkURL)
            } catch {
                throw ClientError.chunkFailed(error.localizedDescription)
            }

            // Per-chunk timeout scales with audio length; floor at caller timeout.
            let chunkDur = Double(frames) / rate
            let chunkTimeout = max(timeout, chunkDur * 2.0 + 120)

            let (segs, raw) = try await transcribeSingle(
                audioURL: chunkURL,
                baseURL: baseURL,
                timeout: chunkTimeout
            )
            merged.append((
                offset: offsetSec,
                segments: segs.map { GigasttChunking.Segment(start: $0.start, end: $0.end, text: $0.text) }
            ))
            if !raw.isEmpty { texts.append(raw) }

            startFrame += AVAudioFramePosition(frames)
            index += 1
        }

        let combined = GigasttChunking.merge(merged)
        guard !combined.isEmpty else { throw ClientError.emptyResult }

        let segments = combined.map { ASRSegment(start: $0.start, end: $0.end, text: $0.text) }
        let rawText = texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        NSLog(
            "[GigasttClient] chunked ASR done chunks=%d segments=%d durationHint=%.1fs",
            chunkCount, segments.count, duration
        )
        return (segments, rawText.isEmpty ? segments.map(\.text).joined(separator: " ") : rawText)
    }

    private static func writeWAVChunk(
        from source: AVAudioFile,
        startFrame: AVAudioFramePosition,
        frameCount: AVAudioFrameCount,
        to url: URL
    ) throws {
        try? FileManager.default.removeItem(at: url)
        let format = source.processingFormat
        let dest = try AVAudioFile(forWriting: url, settings: format.settings)
        source.framePosition = startFrame

        var remaining = frameCount
        let bufSize: AVAudioFrameCount = 16_384
        while remaining > 0 {
            let n = min(remaining, bufSize)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else {
                throw ClientError.chunkFailed("buffer alloc failed")
            }
            try source.read(into: buffer, frameCount: n)
            guard buffer.frameLength > 0 else { break }
            try dest.write(from: buffer)
            remaining -= buffer.frameLength
        }
    }

    private static func decodeTranscription(_ data: Data) throws -> (segments: [ASRSegment], rawText: String) {
        let decoded = try JSONDecoder().decode(TranscribeResponse.self, from: data)
        if let err = decoded.error {
            throw ClientError.apiError(err)
        }

        let segments: [ASRSegment]
        if let segs = decoded.segments, !segs.isEmpty {
            segments = segs.map {
                ASRSegment(
                    start: Float($0.start),
                    end: Float($0.end),
                    text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }.filter { !$0.text.isEmpty }
        } else if let words = decoded.words, !words.isEmpty {
            let text = (decoded.text ?? words.compactMap(\.word).joined(separator: " "))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let start = Float(words.compactMap(\.start).first ?? 0)
            let end = Float(words.compactMap(\.end).last ?? decoded.duration ?? 0)
            segments = text.isEmpty ? [] : [ASRSegment(start: start, end: end, text: text)]
        } else if let text = decoded.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            segments = [ASRSegment(start: 0, end: Float(decoded.duration ?? 0), text: text)]
        } else {
            throw ClientError.emptyResult
        }

        guard !segments.isEmpty else { throw ClientError.emptyResult }
        let rawText = (decoded.text?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? segments.map(\.text).joined(separator: " ")
        return (segments, rawText)
    }

    private static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a", "aac": return "audio/mp4"
        case "flac": return "audio/flac"
        case "ogg", "opus": return "audio/ogg"
        default: return "application/octet-stream"
        }
    }
}
