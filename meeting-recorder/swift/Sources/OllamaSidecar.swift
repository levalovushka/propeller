import Foundation
import PropellerPure

/// Owns a local Ollama runtime for dogfood recaps — download official darwin
/// binary into Application Support, `ollama serve`, pull the default model.
///
/// If something already answers on :11434 (system Ollama.app), we reuse it and
/// never fight the port. Pattern mirrors `GigasttSidecar`.
final class OllamaSidecar: @unchecked Sendable {
    static let shared = OllamaSidecar()

    static let port = 11434
    static let baseURL = URL(string: "http://127.0.0.1:\(port)")!
    /// Pinned for reproducible dogfood installs (not floating `latest`).
    static let releaseTag = "v0.32.4"
    static let defaultModel = Preferences.defaultRecapModel

    private let lock = NSLock()
    private var process: Process?
    private var intentionalStop = false
    private var ensureTask: Task<Void, Error>?
    private var idleStopWork: DispatchWorkItem?

    private init() {}

    // MARK: - Public

    /// Full setup: binary → serve → model. Safe to call repeatedly.
    func ensureReady(
        model: String = OllamaSidecar.defaultModel,
        statusCallback: ((String) -> Void)? = nil,
        progress: ((Double) -> Void)? = nil
    ) async throws {
        cancelIdleStop()
        let (task, isCreator): (Task<Void, Error>, Bool) = {
            lock.lock()
            defer { lock.unlock() }
            if let existing = ensureTask { return (existing, false) }
            let created = Task<Void, Error> {
                try await self.runEnsureReady(
                    model: model,
                    statusCallback: statusCallback,
                    progress: progress
                )
            }
            ensureTask = created
            return (created, true)
        }()
        defer {
            if isCreator {
                lock.lock()
                ensureTask = nil
                lock.unlock()
            }
        }
        try await task.value
    }

