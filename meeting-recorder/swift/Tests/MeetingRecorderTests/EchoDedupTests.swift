import XCTest
@testable import PropellerPure

/// Правило, которое решает, попадёт ли чужая речь на экран под именем владельца.
///
/// Имена тестов — про то, что человек видел на встрече: каждый из них когда-то
/// был строкой собеседника, подписанной «Левон». Реплики в тестах — настоящие,
/// из встречи 2026-08-11 «Дом Пряжи | Оценка КП», где задвоение сняли скриншотом.
final class EchoDedupTests: XCTestCase {

    private let now = 1000.0

    /// Дальняя сторона сказала, потом та же фраза приехала из микрофона.
    private func afterRemote(_ text: String, at start: Double = 10, end: Double = 12) -> EchoDedup {
        var dedup = EchoDedup()
        _ = dedup.remoteSaid(start: start, end: end, text: text)
        return dedup
    }

    /// Реплика снята, а не отложена. Разница существенная: отложенная появится
    /// через секунду и человек увидит тот же дубль, только позже.
    private func assertDropped(
        _ dedup: inout EchoDedup, _ shown: [EchoDedup.Line],
        _ message: String = "", line: UInt = #line
    ) {
        XCTAssertTrue(shown.isEmpty, message, line: line)
        XCTAssertEqual(dedup.waitingCount, 0, "реплика отложена, а не снята", line: line)
        XCTAssertTrue(dedup.tick(at: now + 60).isEmpty, "снятая реплика вернулась позже", line: line)
    }

    // MARK: - То, ради чего правило существует

    func testРепликаСобеседникаНеПоявляетсяПодИменемВладельца() {
        var dedup = afterRemote("па-па-па-пам. Ну, понятно.")
        let shown = dedup.ownerSaid(
            start: 10.2, end: 12.1, text: "па-па-па-пам. Ну, понятно.",
            farSideAudible: true, at: now
        )
        assertDropped(&dedup, shown)
    }

    func testИспорченноеЭхоТожеЭхо() {
        // Микрофон слышит собеседника через комнату, и движок читает это хуже:
        // «интеграции приложения» → «ин интеграции в приложения».
        var dedup = afterRemote("интеграции приложения.")
        let shown = dedup.ownerSaid(
            start: 10.4, end: 12.3, text: "ин интеграции в приложения.",
            farSideAudible: true, at: now
        )
        assertDropped(&dedup, shown, "лишние огрызки не делают эхо новой репликой")
    }

    func testДажеСлогПовторённыйЗаСобеседникомНеПоказывается() {
        var dedup = afterRemote("э-э")
        let shown = dedup.ownerSaid(start: 10.1, end: 11, text: "э-э-э", farSideAudible: true, at: now)
        assertDropped(&dedup, shown)
    }

    func testФразаСразнымиГраницамиУДвухСессийВсёРавноОдна() {
        // Движки режут поток на фразы по-своему: одна и та же фраза приезжает с
        // границами, разъехавшимися на секунду с лишним.
        var dedup = afterRemote("Берём напишем логику в формате.", at: 34, end: 36)
        let shown = dedup.ownerSaid(
            start: 35.4, end: 37.2, text: "Блин, напишем логику в формации.",
            farSideAudible: true, at: now
        )
        assertDropped(&dedup, shown)
    }

    // MARK: - Чего правило не имеет права стоить

    func testПокаСобеседникМолчитРепликаПоказываетсяСразу() {
        // Эху взяться неоткуда, значит и ждать ответа не за чем: собственная
        // речь владельца не платит за дедуп ни миллисекундой.
        var dedup = EchoDedup()
        let shown = dedup.ownerSaid(
            start: 5, end: 7, text: "Тогда я соберу смету к четвергу.",
            farSideAudible: false, at: now
        )
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(dedup.waitingCount, 0)
    }

    func testСвоиСловаВладельцаОстаютсяДажеКогдаЭхоГромчеЕго() {
        // Замер 2026-08-11: собственный голос владельца в его микрофоне тише эха
        // на 4–6 dB. Правило про уровни здесь и провалилось — это правило про
        // текст, и уровни ему безразличны.
        var dedup = afterRemote("Давай посмотрим Фигму.", at: 10, end: 13)
        let shown = dedup.ownerSaid(
            start: 10.5, end: 12.4, text: "Да, нормально, да, погоди секунду.",
            farSideAudible: true, at: now
        )
        XCTAssertEqual(shown.map(\.text), ["Да, нормально, да, погоди секунду."])
    }

