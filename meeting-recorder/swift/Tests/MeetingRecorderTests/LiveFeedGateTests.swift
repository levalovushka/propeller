import XCTest
@testable import PropellerPure

/// Правило, которое решает не тратить электричество на порцию звука.
///
/// Имена — про то, что случилось бы с человеком на встрече, потому что каждый
/// из этих тестов охраняет одно и то же: экономия не имеет права стоить ни
/// одного слова.
final class FeedGateTests: XCTestCase {

    private let gate = FeedGate()

    /// Окна по 50 мс — та же порция, какой приходит захват
    /// (`ProcessTapCapture.startDraining` тикает каждые 50 мс).
    ///
    /// `cells` по умолчанию пустые — «замера когерентности нет», и это законное
    /// состояние: микрофонный путь без системной дорожки, начало записи.
    private func windows(
        _ levels: [(mic: Float, system: Float)], from: Double = 0,
        cells: EchoCoherence.Cells = .none
    ) -> [FeedGate.Window] {
        var t = from
        return levels.map { level in
            defer { t += 0.05 }
            return FeedGate.Window(
                start: t, end: t + 0.05, mic: level.mic, system: level.system, cells: cells
            )
        }
    }

    /// Порция, все громкие ячейки которой объясняются дальней стороной: так
    /// выглядит эхо из колонки (замер 2026-08-11: доля необъяснённых 0.05).
    private let onlyEcho = EchoCoherence.Cells(loud: 20, unexplained: 1)
    /// Владелец говорит поверх чужой речи — на 5 dB **тише** её, как и бывает на
    /// колонках (замер: доля 0.29).
    private let ownerOverEcho = EchoCoherence.Cells(loud: 20, unexplained: 6)

    private func send(_ channel: LiveTranscript.Channel, _ w: [FeedGate.Window]) -> Bool {
        gate.shouldSend(channel: channel, windows: w, secondsSinceLastSend: 0)
    }

    // MARK: - Тишина

    func testПорциюИзОднойТишиныНеОтдаём() {
        let quiet = windows(Array(repeating: (mic: 0.0005, system: 0.0), count: 40))
        XCTAssertFalse(send(.owner, quiet))
        XCTAssertFalse(send(.remote, quiet))
    }

    func testОдногоСловаВКонцеПорцииДостаточноЧтобыОтдатьВсю() {
        // Ровно то, ради чего решение принимается по целой порции: человек начал
        // говорить в последние 150 мс. Отдать надо всё, вместе с тишиной перед
        // словом — иначе движку достанется обрезанный attack.
        var w = windows(Array(repeating: (mic: 0.0005, system: 0.0), count: 37))
        w += windows([(mic: 0.2, system: 0.0), (mic: 0.25, system: 0.0), (mic: 0.22, system: 0.0)],
                     from: 37 * 0.05)
        XCTAssertTrue(send(.owner, w))
    }

    func testРечьДальнейСтороныВСистемнойДорожкеОтдаётся() {
        let remote = windows(Array(repeating: (mic: 0.001, system: 0.25), count: 40))
        XCTAssertTrue(send(.remote, remote))
    }

    // MARK: - Эхо: то, за что сейчас платят зря

    func testЧужаяРечьИзКолонкиНеОтдаётсяМикрофоннойСессией() {
        // Микрофон слышит собеседника из колонки, и оттуда распознаётся 95–97 %
        // её слов. На экран они всё равно не попадут (`EchoDedup`) — гейт не даёт
        // их даже распознать.
        let echo = windows(Array(repeating: (mic: 0.06, system: 0.25), count: 40), cells: onlyEcho)
        XCTAssertFalse(send(.owner, echo))
        XCTAssertTrue(send(.remote, echo), "дальней стороне её собственная речь нужна")
    }

    func testЭхоГромчеСистемнойДорожкиВсёРавноЭхо() {
        // То, на чём провалилось прежнее правило: замер 2026-08-11 показал, что
        // на колонках микрофон бывает громче системного стема, а собственный
        // голос владельца — тише эха на 4–6 dB. Решает когерентность, не уровни.
        let loud = windows(Array(repeating: (mic: 0.30, system: 0.10), count: 40), cells: onlyEcho)
        XCTAssertFalse(send(.owner, loud))
    }

