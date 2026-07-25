import Foundation

/// Minimal loopback client for `gigastt serve` (Bench-only; app uses GigasttClient).
enum GigasttHTTP {
    static let baseURL = URL(string: "http://127.0.0.1:9876")!

    struct Health: Decodable {
        let status: String?
        let model: String?
    }

    private struct TranscribeResponse: Decodable {
        let text: String?
        let duration: Double?
        let segments: [Seg]?
        let words: [Word]?
        let error: String?
        struct Seg: Decodable { let start: Double; let end: Double; let text: String }
        struct Word: Decodable { let word: String?; let start: Double?; let end: Double? }
    }

    static func health() async throws -> Health {
        var req = URLRequest(url: baseURL.appendingPathComponent("health"))
        req.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Health.self, from: data)
    }

    static func transcribe(audioURL: URL, timeout: TimeInterval = 600) async throws -> (segments: Int, text: String) {
        var comps = URLComponents(url: baseURL.appendingPathComponent("v1/transcribe"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "segments", value: "true")]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: req, fromFile: audioURL)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "GigasttHTTP", code: status, userInfo: [NSLocalizedDescriptionKey: body.prefix(200)])
        }
        let decoded = try JSONDecoder().decode(TranscribeResponse.self, from: data)
        if let err = decoded.error { throw NSError(domain: "GigasttHTTP", code: 1, userInfo: [NSLocalizedDescriptionKey: err]) }
        let text: String
        let count: Int
        if let segs = decoded.segments, !segs.isEmpty {
            count = segs.count
            text = segs.map(\.text).joined(separator: " ")
        } else if let t = decoded.text, !t.isEmpty {
            count = 1
            text = t
        } else {
            throw NSError(domain: "GigasttHTTP", code: 2, userInfo: [NSLocalizedDescriptionKey: "empty ASR result"])
        }
        return (count, text)
    }
}
