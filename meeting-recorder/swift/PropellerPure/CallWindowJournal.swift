import Foundation

/// Who is speaking this second — decided over recorded snapshots of the call
/// window's accessibility tree, never over the live tree itself.
///
/// The observer that polls Zoom (plan-speaker-tags.md §4) answers exactly one
/// question and this type is that answer's whole logic: polls go in, one
/// **ledger of confirmed samples** `(t, name)` accumulates, and both consumers
/// read the same ledger — the live transcript asks `name(at:)` while the
/// meeting runs, the offline pass asks the same question per remark, and the
/// journal file gets `spans` derived from it. One smoothing, one owner rule,
/// no second implementation to drift (simplification review 2026-08-20:
/// two smoothings had already drifted 3.8 % apart).
///
/// Silence is a legal answer. When the tiles are gone (screen share collapse,
/// no meeting), no tile carries Zoom's label and the areas don't separate, or
/// two windows both claim tiles, no name is given: a gap is better than an
/// invented name, the same rule as plan-people.md §5.
public enum CallWindowJournal {

    // MARK: - Input: one trace of tree polls

    /// One tile (or participant-panel row) as the probe saw it.
    ///
    /// Field names are the wire contract with `axprobe trace` and
    /// `CallWindowObserver`. Old traces may carry an `order` field — it
    /// belonged to the refuted first-tile rule and decodes into nothing.
    public struct Tile: Codable, Equatable, Sendable {
        /// AX role: a video tile is `AXTabGroup`, a panel row is `AXRow`.
        /// Only tiles vote for the speaker; rows are roster, not speech.
        public let role: String
        /// The whole `AXDescription`: `"Name, audio state, video state"`.
        public let description: String
        /// Raw size in points, un-rounded.
        public let width: Double
        public let height: Double
        /// Window title, only ever compared to itself.
        public let window: String
        /// Owning process name (`zoom.us`).
        public let process: String

        public init(role: String, description: String, width: Double, height: Double,
                    window: String, process: String) {
            self.role = role
            self.description = description
            self.width = width
            self.height = height
            self.window = window
            self.process = process
        }
    }

    /// One poll of the tree.
    public struct Poll: Codable, Equatable, Sendable {
        /// Seconds since the recording's own clock started (the observer
        /// anchors on the recorder, not on the wall).
        public let t: Double
        public let tiles: [Tile]

        public init(t: Double, tiles: [Tile]) {
            self.t = t
            self.tiles = tiles
        }
    }

    /// One journal entry, derived from the ledger for the file and the lab:
    /// `name` was confirmed from `start` to `end`.
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

    /// Decision parameters. Defaults marked **measured** carry a live number;
    /// the rest are chosen (plan-speaker-tags.md §3).
    public struct Tuning: Sendable {
        /// How many times larger the biggest tile must be than the smallest
        /// for area to count as the signal — the speaker-view path, where
        /// Zoom writes no label (measured 2026-08-19: 1080×600 vs 160×80 and
        /// zero labels in the tree). Gallery tiles are strictly equal
        /// (measured 2026-08-20: max/min spread exactly 1.00 across 16 581
        /// polls), so this never misfires there. The 40 pt snapping grid this
        /// used to carry is gone: the ratio absorbs animation jitter on its
        /// own — within-poll size spread measured zero.
        public var areaSpreadRatio: Double
        /// How many consecutive polls a candidate must survive before a
        /// sample is written. Chosen: one poll is a layout animation.
        public var minRunPolls: Int
        /// Substrings of the status tail that mean "microphone muted",
        /// lowercase — a veto on the chosen candidate, never a promotion.
        /// **Measured** (2026-08-20, RU locale): `«Звук компьютера выключен»`;
        /// the same traces show Zoom never labels a muted tile (0 of 16 226),
        /// so this is a second lock on a door the app already keeps shut.
        /// Other locales unmeasured (Н8 narrowed, not closed).
        public var mutedMarkers: [String]
        /// Substrings that mean "this tile is the active speaker" — Zoom's
        /// own explicit label, the strongest signal there is. **Measured**
        /// 2026-08-20: exactly one labelled tile per poll in gallery and
        /// screen-share views, English suffix under a RU locale.
        public var speakerMarkers: [String]
        /// Всё, чем описание плитки заканчивается **вместо имени**, lowercase.
        ///
        /// Нужно ровно для одного: отделить имя от хвоста, когда в самом имени
        /// есть запятая. Список — из замера (`plan-speaker-tags.md` §1:
        /// `«Лева Ловушка, Звук компьютера включен, Video off»`) плюс третий
        /// маркер из трассы 2026-08-20 (`звуковое устройство не подключено`,
        /// 3 опроса). Локали, кроме RU, не мерены — и это **не страшно**: если ни
        /// один маркер не совпал, разбор откатывается на «до первой запятой», то
        /// есть на прежнее поведение. Хуже, чем было, стать не может.
        public var stateMarkers: [String]