    func testПеребивкаОтдаётсяОбеимДорожкам() {
        // Собеседник говорит, владелец вступает посреди — и делает это тише
        // колонок. Его ячейки дальней стороной не объясняются, значит порция
        // уходит и микрофонной сессии тоже.
        var w = windows(Array(repeating: (mic: 0.06, system: 0.25), count: 30), cells: onlyEcho)
        w += windows(
            Array(repeating: (mic: 0.10, system: 0.25), count: 10), from: 30 * 0.05,
            cells: ownerOverEcho
        )
        XCTAssertTrue(send(.owner, w), "иначе первые слова владельца не появятся вовсе")
        XCTAssertTrue(send(.remote, w))
    }

    // MARK: - Когда замера нет

    func testБезОконПорцияУходит() {
        // Начало записи и первые кадры после переподключения: окон ещё нет.
        // Отсутствие замера — не замер, и молчать на этом основании нельзя.
        XCTAssertTrue(send(.owner, []))
        XCTAssertTrue(send(.remote, []))
    }

    func testОдноШумноеОкноПорциюНеОтдаёт() {
        // Пятьдесят миллисекунд — это единицы голосов, и доля от них ничего не
        // значит. Иначе любой щелчок в комнате отменял бы экономию целиком.
        var w = windows(Array(repeating: (mic: 0.06, system: 0.25), count: 39), cells: onlyEcho)
        w += windows(
            [(mic: 0.06, system: 0.25)], from: 39 * 0.05,
            cells: EchoCoherence.Cells(loud: 3, unexplained: 3)
        )
        XCTAssertFalse(send(.owner, w))
    }

    func testБезЗамераКогерентностиПорцияУходит() {
        // Микрофонный путь: системной дорожки нет, объяснять эхо нечем. Гейт
        // обязан молчать, а не считать всё эхом.
        let loud = windows(Array(repeating: (mic: 0.2, system: 0.0), count: 40))
        XCTAssertTrue(send(.owner, loud))
    }

    // MARK: - Сокет не должен закрыться из-за экономии

    func testПослеЧетырёхМинутМолчанияПорцияУходитВсёРавно() {
        // Сервер закрывает сессию через 300 с без кадров. Человек, молча
        // слушающий длинный монолог, не должен из-за гейта потерять сессию.
        let quiet = windows(Array(repeating: (mic: 0.0005, system: 0.0), count: 40))
        XCTAssertFalse(gate.shouldSend(channel: .owner, windows: quiet, secondsSinceLastSend: 100))
        XCTAssertTrue(gate.shouldSend(channel: .owner, windows: quiet, secondsSinceLastSend: 240))
    }

    func testПорогKeepaliveНижеСерверногоТаймаута() {
        // Числа связаны: 300 с — это `--idle-timeout-secs` по умолчанию.
        XCTAssertLessThan(FeedGate.keepaliveSeconds, 300)
    }

    // MARK: - Правила по отдельности

    /// Они разделены не для гибкости, а потому что покупают разное за разную
    /// цену, и это надо было увидеть врозь: эхо даёт −26 % и не может изменить
    /// того, что на экране; тишина даёт −14 %; вместе −38 %, но ценой второго
    /// потерянного слова.
    func testТолькоЭхоНеТрогаетТишину() {
        let gate = FeedGate(rules: .echo)
        let quiet = windows(Array(repeating: (mic: 0.0005, system: 0.0), count: 40))
        XCTAssertTrue(gate.shouldSend(channel: .owner, windows: quiet, secondsSinceLastSend: 0))
        XCTAssertTrue(gate.shouldSend(channel: .remote, windows: quiet, secondsSinceLastSend: 0))
    }

    func testТолькоЭхоРежетЧужуюРечьВМикрофоне() {
        let gate = FeedGate(rules: .echo)
        let echo = windows(Array(repeating: (mic: 0.06, system: 0.25), count: 40), cells: onlyEcho)
        XCTAssertFalse(gate.shouldSend(channel: .owner, windows: echo, secondsSinceLastSend: 0))
    }

    func testТолькоТишинаНеТрогаетЭхо() {
        let gate = FeedGate(rules: .silence)
        let echo = windows(Array(repeating: (mic: 0.06, system: 0.25), count: 40), cells: onlyEcho)
        XCTAssertTrue(
            gate.shouldSend(channel: .owner, windows: echo, secondsSinceLastSend: 0),
            "чужая речь в микрофоне распознается и будет снята по тексту (`EchoDedup`)"
        )
    }

