import XCTest
@testable import PropellerPure

/// Названо по тому, что человек читает в расшифровке готовой встречи: каждая
/// реплика стоит один раз и под тем, кто её сказал.
///
/// Случаи — с встречи тестировщика на колонках: там микрофон слышит дальнюю
/// сторону, и из 2080 слов микрофонной дорожки 1382 чужие.
final class StemAssemblyTests: XCTestCase {

    private func mic(_ start: Double, _ end: Double, _ text: String) -> EchoDedup.Line {
        EchoDedup.Line(start: start, end: end, text: text)
    }

    private func far(_ start: Double, _ end: Double, _ text: String,
                     _ who: String = "Speaker 1") -> StemMerge.Line {
        StemMerge.Line(start: start, end: end, speaker: who, text: text)
    }

    /// Слова реплики с таймингами — так их отдаёт сайдкар (`segments[].words`).
    /// Раскладываются ровно по длительности реплики, чтобы в тесте было видно,
    /// какое слово когда сказано.
    private func words(_ line: EchoDedup.Line) -> [ASRWord] {
        let parts = line.text.split(separator: " ").map(String.init)
        let step = (line.end - line.start) / Double(parts.count)
        return parts.enumerated().map { index, text in
            ASRWord(start: line.start + step * Double(index),
                    end: line.start + step * Double(index) + step * 0.8,
                    text: text)
        }
    }

    private func words(_ lines: [StemMerge.Line]) -> [ASRWord] {
        lines.flatMap { words(EchoDedup.Line(start: $0.start, end: $0.end, text: $0.text)) }
    }

    // MARK: - Эхо

    /// На колонках то же самое приезжает дважды: один раз с системной дорожки,
    /// один раз из микрофона. Второй раз — не реплика владельца.
    func testЭхоНеСтановитсяВторойСтрокой() {
        let lines = StemAssembly.assemble(
            mic: [mic(10.4, 13.1, "давайте перенесем созвон на четверг после обеда")],
            ownerName: "Левон",
            farSide: [far(10.0, 13.0, "давайте перенесём созвон на четверг после обеда")]
        )
        XCTAssertEqual(lines.map(\.speaker), ["Speaker 1"])
        XCTAssertEqual(lines.count, 1)
    }

    /// Эхо распознаётся испорченным — «в формате» приезжает как «в формации».
    /// Сравнение нестрогое именно поэтому.
    func testИспорченноеЭхоТожеСнимается() {
        let lines = StemAssembly.assemble(
            mic: [mic(4.2, 6.0, "нужно собрать метрику в формации и показать заказчику")],
            ownerName: "Левон",
            farSide: [far(4.0, 6.1, "нужно собрать метрику в формате и показать заказчику")]
        )
        XCTAssertEqual(lines.map(\.speaker), ["Speaker 1"])
    }

    /// Порядок подачи — не деталь реализации, а условие правильности.
    /// `EchoDedup.historySeconds` держит минуту истории; если скормить дедупу
    /// сначала всю дальнюю сторону, а потом весь микрофон, от неё к первой
    /// микрофонной реплике останется только конец встречи — и эхо начала
    /// приедет второй строкой под именем владельца.
    func testЭхоСнимаетсяИВНачалеДлиннойВстречи() {
        let lines = StemAssembly.assemble(
            mic: [
                mic(11, 14, "тогда я поправлю расшифровку и покажу в среду"),
                mic(201, 204, "хорошо, значит выкладываем сборку и пишем коллегам"),
            ],
            ownerName: "Левон",
            farSide: [
                far(10, 13.5, "тогда я поправлю расшифровку и покажу в среду"),
                far(200, 203.5, "хорошо, значит выкладываем сборку и пишем коллегам"),
            ]
        )
        XCTAssertEqual(lines.map(\.speaker), ["Speaker 1", "Speaker 1"])
        XCTAssertEqual(lines.count, 2, "эхо на 11-й секунде снято тем же правилом, что и на 201-й")
    }

    // MARK: - Своя речь

    /// Дальняя сторона молчит — эху взяться неоткуда, и ждать нечего.
    func testСвояРечьВТишинеОстаётся() {
        let lines = StemAssembly.assemble(
            mic: [mic(30, 33, "я пока посмотрю логи и вернусь с ответом")],
            ownerName: "Левон",
            farSide: [far(120, 123, "да, спасибо, тогда ждём")]
        )
        XCTAssertEqual(lines.map(\.speaker), ["Левон", "Speaker 1"])
    }