        public init(areaSpreadRatio: Double = 2.0,
                    minRunPolls: Int = 2,
                    mutedMarkers: [String] = ["звук компьютера выключен"],
                    speakerMarkers: [String] = ["active speaker"],
                    stateMarkers: [String] = [
                        "звук компьютера включен",
                        "звук компьютера выключен",
                        "звуковое устройство не подключено",
                        "video on",
                        "video off",
                        "active speaker",
                    ]) {
            self.areaSpreadRatio = areaSpreadRatio
            self.minRunPolls = minRunPolls
            self.mutedMarkers = mutedMarkers
            self.speakerMarkers = speakerMarkers
            self.stateMarkers = stateMarkers
        }
    }

    // MARK: - Name parsing

    /// Имя участника: описание плитки без хвоста состояния.
    ///
    /// Считается **с конца**, а не «до первой запятой»: запятая — законный символ
    /// в display name («Иванов, Иван»), и прежнее правило резало такое имя до
    /// фамилии, а двое однофамильцев склеивались под одной подписью (Н11).
    /// Отрезаются только куски, совпадающие с `Tuning.stateMarkers`.
    ///
    /// **Если не совпал ни один — откат на прежнее правило.** Так локаль, которую
    /// не мерили, не превращает маркеры в часть имени: она просто получает то же
    /// поведение, что и до 2026-08-21. Прежний принцип («смена локализации ломает
    /// маркер, а не имя») этим сохранён.
    public static func name(
        fromDescription description: String, tuning: Tuning = Tuning()
    ) -> String? {
        let parts = description.split(
            separator: ",", omittingEmptySubsequences: false
        ).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var kept = parts
        while let last = kept.last, kept.count > 1, isStateMarker(last, tuning: tuning) {
            kept.removeLast()
        }
        let stripped = parts.count - kept.count

        // Имя из одного куска — старое и новое правило совпадают, спорить не о чем.
        // Имя с запятой — это утверждение, и оно требует доказательства: в
        // замеренном формате хвост несёт **и звук, и видео**
        // (`plan-speaker-tags.md` §1), то есть минимум два маркера. Опознан один —
        // значит локаль разобрана наполовину, и «John Smith, Computer audio on»
        // приехало бы именем; в этом случае откат на прежнее «до первой запятой».
        // Ошибаться безопасно только в эту сторону.
        let name = (kept.count > 1 && stripped < 2)
            ? (parts.first ?? "")
            : kept.joined(separator: ", ")
        return name.isEmpty ? nil : name
    }

    private static func isStateMarker(_ part: String, tuning: Tuning) -> Bool {
        let lowered = part.lowercased()
        return tuning.stateMarkers.contains { lowered.contains($0) }
    }

    /// Everything after the first comma.
    static func statusTail(ofDescription description: String) -> String {
        guard let comma = description.firstIndex(of: ",") else { return "" }
        return String(description[description.index(after: comma)...])
    }

