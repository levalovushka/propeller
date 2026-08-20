import Foundation

/// Who is speaking this second — decided over recorded snapshots of the call
/// window's accessibility tree, never over the live tree itself.
///
/// The observer that polls Zoom (plan-speaker-tags.md §4) answers exactly one
/// question and this type is that answer's whole logic: a trace of polls goes
/// in, a journal of spans `(start, end, name)` comes out. Nothing here imports
/// AppKit or ApplicationServices — the live half is a thin shell that feeds
/// this function, and every rule below is reachable from a test with a JSONL
/// fixture (`Tests/Fixtures/ax-traces/`).
///
/// Silence is a legal answer. When the tiles are gone (screen share), no tile
/// carries Zoom's `active speaker` label and the areas don't separate, or two
/// windows both claim tiles, no span is emitted: a gap is better than an
/// invented name, the same rule as plan-people.md §5.
public enum CallWindowJournal {

    // MARK: - Input: one trace of tree polls

    /// One tile (or participant-panel row) as the probe saw it.
    ///
    /// Field names are the wire contract with `axprobe trace` — the probe
    /// writes these exact keys, one JSON object per poll per line.
    public struct Tile: Codable, Equatable, Sendable {
        /// AX role: a video tile is `AXTabGroup`, a panel row is `AXRow`.
        /// Only tiles vote for the speaker; rows are roster, not speech.
        public let role: String
        /// The whole `AXDescription`: `"Name, audio state, video state"`.
        public let description: String
        /// Raw size in points, un-rounded — snapping to the grid is this
        /// decision's job, so a test can reach it.
        public let width: Double
        public let height: Double
        /// Place among siblings in its window, 1-based.
        public let order: Int
        /// Window title, only ever compared to itself.
        public let window: String
        /// Owning process name (`zoom.us`).
        public let process: String

        public init(role: String, description: String, width: Double, height: Double,
                    order: Int, window: String, process: String) {
            self.role = role
            self.description = description
            self.width = width
            self.height = height
            self.order = order
            self.window = window
            self.process = process
        }
    }

    /// One poll of the tree.
    public struct Poll: Codable, Equatable, Sendable {
        /// Seconds since the trace started.
        public let t: Double
        public let tiles: [Tile]

        public init(t: Double, tiles: [Tile]) {
            self.t = t
            self.tiles = tiles
        }
    }

    /// One journal entry: `name` was speaking from `start` to `end`,
    /// in trace seconds. Same shape the merge rule already consumes
    /// (`DiarizationMerge.speakerLabel(forMidpoint:)`).
    public struct Span: Codable, Equatable, Sendable {
        public let start: Double
        public let end: Double
        public let name: String

        public init(start: Double, end: Double, name: String) {
            self.start = start
            self.end = end
            self.name = name
        }
    }

    // MARK: - Tuning

    /// Decision parameters. Every default below is **chosen, not measured** —
    /// which values ship (and whether this ships at all) is what gate Г0
    /// answers (plan-speaker-tags.md §3). Only `areaGridStep` is a measurement.
    public struct Tuning: Sendable {
        /// Grid step for snapping tile sides, pt. Measured (DIARIZATION.md
        /// H12): a small↔big state change moves hundreds of points, layout
        /// animation inside one state moves units.
        public var areaGridStep: Double
        /// How many times larger the biggest tile must be than the smallest
        /// for area to count as the signal. Below this the tile order decides.
        /// Chosen: measured spread was 50× (1080×600 vs 160×80), equal-size
        /// polls are exactly 1×, so anything in between separates the two.
        public var areaSpreadRatio: Double
        /// How many consecutive polls a candidate must survive before a span
        /// is emitted. Chosen: one poll is what a layout animation looks like.
        public var minRunPolls: Int
        /// Substrings of the status tail that mean "microphone muted",
        /// lowercase. Applied only as a veto on the chosen candidate — never
        /// to promote anyone else (§4: «как нет, никогда как да»). The default
        /// is **measured** (2026-08-20, live meeting, RU locale): a muted tile
        /// reads `«Имя, Звук компьютера выключен, Video off»`, and the same
        /// trace showed Zoom never puts its speaker label on a muted tile —
        /// so this veto is a second lock on a door the app already keeps
        /// shut. Other locales are unmeasured (Н8 narrowed, not closed).
        public var mutedMarkers: [String]
        /// Substrings of the status tail that mean "this tile is the active
        /// speaker" — Zoom's own explicit label, the strongest signal there
        /// is. **Measured 2026-08-20** on a live three-person gallery-view
        /// meeting (Zoom 7.x, Russian interface): exactly one tile per poll
        /// ended with `…, active speaker`, in English despite the RU locale.
        /// One Zoom version measured; the suffix may not survive others.
        public var speakerMarkers: [String]

        public init(areaGridStep: Double = 40,
                    areaSpreadRatio: Double = 2.0,
                    minRunPolls: Int = 2,
                    mutedMarkers: [String] = ["звук компьютера выключен"],
                    speakerMarkers: [String] = ["active speaker"]) {
            self.areaGridStep = areaGridStep
            self.areaSpreadRatio = areaSpreadRatio
            self.minRunPolls = minRunPolls
            self.mutedMarkers = mutedMarkers
            self.speakerMarkers = speakerMarkers
        }
    }