    /// Единственная реплика, которую замер 2026-08-11 не снял и не должен был:
    /// владелец говорит поверх чужой речи, и слова у них разные.
    func testСвояРечьПоверхЧужойОстаётся() {
        let lines = StemAssembly.assemble(
            mic: [mic(50.5, 52.0, "да нормально да да согласен")],
            ownerName: "Левон",
            farSide: [far(49.0, 54.0, "мы тогда закладываем две недели на интеграцию платежей")]
        )
        // Собеседница начала раньше (49.0 против 50.5) — лента читается по
        // началу реплики, поэтому её строка первая.
        XCTAssertEqual(lines.map(\.speaker), ["Speaker 1", "Левон"])
        XCTAssertTrue(lines.contains { $0.text.contains("согласен") })
    }

    /// Микрофон один (наушники сняты, встреча вживую) — снимать эхо нечем и
    /// не нужно, лента это микрофонная дорожка целиком.
    func testБезДальнейСтороныЛентаЭтоМикрофон() {
        let lines = StemAssembly.assemble(
            mic: [mic(0, 2, "начнём с того, что было на прошлой неделе"),
                  mic(10, 12, "и второе — сроки по интеграции")],
            ownerName: "Левон",
            farSide: []
        )
        XCTAssertEqual(lines.map(\.speaker), ["Левон", "Левон"])
        XCTAssertEqual(lines.count, 2, "реплики в десяти секундах друг от друга — разные реплики")
    }

    /// Запись только с системной дорожки (микрофон был выключен): чужая речь
    /// остаётся, ничего не теряется.
    func testБезМикрофонаЛентаЭтоСистемныйСтем() {
        let lines = StemAssembly.assemble(
            mic: [],
            ownerName: "Левон",
            farSide: [far(1, 3, "привет, все на месте?"), far(4, 6, "тогда начинаем", "Speaker 2")]
        )
        XCTAssertEqual(lines.map(\.speaker), ["Speaker 1", "Speaker 2"])
    }

    // MARK: - Порядок и границы

    /// Главное свойство склейки, ради которого всё затевалось: чужая реплика не
    /// оказывается внутри моей, а лента читается сверху вниз.
    func testЛентаЧитаетсяПоПорядку() {
        let lines = StemAssembly.assemble(
            mic: [mic(0, 2, "смотрите, у нас остался последний вопрос по деньгам"),
                  mic(6, 8, "тогда я отправлю смету до конца дня")],
            ownerName: "Левон",
            farSide: [far(3, 5, "да, по бюджету мы готовы обсуждать")]
        )
        XCTAssertEqual(lines.map(\.speaker), ["Левон", "Speaker 1", "Левон"])
        XCTAssertEqual(lines.map(\.start), [0, 3, 6])
    }

