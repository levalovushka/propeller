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
        /// to promote anyone else (§4: «как нет, никогда как да»). Empty by
        /// default: no live muted string has been measured yet, and guessing
        /// one risks vetoing a speaker over a localization coincidence.
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
                    mutedMarkers: [String] = [],
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

    /// The candidate speaker of one poll, or nil for "don't know".
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
    /// Nil is also returned for: no tiles, a lone unlabelled tile (a mini
    /// window after minimizing, a screen-share thumbnail), tiles from two
    /// windows at once (plan §10.1: never attribute names from someone
    /// else's window), or a chosen candidate whose tail says the microphone
    /// is off.
    static func candidate(in poll: Poll, tuning: Tuning) -> String? {
        let named: [(name: String, tile: Tile)] = poll.tiles.compactMap { tile in
            guard tile.role == "AXTabGroup",
                  let name = name(fromDescription: tile.description) else { return nil }
            return (name, tile)
        }
        guard !named.isEmpty else { return nil }
        guard Set(named.map { $0.tile.process + "\u{1}" + $0.tile.window }).count == 1 else {
            return nil
        }

        func tail(_ tile: Tile) -> String {
            statusTail(ofDescription: tile.description).lowercased()
        }
        func tailContains(_ tile: Tile, anyOf markers: [String]) -> Bool {
            markers.contains { !$0.isEmpty && tail(tile).contains($0.lowercased()) }
        }

        let chosen: (name: String, tile: Tile)?
        let labelled = named.filter { tailContains($0.tile, anyOf: tuning.speakerMarkers) }
        if labelled.count == 1 {
            chosen = labelled[0]
        } else if labelled.count > 1 {
            chosen = nil
        } else {
            // No label — the speaker-view path: geometry needs a comparison.
            guard named.count >= 2 else { return nil }
            func snappedArea(_ tile: Tile) -> Double {
                let step = max(tuning.areaGridStep, 1)
                let w = (tile.width / step).rounded(.down) * step
                let h = (tile.height / step).rounded(.down) * step
                return w * h
            }
            let areas = named.map { snappedArea($0.tile) }
            let maxArea = areas.max() ?? 0
            let minArea = areas.min() ?? 0
            if minArea > 0, maxArea / minArea >= tuning.areaSpreadRatio {
                let biggest = zip(named, areas).filter { $0.1 == maxArea }.map { $0.0 }
                chosen = biggest.count == 1 ? biggest[0] : nil
            } else {
                chosen = nil
            }
        }
        guard let chosen else { return nil }

        // The veto: a muted candidate yields silence, never a different name.
        let tail = statusTail(ofDescription: chosen.tile.description).lowercased()
        if tuning.mutedMarkers.contains(where: { !$0.isEmpty && tail.contains($0.lowercased()) }) {
            return nil
        }
        return chosen.name
    }

    /// Trace → journal. A span is emitted only after the same name survives
    /// `minRunPolls` consecutive polls; a one-poll winner is what a layout
    /// animation produces and is dropped whole. Names key the runs, so a
    /// participant renaming mid-meeting starts a new span instead of gluing
    /// two people into one.
    public static func spans(from polls: [Poll], tuning: Tuning = Tuning()) -> [Span] {
        var out: [Span] = []
        var runName: String?
        var runStart = 0.0
        var runEnd = 0.0
        var runPolls = 0

        func flush() {
            if let name = runName, runPolls >= tuning.minRunPolls {
                out.append(Span(start: runStart, end: runEnd, name: name))
            }
            runName = nil
            runPolls = 0
        }

        for poll in polls.sorted(by: { $0.t < $1.t }) {
            let candidate = candidate(in: poll, tuning: tuning)
            if let candidate, candidate == runName {
                runEnd = poll.t
                runPolls += 1
            } else {
                flush()
                if let candidate {
                    runName = candidate
                    runStart = poll.t
                    runEnd = poll.t
                    runPolls = 1
                }
            }
        }
        flush()
        return out
    }
}
