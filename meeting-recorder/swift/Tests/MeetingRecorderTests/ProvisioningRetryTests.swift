import XCTest
@testable import PropellerPure

/// §10 «Фоновые обязательства» для стартовой воронки: лестница без конца,
/// классы отказа измерением, сигналы сбрасывают. Каждый тест — пункт секции.
final class ProvisioningRetryTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    // MARK: - Лестница

    func testЛестницаДоходитДоЧасаИОстаётсяТамНавсегда() {
        var ladder = ProvisioningLadder()
        var delays: [TimeInterval] = []
        for _ in 1...50 {
            delays.append(ladder.failed(.other, at: now).timeIntervalSince(now))
        }
        XCTAssertEqual(Array(delays.prefix(5)), [20, 60, 300, 1200, 3600])
        XCTAssertTrue(delays.dropFirst(4).allSatisfy { $0 == 3600 },
                      "хвост — час, и никогда больше часа")
        for (a, b) in zip(delays, delays.dropFirst()) {
            XCTAssertLessThanOrEqual(a, b, "лестница не ходит назад")
        }
    }

    func testНиОдинКлассНеТерминален() {
        // `failed` возвращает Date, не Optional — обещание §10 держит тип.
        // Тест документирует: даже disk и refused получают следующую попытку.
        for failureClass in ProvisioningRetry.FailureClass.allCases {
            var ladder = ProvisioningLadder()
            let next = ladder.failed(failureClass, at: now)
            XCTAssertGreaterThan(next, now, "\(failureClass)")
        }
    }

    func testШестьМгновенныхОшибокНеТратятПравоНаСедьмую() {
        // Реплика инцидента 2026-08-22: старая конечная лестница сгорала за
        // ~17 минут мгновенных ошибок и замолкала навсегда.
        var ladder = ProvisioningLadder()
        for _ in 1...6 { _ = ladder.failed(.instant, at: now) }
        let seventh = ladder.failed(.instant, at: now)
        XCTAssertEqual(seventh.timeIntervalSince(now), 3600)
    }

    // MARK: - Классы измерением

    func testМгновеннаяСмертьБезПрогрессаЭтоInstant() {
        XCTAssertEqual(
            ProvisioningRetry.transportClass(duration: 0.9, sinceLastProgress: 0.9, sawProgress: false),
            .instant
        )
    }

    func testРовноНаПорогеУжеНеInstant() {
        XCTAssertEqual(
            ProvisioningRetry.transportClass(
                duration: ProvisioningRetry.instantThreshold,
                sinceLastProgress: ProvisioningRetry.instantThreshold,
                sawProgress: false
            ),
            .other
        )
    }

    func testМолчаниеТриМинутыЭтоStallДажеПослеПрогресса() {
        XCTAssertEqual(
            ProvisioningRetry.transportClass(duration: 600, sinceLastProgress: 180, sawProgress: true),
            .stall
        )
    }

    func testНеНачавшийсяPullМолчащийТриМинутыЭтоStall() {
        XCTAssertEqual(
            ProvisioningRetry.transportClass(duration: 200, sinceLastProgress: 200, sawProgress: false),
            .stall
        )
    }

    func testСмертьЧерезСорокСекундБезПрогрессаЭтоOther() {
        XCTAssertEqual(
            ProvisioningRetry.transportClass(duration: 40, sinceLastProgress: 40, sawProgress: false),
            .other
        )
    }

    func testВотчдогИКлассификаторОдноЧисло() {
        // Вотчдог обрывает попытку ровно там, где классификатор назовёт её stall,
        // иначе «что считается зависанием» — два числа, которые разъедутся.
        for since: TimeInterval in [0, 60, 179.9, 180, 181, 3600] {
            XCTAssertEqual(
                ProvisioningRetry.shouldAbort(sinceLastProgress: since),
                ProvisioningRetry.transportClass(
                    duration: since + 100, sinceLastProgress: since, sawProgress: true
                ) == .stall,
                "since=\(since)"
            )
        }
    }

    // MARK: - Кромка сетевого сигнала

    func testПервыйОтсчётЭтоБазаАНеСигнал() {
        // Сеть, которая была живой всё время, — не новость: принять базу за
        // восстановление значит превратить сигнал в таймер, который §10 запрещает.
        var edge = NetworkRestoreEdge()
        XCTAssertFalse(edge.observe(satisfied: true))
        XCTAssertFalse(edge.observe(satisfied: false))
    }

    func testВозвратСетиСрабатываетРовноОдинРаз() {
        var edge = NetworkRestoreEdge()
        _ = edge.observe(satisfied: false)
        XCTAssertTrue(edge.observe(satisfied: true))
        XCTAssertFalse(edge.observe(satisfied: true), "повтор satisfied — не событие")
    }

    func testКаждоеНовоеПадениеДаётНовыйВозврат() {
        var edge = NetworkRestoreEdge()
        _ = edge.observe(satisfied: false)
        XCTAssertTrue(edge.observe(satisfied: true))
        _ = edge.observe(satisfied: false)
        XCTAssertTrue(edge.observe(satisfied: true))
    }

    // MARK: - Живость pull

    func testРастущиеБайтыПриОдномСтатусеЭтоДвижение() {
        var live = PullLiveness()
        XCTAssertTrue(live.advanced(status: "pulling sha256:aa", completed: 100))
        XCTAssertTrue(live.advanced(status: "pulling sha256:aa", completed: 200))
    }

    func testТаЖеСтрокаДословноЭтоКлин() {
        var live = PullLiveness()
        _ = live.advanced(status: "pulling sha256:aa", completed: 300)
        XCTAssertFalse(live.advanced(status: "pulling sha256:aa", completed: 300))
        XCTAssertFalse(live.advanced(status: "pulling sha256:aa", completed: 300))
    }

    func testНовыйБлобСНуляЭтоДвижениеАНеОткат() {
        // Пойманный руками баг ревью 2026-08-22: правило «байты выросли»
        // считало блоб после большого 3,4-ГБ тремя минутами тишины и убивало
        // живую закачку вотчдогом.
        var live = PullLiveness()
        _ = live.advanced(status: "pulling sha256:big", completed: 3_400_000_000)
        XCTAssertTrue(live.advanced(status: "pulling sha256:small", completed: 0))
        XCTAssertTrue(live.advanced(status: "pulling sha256:small", completed: 512))
    }

    func testСменаФазыБезБайтовЭтоДвижение() {
        var live = PullLiveness()
        XCTAssertTrue(live.advanced(status: "pulling manifest", completed: nil))
        XCTAssertFalse(live.advanced(status: "pulling manifest", completed: nil))
        XCTAssertTrue(live.advanced(status: "verifying sha256 digest", completed: nil))
    }

    func testПустойСтатусНичегоНеДвигает() {
        var live = PullLiveness()
        XCTAssertFalse(live.advanced(status: "", completed: nil))
    }

    // MARK: - Сигналы

    func testСетьВернуласьТранспортныеОтказыНачинаютСНачала() {
        for failureClass: ProvisioningRetry.FailureClass in [.instant, .stall, .other] {
            var ladder = ProvisioningLadder()
            for _ in 1...4 { _ = ladder.failed(failureClass, at: now) }
            XCTAssertTrue(ladder.signal(.networkPathRestored), "\(failureClass)")
            let next = ladder.failed(failureClass, at: now)
            XCTAssertEqual(next.timeIntervalSince(now), 20,
                           "после сброса — первая ступень, \(failureClass)")
        }
    }

    func testСетьВернуласьДискИОтказСервераНеСбрасываются() {
        // Сеть не освобождает диск и не меняет ответ сервера, который посмотрел
        // на запрос и сказал «нет».
        for failureClass: ProvisioningRetry.FailureClass in [.disk, .refused] {
            var ladder = ProvisioningLadder()
            _ = ladder.failed(failureClass, at: now)
            XCTAssertFalse(ladder.signal(.networkPathRestored), "\(failureClass)")
            XCTAssertEqual(ladder.attempt, 1, "лестница не тронута, \(failureClass)")
        }
    }

    func testПробуждениеСбрасываетЛюбойКласс() {
        for failureClass in ProvisioningRetry.FailureClass.allCases {
            var ladder = ProvisioningLadder()
            _ = ladder.failed(failureClass, at: now)
            XCTAssertTrue(ladder.signal(.wokeOrActivated), "\(failureClass)")
        }
    }

    func testСигналБезОтказаНеПроситПопытку() {
        // Wi-Fi мигает весь день; пока ничего не сломано, лестница молчит —
        // иначе сигнал превращается в таймер, которого §10 запрещает.
        var ladder = ProvisioningLadder()
        XCTAssertFalse(ladder.signal(.networkPathRestored))
        XCTAssertFalse(ladder.signal(.wokeOrActivated))
    }

    func testУспехЗакрываетЛестницу() {
        var ladder = ProvisioningLadder()
        _ = ladder.failed(.stall, at: now)
        ladder.succeeded()
        XCTAssertEqual(ladder.attempt, 0)
        XCTAssertNil(ladder.lastClass)
        XCTAssertFalse(ladder.signal(.networkPathRestored), "закрытую лестницу нечего сбрасывать")
    }
}
