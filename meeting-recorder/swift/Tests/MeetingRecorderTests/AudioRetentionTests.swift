import XCTest
@testable import PropellerPure

/// # Когда аудио уходит само
///
/// Правило отвечает только на «когда». На «у кого можно» отвечает `AudioReclaim`,
/// и здесь оно спрашивается, а не повторяется: две истины о том, кому ещё нужен
/// звук, — это встреча, которую больше никогда не расшифруют.
///
/// Названы тесты по тому, что человек увидел бы, если правило ошибётся: пропавшая
/// из списка встреча, встреча без расшифровки навсегда, и архив, у которого
/// обновление унесло весь звук.
final class AudioRetentionTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func done(_ id: String, daysAgo: Int, hasAudio: Bool = true) -> AudioRetention.Candidate {
        AudioRetention.Candidate(
            id: id,
            date: now.addingTimeInterval(-Double(daysAgo) * 86_400),
            stage: .summarized,
            hasTranscript: true,
            hasAudio: hasAudio
        )
    }

    // MARK: - Выбор из двух

    func testВыбораКромеДвухРежимовНет() {
        // Третий пункт («хранить всегда») удалён решением 2026-08-20: настройка,
        // которой никто не пользуется, — это ещё один способ получить архив,
        // ведущий себя иначе, чем думает владелец.
        XCTAssertEqual(AudioRetentionMode.allCases, [.afterTranscript, .afterDays])
    }

    func testСрокНазванЧисломАНеПодразумевается() {
        XCTAssertEqual(AudioRetention.days, 30)
    }

    func testСегментедНеПревращаетсяВКолбасу() {
        // Что человек увидел бы: два пункта разной длины растягивают сегментед и
        // ломают ряд настроек. Мера грубая, но она ловит именно это.
        for mode in AudioRetentionMode.allCases {
            XCTAssertLessThanOrEqual(mode.displayName.count, 14, mode.rawValue)
            XCTAssertFalse(mode.displayName.isEmpty)
        }
    }

    // MARK: - Через тридцать дней

    func testСрокИстекаетВДеньКогдаПрошлоРовноТридцать() {
        let candidates = [done("свежая", daysAgo: 29), done("истёкшая", daysAgo: 30)]
        XCTAssertEqual(
            AudioRetention.expired(candidates, mode: .afterDays, now: now),
            ["истёкшая"]
        )
    }

    // MARK: - Сразу после расшифровки

    func testСразуПослеРасшифровкиЗабираетТолькоДоделанное() {
        let candidates = [
            done("доделана", daysAgo: 0),
            AudioRetention.Candidate(
                id: "ещё-не-расшифрована", date: now, stage: .recorded,
                hasTranscript: false, hasAudio: true
            ),
        ]
        XCTAssertEqual(
            AudioRetention.expired(candidates, mode: .afterTranscript, now: now),
            ["доделана"]
        )
    }

    // MARK: - Записанное в прежние дни

    func testПервыйЗапускЗабываетОтветНаВопросКоторогоБольшеНет() {
        // Что человек видел: настройки показывали «Столько дней · 30», хотя
        // продукт живёт по `afterTranscript`. Дефолт применяется только там, где
        // ключа нет, — записанному 17 августа значению смена дефолта иначе не
        // сказала бы ничего.
        XCTAssertEqual(
            AudioRetention.storedMode(raw: "afterDays", resetDone: false),
            .reset(.afterTranscript)
        )
        XCTAssertEqual(
            AudioRetention.storedMode(raw: "keep", resetDone: false),
            .reset(.afterTranscript)
        )
    }

    func testСбросПроисходитОдинРазИНеСъедаетВыборЧеловека() {
        // Иначе выбранные тридцать дней возвращались бы к дефолту каждый запуск,
        // и настройка вела бы себя как испорченная.
        XCTAssertEqual(
            AudioRetention.storedMode(raw: "afterDays", resetDone: true),
            .use(.afterDays)
        )
        XCTAssertEqual(
            AudioRetention.storedMode(raw: "afterTranscript", resetDone: true),
            .use(.afterTranscript)
        )
    }

    func testПустыеНастройкиНеПревращаютДефолтВВыбор() {
        // Ничего не записано — ничего и не записываем: запись на чтении сделала
        // бы нынешний дефолт выбором человека, и следующая его смена так же
        // молча прошла бы мимо.
        XCTAssertEqual(AudioRetention.storedMode(raw: nil, resetDone: true), .use(.afterTranscript))
        XCTAssertEqual(AudioRetention.storedMode(raw: "", resetDone: true), .use(.afterTranscript))
    }

    func testУдалённыйРежимНеОставляетСегментедПустым() {
        // «Всегда» удалён, но в defaults он ещё может лежать — своей рукой или с
        // машины, где сброс уже прошёл. Сегментед держит строку из defaults
        // напрямую, и незнакомое значение не выбрало бы ни один из двух пунктов.
        XCTAssertEqual(
            AudioRetention.storedMode(raw: "keep", resetDone: true),
            .reset(.afterTranscript)
        )
        XCTAssertEqual(
            AudioRetention.storedMode(raw: "afterMonths", resetDone: true),
            .reset(.afterTranscript)
        )
    }

    // MARK: - Кого нельзя трогать ни при каком сроке

    func testНиОднаСтадияНуждающаясяВЗвукеНеТеряетЕгоНиПриКакомСроке() {
        // Свойство, а не пример: правило retention не имеет права ответить
        // «можно» там, где `AudioReclaim` отвечает «нельзя», — иначе встреча
        // останется без входа ASR навсегда, а встреча без текста исчезнет из
        // списка.
        for stage in RecordingStage.allCases {
            for hasTranscript in [true, false] {
                let candidate = AudioRetention.Candidate(
                    id: "\(stage.rawValue)-\(hasTranscript)",
                    date: now.addingTimeInterval(-10 * 365 * 86_400),
                    stage: stage, hasTranscript: hasTranscript, hasAudio: true
                )
                for mode in AudioRetentionMode.allCases {
                    let expired = AudioRetention.expired([candidate], mode: mode, now: now)
                    guard !expired.isEmpty else { continue }
                    XCTAssertTrue(
                        AudioReclaim.isExpendable(stage: stage, hasTranscript: hasTranscript),
                        "\(stage.rawValue)/\(hasTranscript) при \(mode.rawValue)"
                    )
                }
            }
        }
    }

    func testИдущаяЗаписьНеПопадаетПодRetentionДажеСДатойВПрошлом() {
        // У встречи, которую восстановили после краша, дата может быть старой, а
        // файл — тем самым, в который прямо сейчас пишут.
        let live = AudioRetention.Candidate(
            id: "пишется", date: now.addingTimeInterval(-100 * 86_400),
            stage: .recording, hasTranscript: true, hasAudio: true
        )
        XCTAssertEqual(AudioRetention.expired([live], mode: .afterDays, now: now), [])
        XCTAssertEqual(AudioRetention.expired([live], mode: .afterTranscript, now: now), [])
    }

    func testВстречаБезЗвукаНеСчитаетсяИстёкшей() {
        // Иначе счётчик «освободили у N встреч» врёт каждый раз: у половины
        // архива забирать уже нечего.
        let already = done("аудио-уже-нет", daysAgo: 100, hasAudio: false)
        XCTAssertEqual(AudioRetention.expired([already], mode: .afterDays, now: now), [])
    }
}