    func testСловоПовторённоеЧерезМинутуНеСчитаетсяЭхом() {
        // «Понятно» на 10-й секунде и «понятно» на 90-й — это два разных
        // «понятно», а не эхо: рядом по времени ничего похожего нет.
        var dedup = afterRemote("Понятно.")
        _ = dedup.remoteSaid(start: 88, end: 92, text: "Ну и ладно.")
        let shown = dedup.ownerSaid(start: 90, end: 91, text: "Понятно.", farSideAudible: true, at: now)
        XCTAssertEqual(shown.map(\.text), ["Понятно."])
    }

    // MARK: - Порядок ответов: две сессии, гонка

    func testРепликаЖдётОтветаДальнейСтороныИТогдаСнимается() {
        var dedup = EchoDedup()
        // Микрофонная сессия ответила первой — сравнивать пока не с чем.
        let held = dedup.ownerSaid(
            start: 10, end: 12, text: "интеграции приложения.", farSideAudible: true, at: now
        )
        XCTAssertTrue(held.isEmpty)
        XCTAssertEqual(dedup.waitingCount, 1)
        // Дальняя сторона отвечает — и теперь видно, что это была её фраза.
        XCTAssertTrue(dedup.remoteSaid(start: 10, end: 12, text: "Интеграции приложения").isEmpty)
        XCTAssertEqual(dedup.waitingCount, 0)
        XCTAssertTrue(dedup.tick(at: now + 60).isEmpty)
    }

    func testРепликаЖдётОтветаИПоказываетсяКогдаОнДругой() {
        var dedup = EchoDedup()
        XCTAssertTrue(
            dedup.ownerSaid(start: 10, end: 12, text: "Я посмотрю после обеда.",
                            farSideAudible: true, at: now).isEmpty
        )
        let shown = dedup.remoteSaid(start: 10, end: 12, text: "Когда сможешь посмотреть?")
        XCTAssertEqual(shown.map(\.text), ["Я посмотрю после обеда."])
    }

    func testБезОтветаДальнейСтороныРепликаВсёРавноПоказывается() {
        // Её сессия могла переподключаться или там была не речь, а музыка.
        // Отсутствие замера не есть замер — прятать слова на этом основании
        // нельзя, иначе живой текст врёт молчанием.
        var dedup = EchoDedup()
        _ = dedup.ownerSaid(start: 10, end: 12, text: "Ну смотри.", farSideAudible: true, at: now)
        XCTAssertTrue(dedup.tick(at: now + EchoDedup.holdSeconds - 0.1).isEmpty)
        XCTAssertEqual(dedup.tick(at: now + EchoDedup.holdSeconds).map(\.text), ["Ну смотри."])
    }

    func testОжиданиеНеДлитсяДольшеСвоегоПорога() {
        // Потолок добавленной задержки — величина в типе, а не «как получится».
        XCTAssertLessThanOrEqual(EchoDedup.holdSeconds, 2.0)
    }

    func testОстановкаЗаписиНеСъедаетПоследниеСлова() {
        var dedup = EchoDedup()
        _ = dedup.ownerSaid(start: 10, end: 12, text: "Всё, я пошёл.", farSideAudible: true, at: now)
        XCTAssertEqual(dedup.flush().map(\.text), ["Всё, я пошёл."])
        XCTAssertEqual(dedup.waitingCount, 0)
    }

    func testНоваяВстречаНеСудитПоРепликамПрошлой() {
        var dedup = afterRemote("Понятно.")
        dedup.reset()
        _ = dedup.ownerSaid(start: 10, end: 12, text: "Понятно.", farSideAudible: true, at: now)
        // Реплики прошлой встречи снятия не вызывают: ждёт и показывается.
        XCTAssertEqual(dedup.tick(at: now + EchoDedup.holdSeconds).map(\.text), ["Понятно."])
    }

    // MARK: - Память

    func testВстречаНаВосемьЧасовНеРастётВПамяти() {
        var dedup = EchoDedup()
        var t = 0.0
        for _ in 0..<5000 {
            _ = dedup.remoteSaid(start: t, end: t + 2, text: "Одна и та же фраза каждые две секунды.")
            t += 2
        }
        // История старше минуты выброшена: реплику из начала встречи сравнивать
        // уже не с чем, и она показывается.
        let shown = dedup.ownerSaid(
            start: 5, end: 7, text: "Одна и та же фраза каждые две секунды.",
            farSideAudible: true, at: now
        )
        XCTAssertEqual(shown.count, 1)
    }

    // MARK: - Похожесть слов

    func testПохожестьСловНеПутаетРазныеСлова() {
        XCTAssertTrue(EchoDedup.similar("интеграции", "интеграции"))
        XCTAssertTrue(EchoDedup.similar("формации", "формате"))
        XCTAssertFalse(EchoDedup.similar("смета", "фигма"))
        XCTAssertFalse(EchoDedup.similar("да", "давай"))
    }
}
