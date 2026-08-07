import XCTest
@testable import PropellerPure

/// Правило, которое решает, чья реплика уехала в живую колонку.
///
/// Имена тестов — про то, что видит человек на встрече, а не про функцию:
/// каждый из них когда-то был строкой чужой речи под именем владельца.
final class StemDominanceTests: XCTestCase {

    /// Окна по 200 мс — та же порция, какой отдаёт захват.
    private func log(_ levels: [(mic: Float, system: Float)], from: Double = 0) -> StemDominance {
        var d = StemDominance()
        var t = from
        for level in levels {
            d.note(from: t, to: t + 0.2, mic: level.mic, system: level.system)
            t += 0.2
        }
        return d
    }

    func testВНаушникахРепликаВладельцаОстаётсяЕго() {
        // Микрофон громкий, системная дорожка почти пуста — говорит владелец.
        let d = log(Array(repeating: (mic: 0.20, system: 0.002), count: 10))
        XCTAssertEqual(d.ownerSpoke(from: 0, to: 2), true)
    }

    func testВНаушникахЧужаяРечьМикрофонаНеТрогает() {
        // Дальняя сторона говорит, микрофон молчит: микрофонной сессии тут
        // просто нечего распознать, но если она что-то выдаст — это не владелец.
        let d = log(Array(repeating: (mic: 0.001, system: 0.25), count: 10))
        XCTAssertEqual(d.ownerSpoke(from: 0, to: 2), false)
    }

    func testНаКолонкахЧужаяРечьНеСтановитсяРепликойВладельца() {
        // Ровно случай пользователя: микрофон слышит собеседника из колонки —
        // громко (+27 dB над полом), но всё же тише, чем стем, снятый до неё.
        let d = log(Array(repeating: (mic: 0.06, system: 0.25), count: 10))
        XCTAssertEqual(d.ownerSpoke(from: 0, to: 2), false)
    }

    func testНаКолонкахСобственныеСловаВладельцаОстаются() {
        // Он говорит поверх тихого фона звонка — микрофон уверенно громче.
        let d = log(Array(repeating: (mic: 0.30, system: 0.04), count: 10))
        XCTAssertEqual(d.ownerSpoke(from: 0, to: 2), true)
    }

    func testПеребилиПосредиФразыИСомнениеУходитДальнейСтороне() {
        // Половина окон его, половина чужие. Ровно половина — не большинство.
        let d = log(Array(repeating: (mic: 0.30, system: 0.04), count: 5)
                    + Array(repeating: (mic: 0.05, system: 0.30), count: 5))
        XCTAssertEqual(d.ownerSpoke(from: 0, to: 2), false)
    }

    func testТишинаМеждуСловамиНеГолосует() {
        // Восемь окон паузы (в них микрофон формально громче нуля) не должны
        // перевесить две секунды чужой речи.
        let d = log(Array(repeating: (mic: 0.0005, system: 0.0001), count: 8)
                    + Array(repeating: (mic: 0.05, system: 0.30), count: 2))
        XCTAssertEqual(d.ownerSpoke(from: 0, to: 2), false)
    }

    func testБезЗамераТекстНеТеряется() {
        // Начало записи и переподключение сессии: окон на этот промежуток нет.
        // Отсутствие замера — не замер, реплика показывается.
        let d = log(Array(repeating: (mic: 0.2, system: 0.01), count: 5), from: 100)
        XCTAssertNil(d.ownerSpoke(from: 0, to: 2))
    }

    func testБезСистемнойДорожкиВладелецНеТеряетНиСлова() {
        // Микрофонный путь: системного стема нет вовсе, отбирать не у кого.
        let d = log(Array(repeating: (mic: 0.15, system: 0), count: 10))
        XCTAssertEqual(d.ownerSpoke(from: 0, to: 2), true)
    }

    func testСтараяВстречаНеРастётВПамяти() {
        // Восемь часов записи не имеют права стать восемью часами окон.
        var d = StemDominance()
        var t = 0.0
        for _ in 0..<5000 {
            d.note(from: t, to: t + 0.2, mic: 0.1, system: 0.01)
            t += 0.2
        }
        // Всё, что старше минуты, выброшено — спросить про начало уже нельзя.
        XCTAssertNil(d.ownerSpoke(from: 0, to: 2))
        XCTAssertEqual(d.ownerSpoke(from: t - 1, to: t), true)
    }
}
