import Foundation
import Darwin
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
    ///
    /// **Raising this is three steps, not one.** The bundled tarball is slimmed
    /// (`tools/slim-ollama.sh`): the MLX runtime and the Intel CPU backends are
    /// removed, because this engine picks `llama-server` for our model and the app
    /// is arm64-only — 139 MB of bundle becomes 34. Ollama does not support that
    /// officially (ollama/ollama#7419), so the trade has to be re-verified per
    /// version:
    ///
    /// 1. re-run `tools/slim-ollama.sh` for the new tag,
    /// 2. build and generate one summary end to end,
    /// 3. confirm the engine log still says `using llama-server for model`.
    ///
    /// If it ever says MLX instead, the slim archive is no longer safe and
    /// `build.sh` must be pointed back at the full release. MLX already handles
    /// Q4_K_M in preview, which is the quantisation we use, so this is a question
    /// of when rather than whether.
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
        // Asking for the server is a declaration that something needs it, so any
        // pending idle-stop is off. Without this, a backlog of summaries killed
        // its own server: meeting one armed a 30-second stop on success, meeting
        // two started generating immediately, and the timer fired straight through
        // the middle of it — a lost minute of GPU and a retry, per meeting.
        cancelIdleStop()
        if await probeAPI() { return }
        // "A file exists" is not "the right version exists". This door asked only
        // whether the binary was there, so a raised `releaseTag` never reached anyone
        // through it — and it is the door the summary path uses (`RecapService`), which
        // is the common one: `ensureReady` runs at provisioning, this runs at every
        // recap. The same mistake `installedVersionURL` was introduced to fix
        // (see its documentation), at a different entrance.
        //
        // Killing an adopted foreign engine is not a risk here: `probeAPI` above
        // already returned for anything that answers on the port, so a version
        // mismatch at this point can only be our own unpacked copy.
        let fm = FileManager.default
        if !fm.isExecutableFile(atPath: binaryURL.path) || installedVersion != Self.releaseTag {
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
                // SIGKILL, not `interrupt()`: SIGINT is *weaker* than the SIGTERM
                // we already sent, so a process that ignored the first ignored
                // the second too and was never actually stopped.
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
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

    /// Every tag this app has ever pulled as its own default, oldest first.
    ///
    /// The history, not a list of exclusions. The previous shape — "models to delete" —
    /// knew only `qwen2.5:7b` while the default had moved on to `qwen3.5:4b`, so the
    /// next change of default would have left 3,2 GB on every disk with nothing to
    /// notice it. Forgetting a line here is the harmless direction: a tag missing from
    /// the history was never installed by us in the first place.
    ///
    /// **Append when `Preferences.defaultRecapModel` changes. Never remove a line.**
    static let shippedDefaultModels = ["qwen2.5:7b", "qwen3.5:4b"]

    /// Delete superseded default models to get the disk back.
    ///
    /// `adopt-if-present` means this may run against the user's own Ollama, so
    /// deleting there removes a model we did not install. Owner decision
    /// 2026-07-27, made with the facts: the audience is managers who have no
    /// personal Ollama, and every qwen2.5:7b in the fleet was put there by
    /// Propeller 1.11. Scope stays narrow on purpose — only tags this app once
    /// shipped as its default (`shippedDefaultModels`), never an arbitrary model
    /// someone pulled themselves.
    private func reclaimSupersededModels(keeping keep: String) async {
        let superseded = EngineHousekeeping.supersededModels(
            shippedDefaults: Self.shippedDefaultModels,
            current: keep
        )
        for stale in superseded {
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

    /// Version of the engine currently unpacked at `binaryURL`.
    ///
    /// Without this, `ensureBinaryInstalled` returned early on "a file exists"
    /// alone, so raising the pinned `releaseTag` in a new app version changed
    /// nothing for anyone who had already installed — the pin only ever applied
    /// to fresh installs.
    private var installedVersionURL: URL {
        installDir.appendingPathComponent("installed-version.txt")
    }

    private var installedVersion: String? {
        try? String(contentsOf: installedVersionURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

        if fm.isExecutableFile(atPath: binaryURL.path), installedVersion == Self.releaseTag {
            progress?(1.0)
            return
        }

        if fm.isExecutableFile(atPath: binaryURL.path) {
            // Pinned version moved. Replacing the file is not enough: a serve
            // process started from the old binary keeps running it, and
            // `adopt-if-present` would happily reuse it forever.
            NSLog("[OllamaSidecar] engine \(installedVersion ?? "unknown") → \(Self.releaseTag), replacing")
            statusCallback?("Обновляем движок саммари…")
            await stopServerRunningOurBinary()
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
        // Snapshot *before* the archive lands on top of it: afterwards there is no way
        // to tell a file the new engine brought from one the old engine left behind.
        let before = (try? fm.contentsOfDirectory(atPath: installDir.path)) ?? []
        try extractTarball(tarball, into: installDir)
        if tarball.path != bundledTarballURL?.path {
            try? fm.removeItem(at: tarball)
        }
        // Sweeping *after* the extraction, not before, is deliberate: there is never a
        // moment where the engine is missing from disk, so a failed unpack leaves the
        // old, working engine in place instead of nothing.
        sweepPreviousEngine(replacing: before, using: tarball)

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
        try? Self.releaseTag.write(to: installedVersionURL, atomically: true, encoding: .utf8)
        progress?(1.0)
        NSLog("[OllamaSidecar] binary ready at \(binaryURL.path) (\(Self.releaseTag))")
    }

    /// Stop a serve process started from *our* installed binary, so an engine
    /// upgrade actually takes effect.
    ///
    /// Matches on the executable path being exactly `binaryURL`, never on the
    /// port. This is the one case where we do reach for another process, and it
    /// stays narrow on purpose: the whole point of `adopt-if-present` is that
    /// someone else's Ollama — Ollama.app, Homebrew — is none of our business,
    /// and those live at different paths.
    private func stopServerRunningOurBinary() async {
        stop()   // our own tracked child first, if any

        let target = binaryURL.path
        var victims: [pid_t] = []
        let capacity = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard capacity > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(capacity) / MemoryLayout<pid_t>.size)
        guard proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                            Int32(pids.count * MemoryLayout<pid_t>.size)) > 0 else { return }

        for pid in pids where pid > 1 && pid != getpid() {
            var buf = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { continue }
            if String(cString: buf) == target { victims.append(pid) }
        }
        guard !victims.isEmpty else { return }

        NSLog("[OllamaSidecar] stopping old engine \(victims) before replacing it")
        for pid in victims { kill(pid, SIGTERM) }
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if !(await probeAPI()) { return }
        }
        for pid in victims { kill(pid, SIGKILL) }
        try? await Task.sleep(nanoseconds: 300_000_000)
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

    /// Delete what the previous engine version left in the install directory.
    ///
    /// Half the engine's file names carry a version — `libggml-base.0.17.0.dylib`,
    /// `libllama.0.0.1.dylib` — so raising `releaseTag` does not overwrite them, it
    /// orphans them. Measured on an installed 1.16.7: 13 of 26 entries are named that
    /// way, and nothing has ever removed one.
    ///
    /// What may go is decided by `EngineHousekeeping`, in `PropellerPure`, where a test
    /// can reach it — the decision is "delete these files off someone's disk", and the
    /// dangerous answers (the 3,4 GB of weights, the log a person would send us) are
    /// exactly the ones that would look fine here.
    private func sweepPreviousEngine(replacing before: [String], using tarball: URL) {
        guard !before.isEmpty else { return }
        let shipped = tarballTopLevelEntries(tarball)
        let stale = EngineHousekeeping.stalePaths(existing: before, shipped: shipped)
        guard !stale.isEmpty else { return }

        let fm = FileManager.default
        var reclaimed: Int64 = 0
        for name in stale {
            let url = installDir.appendingPathComponent(name)
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int64 {
                reclaimed += size
            }
            try? fm.removeItem(at: url)
        }
        NSLog("[OllamaSidecar] removed \(stale.count) file(s) from the previous engine, "
              + "\(reclaimed / 1_048_576) MB: \(stale.joined(separator: ", "))")
    }

    /// Top-level names the archive carries. Empty means "could not read it", and
    /// `EngineHousekeeping` treats that as "delete nothing" — see its documentation.
    private func tarballTopLevelEntries(_ tarball: URL) -> Set<String> {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        task.arguments = ["-tzf", tarball.path]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return [] }

        var names = Set<String>()
        for line in text.split(separator: "\n") {
            var path = String(line)
            if path.hasPrefix("./") { path.removeFirst(2) }
            guard let first = path.split(separator: "/").first, !first.isEmpty else { continue }
            names.insert(String(first))
        }
        return names
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
        // Backfill memory: the runner's prompt cache is retention we never use
        // (measured Г4 2026-08-15: +5,5 ГБ за 19 минут). Decision and numbers
        // live in `OllamaServeTuning`; llama-server inherits this env.
        env = OllamaServeTuning.apply(to: env)
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
        // Ребёнок получил свою копию дескриптора при запуске — наша больше не
        // нужна, и не закрыть её значит течь по дескриптору на каждый запуск
        // сервера. Предел на процесс — 256; до него доходят не скоро, но
        // «не скоро» это не «никогда», а лог живёт всю жизнь приложения.
        try? logHandle.close()
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

        /// Грубая корзина для телеметрии: почему движок не встал.
        ///
        /// Причина живёт рядом с ошибкой, а не в фасаде аналитики: фасад умеет
        /// только отправлять, а знает про виды отказов тот, кто их бросает.
        /// Корзины, а не `localizedDescription`: наружу не должно уехать ни
        /// байта детали — там пути, HTTP-тела и вывод `tar`.
        var signalReason: String {
            switch self {
            case .binaryNotFound:          return "binary"
            case .binaryMissingAfterExtract, .extractFailed: return "unpack"
            case .downloadFailed:          return "download"
            case .healthTimeout:           return "health"
            case .pullFailed:              return "pull"
            }
        }

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
