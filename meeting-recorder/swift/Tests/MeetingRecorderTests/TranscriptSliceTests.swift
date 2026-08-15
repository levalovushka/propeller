import XCTest
import PropellerPure

/// Какие куски расшифровки уезжают в разговор. Проверяется тем же вопросом, что
/// и всё остальное здесь: что увидит человек, спросивший «а что он сказал про
/// вебхуки», — реплику с разговором вокруг неё или час стенограммы.
final class TranscriptSliceTests: XCTestCase {

    private let segments: [PersistedSegment] = [
        .init(index: 0, startTime: 0, endTime: 10, text: "Давайте начнём со скоупа.", speaker: "Левон"),
        .init(index: 1, startTime: 10, endTime: 20, text: "У меня вопрос по срокам.", speaker: "Костя"),
        .init(index: 2, startTime: 20, endTime: 30, text: "Успеваем, если закроем вебхуки.", speaker: "Левон"),
        .init(index: 3, startTime: 30, endTime: 40, text: "Тогда я беру подпись на себя.", speaker: "Костя"),
        .init(index: 4, startTime: 40, endTime: 50, text: "И отдельно про бюджет.", speaker: "Марина"),
        .init(index: 5, startTime: 290, endTime: 300, text: "Вернёмся к прошлому пункту.", speaker: "Костя"),
        .init(index: 6, startTime: 300, endTime: 310, text: "Возвращаемся к вебхукам.", speaker: "Марина"),
        .init(index: 7, startTime: 310, endTime: 320, text: "Ретраи считаем от исходного тела.", speaker: "Левон"),
    ]

    func testWithoutAQuestionTheMeetingStartsFromTheBeginning() {
        let slice = TranscriptSlice.run(segments: segments, request: .init())
        XCTAssertEqual(slice.fragments.count, 1)
        XCTAssertEqual(slice.fragments[0].segments.first?.index, 0)
        XCTAssertFalse(slice.truncated)
    }

    /// Найденная реплика приезжает с соседями: фраза без разговора вокруг неё
    /// читается как цитата из ниоткуда.
    func testAFoundLineComesWithTheTalkAroundIt() {
        let slice = TranscriptSlice.run(segments: segments, request: .init(query: "вебхук"))
        XCTAssertEqual(slice.fragments.count, 2)
        XCTAssertEqual(slice.fragments[0].segments.map(\.index), [1, 2, 3])
        XCTAssertEqual(slice.fragments[1].segments.map(\.index), [5, 6, 7])
    }

    /// Разрыв между фрагментами — это пропуск в записи, и он должен быть виден:
    /// две далёкие реплики подряд читаются как один разговор.
    func testTheGapBetweenFragmentsIsSaidOutLoud() {
        let slice = TranscriptSlice.run(segments: segments, request: .init(query: "вебхук"))
        XCTAssertTrue(TranscriptSlice.render(slice).contains("\n…\n"))
    }

    func testAskingForOneSpeakerGivesOnlyTheirLines() {
        let slice = TranscriptSlice.run(segments: segments, request: .init(speaker: "костя"))
        let spoken = slice.fragments.flatMap(\.segments)
        XCTAssertEqual(spoken.map(\.index), [1, 3, 5])
        XCTAssertTrue(spoken.allSatisfy { $0.speaker == "Костя" })
    }

    func testSpeakerAndWordsNarrowTogether() {
        let slice = TranscriptSlice.run(segments: segments, request: .init(query: "вебхук", speaker: "Марина"))
        XCTAssertEqual(slice.fragments.flatMap(\.segments).map(\.speaker), ["Костя", "Марина", "Левон"])
    }

    func testATimecodeGivesTheMinuteAroundIt() {
        let slice = TranscriptSlice.run(segments: segments, request: .init(around: 305))
        XCTAssertEqual(slice.fragments.flatMap(\.segments).map(\.index), [5, 6, 7])
    }

    func testNothingFoundIsAnEmptySliceNotTheWholeMeeting() {
        let slice = TranscriptSlice.run(segments: segments, request: .init(query: "прототип"))
        XCTAssertTrue(slice.isEmpty)
    }

    func testAnEmptyTranscriptDoesNotCrash() {
        XCTAssertTrue(TranscriptSlice.run(segments: [], request: .init(full: true)).isEmpty)
    }

    /// `full` есть, но у него есть потолок — и когда он сработал, об этом
    /// сказано. Молча отданная половина расшифровки — это ответ, который
    /// выглядит полным и им не является.
    func testTheWholeTranscriptIsCappedAndSaysSo() {
        let long = (0..<(TranscriptSlice.maxSegments + 20)).map {
            PersistedSegment(index: $0, startTime: Double($0), endTime: Double($0) + 1,
                             text: "реплика \($0)", speaker: "Левон")
        }
        let slice = TranscriptSlice.run(segments: long, request: .init(full: true))
        XCTAssertEqual(slice.fragments[0].segments.count, TranscriptSlice.maxSegments)
        XCTAssertTrue(slice.truncated)
        XCTAssertTrue(TranscriptSlice.render(slice).contains("не целиком"))
    }

    func testEveryLineCarriesItsTimecodeAndSpeaker() {
        let slice = TranscriptSlice.run(segments: segments, request: .init(around: 305))
        XCTAssertTrue(TranscriptSlice.render(slice).hasPrefix("[04:50] Костя: "))
    }

    func testStampGrowsAnHourHandOnlyWhenThereIsOne() {
        XCTAssertEqual(TranscriptSlice.stamp(65), "01:05")
        XCTAssertEqual(TranscriptSlice.stamp(3725), "1:02:05")
    }
}
