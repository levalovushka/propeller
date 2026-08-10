import Foundation

@main
enum BenchMain {
    /// Keeps a spawned gigastt child alive for the process lifetime.
    static var retainedGigastt: Process?
    /// A background-QoS sidecar is spawned with posix_spawn, so it is a bare pid
    /// rather than a Process (`--bg-asr`).
    static var backgroundGigastt: pid_t?

    static func main() async {
        defer {
            if let proc = retainedGigastt, proc.isRunning {
                proc.terminate()
                proc.waitUntilExit()
            }
            retainedGigastt = nil
            if let pid = backgroundGigastt { kill(pid, SIGTERM) }
            backgroundGigastt = nil
        }
        do {
            try await run()
        } catch {
            fputs("ERROR: \(error)\n", stderr)
            exit(1)
        }
    }
}
