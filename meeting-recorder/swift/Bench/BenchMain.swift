import Foundation

@main
enum BenchMain {
    /// Keeps a spawned gigastt child alive for the process lifetime.
    static var retainedGigastt: Process?

    static func main() async {
        defer {
            if let proc = retainedGigastt, proc.isRunning {
                proc.terminate()
                proc.waitUntilExit()
            }
            retainedGigastt = nil
        }
        do {
            try await run()
        } catch {
            fputs("ERROR: \(error)\n", stderr)
            exit(1)
        }
    }
}
