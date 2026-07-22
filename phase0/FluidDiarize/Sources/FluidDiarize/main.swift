// Minimal FluidAudio-only diarization harness for Phase 0.
// Usage (from this directory):
//   swift run -c release FluidDiarize /path/to/audio.wav
import Foundation
import FluidAudio

@main
struct FluidDiarize {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            fputs("Usage: FluidDiarize <audio.wav>\n", stderr)
            exit(2)
        }
        let url = URL(fileURLWithPath: args[1])
        guard FileManager.default.fileExists(atPath: url.path) else {
            fputs("File not found: \(url.path)\n", stderr)
            exit(2)
        }

        print("Loading OfflineDiarizerManager…")
        let config = OfflineDiarizerConfig()
        let diarizer = OfflineDiarizerManager(config: config)
        do {
            try await diarizer.prepareModels()
        } catch {
            fputs("prepareModels failed: \(error)\n", stderr)
            exit(1)
        }

        print("Diarizing \(url.lastPathComponent)…")
        let started = Date()
        do {
            let result = try await diarizer.process(url)
            let elapsed = Date().timeIntervalSince(started)
            print("Done in \(String(format: "%.1f", elapsed))s")
            print("segments=\(result.segments.count)")

            var counts: [String: Int] = [:]
            var durations: [String: Double] = [:]
            for seg in result.segments {
                counts[seg.speakerId, default: 0] += 1
                durations[seg.speakerId, default: 0] += Double(seg.endTimeSeconds - seg.startTimeSeconds)
            }
            print("speakers=\(counts.count)")
            for (id, c) in counts.sorted(by: { durations[$0.key, default: 0] > durations[$1.key, default: 0] }) {
                let dur = durations[id, default: 0]
                print("  \(id) segs=\(c) dur=\(String(format: "%.1f", dur))s")
            }

            // JSON dump next to wav in phase0/
            let outURL = URL(fileURLWithPath: "/Users/levonlobanov/Desktop/Propeller/phase0/talat_fluidaudio.json")
            var payload: [[String: Any]] = []
            for seg in result.segments {
                payload.append([
                    "speakerId": seg.speakerId,
                    "start": seg.startTimeSeconds,
                    "end": seg.endTimeSeconds,
                    "qualityScore": seg.qualityScore,
                ])
            }
            let data = try JSONSerialization.data(withJSONObject: [
                "elapsed_s": elapsed,
                "speaker_counts": counts,
                "speaker_durations": durations,
                "segments": payload,
            ], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: outURL)
            print("wrote \(outURL.path)")

            print("\nFirst 15 segments:")
            for seg in result.segments.prefix(15) {
                print(String(
                    format: "  [%5.1f-%5.1f] \(seg.speakerId) q=%.2f",
                    seg.startTimeSeconds,
                    seg.endTimeSeconds,
                    seg.qualityScore
                ))
            }
        } catch {
            fputs("diarize failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
