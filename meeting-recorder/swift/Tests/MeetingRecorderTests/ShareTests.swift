import XCTest
@testable import PropellerPure

/// Что проверяется здесь: ссылка, документ и круг шифрования — то есть всё,
/// что решает, увидит ли сервер содержимое. Сеть и Keychain остались в
/// `Sources/ShareService.swift`, куда тест не дотягивается.
final class ShareTests: XCTestCase {

    // MARK: - Слаг

    func testTheMeetingNameBecomesReadableLatin() {
        XCTAssertEqual(ShareLink.slugify("Встреча с Даней"), "vstrecha-s-daney")
        XCTAssertEqual(ShareLink.slugify("Квартальный созвон"), "kvartalnyy-sozvon")
        XCTAssertEqual(ShareLink.slugify("Weekly с Прагматикой"), "weekly-s-pragmatikoy")
    }

    /// «ь» и «ъ» отдают пустоту, а не разделитель: иначе «Пьеса» стала бы `p-esa`.
    func testTheSoftSignDoesNotBreakAWord() {
        XCTAssertEqual(ShareLink.slugify("Пьеса"), "pesa")
        XCTAssertEqual(ShareLink.slugify("Съезд"), "sezd")
    }

    func testPunctuationAndSpacesCollapseIntoOneDash() {
        XCTAssertEqual(ShareLink.slugify("Ретро — что пошло не так?"), "retro-chto-poshlo-ne-tak")
        // «ё» → `e`, как в загранпаспорте: «Пётр» пишется `petr`, и заводить
        // для одной буквы второе правило — значит спорить с тем, как люди
        // сами пишут свои имена латиницей.
        XCTAssertEqual(ShareLink.slugify("  1:1   с Лёшей  "), "1-1-s-leshey")
    }

    /// Алфавиты, которых нет в таблице, ведут себя как разделитель: адрес
    /// важнее полноты, а процентная каша в ссылке — это ровно то, от чего
    /// слаг заводился.
    func testAnUntransliterableTitleDegradesToAnEmptySlug() {
        XCTAssertEqual(ShareLink.slugify("会議"), "")
        XCTAssertEqual(ShareLink.slugify("🎉🎉🎉"), "")
        XCTAssertEqual(ShareLink.slugify(""), "")
    }

    func testALongTitleIsCutAtAWordAndNotMidWord() {
        let slug = ShareLink.slugify(
            "Обсуждение архитектуры платежей и всего остального что накопилось за квартал"
        )
        XCTAssertLessThanOrEqual(slug.count, 48)
        XCTAssertFalse(slug.hasSuffix("-"))
        // Резать посреди слова — читается как опечатка; целые слова — как сокращение.
        XCTAssertTrue(slug.hasPrefix("obsuzhdenie-arhitektury-platezhey"), slug)
    }

    // MARK: - Ссылка

    /// Главное свойство ссылки: ни ключа, ни названия встречи нет в той части,
    /// которую браузер отправляет серверу. Проверяется путь, а не намерение.
    func testNeitherTheKeyNorTheNameLeavesTheFragment() throws {
        let key = Data(repeating: 0xAB, count: 32)
        let url = try XCTUnwrap(ShareLink.url(id: "aZ09-_aZ09-_aZ09-_aZ09", key: key, title: "Встреча с Даней"))

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/s/aZ09-_aZ09-_aZ09-_aZ09")
        XCTAssertNil(components.query)
        let fragment = try XCTUnwrap(components.fragment)
        XCTAssertTrue(fragment.hasPrefix("vstrecha-s-daney&k="), fragment)
    }

    func testTheLinkRoundTrips() throws {
        let key = Data((0..<32).map { UInt8($0) })
        let url = try XCTUnwrap(ShareLink.url(id: "aZ09-_aZ09-_aZ09-_aZ09", key: key, title: "Ретро"))
        let parsed = try XCTUnwrap(ShareLink.parse(url))
        XCTAssertEqual(parsed.id, "aZ09-_aZ09-_aZ09-_aZ09")
        XCTAssertEqual(parsed.key, key)
    }