    // MARK: - Trace decoding

    /// Reads a JSONL trace: one poll per line. Lines that are not polls (the
    /// meta header, the torn tail of a killed run) are skipped — a trace is
    /// a recording, and a torn last line must not cost it.
    public static func polls(fromJSONL data: Data) -> [Poll] {
        let decoder = JSONDecoder()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { try? decoder.decode(Poll.self, from: Data($0.utf8)) }
    }

    // MARK: - Decision

    /// Why a poll yielded no name. Five reasons, each earning its keep in
    /// telemetry or a named risk: a dual-monitor Zoom (`twoWindows`, Н9) must
    /// not read as an empty desk (`noTiles`), and a double label (`twoLabels`,
    /// Н10) must not read as a missing one (`noLabel`).
    public enum Silence: String, Codable, CaseIterable, Sendable {
        /// No named video tiles at all (no meeting, share without a strip).
        case noTiles
        /// Named tiles in two windows at once (dual monitor, foreign window).
        case twoWindows
        /// Two tiles both carrying the speaker label.
        case twoLabels
        /// Tiles exist but nothing separates a speaker: no label, and the
        /// areas don't spread (equal gallery tiles, a lone mini-window tile,
        /// a tied top).
        case noLabel
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
    /// 1. **Zoom's own label** (gallery, screen share, three-plus people):
    ///    exactly one labelled tile wins outright, even alone in its window —
    ///    the label is the app speaking, not us comparing.
    /// 2. **Geometry** (speaker view, where Zoom writes no label — measured
    ///    2026-08-19): the biggest tile, when the area spread clears the
    ///    threshold and the top is unique.
    ///
    /// There is deliberately no third rule: "first tile speaks" was refuted
    /// live (0 of 626 polls), and equal unlabelled tiles are silence.
    public static func verdict(in poll: Poll, tuning: Tuning = Tuning()) -> Verdict {
        verdict(named: namedTiles(in: poll, tuning: tuning), tuning: tuning)
    }

    /// Участники опроса: плитки, из описания которых удалось прочитать имя.
    ///
    /// Одно место, где живёт правило «что считается плиткой участника»: у него
    /// три читателя (вердикт, ледгер мьюта, роспись пары), и раньше каждый
    /// выбирал плитки сам — причём один из трёх забывал передать `tuning`, так
    /// что при нестандартных маркерах одна плитка получала два разных имени.
    static func namedTiles(in poll: Poll, tuning: Tuning) -> [(name: String, tile: Tile)] {
        poll.tiles.compactMap { tile in
            guard tile.role == "AXTabGroup",
                  let name = name(fromDescription: tile.description, tuning: tuning)
            else { return nil }
            return (name, tile)
        }
    }

    /// Вердикт по уже выбранным участникам — чтобы вызывающий, которому список
    /// нужен и для себя, не разбирал описания плиток дважды за опрос.
    static func verdict(named: [(name: String, tile: Tile)], tuning: Tuning) -> Verdict {
        guard !named.isEmpty else { return .silent(.noTiles) }
        guard Set(named.map { $0.tile.process + "\u{1}" + $0.tile.window }).count == 1 else {
            return .silent(.twoWindows)
        }

        let chosen: (name: String, tile: Tile)
        let labelled = named.filter {
            CallWindowJournal.tailContains($0.tile, anyOf: tuning.speakerMarkers)
        }
        if labelled.count == 1 {
            chosen = labelled[0]
        } else if labelled.count > 1 {
            return .silent(.twoLabels)
        } else {
            guard named.count >= 2 else { return .silent(.noLabel) }
            let areas = named.map { $0.tile.width * $0.tile.height }
            let maxArea = areas.max() ?? 0
            let minArea = areas.min() ?? 0
            guard minArea > 0, maxArea / minArea >= tuning.areaSpreadRatio else {
                return .silent(.noLabel)
            }
            let biggest = zip(named, areas).filter { $0.1 == maxArea }.map { $0.0 }
            guard biggest.count == 1 else { return .silent(.noLabel) }
            chosen = biggest[0]
        }

        // The veto: a muted candidate yields silence, never a different name.
        if CallWindowJournal.tailContains(chosen.tile, anyOf: tuning.mutedMarkers) {
            return .silent(.muted)
        }
        return .speaker(chosen.name)
    }

