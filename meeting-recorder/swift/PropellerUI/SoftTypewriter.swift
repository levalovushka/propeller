import SwiftUI
import QuartzCore
import PropellerPure

/// Soft typewriter paint + a small driver for SwiftUI status lines.
///
/// Same math as the summary editor (`SummaryTypewriter`). On a string change:
/// dismiss the old words, then appear the new. Used by the sidebar phase line.
enum SoftTypewriter {

    static func paint(
        _ text: String, color: Color, progress: Double, softness: Double
    ) -> AttributedString {
        guard !text.isEmpty else { return AttributedString() }
        var out = AttributedString()
        let chars = Array(text)
        let count = chars.count
        for (i, ch) in chars.enumerated() {
            var piece = AttributedString(String(ch))
            let a = SummaryTypewriter.alpha(
                at: i, count: count, progress: progress, softness: softness
            )
            piece.foregroundColor = color.opacity(a)
            out.append(piece)
        }
        return out
    }
}

/// Owns `displayed` / `progress` for one status line. Call `play(to:)` when the
/// phase string changes; read `displayed` + `progress` to paint. Main-thread only.
final class SoftTypewriterSession: ObservableObject {
    @Published private(set) var displayed: String
    @Published private(set) var progress: Double = 1

    private var generation = 0
    private var timer: Timer?

    private let softChars: Double
    private let appearSecondsPerChar: Double
    private let appearMin: Double
    private let appearMax: Double
    private let dismissSecondsPerChar: Double
    private let dismissMin: Double
    private let dismissMax: Double

    init(
        initial: String = "",
        softChars: Double = Tokens.Sidebar.StatusReveal.softChars,
        appearSecondsPerChar: Double = Tokens.Sidebar.StatusReveal.appearSecondsPerChar,
        appearMin: Double = Tokens.Sidebar.StatusReveal.appearMin,
        appearMax: Double = Tokens.Sidebar.StatusReveal.appearMax,
        dismissSecondsPerChar: Double = Tokens.Sidebar.StatusReveal.dismissSecondsPerChar,
        dismissMin: Double = Tokens.Sidebar.StatusReveal.dismissMin,
        dismissMax: Double = Tokens.Sidebar.StatusReveal.dismissMax
    ) {
        self.displayed = initial
        self.softChars = softChars
        self.appearSecondsPerChar = appearSecondsPerChar
        self.appearMin = appearMin
        self.appearMax = appearMax
        self.dismissSecondsPerChar = dismissSecondsPerChar
        self.dismissMin = dismissMin
        self.dismissMax = dismissMax
    }

    deinit { timer?.invalidate() }

    func snap(to text: String) {
        timer?.invalidate()
        timer = nil
        generation += 1
        displayed = text
        progress = 1
    }

    func play(to new: String, animated: Bool) {
        if !animated || new == displayed {
            snap(to: new)
            return
        }
        generation += 1
        let gen = generation
        let dismissDuration = SummaryTypewriter.duration(
            count: displayed.count,
            secondsPerChar: dismissSecondsPerChar,
            minimum: dismissMin,
            maximum: dismissMax
        )
        let appearDuration = SummaryTypewriter.duration(
            count: new.count,
            secondsPerChar: appearSecondsPerChar,
            minimum: appearMin,
            maximum: appearMax
        )
        animate(from: progress, to: 0, duration: dismissDuration, generation: gen) { [weak self] in
            guard let self, self.generation == gen else { return }
            self.displayed = new
            self.progress = 0
            self.animate(from: 0, to: 1, duration: appearDuration, generation: gen) {}
        }
    }

    private func animate(
        from start: Double,
        to end: Double,
        duration: TimeInterval,
        generation gen: Int,
        done: @escaping () -> Void
    ) {
        timer?.invalidate()
        if duration <= 0 {
            progress = end
            done()
            return
        }
        let started = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self, self.generation == gen else {
                t.invalidate()
                return
            }
            let u = min(1, (CACurrentMediaTime() - started) / duration)
            self.progress = start + (end - start) * u
            if u >= 1 {
                t.invalidate()
                self.timer = nil
                done()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