    /// ASR режет речь по дыханию, и без склейки лента рассыпается на обрывки —
    /// конспект читает их как отдельные мысли.
    func testОбрывкиОдногоЧеловекаСобираютсяВРеплику() {
        let lines = StemAssembly.assemble(
            mic: [mic(0, 3, "мне надо понимать, что происходит,"),
                  mic(3.4, 5, "иначе я не смогу планировать")],
            ownerName: "Левон",
            farSide: []
        )
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "мне надо понимать, что происходит, иначе я не смогу планировать")
    }

    /// Ни одна микрофонная реплика не должна пропасть молча: то, что дождалось
    /// конца встречи, показывается.
    func testПоследняяРепликаНеТеряетсяВОжидании() {
        let lines = StemAssembly.assemble(
            mic: [mic(100, 102, "ага, тогда так и договорились, спасибо большое")],
            ownerName: "Левон",
            farSide: [far(99, 103, "и последнее — счёт пришлём в понедельник утром")]
        )
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.contains { $0.speaker == "Левон" })
    }

    // MARK: - Эхо внутри реплики (по таймингам слов)

    /// Тот самый сегмент со встречи тестировщика: первая половина — свои слова,
    /// вторая — эхо. Построчное правило оставляло его целиком, и владелец
    /// оказывался автором чужой мысли.
    func testЭхоВОднойРепликеСоСвоейРечьюСнимается() {
        let ownLine = mic(10.0, 14.0, "кожаный да я видел ну это на самом деле")
        let farLine = far(12.0, 16.0, "ну это на самом деле классно что они заморочились")
        let lines = StemAssembly.assemble(
            mic: [ownLine], micWords: words(ownLine),
            ownerName: "Левон",
            farSide: [farLine], farWords: words([farLine])
        )
        let own = lines.filter { $0.speaker == "Левон" }
        XCTAssertEqual(own.count, 1)
        XCTAssertEqual(own[0].text, "кожаный да я видел")
        XCTAssertFalse(own[0].text.contains("самом деле"), "чужие слова остались у владельца")
    }

    /// Эхо в середине: собеседник вставил слово в чужую фразу, ASR положил всё в
    /// один сегмент. Реплика рвётся на две, а не сшивается через дырку —
    /// предложения, которого никто не говорил, в ленте быть не должно.
    func testЭхоВСерединеРвётРепликуНаДве() {
        let ownLine = mic(0, 8, "смотри вот тут понял согласен а дальше по срокам")
        let farLine = far(3.2, 4.8, "понял согласен")
        let lines = StemAssembly.assemble(
            mic: [ownLine], micWords: words(ownLine),
            ownerName: "Левон",
            farSide: [farLine], farWords: words([farLine])
        )
        XCTAssertEqual(lines.map(\.speaker), ["Левон", "Speaker 1", "Левон"])
        XCTAssertEqual(lines[0].text, "смотри вот тут")
        XCTAssertEqual(lines[2].text, "а дальше по срокам")
    }

    /// Реплика, которая целиком эхо, уходит целиком — на колонках из микрофона
    /// распознаётся 95–97 % чужой речи, и таких реплик две трети дорожки.
    func testРепликаЦеликомИзЭхаИсчезает() {
        let ownLine = mic(5.0, 9.0, "давайте перенесем созвон на четверг после обеда")
        let farLine = far(5.0, 9.0, "давайте перенесём созвон на четверг после обеда")
        let lines = StemAssembly.assemble(
            mic: [ownLine], micWords: words(ownLine),
            ownerName: "Левон",
            farSide: [farLine], farWords: words([farLine])
        )
        XCTAssertEqual(lines.map(\.speaker), ["Speaker 1"])
    }

    /// То же слово, сказанное в другую минуту, — не эхо. Замер: 80 % эха
    /// совпадает по времени в пределах 0.04 с, а хвост около двух секунд — это
    /// уже совпадение, и своё слово дороже.
    func testТоЖеСловоВДругоеВремяОстаётся() {
        let ownLine = mic(60.0, 64.0, "по срокам укладываемся в четверг как договаривались")
        let farLine = far(10.0, 14.0, "по срокам укладываемся в четверг как договаривались")
        let lines = StemAssembly.assemble(
            mic: [ownLine], micWords: words(ownLine),
            ownerName: "Левон",
            farSide: [farLine], farWords: words([farLine])
        )
        XCTAssertEqual(lines.filter { $0.speaker == "Левон" }.count, 1)
        XCTAssertEqual(lines.first(where: { $0.speaker == "Левон" })?.text,
                       "по срокам укладываемся в четверг как договаривались")
    }

    /// Эхо распознаётся испорченным: «в формате» приезжает как «в формации».
    /// Сравнение нестрогое — то же самое, которым живёт живой слой.
    func testИспорченноеЭхоВнутриРепликиТожеСнимается() {
        let ownLine = mic(20.0, 24.0, "надо собрать метрику в формации")
        let farLine = far(20.0, 24.0, "надо собрать метрику в формате")
        let lines = StemAssembly.assemble(
            mic: [ownLine], micWords: words(ownLine),
            ownerName: "Левон",
            farSide: [farLine], farWords: words([farLine])
        )
        XCTAssertEqual(lines.map(\.speaker), ["Speaker 1"])
    }

    /// Таймингов нет (пустой ответ, старый сайдкар) — работает построчное
    /// правило, а не «показать всё эхо». На колонках две трети микрофонной
    /// дорожки чужие, и остаться без снятия эха хуже, чем снять построчно.
    func testБезТайминговРаботаетПострочноеПравило() {
        let lines = StemAssembly.assemble(
            mic: [mic(10.4, 13.1, "давайте перенесем созвон на четверг после обеда")],
            micWords: [],
            ownerName: "Левон",
            farSide: [far(10.0, 13.0, "давайте перенесём созвон на четверг после обеда")],
            farWords: []
        )
        XCTAssertEqual(lines.map(\.speaker), ["Speaker 1"])
    }

    /// Слова владельца в тишине не трогаются даже там, где собеседник говорил
    /// далеко до и далеко после.
    func testСвояРечьМеждуЧужимиРепликамиЦела() {
        let ownLine = mic(20.0, 24.0, "тогда я поправлю смету и пришлю к утру")
        let far1 = far(0, 5, "давай обсудим бюджет на следующий квартал")
        let far2 = far(40, 45, "хорошо, жду смету и посмотрю вечером")
        let lines = StemAssembly.assemble(
            mic: [ownLine], micWords: words(ownLine),
            ownerName: "Левон",
            farSide: [far1, far2], farWords: words([far1, far2])
        )
        XCTAssertEqual(lines.map(\.speaker), ["Speaker 1", "Левон", "Speaker 1"])
        XCTAssertEqual(lines[1].text, "тогда я поправлю смету и пришлю к утру")
    }
}
