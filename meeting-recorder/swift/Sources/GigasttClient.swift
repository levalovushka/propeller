import Foundation

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
    static func transcribe(
        audioURL: URL,
        baseURL: URL = defaultBaseURL,
        timeout: TimeInterval = 600
    ) async throws -> (segments: [ASRSegment], rawText: String) {
        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioURL)
        } catch {
            throw ClientError.readFailed(audioURL.path)
        }

        var comps = URLComponents(url: baseURL.appendingPathComponent("v1/transcribe"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "segments", value: "true"),
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue(contentType(for: audioURL), forHTTPHeaderField: "Content-Type")
        req.httpBody = audioData

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw ClientError.notReachable(error.localizedDescription)
        }

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? -1
        if !(200..<300).contains(status) {
            let body = String(data: data, encoding: .utf8) ?? ""
            // Try to surface API error envelope
            if let env = try? JSONDecoder().decode(TranscribeResponse.self, from: data),
               let msg = env.error ?? env.code {
                throw ClientError.apiError(msg)
            }
            throw ClientError.badStatus(status, body)
        }

        let decoded = try JSONDecoder().decode(TranscribeResponse.self, from: data)
        if let err = decoded.error {
            throw ClientError.apiError(err)
        }

        let segments: [ASRSegment]
        if let segs = decoded.segments, !segs.isEmpty {
            segments = segs.map {
                ASRSegment(start: Float($0.start), end: Float($0.end), text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }.filter { !$0.text.isEmpty }
        } else if let words = decoded.words, !words.isEmpty {
            // Fallback: one segment from words if server omitted segments
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
