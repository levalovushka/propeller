import Foundation
import Darwin
import PropellerMetrics

/// Owns the local `gigastt serve` child process: find/bundle binary, ensure
/// e2e_rnnt models, spawn on loopback:9876, restart on crash, kill on quit.
final class GigasttSidecar: @unchecked Sendable {
    static let shared = GigasttSidecar()

    static let port = 9876
    static let variant = "e2e_rnnt"
    static let baseURL = URL(string: "http://127.0.0.1:\(port)")!

    private let lock = NSLock()
    private var process: Process?
    private var intentionalStop = false
    private var ready = false
    private var startTask: Task<Void, Error>?
    /// Debounced idle-stop so back-to-back transcriptions don't thrash the process.
    private var idleStopWork: DispatchWorkItem?
    /// Consecutive unintentional exits — reset on a healthy spawn (S3).
    private var consecutiveCrashRestarts = 0
    private static let maxCrashRestarts = 5

    private init() {}

    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return ready
    }

    /// Last hard failure surfaced to UI (restart exhausted / foreign port). Cleared on success.
    private(set) var lastFailureMessage: String?

    /// Ensure models exist and the server is healthy. Safe to call repeatedly.
    /// Cancels any pending idle-stop — calling this means we need the server now.
    func ensureReady(
        statusCallback: ((String) -> Void)? = nil,
        downloadProgress: ((Double) -> Void)? = nil
    ) async throws {
        cancelIdleStop()

        // Create-or-return in one critical section (plan-optimization C9).
        // Only the creator clears `startTask` — joiners must not wipe a newer spawn.
        let (task, isCreator): (Task<Void, Error>, Bool) = {
            lock.lock()
            defer { lock.unlock() }
            if let existing = startTask {
                return (existing, false)
            }
            let created = Task<Void, Error> {
                try await self.startIfNeeded(
                    statusCallback: statusCallback,
                    downloadProgress: downloadProgress
                )
            }
            startTask = created
            return (created, true)
        }()
        defer {
            if isCreator {
                lock.lock()
                startTask = nil
                lock.unlock()
            }
        }
        try await task.value
    }

    func stop() {
        cancelIdleStop()
        lock.lock()
        intentionalStop = true
        consecutiveCrashRestarts = 0
        let proc = process
        process = nil
        ready = false
        lock.unlock()

        guard let proc else { return }
        if proc.isRunning {
            proc.terminate()
            // Give it a moment, then force-kill
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                }
            }
        }
        Self.clearPIDFile()
        NSLog("[GigasttSidecar] stopped")
    }

    /// Schedule a graceful stop after `grace` seconds of idle. Cancelled by
    /// `ensureReady` / `stop`. Lets the ASR model leave RAM between meetings
    /// without thrashing on rapid back-to-back transcriptions (plan-optimization E1).
    func stopAfterIdle(_ grace: TimeInterval = 45) {
        cancelIdleStop()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSLog("[GigasttSidecar] idle-stop after \(Int(grace))s")
            self.stop()
        }
        idleStopWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + grace, execute: work)
    }

    private func cancelIdleStop() {
        idleStopWork?.cancel()
        idleStopWork = nil
    }

    /// Restart the server so an updated hotwords file takes effect — hotwords
    /// are a server-launch argument, not per-request (gigastt CHANGELOG: "deferred").
    /// Any transcription in flight when this is called will fail; callers should
    /// only invoke this from Settings, not mid-recording.
    func restart(statusCallback: ((String) -> Void)? = nil) async throws {
        stop()
        // Wait until the dying server stops answering /health — otherwise
        // ensureReady sees "healthy + no tracked process" → false portOccupied (R1).
        for _ in 0..<40 {
            if !(await probeHealth()) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await ensureReady(statusCallback: statusCallback)
    }

    // MARK: - Internals

    private func startIfNeeded(
        statusCallback: ((String) -> Void)?,
        downloadProgress: ((Double) -> Void)?
    ) async throws {
        // Healthy AND ours → reuse. Healthy but no tracked child → maybe our orphan (C8).
        if await probeHealth() {
            if isProcessAlive() {
                lock.lock(); ready = true; lastFailureMessage = nil; lock.unlock()
                statusCallback?("gigastt ready")
                downloadProgress?(1.0)
                return
            }
            if await reclaimOrphanIfOurs() {
                // Port freed — fall through to a fresh spawn.
            } else {
                throw SidecarError.portOccupied(Self.port)
            }
        }

        let binary = try resolveBinary()
        let modelDir = resolveModelDir()
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        if !modelsPresent(at: modelDir) {
            statusCallback?("Downloading GigaAM model…")
            try await downloadModels(
                binary: binary,
                modelDir: modelDir,
                statusCallback: statusCallback,
                downloadProgress: downloadProgress
            )
        } else {
            downloadProgress?(1.0)
        }

        statusCallback?("Starting gigastt…")
        try await PipelineMetrics.interval(PipelineMetrics.sidecar, PipelineMetrics.spawn) {
            try spawnServer(binary: binary, modelDir: modelDir)
            try await waitUntilHealthy(timeout: 180, statusCallback: statusCallback)
        }

        lock.lock()
        ready = true
        consecutiveCrashRestarts = 0
        lastFailureMessage = nil
        lock.unlock()
        statusCallback?("gigastt ready")
        downloadProgress?(1.0)
        NSLog("[GigasttSidecar] ready on \(Self.baseURL.absoluteString)")
    }

    /// Kill a leftover `gigastt` from a previous crash/kill-9 if the PID file matches.
    private func reclaimOrphanIfOurs() async -> Bool {
        let url = Self.pidFileURL
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1 else {
            return false
        }
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        let path = String(cString: buf)
        guard (path as NSString).lastPathComponent == "gigastt" else {
            return false
        }
        NSLog("[GigasttSidecar] reclaiming orphan pid=\(pid) path=\(path)")
        kill(pid, SIGTERM)
        for _ in 0..<25 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if !(await probeHealth()) {
                try? FileManager.default.removeItem(at: url)
                return true
            }
        }
        kill(pid, SIGKILL)
        try? await Task.sleep(nanoseconds: 200_000_000)
        try? FileManager.default.removeItem(at: url)
        return !(await probeHealth())
    }

    private func spawnServer(binary: URL, modelDir: URL) throws {
        lock.lock()
        intentionalStop = false
        lock.unlock()

        let logDir = modelDir.deletingLastPathComponent()
        let logURL = logDir.appendingPathComponent("gigastt-serve.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        _ = try logHandle.seekToEnd()

        var arguments = [
            "serve",
            "--model-dir", modelDir.path,
            "--model-variant", Self.variant,
            "--port", "\(Self.port)",
            "--pool-size", "1",
            // Headroom for ~25–27 min 16 kHz mono chunks (client still chunks
            // longer meetings — body-limit alone cannot cover 2h files).
            "--body-limit-bytes", "67108864",
            // Long chunks on CPU can exceed the 600s default inference cap.
            "--inference-timeout-secs", "0",
            // Curated Russian brand/acronym lexicon — always-on, free win with
            // no effect unless a term actually shows up in the audio.
            "--hotwords-default",
        ]
        if let hotwordsFile = writeHotwordsFile() {
            arguments.append("--hotwords-file")
            arguments.append(hotwordsFile.path)
        }

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = arguments
        proc.standardOutput = logHandle
        proc.standardError = logHandle
        proc.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.lock.lock()
            let intentional = self.intentionalStop
            if self.process == process { self.process = nil; self.ready = false }
            Self.clearPIDFile()
            var delay: TimeInterval?
            if !intentional {
                self.consecutiveCrashRestarts += 1
                let n = self.consecutiveCrashRestarts
                if n > Self.maxCrashRestarts {
                    let msg = "gigastt crashed \(n) times — giving up. Check the model or reinstall."
                    self.lastFailureMessage = msg
                    NSLog("[GigasttSidecar] \(msg)")
                } else {
                    // 1.5 → 3 → 6 → 12 → 24 s (S3)
                    delay = min(60.0, 1.5 * pow(2.0, Double(n - 1)))
                }
            }
            self.lock.unlock()
            NSLog("[GigasttSidecar] process exited status=\(process.terminationStatus) intentional=\(intentional)")
            if let delay {
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    Task {
                        do {
                            try await self.ensureReady()
                        } catch {
                            NSLog("[GigasttSidecar] restart failed: \(error)")
                        }
                    }
                }
            }
        }

        try proc.run()
        lock.lock(); process = proc; lock.unlock()
        Self.writePIDFile(proc.processIdentifier)
        NSLog("[GigasttSidecar] spawned pid=\(proc.processIdentifier) binary=\(binary.path)")
    }

    private func waitUntilHealthy(timeout: TimeInterval, statusCallback: ((String) -> Void)?) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var attempt = 0
        while Date() < deadline {
            attempt += 1
            if await probeHealth() { return }
            if !isProcessAlive() && attempt > 2 {
                throw SidecarError.exitedEarly
            }
            if attempt % 5 == 0 {
                statusCallback?("Loading gigastt model…")
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw SidecarError.healthTimeout
    }

    private func isProcessAlive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    private func probeHealth() async -> Bool {
        do {
            let health = try await GigasttClient.health(baseURL: Self.baseURL)
            // /health is up during CoreML load with model="loading" — wait for a real model id.
            guard let model = health.model, !model.isEmpty, model != "loading" else {
                return false
            }
            return true
        } catch {
            return false
        }
    }

    private func downloadModels(
        binary: URL,
        modelDir: URL,
        statusCallback: ((String) -> Void)?,
        downloadProgress: ((Double) -> Void)?
    ) async throws {
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = [
            "download",
            "--prequantized",
            "--model-variant", Self.variant,
            "--model-dir", modelDir.path,
            "--progress", "json",
        ]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        // Drain stderr continuously so a chatty download can't deadlock on a full pipe (R4).
        final class DownloadIO: @unchecked Sendable {
            let lock = NSLock()
            var errData = Data()
            var outRemainder = ""
        }
        let io = DownloadIO()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    var settled = false
                    let finish: (Result<Void, Error>) -> Void = { result in
                        guard !settled else { return }
                        settled = true
                        out.fileHandleForReading.readabilityHandler = nil
                        err.fileHandleForReading.readabilityHandler = nil
                        cont.resume(with: result)
                    }

                    err.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        guard !chunk.isEmpty else { return }
                        io.lock.lock(); io.errData.append(chunk); io.lock.unlock()
                    }

                    out.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
                        io.lock.lock()
                        io.outRemainder += text
                        var lines: [String] = []
                        while let nl = io.outRemainder.firstIndex(of: "\n") {
                            lines.append(String(io.outRemainder[..<nl]))
                            io.outRemainder = String(io.outRemainder[io.outRemainder.index(after: nl)...])
                        }
                        io.lock.unlock()
                        for line in lines {
                            guard let data = line.data(using: .utf8),
                                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                            else { continue }
                            if let frac = Self.progressFraction(from: obj) {
                                downloadProgress?(min(max(frac, 0), 0.99))
                            }
                            if let msg = obj["message"] as? String ?? obj["file"] as? String {
                                statusCallback?("Downloading: \(msg)")
                            }
                        }
                    }

                    proc.terminationHandler = { process in
                        if process.terminationStatus == 0 {
                            finish(.success(()))
                        } else {
                            io.lock.lock()
                            let snapshot = io.errData
                            io.lock.unlock()
                            let msg = String(data: snapshot, encoding: .utf8)
                                ?? "exit \(process.terminationStatus)"
                            finish(.failure(SidecarError.downloadFailed(msg)))
                        }
                    }

                    do {
                        try proc.run()
                    } catch {
                        finish(.failure(error))
                    }
                }
            }
            group.addTask {
                // ~3 GB model — generous ceiling; prevents infinite hang on stalled network.
                try await Task.sleep(nanoseconds: 45 * 60 * 1_000_000_000)
                if proc.isRunning {
                    proc.terminate()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                }
                throw SidecarError.downloadFailed("download timed out after 45 minutes")
            }

            // First finished wins; cancel the sibling (timeout or already-done download).
            try await group.next()
            group.cancelAll()
        }

        guard modelsPresent(at: modelDir) else {
            throw SidecarError.downloadFailed("model files missing after download")
        }
        downloadProgress?(1.0)
    }

    private static func progressFraction(from obj: [String: Any]) -> Double? {
        if let p = obj["progress"] as? Double { return p <= 1 ? p : p / 100 }
        if let p = obj["fraction"] as? Double { return p }
        if let p = obj["percent"] as? Double { return p / 100 }
        if let done = obj["bytes_done"] as? Double, let total = obj["bytes_total"] as? Double, total > 0 {
            return done / total
        }
        return nil
    }

    // MARK: - Paths

    func resolveBinary() throws -> URL {
        // Bundled next to the main executable
        if let aux = Bundle.main.url(forAuxiliaryExecutable: "gigastt"),
           FileManager.default.isExecutableFile(atPath: aux.path) {
            return aux
        }
        let inMacOS = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/gigastt")
        if FileManager.default.isExecutableFile(atPath: inMacOS.path) {
            return inMacOS
        }

        // Dev fallback — only in DEBUG builds (plan-optimization H2/H3).
        #if DEBUG
        let candidates = [
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Desktop/Propeller/tools/gigastt/gigastt"),
        ]
        for url in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
            NSLog("[GigasttSidecar] using dev binary \(url.path)")
            return url
        }
        #endif

        if let path = ProcessInfo.processInfo.environment["GIGASTT_BIN"] {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }

        throw SidecarError.binaryNotFound
    }

    func resolveModelDir() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Meeting Recorder/gigastt-models", isDirectory: true)
        if modelsPresent(at: appSupport) { return appSupport }

        #if DEBUG
        // Dev: reuse already-downloaded e2e models from Propeller/tools
        let dev = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Desktop/Propeller/tools/gigastt/models-e2e", isDirectory: true)
        if modelsPresent(at: dev) {
            NSLog("[GigasttSidecar] using dev model dir \(dev.path)")
            return dev
        }
        #endif

        return appSupport
    }

    /// Writes the user's "Domain terms" (Settings → Transcription → Vocabulary)
    /// to gigastt's hotwords file, one phrase per line. Returns the file URL,
    /// or nil (and removes any stale file) when there are no terms configured.
    private func writeHotwordsFile() -> URL? {
        let terms = Preferences.shared.domainTermsList
        let url = Self.hotwordsFileURL
        guard !terms.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try terms.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            NSLog("[GigasttSidecar] failed to write hotwords file: \(error)")
            return nil
        }
    }

    private static var pidFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Meeting Recorder/gigastt.pid")
    }

    private static func writePIDFile(_ pid: Int32) {
        let url = pidFileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? "\(pid)".write(to: url, atomically: true, encoding: .utf8)
    }

    private static func clearPIDFile() {
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    private static var hotwordsFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Meeting Recorder/hotwords.txt")
    }

    func modelsPresent(at dir: URL) -> Bool {
        let encoder = dir.appendingPathComponent("v3_e2e_rnnt_encoder_int8.onnx")
        let decoder = dir.appendingPathComponent("v3_e2e_rnnt_decoder.onnx")
        let joint = dir.appendingPathComponent("v3_e2e_rnnt_joint.onnx")
        let fm = FileManager.default
        return fm.fileExists(atPath: encoder.path)
            && fm.fileExists(atPath: decoder.path)
            && fm.fileExists(atPath: joint.path)
    }

    enum SidecarError: LocalizedError {
        case binaryNotFound
        case healthTimeout
        case exitedEarly
        case downloadFailed(String)
        case portOccupied(Int)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "gigastt binary not found in the app bundle."
            case .healthTimeout:
                return "gigastt did not become ready in time."
            case .exitedEarly:
                return "gigastt exited before becoming ready. See Console / Application Support log."
            case .downloadFailed(let detail):
                return "Failed to download GigaAM model: \(detail.prefix(200))"
            case .portOccupied(let port):
                return "Port \(port) is already serving gigastt from another process. Quit it or free the port, then retry."
            }
        }
    }
}
