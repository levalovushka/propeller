import Foundation
import Darwin

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

    private init() {}

    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return ready
    }

    /// Ensure models exist and the server is healthy. Safe to call repeatedly.
    func ensureReady(
        statusCallback: ((String) -> Void)? = nil,
        downloadProgress: ((Double) -> Void)? = nil
    ) async throws {
        // Reuse in-flight start
        let existing: Task<Void, Error>? = {
            lock.lock(); defer { lock.unlock() }
            return startTask
        }()
        if let existing {
            try await existing.value
            return
        }

        let task = Task<Void, Error> {
            try await self.startIfNeeded(
                statusCallback: statusCallback,
                downloadProgress: downloadProgress
            )
        }
        lock.lock(); startTask = task; lock.unlock()
        defer {
            lock.lock(); startTask = nil; lock.unlock()
        }
        try await task.value
    }

    func stop() {
        lock.lock()
        intentionalStop = true
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
        NSLog("[GigasttSidecar] stopped")
    }

    // MARK: - Internals

    private func startIfNeeded(
        statusCallback: ((String) -> Void)?,
        downloadProgress: ((Double) -> Void)?
    ) async throws {
        // Already healthy (our process or an external serve)?
        if await probeHealth() {
            lock.lock(); ready = true; lock.unlock()
            statusCallback?("gigastt ready")
            downloadProgress?(1.0)
            return
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
        try spawnServer(binary: binary, modelDir: modelDir)
        try await waitUntilHealthy(timeout: 180, statusCallback: statusCallback)

        lock.lock(); ready = true; lock.unlock()
        statusCallback?("gigastt ready")
        downloadProgress?(1.0)
        NSLog("[GigasttSidecar] ready on \(Self.baseURL.absoluteString)")
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

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = [
            "serve",
            "--model-dir", modelDir.path,
            "--model-variant", Self.variant,
            "--port", "\(Self.port)",
            "--pool-size", "1",
        ]
        proc.standardOutput = logHandle
        proc.standardError = logHandle
        proc.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.lock.lock()
            let intentional = self.intentionalStop
            if self.process == process { self.process = nil; self.ready = false }
            self.lock.unlock()
            NSLog("[GigasttSidecar] process exited status=\(process.terminationStatus) intentional=\(intentional)")
            if !intentional {
                // Auto-restart after brief delay
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
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

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var settled = false
            let finish: (Result<Void, Error>) -> Void = { result in
                guard !settled else { return }
                settled = true
                cont.resume(with: result)
            }

            out.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                // Best-effort: parse complete lines in this chunk
                if let text = String(data: chunk, encoding: .utf8) {
                    for line in text.split(whereSeparator: \.isNewline) {
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
            }

            proc.terminationHandler = { process in
                out.fileHandleForReading.readabilityHandler = nil
                if process.terminationStatus == 0 {
                    finish(.success(()))
                } else {
                    let errData = err.fileHandleForReading.readDataToEndOfFile()
                    let msg = String(data: errData, encoding: .utf8) ?? "exit \(process.terminationStatus)"
                    finish(.failure(SidecarError.downloadFailed(msg)))
                }
            }

            do {
                try proc.run()
            } catch {
                finish(.failure(error))
            }
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

        // Dev fallback: Propeller/tools/gigastt/gigastt
        let candidates = [
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Desktop/Propeller/tools/gigastt/gigastt"),
            URL(fileURLWithPath: "/Users/levonlobanov/Desktop/Propeller/tools/gigastt/gigastt"),
        ]
        for url in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
            NSLog("[GigasttSidecar] using dev binary \(url.path)")
            return url
        }

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

        // Dev: reuse already-downloaded e2e models from Propeller/tools
        let dev = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Desktop/Propeller/tools/gigastt/models-e2e", isDirectory: true)
        if modelsPresent(at: dev) {
            NSLog("[GigasttSidecar] using dev model dir \(dev.path)")
            return dev
        }

        return appSupport
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
            }
        }
    }
}
