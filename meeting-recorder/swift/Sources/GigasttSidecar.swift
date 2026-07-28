import Foundation
import Darwin
import PropellerMetrics
import PropellerPure

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
                statusCallback?("gigastt готов")
                downloadProgress?(1.0)
                return
            }
            if await reclaimOrphan() {
                // Port freed — fall through to a fresh spawn.
            } else {
                throw SidecarError.portOccupied(Self.port)
            }
        }

        let binary = try resolveBinary()
        let modelDir = resolveModelDir()
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        if !modelsPresent(at: modelDir) {
            seedModelsFromBundle(into: modelDir, statusCallback: statusCallback)
        }

        if !modelsPresent(at: modelDir) {
            statusCallback?("Загрузка GigaAM…")
            try await downloadModels(
                binary: binary,
                modelDir: modelDir,
                statusCallback: statusCallback,
                downloadProgress: downloadProgress
            )
        } else {
            downloadProgress?(1.0)
        }

        statusCallback?("Запуск gigastt…")
        try await PipelineMetrics.interval(PipelineMetrics.sidecar, PipelineMetrics.spawn) {
            try spawnServer(binary: binary, modelDir: modelDir)
            try await waitUntilHealthy(timeout: 180, statusCallback: statusCallback)
        }

        lock.lock()
        ready = true
        consecutiveCrashRestarts = 0
        lastFailureMessage = nil
        lock.unlock()
        statusCallback?("gigastt готов")
        downloadProgress?(1.0)
        NSLog("[GigasttSidecar] ready on \(Self.baseURL.absoluteString)")
    }

    /// Free our port from a leftover `gigastt`, whether or not we can prove we
    /// started it.
    ///
    /// The PID file only identifies orphans from the *same* build. After an
    /// update it is gone or stale, so a sidecar left over from the previous
    /// version kept :9876 and every launch failed with `portOccupied` — the app
    /// could not transcribe at all until the user killed the process by hand.
    ///
    /// We reclaim rather than adopt on purpose. Unlike Ollama, gigastt takes its
    /// body limit, hotwords file and `--offline` as *launch arguments*, so an old
    /// process silently carries the old limits — which is how a 49-minute meeting
    /// still hit HTTP 413 after we had raised that limit. A server we did not
    /// start is not a server we can trust the behaviour of.
    private func reclaimOrphan() async -> Bool {
        if await reclaimByPIDFile() { return true }
        return await reclaimByProcessName()
    }

    /// Fast path: an orphan from this same build, recorded in the PID file.
    private func reclaimByPIDFile() async -> Bool {
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

    /// Fallback: find any running `gigastt` that is not our child and stop it.
    ///
    /// Scans the process table rather than the socket table — no `lsof`, no
    /// elevated access, and the match is narrow: the executable's own file name
    /// must be exactly `gigastt`. Only ever runs when our port is already taken
    /// and we have no tracked child, i.e. when the alternative is failing.
    private func reclaimByProcessName() async -> Bool {
        let ours = { () -> pid_t in
            lock.lock(); defer { lock.unlock() }
            return process?.processIdentifier ?? -1
        }()

        var candidates: [pid_t] = []
        let capacity = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard capacity > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(capacity) / MemoryLayout<pid_t>.size)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                                    Int32(pids.count * MemoryLayout<pid_t>.size))
        guard written > 0 else { return false }

        for pid in pids where pid > 1 && pid != ours && pid != getpid() {
            var buf = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { continue }
            if SidecarProcess.isBundledSidecar(path: String(cString: buf)) {
                candidates.append(pid)
            }
        }
        guard !candidates.isEmpty else { return false }

        NSLog("[GigasttSidecar] port held by untracked gigastt \(candidates) — reclaiming")
        for pid in candidates { kill(pid, SIGTERM) }
        for _ in 0..<25 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if !(await probeHealth()) {
                Self.clearPIDFile()
                return true
            }
        }
        for pid in candidates { kill(pid, SIGKILL) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        Self.clearPIDFile()
        let freed = !(await probeHealth())
        if !freed {
            NSLog("[GigasttSidecar] something still answers on :\(Self.port) after SIGKILL")
        }
        return freed
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

        ensureEncoderPresenceMarker(in: modelDir)

        var arguments = [
            "serve",
            "--model-dir", modelDir.path,
            "--model-variant", Self.variant,
            "--port", "\(Self.port)",
            "--pool-size", "1",
            // Headroom for ~25–27 min 16 kHz mono chunks (client still chunks
            // longer meetings — body-limit alone cannot cover 2h files).
            "--body-limit-bytes", "\(GigasttChunking.serverBodyLimitBytes)",
            // Long chunks on CPU can exceed the 600s default inference cap.
            "--inference-timeout-secs", "0",
            // Curated Russian brand/acronym lexicon — always-on, free win with
            // no effect unless a term actually shows up in the audio.
            "--hotwords-default",
            // Every fetch belongs to `downloadModels`, where there is a progress
            // bar and a disk check. Without this, serve quietly pulls 885 MB
            // mid-transcription and a flaky link strands it half-done - exactly
            // the 85% hang seen on 2026-07-27. A missing file now fails fast,
            // naming the file, instead of silently saturating the connection.
            "--offline",
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
                statusCallback?("Загрузка модели gigastt…")
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
                                statusCallback?("Загрузка: \(msg)")
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

    /// Writes gigastt's hotwords file, one phrase per line: the built-in team
    /// lexicon (`BuiltinHotwords`) plus whatever the user added in Settings →
    /// Transcription → Vocabulary. Always non-empty now that a baseline ships,
    /// so the file is only removed if the baseline itself is somehow empty.
    private func writeHotwordsFile() -> URL? {
        let terms = BuiltinHotwords.merged(withUserTerms: Preferences.shared.domainTermsList)
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

    /// Copy the ASR weights shipped inside the .app into the writable model dir.
    ///
    /// The weights (~247 MB INT8 set) ride in the DMG, so a fresh install has no
    /// ASR download at all: no progress bar to strand on a dropped connection,
    /// no disk gate, and the first meeting transcribes offline. `downloadModels`
    /// stays as the fallback for dev builds run straight from `swift build`,
    /// where Bundle.main has no Resources.
    ///
    /// Copied rather than used in place: gigastt writes `coreml_cache/` and lock
    /// files next to the models, and Contents/Resources is code-signed — writing
    /// there would break the signature.
    private func seedModelsFromBundle(into modelDir: URL, statusCallback: ((String) -> Void)?) {
        guard let bundled = Bundle.main.url(forResource: "gigastt-models", withExtension: nil) else {
            return
        }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil),
              !files.isEmpty else { return }

        statusCallback?("Готовим модель распознавания…")
        for src in files {
            let dst = modelDir.appendingPathComponent(src.lastPathComponent)
            guard !fm.fileExists(atPath: dst.path) else { continue }
            do {
                try fm.copyItem(at: src, to: dst)
            } catch {
                NSLog("[GigasttSidecar] seeding \(src.lastPathComponent) failed: \(error.localizedDescription)")
            }
        }
        NSLog("[GigasttSidecar] seeded ASR models from app bundle")
    }

    /// Work around a gigastt 2.14 inconsistency between its own subcommands.
    ///
    /// `gigastt download --prequantized` fetches the INT8 bundle (258 MB) and
    /// reports "Model ready". `gigastt serve` then decides the model is *not*
    /// installed, because its presence check looks for the FP32 filename, and
    /// silently downloads 885 MB from HuggingFace — a file it never reads: the
    /// log says "Using INT8 quantized encoder" either way.
    ///
    /// Verified 2026-07-27 on 2.14.0: with a zero-byte file at that path, serve
    /// loads the INT8 encoder and transcribes correctly. So the placeholder only
    /// satisfies an existence test — it is never opened. Combined with `--offline`
    /// on serve, this keeps every download inside our own progress-reported step.
    ///
    /// Re-check when bumping gigastt: if a release makes serve accept an
    /// INT8-only directory, delete this and the `--offline` flag together.
    private func ensureEncoderPresenceMarker(in dir: URL) {
        let fp32 = dir.appendingPathComponent("v3_e2e_rnnt_encoder.onnx")
        let fm = FileManager.default
        guard !fm.fileExists(atPath: fp32.path) else { return }
        guard fm.fileExists(atPath: dir.appendingPathComponent("v3_e2e_rnnt_encoder_int8.onnx").path) else {
            return  // no INT8 either — let the normal download path run
        }
        if fm.createFile(atPath: fp32.path, contents: Data()) {
            NSLog("[GigasttSidecar] wrote FP32 presence marker — skips a needless 885 MB fetch")
        }
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
                return "Бинарник gigastt не найден в бандле приложения."
            case .healthTimeout:
                return "gigastt не успел стать готовым."
            case .exitedEarly:
                return "gigastt завершился до готовности. Смотрите Console / лог Application Support."
            case .downloadFailed(let detail):
                return "Не удалось скачать модель GigaAM: \(detail.prefix(200))"
            case .portOccupied(let port):
                return "Порт \(port) уже занят другим процессом gigastt. Закройте его или освободите порт и повторите."
        }
        }
    }
}