    /// Совпал ли хвост описания плитки с каким-нибудь из маркеров.
    ///
    /// Хвост не разбирается на структуру — только сравнивается подстроками, —
    /// поэтому смена локализации Zoom ломает маркер, а не имя.
    static func tailContains(_ tile: Tile, anyOf markers: [String]) -> Bool {
        let tail = statusTail(ofDescription: tile.description).lowercased()
        return markers.contains { !$0.isEmpty && tail.contains($0.lowercased()) }
    }

    // MARK: - The machine: one ledger for live and batch

    /// Polls go in one at a time; a ledger of confirmed samples accumulates;
    /// every consumer reads the ledger. The live transcript asks `name(at:)`
    /// while the meeting runs, the offline pass asks the same question per
    /// remark, and the journal file takes `spans`.
    ///
    /// Honesty rules:
    ///
    /// - **Smoothing**: a name must survive `minRunPolls` consecutive polls
    ///   before a sample is written — one poll is a layout animation.
    /// - **The owner's tile is found, never asked.** The journal names the
    ///   owner too, but the transcript's owner turns are already attributed
    ///   by the microphone — the stronger fact. The name whose samples
    ///   co-occur with the owner's turns (share ≥ `ownerMinShare` over at
    ///   least `ownerMinEvidencePolls` overlapping polls) is the owner's tile
    ///   and never reaches a far-side line. Both floors are load-bearing:
    ///   without the evidence floor, a 70-second prefix of a live meeting
    ///   measurably crowned the wrong person (share 0.625 on 7 seconds); the
    ///   share floor holds a measured 0.75-vs-0.28 gap between the owner and
    ///   everyone else. Once locked, never revisited.
    /// - **A name is given once, at ask time** — the live layer's promise
    ///   that shown text is never rewritten extends to the label.
    public struct LiveSpeaker {
        private let tuning: Tuning
        private let ownerMinShare: Double
        private let ownerMinEvidencePolls: Int
        /// Nearest-sample reach for `name(at:)`. Chosen: the effective poll
        /// step is ~0.45 s (measured), so one second spans two misses.
        private let nameWindow: Double

        private var runName: String?
        private var runPolls = 0
        /// The ledger. An 80-minute meeting is ~11 000 samples — no pruning.
        private var samples: [(t: Double, name: String)] = []
        private var totalPolls: [String: Int] = [:]
        private var overlapPolls: [String: Int] = [:]
        private var ownerTurns: [(start: Double, end: Double)] = []
        private var lockedOwner: String?
        /// Время каждого опроса — чтобы «не знаю» отличалось от «не был выключен».
        /// Одно `Double` на опрос: 80-минутная встреча это ~11 000 чисел.
        private var pollTimes: [Double] = []
        /// Только выключенные плитки, по имени и времени. Хранить включённые
        /// незачем: вопрос всегда «был ли выключен», а «не найдено» при живом
        /// опросе рядом и означает «не был».
        private var mutedTiles: [(t: Double, name: String)] = []

        public init(tuning: Tuning = Tuning(),
                    ownerMinShare: Double = 0.5,
                    ownerMinEvidencePolls: Int = 25,
                    nameWindow: Double = 1.0) {
            self.tuning = tuning
            self.ownerMinShare = ownerMinShare
            self.ownerMinEvidencePolls = ownerMinEvidencePolls
            self.nameWindow = nameWindow
        }

