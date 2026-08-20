import XCTest
@testable import PropellerPure

/// The call-window speaker decision, run over recorded traces.
///
/// Named after what a person saw on the live probe run (DIARIZATION.md H12),
/// not after the functions under test. Every fixture is synthetic — written
/// by hand from the measured geometry, because a live trace carries real
/// people's names and lives outside the repository
/// (`Tests/Fixtures/ax-traces/README.md`).
final class CallWindowJournalTests: XCTestCase {

    private func trace(_ name: String) throws -> [CallWindowJournal.Poll] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // MeetingRecorderTests
            .deletingLastPathComponent()      // Tests
            .appendingPathComponent("Fixtures/ax-traces/\(name)")
        return CallWindowJournal.polls(fromJSONL: try Data(contentsOf: url))
    }

    private func tile(_ description: String, w: Double, h: Double,
                      window: String = "Zoom Meeting",
                      process: String = "zoom.us") -> CallWindowJournal.Tile {
        CallWindowJournal.Tile(role: "AXTabGroup", description: description,
                               width: w, height: h,
                               window: window, process: process)
    }

    private let levon = "Levon Lobanov, Звук компьютера включен, Video on"
    private let leva = "Лева Ловушка, Звук компьютера включен, Video off"

    // MARK: - The three §11.1 traces

    func testДвоеПоОчередиДаютДваПролётаСИменами() throws {
        // Speaker view, no labels: geometry decides. The one transition poll
        // with equal tiles is honest silence — order used to decide there and
        // was refuted on the live gallery trace (0 of 626 polls). Ends are the
        // last confirming sample: boundary coverage is the nearest-sample
        // rule's job now, not stretched ends.
        let spans = CallWindowJournal.spans(from: try trace("synthetic-two-speakers.jsonl"))
        XCTAssertEqual(spans, [
            CallWindowJournal.Span(start: 0.0, end: 2.0, name: "Levon Lobanov"),
            CallWindowJournal.Span(start: 2.8, end: 4.8, name: "Лева Ловушка"),
        ])
    }

    func testМеткаActiveSpeakerВедётЖурналВГалерее() throws {
        // The live 2026-08-20 trace: three equal tiles, exactly one per poll
        // labelled by Zoom itself. The label leads; a one-poll flicker to a
        // third person is dropped by smoothing — and no longer splits the
        // continuous turn around it: same-name samples a short gap apart fold
        // into one span (the ledger's gain over the old run-per-break rule).
        let spans = CallWindowJournal.spans(from: try trace("synthetic-gallery-marker.jsonl"))
        XCTAssertEqual(spans, [
            CallWindowJournal.Span(start: 0.0, end: 1.6, name: "Анна Пример"),
            CallWindowJournal.Span(start: 2.0, end: 5.2, name: "Борис Пример"),
            CallWindowJournal.Span(start: 5.6, end: 7.2, name: "Вера Пример"),
        ])
    }

    func testНаДемонстрацииЭкранаНаблюдательМолчит() throws {
        // No tiles, then a single floating thumbnail: nothing to compare
        // against, so nothing is claimed — the diarizer covers these seconds.
        XCTAssertEqual(CallWindowJournal.spans(from: try trace("synthetic-screen-share.jsonl")), [])
    }

    func testZoomБезВстречиЖурналПуст() throws {
        let polls = try trace("synthetic-no-meeting.jsonl")
        // The meta header is not a poll and must not crash the reader.
        XCTAssertEqual(polls.count, 5)
        XCTAssertEqual(CallWindowJournal.spans(from: polls), [])
    }

    // MARK: - Smoothing

    func testПерестановкаРавныхПлитокБезМеткиЖурналМолчит() {
        // Refuted rule, kept as a tombstone: on the live gallery trace the
        // first tile matched Zoom's own label in 0 of 626 polls. Equal tiles
        // without a label are silence — reorder them all you want.
        var polls: [CallWindowJournal.Poll] = []
        for i in 0..<5 {
            polls.append(.init(t: Double(i * 4) / 10, tiles: [
                tile(levon, w: 720, h: 400),
                tile(leva, w: 720, h: 400),
            ]))
        }
        polls.append(.init(t: 2.0, tiles: [
            tile(leva, w: 720, h: 400),
            tile(levon, w: 720, h: 400),
        ]))
        for i in 6..<11 {
            polls.append(.init(t: Double(i * 4) / 10, tiles: [
                tile(levon, w: 720, h: 400),
                tile(leva, w: 720, h: 400),
            ]))
        }
        XCTAssertEqual(CallWindowJournal.spans(from: polls), [])
    }

    func testОдиночныйВыбросПлощадиНеСоздаётПролёт() {
        var polls: [CallWindowJournal.Poll] = []
        for i in 0..<5 {
            polls.append(.init(t: Double(i * 4) / 10, tiles: [
                tile(levon, w: 1080, h: 600),
                tile(leva, w: 160, h: 80),
            ]))
        }
        // One poll mid-animation where the sizes have already crossed over.
        polls.append(.init(t: 2.0, tiles: [
            tile(leva, w: 1080, h: 600),
            tile(levon, w: 160, h: 80),
        ]))
        for i in 6..<11 {
            polls.append(.init(t: Double(i * 4) / 10, tiles: [
                tile(levon, w: 1080, h: 600),
                tile(leva, w: 160, h: 80),
            ]))
        }
        XCTAssertFalse(CallWindowJournal.spans(from: polls).contains { $0.name == "Лева Ловушка" })
    }

    // MARK: - Names

    func testУчастникПереименовалсяЖурналНеСклеиваетДвоих() {
        // The runs are keyed by name: a rename mid-meeting ends one span and
        // starts another, it never merges two names into one person.
        var polls: [CallWindowJournal.Poll] = []
        for i in 0..<6 {
            polls.append(.init(t: Double(i * 4) / 10, tiles: [
                tile(leva, w: 1080, h: 600),
                tile(levon, w: 160, h: 80),
            ]))
        }
        for i in 6..<12 {
            polls.append(.init(t: Double(i * 4) / 10, tiles: [
                tile("Лев Л., Звук компьютера включен, Video off", w: 1080, h: 600),
                tile(levon, w: 160, h: 80),
            ]))
        }
        let spans = CallWindowJournal.spans(from: polls)
        XCTAssertEqual(spans, [
            CallWindowJournal.Span(start: 0.0, end: 2.0, name: "Лева Ловушка"),
            CallWindowJournal.Span(start: 2.4, end: 4.4, name: "Лев Л."),
        ])
    }

    func testИмяЭтоПрефиксДоПервойЗапятой() {
        XCTAssertEqual(CallWindowJournal.name(fromDescription: levon), "Levon Lobanov")
        // No status tail at all: the name is still a name.
        XCTAssertEqual(CallWindowJournal.name(fromDescription: "Иван"), "Иван")
        XCTAssertEqual(CallWindowJournal.name(fromDescription: "  Иван , что-то"), "Иван")
        // A tile with no name is not a participant.
        XCTAssertNil(CallWindowJournal.name(fromDescription: ""))
        XCTAssertNil(CallWindowJournal.name(fromDescription: ", Звук компьютера включен"))
    }

    // MARK: - "Don't know" is a legal answer

    func testЗамереннаяСтрокаМьютаЛовитсяПоУмолчанию() {
        // The default marker is the measured live string (2026-08-20, RU
        // locale) — and «выключен» must not match «включен», which every
        // other test on the default tuning proves from the other side.
        var polls: [CallWindowJournal.Poll] = []
        for i in 0..<6 {
            polls.append(.init(t: Double(i * 4) / 10, tiles: [
                tile("Лева Ловушка, Звук компьютера выключен, Video off", w: 1080, h: 600),
                tile(levon, w: 160, h: 80),
            ]))
        }
        XCTAssertEqual(CallWindowJournal.spans(from: polls), [])
    }

    func testЗаглушённыйГоворящимНеСтановится() {
        // The muted veto silences the chosen candidate; it never promotes the
        // other tile — «как нет, никогда как да» (plan-speaker-tags.md §4).
        let tuning = CallWindowJournal.Tuning(mutedMarkers: ["звук выключен"])
        var polls: [CallWindowJournal.Poll] = []
        for i in 0..<6 {
            polls.append(.init(t: Double(i * 4) / 10, tiles: [
                tile("Лева Ловушка, Звук выключен, Video off", w: 1080, h: 600),
                tile(levon, w: 160, h: 80),
            ]))
        }
        XCTAssertEqual(CallWindowJournal.spans(from: polls, tuning: tuning), [])
    }

    func testПлиткиИзДвухОконОдновременноЖурналМолчит() {
        // Plan §10.1: names must never be attributed out of someone else's
        // window. Two windows both showing tiles is an ambiguity, not a race.
        var polls: [CallWindowJournal.Poll] = []
        for i in 0..<6 {
            polls.append(.init(t: Double(i * 4) / 10, tiles: [
                tile(levon, w: 1080, h: 600),
                tile(leva, w: 160, h: 80, window: "Zoom Meeting 2"),
            ]))
        }
        XCTAssertEqual(CallWindowJournal.spans(from: polls), [])
    }

    func testДвеМеткиСразуЖурналМолчит() {
        // Two tiles both claiming Zoom's label is an ambiguity, not a race.
        var polls: [CallWindowJournal.Poll] = []
        for i in 0..<6 {
            polls.append(.init(t: Double(i * 4) / 10, tiles: [
                tile(levon + ", active speaker", w: 520, h: 280),
                tile(leva + ", active speaker", w: 520, h: 280),
            ]))
        }
        XCTAssertEqual(CallWindowJournal.spans(from: polls), [])
    }

    func testОдинокаяПлиткаСМеткойДаётПролёт() {
        // The label is the app speaking, not us comparing — it stands alone.
        // Chosen, not measured: a lone labelled tile has not been seen live
        // (the minimized mini window carried no label).
        var polls: [CallWindowJournal.Poll] = []
        for i in 0..<6 {
            polls.append(.init(t: Double(i * 4) / 10, tiles: [
                tile(levon + ", active speaker", w: 320, h: 180),
            ]))
        }
        XCTAssertEqual(CallWindowJournal.spans(from: polls),
                       [CallWindowJournal.Span(start: 0.0, end: 2.0, name: "Levon Lobanov")])
    }

    func testМеткаБьётПлощадь() {
        // A stale big tile mid-transition must not outvote Zoom's own label.
        var polls: [CallWindowJournal.Poll] = []
        for i in 0..<6 {
            polls.append(.init(t: Double(i * 4) / 10, tiles: [
                tile(levon, w: 1080, h: 600),
                tile(leva + ", active speaker", w: 160, h: 80),
            ]))
        }
        XCTAssertEqual(CallWindowJournal.spans(from: polls),
                       [CallWindowJournal.Span(start: 0.0, end: 2.0, name: "Лева Ловушка")])
    }

    func testМеткаНаЗаглушённомЖурналМолчит() {
        // The muted veto outranks even the label — «как нет, никогда как да».
        let tuning = CallWindowJournal.Tuning(mutedMarkers: ["звук выключен"])
        var polls: [CallWindowJournal.Poll] = []
        for i in 0..<6 {
            polls.append(.init(t: Double(i * 4) / 10, tiles: [
                tile("Лева Ловушка, Звук выключен, Video off, active speaker", w: 520, h: 280),
                tile(levon, w: 520, h: 280),
            ]))
        }
        XCTAssertEqual(CallWindowJournal.spans(from: polls, tuning: tuning), [])
    }

    func testСпорнаяВершинаПлощадиЖурналМолчит() {
        // Two equally big tiles above the spread threshold: the area signal
        // fired but does not name a single person — silence, not a coin toss.
        var polls: [CallWindowJournal.Poll] = []
        for i in 0..<6 {
            polls.append(.init(t: Double(i * 4) / 10, tiles: [
                tile(levon, w: 1080, h: 600),
                tile(leva, w: 1080, h: 600),
                tile("Гость, Звук компьютера включен, Video off", w: 160, h: 80),
            ]))
        }
        XCTAssertEqual(CallWindowJournal.spans(from: polls), [])
    }

    func testСтрокиПанелиНеГолосуютЗаГоворящего() {
        // Panel rows are roster, not speech: a panel left open must not turn
        // its first row into the speaker.
        var polls: [CallWindowJournal.Poll] = []
        for i in 0..<6 {
            polls.append(.init(t: Double(i * 4) / 10, tiles: [
                CallWindowJournal.Tile(role: "AXRow", description: "Лева Ловушка (Организатор, я)",
                                       width: 300, height: 40,
                                       window: "Zoom Meeting", process: "zoom.us"),
                CallWindowJournal.Tile(role: "AXRow", description: "Levon Lobanov",
                                       width: 300, height: 40,
                                       window: "Zoom Meeting", process: "zoom.us"),
            ]))
        }
        XCTAssertEqual(CallWindowJournal.spans(from: polls), [])
    }

    func testМолчаниеНазываетПричину() {
        // Telemetry must distinguish a dual-monitor Zoom from an empty desk.
        func reason(_ tiles: [CallWindowJournal.Tile]) -> CallWindowJournal.Silence? {
            if case .silent(let r) = CallWindowJournal.verdict(in: .init(t: 0, tiles: tiles)) {
                return r
            }
            return nil
        }
        XCTAssertEqual(reason([]), .noTiles)
        XCTAssertEqual(reason([tile(levon, w: 320, h: 180)]), .noLabel)
        XCTAssertEqual(reason([tile(levon, w: 520, h: 280),
                               tile(leva, w: 520, h: 280, window: "Zoom Meeting 2")]),
                       .twoWindows)
        XCTAssertEqual(reason([tile(levon + ", active speaker", w: 520, h: 280),
                               tile(leva + ", active speaker", w: 520, h: 280)]),
                       .twoLabels)
        XCTAssertEqual(reason([tile(levon, w: 720, h: 400),
                               tile(leva, w: 720, h: 400)]),
                       .noLabel)
        XCTAssertEqual(reason([tile(levon, w: 1080, h: 600),
                               tile(leva, w: 1080, h: 600),
                               tile("Гость, Звук", w: 160, h: 80)]),
                       .noLabel)
        if case .silent(let r) = CallWindowJournal.verdict(
            in: .init(t: 0, tiles: [
                tile("Лева Ловушка, Звук выключен, active speaker", w: 520, h: 280),
                tile(levon, w: 520, h: 280),
            ]),
            tuning: CallWindowJournal.Tuning(mutedMarkers: ["звук выключен"])) {
            XCTAssertEqual(r, .muted)
        } else {
            XCTFail("заглушённый кандидат обязан дать причину muted")
        }
    }

    // MARK: - The live machine

    /// A meeting in miniature: the owner speaks first (locks his tile), then
    /// the far side takes over.
    private func warmedMachine() -> CallWindowJournal.LiveSpeaker {
        var live = CallWindowJournal.LiveSpeaker()
        for i in 0..<40 {
            live.take(.init(t: Double(i * 4) / 10, tiles: [
                tile(levon + ", active speaker", w: 520, h: 280),
                tile(leva, w: 520, h: 280),
            ]))
        }
        live.noteOwnerTurn(start: 0.0, end: 16.0)
        return live
    }

    func testЖивоеИмяПоявляетсяТолькоПослеОпознанияВладельца() {
        var live = CallWindowJournal.LiveSpeaker()
        // Far side speaks from the first second — but nobody has co-spoken
        // with the mic yet, so the line stays unnamed rather than risk the
        // owner's own tile.
        for i in 0..<10 {
            live.take(.init(t: Double(i * 4) / 10, tiles: [
                tile(leva + ", active speaker", w: 520, h: 280),
                tile(levon, w: 520, h: 280),
            ]))
        }
        XCTAssertNil(live.name(at: 2.0))
    }

    func testПослеОпознанияЧужаяСтрокаПолучаетИмяАВладелецНикогда() {
        var live = warmedMachine()
        for i in 40..<60 {
            live.take(.init(t: Double(i * 4) / 10, tiles: [
                tile(leva + ", active speaker", w: 520, h: 280),
                tile(levon, w: 520, h: 280),
            ]))
        }
        // A far line finalized around second 20 gets the far name...
        XCTAssertEqual(live.name(at: 20.0), "Лева Ловушка")
        // ...and the owner's own tile never reaches a line, even at a second
        // where it held the label.
        XCTAssertNil(live.name(at: 8.0))
    }

    func testЖивойВыбросНаОдинОпросИмениНеМеняет() {
        var live = warmedMachine()
        for i in 40..<50 {
            live.take(.init(t: Double(i * 4) / 10, tiles: [
                tile(leva + ", active speaker", w: 520, h: 280),
                tile(levon, w: 520, h: 280),
            ]))
        }
        // One glitch poll flips the label; smoothing must not let it through.
        live.take(.init(t: 20.4, tiles: [
            tile("Гость, Звук, active speaker", w: 520, h: 280),
            tile(leva, w: 520, h: 280),
        ]))
        for i in 52..<56 {
            live.take(.init(t: Double(i * 4) / 10, tiles: [
                tile(leva + ", active speaker", w: 520, h: 280),
                tile(levon, w: 520, h: 280),
            ]))
        }
        XCTAssertEqual(live.name(at: 20.4), "Лева Ловушка")
    }

    func testВдалиОтПоследнегоОпросаМашинкаМолчит() {
        let live = warmedMachine()
        // The buffer knows nothing about second 500 — no guessing.
        XCTAssertNil(live.name(at: 500.0))
    }

    // MARK: - The 1×1 shortcut (sole companion)

    private func pairPolls(_ owner: String, _ other: String, count: Int,
                           from start: Int = 0) -> [CallWindowJournal.Poll] {
        (start..<(start + count)).map { i in
            .init(t: Double(i * 4) / 10, tiles: [
                tile(owner + ", Звук компьютера включен, Video on", w: 608, h: 342),
                tile(other + ", Звук компьютера включен, Video off", w: 608, h: 342),
            ])
        }
    }

    func testНаОдинОдинВтораяПлиткаНазываетСобеседника() {
        // The measured class (20260820_213214): two equal tiles, zero labels
        // for the whole meeting — the roster answers where no speaking signal
        // exists. Mini-window polls don't vote either way.
        var polls = pairPolls("Levon Lobanov", "Лева Ловушка", count: 40)
        polls.append(.init(t: 16.0, tiles: [tile(levon, w: 320, h: 180)]))
        XCTAssertEqual(
            CallWindowJournal.soleCompanion(polls: polls, ownerZoomName: "Levon Lobanov"),
            "Лева Ловушка"
        )
    }

    func testТретийУчастникВыключаетСоставнуюПодпись() {
        var polls = pairPolls("Levon Lobanov", "Лева Ловушка", count: 40)
        polls.append(.init(t: 16.0, tiles: [
            tile(levon, w: 608, h: 342),
            tile(leva, w: 608, h: 342),
            tile("Гость, Звук компьютера включен, Video off", w: 608, h: 342),
        ]))
        XCTAssertNil(CallWindowJournal.soleCompanion(polls: polls, ownerZoomName: "Levon Lobanov"))
    }

    func testПереименованиеСобеседникаВыключаетСоставнуюПодпись() {
        var polls = pairPolls("Levon Lobanov", "Лева Ловушка", count: 40)
        polls += pairPolls("Levon Lobanov", "Лев Л.", count: 10, from: 40)
        XCTAssertNil(CallWindowJournal.soleCompanion(polls: polls, ownerZoomName: "Levon Lobanov"))
    }

    func testБезЯкоряВладельцаСоставнаяПодписьМолчит() {
        let polls = pairPolls("Levon Lobanov", "Лева Ловушка", count: 40)
        XCTAssertNil(CallWindowJournal.soleCompanion(polls: polls, ownerZoomName: nil))
        // Пара без владельца — чужая встреча рядом, не наша.
        XCTAssertNil(CallWindowJournal.soleCompanion(polls: polls, ownerZoomName: "Кто-То Ещё"))
    }

    func testМалоУликСоставнаяПодписьМолчит() {
        let polls = pairPolls("Levon Lobanov", "Лева Ловушка", count: 10)
        XCTAssertNil(CallWindowJournal.soleCompanion(polls: polls, ownerZoomName: "Levon Lobanov"))
    }

    // MARK: - Applying the journal to a transcript

    func testКороткоеПерекрытиеГостяНеДелаетЕгоВладельцем() {
        // The measured trap (simplification review 2026-08-20): on a 70 s
        // prefix of a live meeting, share alone (0.625 on 7 s of overlap)
        // crowned a guest as the owner and erased her name from the feed.
        // The evidence floor is what stands between that and us.
        var live = CallWindowJournal.LiveSpeaker()
        // A guest's tile briefly co-occurs with the owner's mic (echo).
        for i in 0..<10 {
            live.take(.init(t: Double(i * 4) / 10, tiles: [
                tile(leva + ", active speaker", w: 520, h: 280),
                tile(levon, w: 520, h: 280),
            ]))
        }
        live.noteOwnerTurn(start: 0.0, end: 4.0)
        // High share, thin evidence: nobody is crowned.
        XCTAssertNil(live.ownerZoomName)
        XCTAssertNil(live.name(at: 2.0))
        // The owner then actually speaks long enough — his own tile takes the
        // label, evidence accumulates, and the lock lands on him.
        for i in 10..<50 {
            live.take(.init(t: Double(i * 4) / 10, tiles: [
                tile(levon + ", active speaker", w: 520, h: 280),
                tile(leva, w: 520, h: 280),
            ]))
        }
        live.noteOwnerTurn(start: 4.0, end: 20.0)
        XCTAssertEqual(live.ownerZoomName, "Levon Lobanov")
    }

    func testНовыйСлучайАтрибуцииПризнаётсяПроИсточник() throws {
        XCTAssertEqual(SpeakerAttribution.callWindow.rawValue, "callWindow")
        XCTAssertNotNil(SpeakerAttribution.callWindow.disclosure)
        // The value survives its round trip through the index on disk.
        let decoded = try JSONDecoder().decode(SpeakerAttribution.self,
                                               from: Data("\"callWindow\"".utf8))
        XCTAssertEqual(decoded, .callWindow)
    }

    func testТрассаОкнаСтираетсяВместеСоВстречей() {
        // Names of real people on disk: the trace must be a known kind of
        // trace, or erasure's completeness test cannot see it.
        XCTAssertEqual(MeetingErasure.kind(of: "20260820_100315.calltrace.jsonl",
                                           for: "20260820_100315"),
                       .callWindowTrace)
        XCTAssertTrue(MeetingErasure.belongs("20260820_100315.calltrace.jsonl",
                                             to: "20260820_100315"))
    }

    func testРваныйХвостТрассыНеРоняетЧтение() {
        // A killed probe leaves a torn last line; the recording must survive.
        let jsonl = """
        {"meta":{"note":"x"}}
        {"t":0.0,"tiles":[]}
        {"t":0.4,"tiles":[]}
        {"t":0.8,"til
        """
        XCTAssertEqual(CallWindowJournal.polls(fromJSONL: Data(jsonl.utf8)).count, 2)
    }
}
