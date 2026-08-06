import AVFoundation
import SwiftUI
import PropellerUI

/// Full-width waveform player for the meeting detail view (talat-style).
/// Draws downsampled peaks, fills the played portion with the accent color,
/// and supports click/drag-to-seek. Peaks are loaded in chunks so hour-long
/// recordings don't get read into memory at once.
struct WaveformScrubber: View {
    @ObservedObject var player: AudioPlayer
    let audioURL: URL?

    @State private var peaks: [Float] = []
    @State private var loadedPath: String?

    var body: some View {
        HStack(spacing: 12) {
            playButton

            VStack(spacing: 2) {
                waveform
                    .frame(height: 36)

                HStack {
                    Text(player.currentTimeFormatted)
                    Spacer()
                    Text(player.totalDurationFormatted)
                }
                .typo(Tokens.Typography.Label.xsMedium, monospacedDigit: true)
                .foregroundStyle(.tertiary)
            }
        }
    }

    private var playButton: some View {
        Button {
            if player.isPlaying {
                player.pause()
            } else if player.progress > 0 && player.progress < 1 {
                player.resume()
            } else if let url = audioURL {
                player.play(url: url)
            }
        } label: {
            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.plain)
        .disabled(audioURL == nil)
    }

    private var waveform: some View {
        GeometryReader { geo in
            let progress = max(0, min(1, player.progress))

            Canvas { ctx, size in
                let mid = size.height / 2
                if peaks.isEmpty {
                    // Placeholder line while peaks load (or when audio is gone).
                    let rect = CGRect(x: 0, y: mid - 1, width: size.width, height: 2)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(.secondary.opacity(0.2)))
                    return
                }
                let slot = size.width / CGFloat(peaks.count)
                let barWidth = max(1.0, slot * 0.65)
                let playedX = size.width * progress
                for (i, p) in peaks.enumerated() {
                    let h = max(2.0, CGFloat(p) * size.height)
                    let x = CGFloat(i) * slot + (slot - barWidth) / 2
                    let rect = CGRect(x: x, y: mid - h / 2, width: barWidth, height: h)
                    let played = x + barWidth / 2 <= playedX
                    ctx.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .color(played ? .accentColor : .secondary.opacity(0.3))
                    )
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard let url = audioURL else { return }
                if player.totalDuration <= 0 {
                    player.load(url: url)
                }
                guard player.totalDuration > 0 else { return }
                let fraction = value.location.x / geo.size.width
                player.seek(to: max(0, min(1, fraction)))
            })
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .task(id: audioURL?.path ?? "") {
                guard let url = audioURL else {
                    peaks = []
                    loadedPath = nil
                    return
                }
                guard loadedPath != url.path else { return }
                let target = max(80, Int(geo.size.width / 4))
                peaks = await Self.loadPeaksChunked(url: url, target: target)
                loadedPath = url.path
            }
        }
    }

    /// Chunked peak extraction: reads the file in ~1M-frame blocks so long
    /// meeting recordings never occupy full-length buffers.
    static func loadPeaksChunked(url: URL, target: Int) async -> [Float] {
        await Task.detached(priority: .utility) { () -> [Float] in
            guard let file = try? AVAudioFile(forReading: url) else { return [] }
            let totalFrames = Int(file.length)
            guard totalFrames > 0 else { return [] }

            let bucketSize = max(1, totalFrames / target)
            let fmt = file.processingFormat
            let chunkFrames: AVAudioFrameCount = 1 << 20
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunkFrames) else { return [] }

            var peaks: [Float] = []
            peaks.reserveCapacity(target + 1)
            var currentPeak: Float = 0
            var framesInBucket = 0

            while file.framePosition < file.length {
                do { try file.read(into: buf, frameCount: chunkFrames) } catch { break }
                guard let channel = buf.floatChannelData?[0] else { break }
                let n = Int(buf.frameLength)
                if n == 0 { break }
                for k in 0..<n {
                    let v = abs(channel[k])
                    if v > currentPeak { currentPeak = v }
                    framesInBucket += 1
                    if framesInBucket >= bucketSize {
                        peaks.append(currentPeak)
                        currentPeak = 0
                        framesInBucket = 0
                    }
                }
            }
            if framesInBucket > 0 { peaks.append(currentPeak) }

            let maxP = peaks.max() ?? 1
            if maxP > 0 {
                peaks = peaks.map { $0 / maxP }
            }
            return peaks
        }.value
    }
}