        /// The unconfirmed head of the current run: written into the ledger
        /// retroactively the moment the run survives `minRunPolls`, so a
        /// confirmed run is credited from its first poll — the batch and the
        /// live path used to differ by exactly this (−3.8 % named seconds,
        /// measured), and now cannot.
        private var pending: [(t: Double, name: String)] = []

        public mutating func take(_ poll: Poll) {
            pollTimes.append(poll.t)
            let named = CallWindowJournal.namedTiles(in: poll, tuning: tuning)
            for (name, tile) in named
            where CallWindowJournal.tailContains(tile, anyOf: tuning.mutedMarkers) {
                mutedTiles.append((t: poll.t, name: name))
            }

            var name: String?
            if case .speaker(let n) = CallWindowJournal.verdict(named: named, tuning: tuning) {
                name = n
            }
            if let name, name == runName {
                runPolls += 1
            } else {
                runName = name
                runPolls = name == nil ? 0 : 1
                pending.removeAll()
            }
            guard let name else { return }
            pending.append((t: poll.t, name: name))
            guard runPolls >= tuning.minRunPolls else { return }

            for sample in pending {
                samples.append(sample)
                totalPolls[sample.name, default: 0] += 1
                if ownerTurns.contains(where: { sample.t >= $0.start && sample.t <= $0.end }) {
                    overlapPolls[sample.name, default: 0] += 1
                }
            }
            pending.removeAll()
            lockOwnerIfEvident()
        }

        /// The owner's mic turns arrive late — a line finalizes seconds after
        /// the speech — so overlap is credited retroactively from the ledger,
        /// and the turn is kept for polls still to come.
        public mutating func noteOwnerTurn(start: Double, end: Double) {
            ownerTurns.append((start, end))
            for sample in samples where sample.t >= start && sample.t <= end {
                overlapPolls[sample.name, default: 0] += 1
            }
            lockOwnerIfEvident()
        }

        /// The owner's Zoom display name, once the correlation is evident.
        public var ownerZoomName: String? { lockedOwner }

        /// Был ли микрофон владельца выключен в звонилке около секунды `t`.
        ///
        /// `nil` — «не знаю», и это законный ответ: замок владельца ещё не
        /// защёлкнулся, или опросов рядом с этой секундой нет вовсе. Отличать
        /// «не знаю» от «не был выключен» обязательно: на первом можно только
        /// молчать, на втором — утверждать.
        ///
        /// Зачем это вообще. Замерено 2026-08-20: из 23 реплик владельца в ленте
        /// **21 сказана при выключенной в Zoom плитке** — человек в этот момент
        /// на встрече молчал, а расшифровка его цитирует. Микрофон Мака слышит
        /// его всегда, мьют живёт только в звонилке. Здесь пока лишь **знание**:
        /// что с такой репликой делать — отдельный шаг, и до живой проверки
        /// фильтровать саммари этим нельзя, иначе ложный мьют съест настоящую речь.
        public func ownerMuted(at t: Double) -> Bool? {
            guard let lockedOwner else { return nil }
            guard let nearestPoll = pollTimes.min(by: { abs($0 - t) < abs($1 - t) }),
                  abs(nearestPoll - t) <= nameWindow else { return nil }
            return mutedTiles.contains {
                $0.name == lockedOwner && abs($0.t - t) <= nameWindow
            }
        }

        /// Доля реплик владельца, сказанных при выключенной плитке, и сколько их
        /// удалось рассудить. Для лога и для следующего замера — одна строка вместо
        /// пересчёта руками.
        public var ownerMutedTurnShare: (muted: Int, judged: Int) {
            var muted = 0, judged = 0
            for turn in ownerTurns {
                guard let isMuted = ownerMuted(at: (turn.start + turn.end) / 2) else { continue }
                judged += 1
                if isMuted { muted += 1 }
            }
            return (muted, judged)
        }

