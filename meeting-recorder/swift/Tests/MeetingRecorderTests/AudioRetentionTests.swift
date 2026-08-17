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

    // MARK: - Дефолт

    func testПоУмолчаниюОбновлениеНеУноситНиОдногоФайла() {
        // Единственный дефолт, который можно поставить, не спросив человека: у
        // апдейта нет способа спросить, а retention с любым N в первый же запуск
        // прошёл бы по всему уже лежащему архиву.
        let archive = (0 ..< 50).map { done("m\($0)", daysAgo: $0 * 10) }
        XCTAssertEqual(AudioRetention.expired(archive, mode: .keep, now: now), [])
    }

    func testРазумныйДефолтСрокаНазванЧисломАНеПодразумевается() {
        XCTAssertEqual(AudioRetention.defaultDays, 30)
        XCTAssertTrue(AudioRetention.dayRange.contains(AudioRetention.defaultDays))
    }

    // MARK: - Через N дней

    func testСрокИстекаетВДеньКогдаПрошлоРовноN() {
        let candidates = [done("свежая", daysAgo: 29), done("истёкшая", daysAgo: 30)]
        XCTAssertEqual(
            AudioRetention.expired(candidates, mode: .afterDays, days: 30, now: now),
            ["истёкшая"]
        )
    }

    func testНастройкаНеУмеетВыставитьНольДней() {
        // Ноль означал бы `afterTranscript`, сказанный другим способом. Двух
        // путей к одному поведению не бывает: человек выключит один и удивится.
        XCTAssertEqual(AudioRetention.clampedDays(0), 1)
        XCTAssertEqual(AudioRetention.clampedDays(-5), 1)
        XCTAssertEqual(AudioRetention.clampedDays(10_000), 365)
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
                for mode in [AudioRetentionMode.afterTranscript, .afterDays] {
                    let expired = AudioRetention.expired(
                        [candidate], mode: mode, days: 1, now: now
                    )
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
        XCTAssertEqual(AudioRetention.expired([live], mode: .afterDays, days: 1, now: now), [])
        XCTAssertEqual(AudioRetention.expired([live], mode: .afterTranscript, now: now), [])
    }

    func testВстречаБезЗвукаНеСчитаетсяИстёкшей() {
        // Иначе счётчик «освободили у N встреч» врёт каждый раз: у половины
        // архива забирать уже нечего.
        let already = done("аудио-уже-нет", daysAgo: 100, hasAudio: false)
        XCTAssertEqual(AudioRetention.expired([already], mode: .afterDays, days: 30, now: now), [])
    }
}
