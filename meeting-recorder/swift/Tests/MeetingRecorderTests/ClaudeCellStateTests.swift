import XCTest
import PropellerPure

/// Ячейка «Claude» в настройках. Проверяется тем, что человек прочитает: у этой
/// фичи нет никакого другого места, где он может узнать, работает она или нет.
final class ClaudeCellStateTests: XCTestCase {

    private func state(
        installed: Bool = true,
        configured: Bool = false,
        marked: Date? = nil,
        failed: Bool = false
    ) -> ClaudeCellState {
        ClaudeCellMachine.state(
            claudeInstalled: installed,
            configured: configured,
            markedAt: marked,
            lastWriteFailed: failed
        )
    }

    // MARK: - Таблица

    func testWithNothingDoneItIsAnOffer() {
        XCTAssertEqual(state(), .offer)
    }

    func testAWrittenConfigThatClaudeHasNotReadAsksForARestart() {
        XCTAssertEqual(state(configured: true), .restartNeeded)
    }

    func testAMarkAfterTheConfigMeansConnected() {
        XCTAssertEqual(state(configured: true, marked: Date()), .connected)
    }

    /// Запись пропала, а отметка осталась — единственное, чем это может быть:
    /// Клод переписал свой конфиг целиком.
    func testAMarkWithoutAConfigMeansTheConnectionWentMissing() {
        XCTAssertEqual(state(configured: false, marked: Date()), .lost)
    }

    // MARK: - Что старше чего

    /// Клода нет — про чужой конфиг говорить нечего, чей бы он ни был. Иначе
    /// человек, снёсший Клода, читал бы «Claude подключён».
    func testWithoutClaudeNothingElseMatters() {
        XCTAssertEqual(state(installed: false, configured: true, marked: Date()), .notInstalled)
        XCTAssertEqual(state(installed: false, failed: true), .notInstalled)
    }

    /// Отказ записи — это ответ на нажатие, и он старше того, что выводится из
    /// файлов: человек только что нажал, и обязан узнать, чем это кончилось.
    func testAFailedWriteOutranksTheFilesUnderIt() {
        XCTAssertEqual(state(configured: false, marked: nil, failed: true), .writeFailed)
        XCTAssertEqual(state(configured: true, marked: Date(), failed: true), .writeFailed)
    }

    // MARK: - Слова

    func testEveryStateSaysSomething() {
        for state in ClaudeCellState.allCases {
            XCTAssertFalse(state.subtitle.isEmpty, state.rawValue)
        }
        XCTAssertEqual(Set(ClaudeCellState.allCases.map(\.subtitle)).count, ClaudeCellState.allCases.count)
    }

    /// Кнопка есть ровно там, где нажатие что-то меняет. «Перезапустите» и
    /// «подключён» кнопки не носят: в первом случае очередь за человеком и его
    /// открытыми чатами, во втором делать уже нечего.
    func testTheButtonIsOnlyWhereAPressWouldChangeSomething() {
        XCTAssertEqual(state().actionTitle, "Подключить")
        XCTAssertEqual(state(configured: false, marked: Date()).actionTitle, "Подключить")
        XCTAssertEqual(state(failed: true).actionTitle, "Подключить")
        XCTAssertNil(state(configured: true).actionTitle)
        XCTAssertNil(state(configured: true, marked: Date()).actionTitle)
        XCTAssertNil(state(installed: false).actionTitle)
    }

    /// Подключение и переподключение — одно действие, поэтому подпись у них
    /// одна. Разные слова означали бы разные ветки в коде, которых нет.
    func testReconnectingIsTheSameActionAndSaysSo() {
        XCTAssertEqual(state().actionTitle, state(configured: false, marked: Date()).actionTitle)
    }

    func testOnlyTheMissingAppOffersALink() {
        XCTAssertEqual(state(installed: false).linkURL, ClaudeConnection.downloadURL)
        for state in ClaudeCellState.allCases where state != .notInstalled {
            XCTAssertNil(state.linkURL, state.rawValue)
        }
    }

    func testTheCheckmarkBelongsToConnectedAlone() {
        XCTAssertEqual(ClaudeCellState.allCases.filter(\.showsCheckmark), [.connected])
    }

    /// Ни одно состояние не просит человека разбираться: причина отказа записи
    /// уезжает в телеметрию, а не в строку под заголовком.
    func testNoStateAsksThePersonToDebugAnything() {
        for state in ClaudeCellState.allCases {
            for word in ["Повтор", "Попроб", "Ошибка", "ажмите", "путь", "JSON"] {
                XCTAssertFalse(state.subtitle.contains(word), "«\(state.subtitle)» содержит «\(word)»")
            }
        }
    }
}