    /// Встреча без названия ссылку не ломает — просто теряет украшение.
    func testAnUnnamedMeetingStillGetsAWorkingLink() throws {
        let url = try XCTUnwrap(ShareLink.url(id: "aZ09-_aZ09-_aZ09-_aZ09", key: Data(repeating: 1, count: 32), title: ""))
        XCTAssertEqual(url.fragment(percentEncoded: false)?.hasPrefix("k="), true)
        XCTAssertNotNil(ShareLink.parse(url))
    }

    func testBase64urlCarriesNoCharacterThatAUrlWouldEscape() {
        let encoded = ShareLink.base64url(Data((0..<32).map { UInt8($0 &* 7) }))
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
        XCTAssertEqual(ShareLink.data(base64url: encoded), Data((0..<32).map { UInt8($0 &* 7) }))
    }

    // MARK: - Документ

    private var summary: SummaryDocument {
        SummaryDocument(blocks: [
            .init(id: "1", kind: .lead, text: "Договорились перенести релиз."),
            .init(id: "2", kind: .heading, text: "Решения"),
            .init(id: "3", kind: .bullet, spans: [
                .init("Релиз уезжает на "), .init("3 сентября", bold: true),
            ]),
            .init(id: "4", kind: .body, spans: []),
            .init(id: "5", kind: .body, spans: [.init("Вернуться", italic: true)]),
        ])
    }

    func testTheSharedDocumentIsWhatThePaneDraws() throws {
        let payload = SharePayload.make(
            title: "Квартальный созвон",
            date: DateComponents(
                calendar: .current, timeZone: .current,
                year: 2026, month: 8, day: 22, hour: 16, minute: 30
            ).date,
            peopleCount: 6,
            document: summary,
            now: DateComponents(
                calendar: .current, timeZone: .current, year: 2026, month: 8, day: 27
            ).date!
        )

        XCTAssertEqual(payload.title, "Квартальный созвон")
        XCTAssertEqual(payload.meta, ["22 авг, 16:30", "6 человек"])
        // Пустой блок — разделительная строка markdown, на экране её нет.
        XCTAssertEqual(payload.blocks.map(\.kind), ["lead", "heading", "bullet", "body"])
        XCTAssertEqual(payload.blocks[2].spans[1].bold, true)
        XCTAssertEqual(payload.blocks[3].spans[0].italic, true)
    }

    /// `"bold":false` у каждого отрезка — треть веса блоба на слове, которое
    /// ничего не значит. Поэтому невыделенный отрезок ключа не несёт вовсе.
    func testAPlainSpanCarriesNoFlagsAtAll() throws {
        let payload = SharePayload.make(
            title: "Ретро", date: nil, peopleCount: 0, document: summary
        )
        let json = try String(decoding: payload.encoded(), as: UTF8.self)
        XCTAssertFalse(json.contains("false"), json)
        XCTAssertTrue(json.contains("\"v\":1"))
        // Ни даты, ни людей — чипов нет, а не «0 человек».
        XCTAssertEqual(payload.meta, [])
    }

    // MARK: - Крипта

    func testTheSummaryComesBackOutTheOtherSide() throws {
        let plaintext = try SharePayload.make(
            title: "Квартальный созвон", date: Date(), peopleCount: 6, document: summary
        ).encoded()

        let sealed = try ShareCrypto.seal(plaintext)
        XCTAssertEqual(try ShareCrypto.open(blob: sealed.blob, key: sealed.key), plaintext)
    }