        /// Who was speaking around second `t`, owner excluded; nil = don't
        /// know, and the caller keeps whatever label it had.
        ///
        /// Names flow only after the owner's tile is locked: until then any
        /// name could be the owner's own, and a doubled owner is worse than
        /// an unnamed first minute. A meeting where the owner never speaks
        /// therefore never names lines — honestly.
        public func name(at t: Double) -> String? {
            guard let lockedOwner else { return nil }
            let nearest = samples.min { abs($0.t - t) < abs($1.t - t) }
            guard let nearest, abs(nearest.t - t) <= nameWindow else { return nil }
            if nearest.name == lockedOwner { return nil }
            return nearest.name
        }

        /// The ledger folded into spans, for the journal file and the lab.
        /// A run breaks on a name change or a gap wider than `maxGap`; ends
        /// are the last sample's time — no stretching, the nearest-sample
        /// rule covers boundaries better than stretched ends did (measured:
        /// 98.6 % agreement, and the differences favour the ledger).
        public func spans(maxGap: Double = 1.0) -> [Span] {
            var out: [Span] = []
            for sample in samples {
                if let last = out.last, last.name == sample.name,
                   sample.t - last.end <= maxGap {
                    out[out.count - 1] = Span(start: last.start, end: sample.t, name: last.name)
                } else {
                    out.append(Span(start: sample.t, end: sample.t, name: sample.name))
                }
            }
            return out
        }

        private mutating func lockOwnerIfEvident() {
            guard lockedOwner == nil else { return }
            let best = overlapPolls
                .compactMap { name, polls -> (name: String, share: Double, polls: Int)? in
                    guard let total = totalPolls[name], total > 0 else { return nil }
                    return (name, Double(polls) / Double(total), polls)
                }
                .max { $0.share < $1.share }
            guard let best, best.polls >= ownerMinEvidencePolls, best.share >= ownerMinShare
            else { return }
            lockedOwner = best.name
        }
    }

    // MARK: - Batch conveniences over the same machine

    /// Trace → journal spans. The journal file keeps every name including the
    /// owner's — exclusion is the transcript's business, not the file's.
    public static func spans(from polls: [Poll], tuning: Tuning = Tuning()) -> [Span] {
        var machine = LiveSpeaker(tuning: tuning)
        for poll in polls.sorted(by: { $0.t < $1.t }) { machine.take(poll) }
        return machine.spans()
    }

    /// The 1×1 shortcut: when the whole trace shows exactly two named tiles —
    /// the owner's and one other, constant — the far side is one person, and
    /// every far-side remark carries that name **without any speaking signal**.
    ///
    /// Measured need (2026-08-20, `20260820_213214`): a two-tile gallery
    /// carries zero `active speaker` labels across the whole meeting and both
    /// tiles are equal — the per-second journal is silent by construction
    /// there, yet the roster answer is certain. This is the most common
    /// meeting class in the archive.
    ///
    /// Strict by design, silence on any doubt: a third named tile in any
    /// poll, a companion that changes name mid-meeting (rename — an honest
    /// no), a pair that does not contain the owner, or fewer than `minPolls`
    /// qualifying polls (~13 s of evidence, chosen) — all return nil.
    /// Polls with fewer than two named tiles (mini window, screen share
    /// collapse) don't vote either way.
    public static func soleCompanion(
        polls: [Poll],
        ownerZoomName: String?,
        minPolls: Int = 30
    ) -> String? {
        guard let ownerZoomName else { return nil }
        var companion: String?
        var qualifying = 0
        for poll in polls {
            let names = Set(namedTiles(in: poll, tuning: Tuning()).map(\.name))
            guard names.count >= 2 else { continue }
            guard names.count == 2, names.contains(ownerZoomName),
                  let other = names.first(where: { $0 != ownerZoomName })
            else { return nil }
            if let companion, companion != other { return nil }
            companion = other
            qualifying += 1
        }
        return qualifying >= minPolls ? companion : nil
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
