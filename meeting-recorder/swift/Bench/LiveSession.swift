import Foundation
import PropellerPure

/// One measured recognition session — the bench-side twin of
/// `Sources/GigasttLiveSession.swift`.
///
/// Deliberately *not* a copy of the whole thing: the app's session hides socket
/// failures behind a reconnect ladder, because a live transcript owes the
/// meeting nothing and must never surface an error. A benchmark owes the
/// opposite. A dropped socket here means the numbers describe a partly
/// unrecognized clip, so it is recorded and the run is thrown away rather than
/// quietly averaged in.
///
/// What is kept identical, because it is what costs: 2 s portions, 16 kHz mono
/// little-endian Int16, `configure` before the first frame, finals only.
final class LiveWSSession: @unchecked Sendable {

    let channel: LiveTranscript.Channel

    private let collector: Collector
    private let endpoint: URL
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var buffer: [Float] = []
    private var ready = false
    private var closed = false
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []

    /// Frames handed to the session by the harness.
    private(set) var framesOffered = 0
    /// Frames actually put on the socket. Equal to `framesOffered` today — the
    /// ratio exists so that a feeding policy which skips audio has somewhere to
    /// show up, and cannot claim a saving without also showing what it skipped.
    private(set) var framesFed = 0
    private(set) var failure: String?

    private static let sampleRate = 16_000
    private var chunkFrames: Int { Int(Double(Self.sampleRate) * LiveHarness.sessionChunkSeconds) }

    init(port: Int, channel: LiveTranscript.Channel, collector: Collector) {
        self.channel = channel
        self.collector = collector
        self.endpoint = URL(string: "ws://127.0.0.1:\(port)/v1/ws")!
    }

    // MARK: - Socket

    func open() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 8 * 3600
        let session = URLSession(configuration: configuration)
        let socket = session.webSocketTask(with: endpoint)
        socket.maximumMessageSize = 4 * 1024 * 1024

        lock.lock()
        self.session = session
        self.task = socket
        lock.unlock()

        socket.resume()
        receive(on: socket)
        send(text: #"{"type":"configure","sample_rate":16000}"#, on: socket)
    }

    func waitUntilReady(timeout: TimeInterval = 120) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let state = snapshot()
            if state.ready { return }
            if let failure = state.failure { throw BenchError.sessionFailed(failure) }
            guard Date() < deadline else { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw BenchError.sessionFailed("\(channel.rawValue): no `ready` within \(Int(timeout))s")
    }

    /// Taking the lock inside an `async` function is a Swift 6 error even when no
    /// suspension sits between lock and unlock; reading through a synchronous
    /// helper keeps it honest.
    private func snapshot() -> (ready: Bool, failure: String?) {
        lock.lock(); defer { lock.unlock() }
        return (ready, failure)
    }

    // MARK: - Audio

    func feed(_ frames: [Float]) {
        guard !frames.isEmpty else { return }
        lock.lock()
        guard !closed else { lock.unlock(); return }
        framesOffered += frames.count
        buffer.append(contentsOf: frames)
        guard ready, let socket = task, buffer.count >= chunkFrames else { lock.unlock(); return }
        let portion = buffer
        buffer.removeAll(keepingCapacity: true)
        framesFed += portion.count
        lock.unlock()
        send(data: Self.pcm16(portion), on: socket)
    }

    /// Hand over a tail shorter than a portion — the app does this on pause and
    /// on stop, and the last words are the ones people look at.
    func flush() {
        lock.lock()
        guard !closed, ready, let socket = task, !buffer.isEmpty else { lock.unlock(); return }
        let held = buffer
        buffer.removeAll(keepingCapacity: true)
        framesFed += held.count
        lock.unlock()
        send(data: Self.pcm16(held), on: socket)
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let socket = task
        let session = self.session
        task = nil
        self.session = nil
        lock.unlock()
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    /// Same conversion as `GigasttLiveSession.pcm16` — it is on the hot path 20
    /// times a second per track, so it belongs in the measured cost.
    static func pcm16(_ frames: [Float]) -> Data {
        var samples = [Int16](repeating: 0, count: frames.count)
        for i in 0..<frames.count {
            let clamped = min(max(frames[i], -1), 1)
            samples[i] = Int16(clamped * 32767)
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func send(text: String, on socket: URLSessionWebSocketTask) {
        socket.send(.string(text)) { [weak self] error in
            if let error { self?.fail("send configure: \(error.localizedDescription)") }
        }
    }

    private func send(data: Data, on socket: URLSessionWebSocketTask) {
        socket.send(.data(data)) { [weak self] error in
            if let error { self?.fail("send audio: \(error.localizedDescription)") }
        }
    }

    private func receive(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.lock.lock()
                let expected = self.closed
                self.lock.unlock()
                if !expected { self.fail("receive: \(error.localizedDescription)") }
            case .success(let message):
                if case .string(let text) = message { self.handle(text) }
                self.receive(on: socket)
            }
        }
    }

    private func handle(_ json: String) {
        guard let data = json.data(using: .utf8),
              let message = try? JSONDecoder().decode(ServerMessage.self, from: data)
        else { return }

        switch message.type {
        case "ready":
            lock.lock()
            ready = true
            lock.unlock()
        case "final":
            guard let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }
            let span = message.span()
            collector.add(
                Collector.Final(
                    channel: channel, text: text, start: span.start, end: span.end,
                    receivedAt: collector.elapsed()
                )
            )
        case "error":
            fail("server: \(message.code ?? message.message ?? "error")")
        default:
            break
        }
    }

    private func fail(_ reason: String) {
        lock.lock()
        if failure == nil { failure = "\(channel.rawValue): \(reason)" }
        lock.unlock()
        FileHandle.standardError.write("session failure — \(reason)\n".data(using: .utf8)!)
    }

    private struct ServerMessage: Decodable {
        let type: String
        let text: String?
        let words: [Word]?
        let code: String?
        let message: String?

        struct Word: Decodable { let start: Double?; let end: Double? }

        func span() -> (start: Double, end: Double) {
            let starts = words?.compactMap(\.start) ?? []
            let ends = words?.compactMap(\.end) ?? []
            let start = starts.min() ?? 0
            let end = ends.max() ?? start
            return (start, max(end, start))
        }
    }
}

/// Finals from both sessions, with the moment each arrived.
///
/// The clock starts when audio starts, not when the harness starts: `ready` can
/// take seconds after a cold boot, and counting that into lag would report the
/// sidecar's start-up as the live layer's latency.
final class Collector: @unchecked Sendable {
    struct Final {
        let channel: LiveTranscript.Channel
        let text: String
        let start: Double
        let end: Double
        /// Seconds from the first frame of audio.
        let receivedAt: Double
    }

    private let lock = NSLock()
    private var items: [Final] = []
    private var clockStart: Date?

    var finals: [Final] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    func beginClock() {
        lock.lock()
        clockStart = Date()
        lock.unlock()
    }

    func elapsed() -> Double {
        lock.lock(); defer { lock.unlock() }
        guard let clockStart else { return 0 }
        return Date().timeIntervalSince(clockStart)
    }

    func add(_ final: Final) {
        lock.lock()
        items.append(final)
        lock.unlock()
    }
}