    /// Форма блоба — это контракт с браузером: вьюер отрезает первые 12 байт
    /// и зовёт WebCrypto. Сдвиг на байт здесь ломает каждую живую ссылку.
    func testTheBlobIsANonceFollowedBySealedBytes() throws {
        let plaintext = Data("саммари".utf8)
        let sealed = try ShareCrypto.seal(plaintext)
        let deflated = try ShareCrypto.deflate(plaintext)

        XCTAssertEqual(sealed.key.count, 32)
        // nonce 12 + шифротекст ровно в размер сжатого + тег 16.
        XCTAssertEqual(sealed.blob.count, 12 + deflated.count + 16)
    }

    func testTwoSealsOfTheSameTextShareNothing() throws {
        let plaintext = Data("одно и то же саммари".utf8)
        let first = try ShareCrypto.seal(plaintext)
        let second = try ShareCrypto.seal(plaintext)
        XCTAssertNotEqual(first.key, second.key)
        XCTAssertNotEqual(first.blob, second.blob)
    }

    func testAWrongKeyOpensNothing() throws {
        let sealed = try ShareCrypto.seal(Data("саммари".utf8))
        var wrong = sealed.key
        wrong[0] ^= 0xFF
        XCTAssertThrowsError(try ShareCrypto.open(blob: sealed.blob, key: wrong))
    }

    /// GCM — это ещё и подпись: подменённый на сервере байт не расшифруется,
    /// а не покажет искажённое саммари.
    func testATamperedBlobIsRejected() throws {
        var sealed = try ShareCrypto.seal(Data("саммари, которое кто-то поправил".utf8))
        var blob = sealed.blob
        blob[20] ^= 0x01
        XCTAssertThrowsError(try ShareCrypto.open(blob: blob, key: sealed.key))
        sealed = try ShareCrypto.seal(Data("x".utf8))
        XCTAssertNoThrow(try ShareCrypto.open(blob: sealed.blob, key: sealed.key))
    }

    /// Разжиматель растит буфер, пока влезет. Длинное саммари — то, на чём
    /// первый вариант с одним буфером молча возвращал ноль.
    func testALongSummarySurvivesTheRoundTrip() throws {
        let long = Data(String(repeating: "Договорились перенести релиз на неделю. ", count: 5000).utf8)
        let sealed = try ShareCrypto.seal(long)
        XCTAssertLessThan(sealed.blob.count, long.count / 4)
        XCTAssertEqual(try ShareCrypto.open(blob: sealed.blob, key: sealed.key), long)
    }

    // MARK: - Контракт с браузером

    /// Кладёт живой блоб и ключ на диск — чтобы страницу расшифровал настоящий
    /// браузер, а не второй экземпляр этой же математики.
    ///
    /// Круг «зашифровали → расшифровали» в Swift замкнут выше и ничего не
    /// говорит про WebCrypto и `DecompressionStream`: разойтись они могут в
    /// длине nonce, в порядке тега и в том, что `COMPRESSION_ZLIB` — сырой
    /// DEFLATE, а не gzip. Это единственный способ спросить у той стороны.
    ///
    ///     SHARE_BLOB=/tmp/share swift test --filter testTheBlobIsReadableByARealBrowser
    ///
    /// Пишет `<path>.bin` и `<path>.key`; без переменной — пропускается.
    func testTheBlobIsReadableByARealBrowser() throws {
        guard let path = ProcessInfo.processInfo.environment["SHARE_BLOB"] else {
            throw XCTSkip("SHARE_BLOB не задан")
        }
        let payload = SharePayload.make(
            title: "Квартальный созвон",
            date: DateComponents(
                calendar: .current, timeZone: .current,
                year: 2026, month: 8, day: 22, hour: 16, minute: 30
            ).date,
            peopleCount: 6,
            document: summary
        )
        let sealed = try ShareCrypto.seal(payload.encoded())
        try sealed.blob.write(to: URL(fileURLWithPath: path + ".bin"))
        try Data(ShareLink.base64url(sealed.key).utf8)
            .write(to: URL(fileURLWithPath: path + ".key"))
    }
}