    // MARK: - Name parsing

    /// Participant name: the `AXDescription` prefix up to the first comma.
    /// The tail (audio/video state) is never interpreted for meaning here, so
    /// a Zoom localization change breaks the tail's reading, not the name.
    public static func name(fromDescription description: String) -> String? {
        let head = description.split(separator: ",", maxSplits: 1,
                                     omittingEmptySubsequences: false).first ?? ""
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Everything after the first comma — compared to itself and matched
    /// against `mutedMarkers`, never parsed for structure.
    static func statusTail(ofDescription description: String) -> String {
        guard let comma = description.firstIndex(of: ",") else { return "" }
        return String(description[description.index(after: comma)...])
    }

    // MARK: - Trace decoding

    /// Reads a JSONL trace: one poll per line. Lines that are not polls (the
    /// probe's meta header, truncated tails of a killed run) are skipped —
    /// a trace is a lab recording, and a torn last line must not cost it.
    public static func polls(fromJSONL data: Data) -> [Poll] {
        let decoder = JSONDecoder()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { try? decoder.decode(Poll.self, from: Data($0.utf8)) }
    }

    // MARK: - Decision

    /// Why a poll yielded no name. Silence is a legal answer, but an
    /// unexplained one is invisible to telemetry (§8.4 wants "how often did
    /// the observer say it found no tiles") and to the lab — a dual-monitor
    /// Zoom that never speaks must not look like an empty desk.
    public enum Silence: String, Codable, CaseIterable, Sendable {
        /// No named video tiles at all (screen share, no meeting).
        case noTiles
        /// One unlabelled tile — nothing to compare against (mini window
        /// after minimizing, a floating thumbnail).
        case loneTile
        /// Named tiles in two windows at once (dual monitor, foreign window).
        case twoWindows
        /// Two tiles both carrying the speaker label.
        case twoLabels
        /// No label and the area spread below threshold (gallery view).
        case flatAreas
        /// The area signal fired but the top is shared.
        case areaTie
        /// The chosen candidate's tail matched a muted marker.
        case muted
    }

    public enum Verdict: Equatable, Sendable {
        case speaker(String)
        case silent(Silence)
    }

    /// The verdict of one poll: a name, or a reasoned "don't know".
    ///
    /// Two signals, in measured order of trust:
    ///
    /// 1. **Zoom's own label.** A tile whose status tail says `active speaker`
    ///    (measured live 2026-08-20, gallery view: exactly one per poll).
    ///    Exactly one labelled tile wins outright — even alone in its window,
    ///    because the label is the app speaking, not us comparing. Two labels
    ///    at once is an ambiguity, not a race: silence.
    /// 2. **Geometry** (measured 2026-08-19, speaker view): the biggest tile,
    ///    when the area spread clears the threshold and the top is unique.
    ///
    /// There is deliberately no third rule. "First tile speaks" was in the
    /// plan and is refuted: on the live gallery trace the first tile matched
    /// the label in **0 of 626 polls** — it would have signed a whole meeting
    /// with the wrong names. Equal tiles without a label are silence.
    ///
    /// Silence is returned with its reason: no tiles, a lone unlabelled tile
    /// (a mini window after minimizing, a screen-share thumbnail), tiles from
    /// two windows at once (plan §10.1: never attribute names from someone
    /// else's window), two labels, a flat or tied geometry, or a chosen
    /// candidate whose tail says the microphone is off.
    public static func verdict(in poll: Poll, tuning: Tuning = Tuning()) -> Verdict {
        let named: [(name: String, tile: Tile)] = poll.tiles.compactMap { tile in
            guard tile.role == "AXTabGroup",
                  let name = name(fromDescription: tile.description) else { return nil }
            return (name, tile)
        }
        guard !named.isEmpty else { return .silent(.noTiles) }
        guard Set(named.map { $0.tile.process + "\u{1}" + $0.tile.window }).count == 1 else {
            return .silent(.twoWindows)
        }

        func tailContains(_ tile: Tile, anyOf markers: [String]) -> Bool {
            let tail = statusTail(ofDescription: tile.description).lowercased()
            return markers.contains { !$0.isEmpty && tail.contains($0.lowercased()) }
        }

        let chosen: (name: String, tile: Tile)
        let labelled = named.filter { tailContains($0.tile, anyOf: tuning.speakerMarkers) }
        if labelled.count == 1 {
            chosen = labelled[0]
        } else if labelled.count > 1 {
            return .silent(.twoLabels)
        } else {
            // No label — the speaker-view path: geometry needs a comparison.
            guard named.count >= 2 else { return .silent(.loneTile) }
            func snappedArea(_ tile: Tile) -> Double {
                let step = max(tuning.areaGridStep, 1)
                let w = (tile.width / step).rounded(.down) * step
                let h = (tile.height / step).rounded(.down) * step
                return w * h
            }
            let areas = named.map { snappedArea($0.tile) }
            let maxArea = areas.max() ?? 0
            let minArea = areas.min() ?? 0
            guard minArea > 0, maxArea / minArea >= tuning.areaSpreadRatio else {
                return .silent(.flatAreas)
            }
            let biggest = zip(named, areas).filter { $0.1 == maxArea }.map { $0.0 }
            guard biggest.count == 1 else { return .silent(.areaTie) }
            chosen = biggest[0]
        }

        // The veto: a muted candidate yields silence, never a different name.
        if tailContains(chosen.tile, anyOf: tuning.mutedMarkers) {
            return .silent(.muted)
        }
        return .speaker(chosen.name)
    }

    /// Trace → journal. A span is emitted only after the same name survives
    /// `minRunPolls` consecutive polls; a one-poll winner is what a layout
    /// animation produces and is dropped whole. Names key the runs, so a
    /// participant renaming mid-meeting starts a new span instead of gluing
    /// two people into one.
    ///
    /// A span's end is stretched past its last confirming poll by half the
    /// gap to the poll that broke the run, capped at half a poll step: the
    /// speech was observed *until the change*, not until the last look, and
    /// closing at the last look shaved up to one step per span — enough to
    /// read as coverage lost to the meeting when it was lost to the ruler.
    /// The half is chosen, not measured; a run ended by the trace itself is
    /// not stretched.
    public static func spans(from polls: [Poll], tuning: Tuning = Tuning()) -> [Span] {
        let sorted = polls.sorted { $0.t < $1.t }
        let deltas = zip(sorted.dropFirst(), sorted).map { $0.t - $1.t }.filter { $0 > 0 }.sorted()
        let step = deltas.isEmpty ? 0 : deltas[deltas.count / 2]

        var out: [Span] = []
        var runName: String?
        var runStart = 0.0
        var runEnd = 0.0
        var runPolls = 0

        func flush(breakAt: Double?) {
            if let name = runName, runPolls >= tuning.minRunPolls {
                var end = runEnd
                if let breakAt { end += min(breakAt - runEnd, step) / 2 }
                out.append(Span(start: runStart, end: end, name: name))
            }
            runName = nil
            runPolls = 0
        }

        for poll in sorted {
            var name: String?
            if case .speaker(let n) = verdict(in: poll, tuning: tuning) { name = n }
            if let name, name == runName {
                runEnd = poll.t
                runPolls += 1
            } else {
                flush(breakAt: poll.t)
                if let name {
                    runName = name
                    runStart = poll.t
                    runEnd = poll.t
                    runPolls = 1
                }
            }
        }
        flush(breakAt: nil)
        return out
    }

    // MARK: - Applying the journal to a transcript

    /// The owner's Zoom display name, found by correlation — never asked.
    ///
    /// The journal names everyone including the owner, but the transcript's
    /// owner turns are already attributed by the microphone stem, which is
    /// the stronger fact. The journal name whose spans co-occur with the
    /// owner's own turns is the owner's tile (measured 2026-08-20: 94.6 %
    /// agreement on 221 s of speech); it must never reach the feed, or the
    /// owner splits into two people («Левон» and «Levon Lobanov»).
    /// `minShare` is chosen, not measured: below it no name is claimed.
    public static func ownerZoomName(
        spans: [Span],
        ownerTurns: [(start: Double, end: Double)],
        minShare: Double = 0.5
    ) -> String? {
        var overlap: [String: Double] = [:]
        var total: [String: Double] = [:]
        for span in spans {
            total[span.name, default: 0] += span.end - span.start
            for turn in ownerTurns {
                let shared = min(span.end, turn.end) - max(span.start, turn.start)
                if shared > 0 { overlap[span.name, default: 0] += shared }
            }
        }
        let best = overlap
            .compactMap { name, seconds -> (String, Double)? in
                guard let t = total[name], t > 0 else { return nil }
                return (name, seconds / t)
            }
            .max { $0.1 < $1.1 }
        guard let best, best.1 >= minShare else { return nil }
        return best.0
    }

    /// The journal's answer for one far-side remark, by the same midpoint
    /// rule the merge already uses — or nil, and the caller keeps whatever
    /// label it had (diarization covers the journal's silence).
    ///
    /// The owner's Zoom name answers nil too: a far-side remark the journal
    /// attributes to the owner is an overlap or an echo, and «Speaker N» is
    /// honest where a wrong name would not be.
    public static func remoteLabel(
        midpoint: Double,
        spans: [Span],
        excludingOwner ownerZoomName: String?
    ) -> String? {
        guard let span = spans.first(where: { midpoint >= $0.start && midpoint <= $0.end })
        else { return nil }
        if let ownerZoomName, span.name == ownerZoomName { return nil }
        return span.name
    }

    /// How often the observer stayed silent, by reason — the lab preview of
    /// the §8.4 telemetry.
    public static func silenceCounts(from polls: [Poll],
                                     tuning: Tuning = Tuning()) -> [Silence: Int] {
        var out: [Silence: Int] = [:]
        for poll in polls {
            if case .silent(let reason) = verdict(in: poll, tuning: tuning) {
                out[reason, default: 0] += 1
            }
        }
        return out
    }
}
