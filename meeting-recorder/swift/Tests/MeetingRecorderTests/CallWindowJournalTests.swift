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

    private func tile(_ description: String, w: Double, h: Double, order: Int,
                      window: String = "Zoom Meeting",
                      process: String = "zoom.us") -> CallWindowJournal.Tile {
        CallWindowJournal.Tile(role: "AXTabGroup", description: description,
                               width: w, height: h, order: order,
                               window: window, process: process)
    }

    private let levon = "Levon Lobanov, Звук компьютера включен, Video on"
    private let leva = "Лева Ловушка, Звук компьютера включен, Video off"

    // MARK: - The three §11.1 traces

    func testДвоеПоОчередиДаютДваПролётаСИменами() throws {
        let spans = CallWindowJournal.spans(from: try trace("synthetic-two-speakers.jsonl"))
        XCTAssertEqual(spans, [
            CallWindowJournal.Span(start: 0.0, end: 2.0, name: "Levon Lobanov"),
            CallWindowJournal.Span(start: 2.4, end: 4.8, name: "Лева Ловушка"),
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

    func testПерестановкаПлитокБезРечиНеСоздаётРеплику() {
        // Measured on the live run: tiles reorder at equal sizes even before
        // the view switches. One poll of a swapped order is layout animation,
        // not a remark.
        var polls: [CallWindowJournal.Poll] = []
        for i in 0..<5 {
            polls.append(.init(t: Double(i) * 0.4, tiles: [
                tile(levon, w: 720, h: 400, order: 1),
                tile(leva, w: 720, h: 400, order: 2),
            ]))
        }
        polls.append(.init(t: 2.0, tiles: [
            tile(leva, w: 720, h: 400, order: 1),
            tile(levon, w: 720, h: 400, order: 2),
        ]))
        for i in 6..<11 {
            polls.append(.init(t: Double(i) * 0.4, tiles: [
                tile(levon, w: 720, h: 400, order: 1),
                tile(leva, w: 720, h: 400, order: 2),
            ]))
        }
        let spans = CallWindowJournal.spans(from: polls)
        XCTAssertFalse(spans.contains { $0.name == "Лева Ловушка" })
        XCTAssertEqual(Set(spans.map(\.name)), ["Levon Lobanov"])
    }

    func testОдиночныйВыбросПлощадиНеСоздаётПролёт() {
        var polls: [CallWindowJournal.Poll] = []
        for i in 0..<5 {
            polls.append(.init(t: Double(i) * 0.4, tiles: [
                tile(levon, w: 1080, h: 600, order: 1),
                tile(leva, w: 160, h: 80, order: 2),
            ]))
        }
        // One poll mid-animation where the sizes have already crossed over.
        polls.append(.init(t: 2.0, tiles: [
            tile(leva, w: 1080, h: 600, order: 1),
            tile(levon, w: 160, h: 80, order: 2),
        ]))
        for i in 6..<11 {
            polls.append(.init(t: Double(i) * 0.4, tiles: [
                tile(levon, w: 1080, h: 600, order: 1),
                tile(leva, w: 160, h: 80, order: 2),
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
            polls.append(.init(t: Double(i) * 0.4, tiles: [
                tile(leva, w: 1080, h: 600, order: 1),
                tile(levon, w: 160, h: 80, order: 2),
            ]))
        }
        for i in 6..<12 {
            polls.append(.init(t: Double(i) * 0.4, tiles: [
                tile("Лев Л., Звук компьютера включен, Video off", w: 1080, h: 600, order: 1),
                tile(levon, w: 160, h: 80, order: 2),
            ]))
        }
        let spans = CallWindowJournal.spans(from: polls)
        XCTAssertEqual(spans.map(\.name), ["Лева Ловушка", "Лев Л."])
        XCTAssertFalse(spans.contains { $0.start < 2.0 && $0.end > 2.8 })
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

    func testЗаглушённыйГоворящимНеСтановится() {
        // The muted veto silences the chosen candidate; it never promotes the
        // other tile — «как нет, никогда как да» (plan-speaker-tags.md §4).
        let tuning = CallWindowJournal.Tuning(mutedMarkers: ["звук выключен"])
        var polls: [CallWindowJournal.Poll] = []
        for i in 0..<6 {
            polls.append(.init(t: Double(i) * 0.4, tiles: [
                tile("Лева Ловушка, Звук выключен, Video off", w: 1080, h: 600, order: 1),
                tile(levon, w: 160, h: 80, order: 2),
            ]))
        }
        XCTAssertEqual(CallWindowJournal.spans(from: polls, tuning: tuning), [])
    }

    func testПлиткиИзДвухОконОдновременноЖурналМолчит() {
        // Plan §10.1: names must never be attributed out of someone else's
        // window. Two windows both showing tiles is an ambiguity, not a race.
        var polls: [CallWindowJournal.Poll] = []
        for i in 0..<6 {
            polls.append(.init(t: Double(i) * 0.4, tiles: [
                tile(levon, w: 1080, h: 600, order: 1),
                tile(leva, w: 160, h: 80, order: 1, window: "Zoom Meeting 2"),
            ]))
        }
        XCTAssertEqual(CallWindowJournal.spans(from: polls), [])
    }

    func testДвеРавныеПлиткиНаПервомМестеЖурналМолчит() {
        var polls: [CallWindowJournal.Poll] = []
        for i in 0..<6 {
            polls.append(.init(t: Double(i) * 0.4, tiles: [
                tile(levon, w: 720, h: 400, order: 1),
                tile(leva, w: 720, h: 400, order: 1),
            ]))
        }
        XCTAssertEqual(CallWindowJournal.spans(from: polls), [])
    }

    func testСпорнаяВершинаПлощадиЖурналМолчит() {
        // Two equally big tiles above the spread threshold: the area signal
        // fired but does not name a single person — silence, not a coin toss.
        var polls: [CallWindowJournal.Poll] = []
        for i in 0..<6 {
            polls.append(.init(t: Double(i) * 0.4, tiles: [
                tile(levon, w: 1080, h: 600, order: 1),
                tile(leva, w: 1080, h: 600, order: 2),
                tile("Гость, Звук компьютера включен, Video off", w: 160, h: 80, order: 3),
            ]))
        }
        XCTAssertEqual(CallWindowJournal.spans(from: polls), [])
    }

    func testСтрокиПанелиНеГолосуютЗаГоворящего() {
        // Panel rows are roster, not speech: a panel left open must not turn
        // its first row into the speaker.
        var polls: [CallWindowJournal.Poll] = []
        for i in 0..<6 {
            polls.append(.init(t: Double(i) * 0.4, tiles: [
                CallWindowJournal.Tile(role: "AXRow", description: "Лева Ловушка (Организатор, я)",
                                       width: 300, height: 40, order: 1,
                                       window: "Zoom Meeting", process: "zoom.us"),
                CallWindowJournal.Tile(role: "AXRow", description: "Levon Lobanov",
                                       width: 300, height: 40, order: 2,
                                       window: "Zoom Meeting", process: "zoom.us"),
            ]))
        }
        XCTAssertEqual(CallWindowJournal.spans(from: polls), [])
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