    /// Start serve only if our binary exists and nothing is on :11434.
    /// Does not download binary or pull models (cheap path for recap).
    func ensureServerRunning() async {
        if await probeAPI() { return }
        if !FileManager.default.isExecutableFile(atPath: binaryURL.path) {
            do {
                try await ensureBinaryInstalled(statusCallback: nil, progress: nil)
            } catch {
                NSLog("[OllamaSidecar] unpack for serve failed: \(error.localizedDescription)")
                return
            }
        }
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else { return }
        do {
            try await startServeIfNeeded(statusCallback: nil)
            try await waitUntilHealthy(timeout: 30, statusCallback: nil)
        } catch {
            NSLog("[OllamaSidecar] ensureServerRunning failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        cancelIdleStop()
        lock.lock()
        intentionalStop = true
        let proc = process
        process = nil
        lock.unlock()
        guard let proc else { return }
        if proc.isRunning {
            proc.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if proc.isRunning { proc.interrupt() }
            }
        }
    }

    /// Drop the serve process after idle so qwen doesn't sit in VRAM between meetings.
    func stopAfterIdle(_ grace: TimeInterval = 45) {
        cancelIdleStop()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSLog("[OllamaSidecar] idle-stop after \(Int(grace))s")
            self.stop()
        }
        idleStopWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + grace, execute: work)
    }

    private func cancelIdleStop() {
        idleStopWork?.cancel()
        idleStopWork = nil
    }

    /// Is the model already on disk? Answers without spawning `ollama serve`,
    /// so the summary panel can offer «Скачать» instead of a «Сгенерировать»
    /// button that can only produce `HTTP 404: model not found`.
    ///
    /// Prefers the live API when a server happens to be up (authoritative), and
    /// otherwise reads the manifest layout directly. Both our own models dir and
    /// `~/.ollama` are checked, because `adopt-if-present` means the model may
    /// legitimately live in the user's own install.
    func isModelInstalled(_ name: String) async -> Bool {
        if await probeAPI(), let tags = try? await fetchTags() {
            return tags.contains { $0 == name || $0.hasPrefix(name) }
        }
        let parts = name.split(separator: ":", maxSplits: 1)
        let repo = String(parts.first ?? "")
        let tag = parts.count > 1 ? String(parts[1]) : "latest"
        guard !repo.isEmpty else { return false }

        // Only our own store. When nothing is listening we are the ones who will
        // spawn `serve`, and we spawn it with OLLAMA_MODELS pointed here — a
        // model sitting in the user's ~/.ollama would be invisible to it. Counting
        // it would make the panel claim "ready" and the recap fail with 404.
        // The adopted-server case is already covered by the probe above.
        let manifest = modelsDir
            .appendingPathComponent("manifests/registry.ollama.ai/library", isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
            .appendingPathComponent(tag)
        return FileManager.default.fileExists(atPath: manifest.path)
    }

    func modelPresent(_ name: String) async -> Bool {
        guard let tags = try? await fetchTags() else { return false }
        return tags.contains { $0 == name || $0.hasPrefix(name) }
    }

    // MARK: - Pipeline

    private func runEnsureReady(
        model: String,
        statusCallback: ((String) -> Void)?,
        progress: ((Double) -> Void)?
    ) async throws {
        // Phase weights: unpack engine 0–0.15, serve 0.15–0.25, pull model 0.25–1.0
        if await probeAPI() {
            statusCallback?("Ollama уже запущен")
            progress?(0.25)
        } else {
            try await ensureBinaryInstalled(
                statusCallback: statusCallback,
                progress: { frac in progress?(frac * 0.15) }
            )
            statusCallback?("Запуск Ollama…")
            progress?(0.15)
            try await startServeIfNeeded(statusCallback: statusCallback)
            try await waitUntilHealthy(timeout: 90, statusCallback: statusCallback)
            progress?(0.25)
        }

        if await modelPresent(model) {
            statusCallback?("Модель готова")
            progress?(1.0)
            await reclaimSupersededModels(keeping: model)
            return
        }

        statusCallback?("Скачиваем модель саммари…")
        try await pullModelWithRetry(
            model,
            statusCallback: statusCallback,
            progress: { frac in progress?(0.25 + frac * 0.75) }
        )
        statusCallback?("Модель готова")
        progress?(1.0)
        await reclaimSupersededModels(keeping: model)
    }

    /// Backoff between pull attempts. Long tail on purpose: the download is
    /// unattended, so waiting out a tunnel or a hotel Wi-Fi hiccup beats making
    /// the user find Settings. ~17 minutes of wall clock across all attempts.
    private static let pullRetryDelays: [UInt64] = [5, 15, 45, 120, 300, 600]

    /// Retry a dropped model pull instead of dying on the first blip.
    ///
    /// Ollama stores blobs incrementally and skips what it already has, so a
    /// retry resumes rather than restarting the 3.4 GB — which is what makes an
    /// aggressive retry policy affordable here.
    ///
    /// Only transport failures are retried: a bad model name or an out-of-space
    /// disk fails the same way forever, and hiding that behind 17 minutes of
    /// silent retries would be worse than reporting it.
    private func pullModelWithRetry(
        _ model: String,
        statusCallback: ((String) -> Void)?,
        progress: ((Double) -> Void)?
    ) async throws {
        var attempt = 0
        while true {
            do {
                try await pullModel(model, statusCallback: statusCallback, progress: progress)
                return
            } catch {
                // A pull that actually landed the model counts as success even if
                // the stream died on the last line.
                if await modelPresent(model) { return }

                guard Self.isRetryable(error), attempt < Self.pullRetryDelays.count else {
                    throw error
                }
                let delay = Self.pullRetryDelays[attempt]
                attempt += 1
                NSLog("[OllamaSidecar] pull failed (\(error.localizedDescription)) — retry \(attempt) in \(delay)s")
                statusCallback?("Связь прервалась. Продолжим через \(Self.humanDelay(delay))…")
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                statusCallback?("Догружаем модель саммари…")
            }
        }
    }

    private static func humanDelay(_ seconds: UInt64) -> String {
        seconds < 60 ? "\(seconds) с" : "\(seconds / 60) мин"
    }

    /// Transport-level failure worth another attempt, as opposed to a request
    /// that will fail identically forever. Message classification lives in
    /// `PropellerPure.OllamaRetry` so it can be tested without a network.
    static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .resourceUnavailable, .secureConnectionFailed, .badServerResponse:
                return true
            default:
                return false
            }
        }
        return OllamaRetry.isRetryable(message: error.localizedDescription)
    }

    /// Models we shipped as a default in an earlier version and no longer use.
    /// A 1.11 install pulled qwen2.5:7b (4.7 GB); after the 1.12 migration it is
    /// dead weight next to the 3.4 GB replacement.
    static let supersededModels = ["qwen2.5:7b"]

    /// Delete superseded default models to get the disk back.
    ///
    /// `adopt-if-present` means this may run against the user's own Ollama, so
    /// deleting there removes a model we did not install. Owner decision
    /// 2026-07-27, made with the facts: the audience is managers who have no
    /// personal Ollama, and every qwen2.5:7b in the fleet was put there by
    /// Propeller 1.11. Scope stays narrow on purpose — only tags this app once
    /// shipped as its default (`supersededModels`), never an arbitrary model
    /// someone pulled themselves.
    private func reclaimSupersededModels(keeping keep: String) async {
        for stale in Self.supersededModels where stale != keep {
            guard await modelPresent(stale) else { continue }
            if await deleteModel(stale) {
                NSLog("[OllamaSidecar] reclaimed disk from superseded model \(stale)")
            }
        }
    }

    private func deleteModel(_ name: String) async -> Bool {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("api/delete"))
        req.httpMethod = "DELETE"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name])
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            NSLog("[OllamaSidecar] delete \(name) failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Paths

    var installDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Meeting Recorder/ollama", isDirectory: true)
    }

    var modelsDir: URL {
        installDir.appendingPathComponent("models", isDirectory: true)
    }

    var binaryURL: URL {
        installDir.appendingPathComponent("ollama")
    }

    /// Bundled by `build.sh` into Contents/Resources (~140 MB compressed).
    private var bundledTarballURL: URL? {
        Bundle.main.url(forResource: "ollama-darwin", withExtension: "tgz")
    }

    private var downloadURL: URL {
        URL(string: "https://github.com/ollama/ollama/releases/download/\(Self.releaseTag)/ollama-darwin.tgz")!
    }

    // MARK: - Binary

    /// Prefer the DMG-bundled tarball (no network). Fall back to GitHub only if
    /// the bundle is missing (dev / incomplete build).
    private func ensureBinaryInstalled(
        statusCallback: ((String) -> Void)?,
        progress: ((Double) -> Void)?
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: installDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        if fm.isExecutableFile(atPath: binaryURL.path) {
            progress?(1.0)
            return
        }

        let tarball: URL
        if let bundled = bundledTarballURL, fm.fileExists(atPath: bundled.path) {
            statusCallback?("Распаковываем движок саммари…")
            progress?(0.2)
            tarball = bundled
        } else {
            statusCallback?("Скачиваем движок саммари…")
            progress?(0)
            let dest = installDir.appendingPathComponent("ollama-darwin.tgz")
            try await downloadFile(from: downloadURL, to: dest) { frac in
                progress?(frac * 0.85)
                let pct = Int(frac * 100)
                statusCallback?("Скачиваем движок саммари… \(pct)%")
            }
            tarball = dest
        }

        statusCallback?("Распаковываем движок саммари…")
        progress?(0.9)
        try extractTarball(tarball, into: installDir)
        if tarball.path != bundledTarballURL?.path {
            try? fm.removeItem(at: tarball)
        }

        if !fm.fileExists(atPath: binaryURL.path) {
            if let found = findOllamaBinary(under: installDir) {
                try? fm.removeItem(at: binaryURL)
                try fm.moveItem(at: found, to: binaryURL)
            }
        }
        guard fm.fileExists(atPath: binaryURL.path) else {
            throw SidecarError.binaryMissingAfterExtract
        }

        try makeExecutable(binaryURL)
        stripQuarantine(installDir)
        progress?(1.0)
        NSLog("[OllamaSidecar] binary ready at \(binaryURL.path)")
    }

    private func findOllamaBinary(under dir: URL) -> URL? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return nil }
        while let item = en.nextObject() as? URL {
            if item.lastPathComponent == "ollama", item.path != binaryURL.path {
                return item
            }
        }
        return nil
    }

    private func makeExecutable(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private func stripQuarantine(_ url: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = ["-dr", "com.apple.quarantine", url.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    private func extractTarball(_ tarball: URL, into dir: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        task.arguments = ["-xzf", tarball.path, "-C", dir.path]
        task.currentDirectoryURL = dir
        let err = Pipe()
        task.standardError = err
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw SidecarError.extractFailed(msg.prefix(200).description)
        }
    }

    private func downloadFile(
        from url: URL,
        to dest: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SidecarError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let total = response.expectedContentLength
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }

        var written: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(256 * 1024)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 256 * 1024 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if total > 0 {
                    progress(min(Double(written) / Double(total), 0.99))
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
        }
        progress(1.0)
        guard written > 1_000_000 else {
            throw SidecarError.downloadFailed("файл слишком маленький (\(written) байт)")
        }
    }

    // MARK: - Serve

    private func startServeIfNeeded(statusCallback: ((String) -> Void)?) async throws {
        if await probeAPI() { return }
        if isProcessAlive() {
            // Wait a bit for our child to come up.
            return
        }

        lock.lock()
        intentionalStop = false
        lock.unlock()

        let bin = binaryURL
        guard FileManager.default.isExecutableFile(atPath: bin.path) else {
            throw SidecarError.binaryNotFound
        }

        let logURL = installDir.appendingPathComponent("ollama-serve.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        _ = try logHandle.seekToEnd()

        let proc = Process()
        proc.executableURL = bin
        proc.arguments = ["serve"]
        proc.currentDirectoryURL = installDir
        proc.standardOutput = logHandle
        proc.standardError = logHandle
        var env = ProcessInfo.processInfo.environment
        env["OLLAMA_HOST"] = "127.0.0.1:\(Self.port)"
        env["OLLAMA_MODELS"] = modelsDir.path
        // Prefer libs sitting next to the extracted binary.
        let existing = env["DYLD_LIBRARY_PATH"] ?? ""
        env["DYLD_LIBRARY_PATH"] = existing.isEmpty ? installDir.path : "\(installDir.path):\(existing)"
        proc.environment = env
        proc.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.lock.lock()
            let intentional = self.intentionalStop
            if self.process == p { self.process = nil }
            self.lock.unlock()
            if !intentional {
                NSLog("[OllamaSidecar] serve exited status=\(p.terminationStatus)")
            }
        }

        statusCallback?("Запуск Ollama…")
        try proc.run()
        lock.lock()
        process = proc
        lock.unlock()
        NSLog("[OllamaSidecar] spawned serve pid=\(proc.processIdentifier)")
    }

    private func isProcessAlive() -> Bool {
        lock.lock()
        let p = process
        lock.unlock()
        return p?.isRunning == true
    }

    private func waitUntilHealthy(
        timeout: TimeInterval,
        statusCallback: ((String) -> Void)?
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await probeAPI() { return }
            statusCallback?("Ждём готовности Ollama…")
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        throw SidecarError.healthTimeout
    }

    // MARK: - HTTP

    func probeAPI() async -> Bool {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("api/tags"))
        req.timeoutInterval = 3
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func fetchTags() async throws -> [String] {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("api/tags"))
        req.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SidecarError.healthTimeout
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            return []
        }
        return models.compactMap { $0["name"] as? String }
    }

    private func pullModel(
        _ model: String,
        statusCallback: ((String) -> Void)?,
        progress: ((Double) -> Void)?
    ) async throws {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("api/pull"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60 * 60
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": model,
            "stream": true,
        ])

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SidecarError.pullFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        var lineData = Data()
        var lastFrac = 0.0
        for try await byte in bytes {
            if byte == UInt8(ascii: "\n") {
                if let line = String(data: lineData, encoding: .utf8) {
                    try handlePullLine(line, statusCallback: statusCallback, progress: progress, lastFrac: &lastFrac)
                }
                lineData.removeAll(keepingCapacity: true)
            } else {
                lineData.append(byte)
            }
        }
        if !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) {
            try handlePullLine(line, statusCallback: statusCallback, progress: progress, lastFrac: &lastFrac)
        }

        guard await modelPresent(model) else {
            throw SidecarError.pullFailed("модель не появилась после pull")
        }
        progress?(1.0)
    }

    private func handlePullLine(
        _ line: String,
        statusCallback: ((String) -> Void)?,
        progress: ((Double) -> Void)?,
        lastFrac: inout Double
    ) throws {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if let err = obj["error"] as? String, !err.isEmpty {
            throw SidecarError.pullFailed(err)
        }
        let status = obj["status"] as? String ?? ""
        if let total = obj["total"] as? Double, total > 0,
           let completed = obj["completed"] as? Double {
            let frac = min(max(completed / total, 0), 0.99)
            if frac > lastFrac + 0.005 {
                lastFrac = frac
                progress?(frac)
                statusCallback?("Скачиваем модель саммари… \(Int(frac * 100))%")
            }
        } else if !status.isEmpty {
            statusCallback?(status)
        }
    }

    // MARK: - Errors

    enum SidecarError: LocalizedError {
        case binaryNotFound
        case binaryMissingAfterExtract
        case downloadFailed(String)
        case extractFailed(String)
        case healthTimeout
        case pullFailed(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "Движок саммари не найден. Нажмите «Скачать» ещё раз."
            case .binaryMissingAfterExtract:
                return "Не удалось распаковать Ollama."
            case .downloadFailed(let detail):
                return "Не удалось скачать движок саммари: \(detail). Нужен интернет."
            case .extractFailed(let detail):
                return "Ошибка распаковки Ollama: \(detail)"
            case .healthTimeout:
                return "Ollama не успел запуститься. Попробуйте ещё раз."
            case .pullFailed(let detail):
                return "Не удалось скачать модель: \(detail)"
            }
        }
    }
}
