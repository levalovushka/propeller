import AVFoundation
import Foundation
import PropellerPure

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


    enum ClientError: LocalizedError {
        init(_ failure: BoundaryResponses.ASRFailure) {
            switch failure {
            case .tooLarge(let status): self = .badStatus(status, "тело запроса слишком большое")
            case .rejected(let message): self = .apiError(message)
            case .badStatus(let status, let body): self = .badStatus(status, body)
            case .empty: self = .emptyResult
            case .malformed: self = .apiError("не удалось разобрать ответ gigastt")
            }
        }

        case notReachable(String)
        case badStatus(Int, String)
        case apiError(String)
        case emptyResult
        case readFailed(String)
        case chunkFailed(String)

        var errorDescription: String? {
            switch self {
            case .notReachable(let detail):
                return "gigastt недоступен. \(detail)"
            case .badStatus(let code, let body):
                return "gigastt HTTP \(code): \(body.prefix(200))"
            case .apiError(let msg):
                return "Ошибка gigastt: \(msg)"
            case .emptyResult:
                return "gigastt не вернул сегменты (тишина или слишком короткий фрагмент?)."
            case .readFailed(let path):
                return "Не удалось прочитать аудио: \(path)"
            case .chunkFailed(let detail):
                return "Не удалось разрезать аудио: \(detail)"
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

        // One place decides what the sidecar's answer means — the same one the
        // recorded fixtures exercise (BoundaryResponses).
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        switch BoundaryResponses.readASR(status: status, data: data) {
        case .success(let transcription):
            return (transcription.segments, transcription.rawText)
        case .failure(let failure):
            throw ClientError(failure)
        }
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
        // Не `emptyResult`: у того теперь ровно один смысл — «сайдкар ответил, и
        // слов в аудио нет», по которому запись выводится из очереди навсегда
        // (`SilentRecording`). Ноль кусков при ненулевой длине — арифметика
        // чанкера, то есть наша, и она обязана остаться ретраибельной.
        guard chunkCount > 0 else { throw ClientError.chunkFailed("нечего резать") }

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

            progressCallback?("Расшифровка \(index + 1)/\(chunkCount)…")

            // Per-chunk timeout scales with audio length; floor at caller timeout.
            let chunkDur = Double(frames) / rate
            let chunkTimeout = max(timeout, chunkDur * 2.0 + 120)

            let (segs, raw) = try await transcribeChunkDividingOnTooLarge(
                source: source,
                startFrame: startFrame,
                frameCount: frames,
                rate: rate,
                into: tmpDir,
                index: index,
                baseURL: baseURL,
                timeout: chunkTimeout,
                progressCallback: progressCallback
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

    /// Send one piece — and if the sidecar says it is too large, send it as two.
    ///
    /// A 413 means the chunker's arithmetic was wrong about this file, not that the
    /// meeting cannot be transcribed. Halving is tried down to
    /// `GigasttChunking.minChunkSeconds`; past that the ladder in `PipelineRetry`
    /// takes over, because a 413 on half a minute of audio is a broken sidecar
    /// rather than a size (`design/no-dead-ends.md`, Э4).
    private static func transcribeChunkDividingOnTooLarge(
        source: AVAudioFile,
        startFrame: AVAudioFramePosition,
        frameCount: AVAudioFrameCount,
        rate: Double,
        into tmpDir: URL,
        index: Int,
        baseURL: URL,
        timeout: TimeInterval,
        progressCallback: ((String) -> Void)?
    ) async throws -> (segments: [ASRSegment], rawText: String) {
        let seconds = Double(frameCount) / rate
        let url = tmpDir.appendingPathComponent(
            String(format: "chunk-%02d-%.0f.wav", index, seconds)
        )
        do {
            try writeWAVChunk(from: source, startFrame: startFrame, frameCount: frameCount, to: url)
        } catch {
            throw ClientError.chunkFailed(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            return try await transcribeSingle(audioURL: url, baseURL: baseURL, timeout: timeout)
        } catch ClientError.badStatus(413, _) {
            guard let smaller = GigasttChunking.smallerChunk(after: seconds) else {
                NSLog("[GigasttClient] 413 at the %.0fs floor — not a size problem", seconds)
                throw ClientError.badStatus(413, "тело запроса слишком большое")
            }
            NSLog("[GigasttClient] 413 on a %.0fs chunk — dividing to %.0fs", seconds, smaller)
            let half = AVAudioFrameCount(max(1, Double(frameCount) / 2))
            var pieces: [(offset: Float, segments: [GigasttChunking.Segment])] = []
            var texts: [String] = []
            var cursor = startFrame
            var part = 0
            while cursor < startFrame + AVAudioFramePosition(frameCount) {
                let remaining = startFrame + AVAudioFramePosition(frameCount) - cursor
                let take = AVAudioFrameCount(min(AVAudioFramePosition(half), remaining))
                let (segs, raw) = try await transcribeChunkDividingOnTooLarge(
                    source: source,
                    startFrame: cursor,
                    frameCount: take,
                    rate: rate,
                    into: tmpDir,
                    index: index * 100 + part,
                    baseURL: baseURL,
                    timeout: timeout,
                    progressCallback: progressCallback
                )
                // Each half reports times from its own start, so it merges at the
                // distance between the two starts — not at zero, and not at the
                // absolute position in the file, which the caller adds later.
                pieces.append((
                    offset: Float(Double(cursor - startFrame) / rate),
                    segments: segs.map {
                        GigasttChunking.Segment(start: $0.start, end: $0.end, text: $0.text)
                    }
                ))
                if !raw.isEmpty { texts.append(raw) }
                cursor += AVAudioFramePosition(take)
                part += 1
            }
            let merged = GigasttChunking.merge(pieces)
            return (
                merged.map { ASRSegment(start: $0.start, end: $0.end, text: $0.text) },
                texts.joined(separator: " ")
            )
        }
    }

    private static func writeWAVChunk(
        from source: AVAudioFile,
        startFrame: AVAudioFramePosition,
        frameCount: AVAudioFrameCount,
        to url: URL
    ) throws {
        try? FileManager.default.removeItem(at: url)
        let format = source.processingFormat
        // Write in the source's ON-DISK format, not its processing format.
        // AVAudioFile always decodes to Float32 in memory, so writing with
        // `processingFormat.settings` re-encoded a 16 kHz Int16 mix as Float32
        // and doubled every chunk: a 20-minute piece became 73.2 MiB against the
        // sidecar's 64 MiB body limit, so long meetings failed with HTTP 413
        // even though chunking had run correctly. `write(from:)` converts from
        // the buffer's processing format to the file format for us.
        let dest = try AVAudioFile(forWriting: url, settings: source.fileFormat.settings)
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