    func testТолькоТишинаРежетТишину() {
        let gate = FeedGate(rules: .silence)
        let quiet = windows(Array(repeating: (mic: 0.0005, system: 0.0), count: 40))
        XCTAssertFalse(gate.shouldSend(channel: .owner, windows: quiet, secondsSinceLastSend: 0))
        XCTAssertFalse(gate.shouldSend(channel: .remote, windows: quiet, secondsSinceLastSend: 0))
    }
}

/// Шкала времени, когда часть звука движку не отдана.
///
/// Это тесты про худший исход экономии: не «текста меньше», а «текст лёг раньше,
/// чем был сказан», поверх уже показанного.
final class FedTimelineTests: XCTestCase {

    func testБезПропусковШкалыСовпадают() {
        var timeline = FedTimeline()
        for i in 0..<5 {
            timeline.fed(meetingStart: Double(i) * 2, seconds: 2)
        }
        XCTAssertEqual(timeline.meetingTime(forServer: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(timeline.meetingTime(forServer: 7.5), 7.5, accuracy: 1e-9)
        XCTAssertEqual(timeline.totalSkippedSeconds, 0)
    }

    func testПослеПропускаТекстЛожитсяТудаГдеБылСказан() {
        var timeline = FedTimeline()
        timeline.fed(meetingStart: 0, seconds: 2)      // 0–2 встречи = 0–2 сервера
        timeline.skipped(seconds: 6)                    // 2–8 встречи не отдано
        timeline.fed(meetingStart: 8, seconds: 2)      // 8–10 встречи = 2–4 сервера

        // Слово, которое движок отнёс на свою 3-ю секунду, сказано на 9-й.
        XCTAssertEqual(timeline.meetingTime(forServer: 3), 9, accuracy: 1e-9)
        XCTAssertEqual(timeline.totalSkippedSeconds, 6, accuracy: 1e-9)
    }

    func testПропускиНакапливаютсяЧерезВсюВстречу() {
        var timeline = FedTimeline()
        var meeting = 0.0
        // Час встречи: две секунды отдаём, четыре пропускаем.
        for _ in 0..<600 {
            timeline.fed(meetingStart: meeting, seconds: 2)
            meeting += 2
            timeline.skipped(seconds: 4)
            meeting += 4
        }
        XCTAssertEqual(timeline.totalSkippedSeconds, 2400, accuracy: 1e-6)
        // Последняя отданная порция — 1200 с серверного времени, 3596-я секунда
        // встречи. Ошибка здесь и есть «текст врёт тем сильнее, чем дольше идёт
        // встреча».
        XCTAssertEqual(timeline.meetingTime(forServer: 1199), 3595, accuracy: 1e-6)
    }

    func testВремяДоПервойОтданнойПорцииНеТеряется() {
        var timeline = FedTimeline()
        XCTAssertEqual(timeline.meetingTime(forServer: 1.5), 1.5, accuracy: 1e-9)
        timeline.skipped(seconds: 4)
        timeline.fed(meetingStart: 4, seconds: 2)
        XCTAssertEqual(timeline.meetingTime(forServer: 0.5), 4.5, accuracy: 1e-9)
    }

    func testПропускПередСамымНачаломСдвигаетВсё() {
        var timeline = FedTimeline()
        timeline.skipped(seconds: 10)
        timeline.fed(meetingStart: 10, seconds: 2)
        XCTAssertEqual(timeline.meetingTime(forServer: 0), 10, accuracy: 1e-9)
        XCTAssertEqual(timeline.meetingTime(forServer: 1), 11, accuracy: 1e-9)
    }

    func testКартаНеРастётПокаПропусковНет() {
        // Восьмичасовая встреча без пропусков — одна запись, а не четырнадцать
        // тысяч. Проверяется через равенство значений: структура Equatable, и
        // две одинаково устроенные шкалы обязаны совпадать.
        var dense = FedTimeline()
        for i in 0..<1000 { dense.fed(meetingStart: Double(i) * 2, seconds: 2) }
        var single = FedTimeline()
        single.fed(meetingStart: 0, seconds: 2000)
        XCTAssertEqual(dense.meetingTime(forServer: 1500), single.meetingTime(forServer: 1500))
    }

    func testНулевыеИОтрицательныеПорцииИгнорируются() {
        var timeline = FedTimeline()
        timeline.fed(meetingStart: 0, seconds: 0)
        timeline.skipped(seconds: -1)
        XCTAssertEqual(timeline.totalSkippedSeconds, 0)
        XCTAssertEqual(timeline.meetingTime(forServer: 5), 5, accuracy: 1e-9)
    }
}
