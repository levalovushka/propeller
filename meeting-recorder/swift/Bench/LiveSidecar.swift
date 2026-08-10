import Foundation

/// A gigastt of our own, on our own port, spawned with the app's flags.
///
/// Its own process for two reasons. The measurement needs a pid — the cost of a
/// live transcript is spent inside the sidecar, not here (`ProcessCost`) — and
/// attaching to whichever server happens to be up would meter the app's traffic
/// alongside the harness's.
///
/// The flags are copied from `Sources/GigasttSidecar.swift:327`, and copied
/// on purpose: `--pool-size 2` is what makes two concurrent sessions possible
/// instead of one waiting behind the other, so a run with a different pool size
/// measures a different product. When that file changes, change this list.
final class LiveSidecar {
    let pid: pid_t
    private let process: Process

    private init(process: Process) {
        self.process = process
        self.pid = process.processIdentifier
    }

    static func start(port: Int, poolSize: Int = 2) async throws -> LiveSidecar {
        if let existing = try? await LiveHealth.probe(port: port), existing {
            throw BenchError.portBusy(port)
        }

        let binary = try resolveGigasttBinary()
        let modelDir = resolveGigasttModelDir()
        let logURL = modelDir.deletingLastPathComponent()
            .appendingPathComponent("live-bench-gigastt-serve.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)

        var arguments = [
            "serve",
            "--model-dir", modelDir.path,
            "--model-variant", "e2e_rnnt",
            "--port", "\(port)",
            "--pool-size", "\(poolSize)",
            "--max-session-secs", "28800",
            "--inference-timeout-secs", "0",
            "--hotwords-default",
            "--offline",
        ]
        // The app always passes a hotwords file when it can write one, and
        // hotwords change what the engine does per portion. Measuring without
        // them would measure a configuration nobody ships.
        let hotwords = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Meeting Recorder/hotwords.txt")
        if FileManager.default.fileExists(atPath: hotwords.path) {
            arguments += ["--hotwords-file", hotwords.path]
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        try process.run()

        print("gigastt pid \(process.processIdentifier) on port \(port) — log: \(logURL.path)")
        for _ in 0..<180 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            guard process.isRunning else { throw BenchError.sidecarTimeout }
            if let healthy = try? await LiveHealth.probe(port: port), healthy {
                return LiveSidecar(process: process)
            }
        }
        process.terminate()
        throw BenchError.sidecarTimeout
    }

    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }
}

enum LiveHealth {
    /// True when a server on this port is up *and* done loading.
    static func probe(port: Int) async throws -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        request.timeoutInterval = 3
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return false
        }
        struct Health: Decodable { let model: String? }
        let health = try? JSONDecoder().decode(Health.self, from: data)
        return health?.model != "loading"
    }
}
