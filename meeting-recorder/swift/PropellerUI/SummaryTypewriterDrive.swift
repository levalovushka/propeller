import AppKit
import QuartzCore
import PropellerPure

/// Runs a soft typewriter on an `NSTextView` via temporary foreground colours.
///
/// Storage stays intact — only `NSLayoutManager` temporary attributes change —
/// so ⌘Z, restyle, and markdown round-trips are unaffected. One session at a
/// time: a new run cancels the previous.
final class SummaryTypewriterDrive {
    private weak var textView: NSTextView?
    private var timer: Timer?
    private var generation = 0

    init(textView: NSTextView) {
        self.textView = textView
    }

    deinit { timer?.invalidate() }

    func cancel() {
        timer?.invalidate()
        timer = nil
        generation += 1
    }

    /// Snap to a pose without animating.
    func snap(range: NSRange, progress: Double, colour: NSColor) {
        cancel()
        apply(range: range, progress: progress, colour: colour)
    }

    /// Clear typewriter temporary colours over `range` (or the whole doc).
    func clear(range: NSRange? = nil) {
        cancel()
        guard let layout = textView?.layoutManager else { return }
        let whole = range ?? NSRange(location: 0, length: (textView?.string as NSString?)?.length ?? 0)
        guard whole.length > 0 else { return }
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
        invalidate(range: whole)
    }

    /// Animate `progress` from…to over `duration`. Calls `completion` on the
    /// main queue when finished (or immediately if duration is 0 / reduce motion).
    func animate(
        range: NSRange,
        from start: Double,
        to end: Double,
        duration: TimeInterval,
        colour: NSColor,
        reduceMotion: Bool,
        completion: (@MainActor () -> Void)? = nil
    ) {
        cancel()
        let gen = generation
        guard range.length > 0, let textView, textView.layoutManager != nil else {
            Task { @MainActor in completion?() }
            return
        }
        if reduceMotion || duration <= 0 {
            apply(range: range, progress: end, colour: colour)
            Task { @MainActor in completion?() }
            return
        }

        apply(range: range, progress: start, colour: colour)
        let started = CACurrentMediaTime()
        // Linear head — ease-out made the first letters slam on and read as
        // chunky. A steady crawl with a wide soft edge is the soft typewriter.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self, self.generation == gen else {
                t.invalidate()
                return
            }
            let u = min(1, (CACurrentMediaTime() - started) / duration)
            self.apply(range: range, progress: start + (end - start) * u, colour: colour)
            if u >= 1 {
                t.invalidate()
                self.timer = nil
                Task { @MainActor in completion?() }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - Paint

    private func apply(range: NSRange, progress: Double, colour: NSColor) {
        guard let textView, let layout = textView.layoutManager else { return }
        let end = (textView.string as NSString).length
        guard range.location >= 0, NSMaxRange(range) <= end, range.length > 0 else { return }

        let count = range.length
        let soft = Tokens.Pane.Reveal.softChars
        // Three runs: fully on, soft ramp (one attr per char — the ramp is
        // short), fully off. Avoids a hard step every few glyphs.
        var i = 0
        while i < count {
            let a = SummaryTypewriter.alpha(
                at: i, count: count, progress: progress, softness: soft
            )
            if a <= 0.001 || a >= 0.999 {
                var j = i + 1
                while j < count {
                    let b = SummaryTypewriter.alpha(
                        at: j, count: count, progress: progress, softness: soft
                    )
                    if a <= 0.001 ? b > 0.001 : b < 0.999 { break }
                    j += 1
                }
                let sub = NSRange(location: range.location + i, length: j - i)
                layout.addTemporaryAttribute(
                    .foregroundColor,
                    value: a <= 0.001 ? colour.withAlphaComponent(0) : colour,
                    forCharacterRange: sub
                )
                i = j
            } else {
                layout.addTemporaryAttribute(
                    .foregroundColor,
                    value: colour.withAlphaComponent(a),
                    forCharacterRange: NSRange(location: range.location + i, length: 1)
                )
                i += 1
            }
        }
        invalidate(range: range)
    }

    private func invalidate(range: NSRange) {
        guard let textView, let layout = textView.layoutManager else { return }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        if glyphs.length > 0 {
            layout.invalidateDisplay(forGlyphRange: glyphs)
        }
        textView.needsDisplay = true
    }
}
