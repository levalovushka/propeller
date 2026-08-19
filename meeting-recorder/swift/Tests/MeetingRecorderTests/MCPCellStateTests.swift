import XCTest
import PropellerPure

/// Ячейка «Claude» в настройках. Проверяется тем, что человек прочитает: у этой
/// фичи нет никакого другого места, где он может узнать, работает она или нет.
final class MCPCellStateTests: XCTestCase {

    private func state(
        installed: Bool = true,
        configured: Bool = false,
        marked: Date? = nil,
        failed: Bool = false
    ) -> MCPCellState {
        MCPCellMachine.state(
            installed: installed,
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

    /// Каждое состояние либо говорит что-то своё, либо молчит — и молчат ровно
    /// два, оба потому, что за них говорит то, что стоит справа: у отказа
    /// записи — кнопка «Попробовать снова», у подключённого — галочка.
    func testEveryStateEitherSaysSomethingOfItsOwnOrSaysNothing() {
        let said = MCPCellState.allCases.compactMap { $0.subtitle(for: .claudeDesktop) }
        XCTAssertEqual(Set(said).count, said.count)
        XCTAssertTrue(said.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(
            MCPCellState.allCases.filter { $0.subtitle(for: .claudeDesktop) == nil },
            [.connected, .writeFailed]
        )
    }

    /// Молчащее состояние обязано нести смысл кнопкой — иначе строка не
    /// отличается от предложения подключиться.
    func testTheSilentStateSaysItInTheButton() {
        XCTAssertEqual(MCPCellState.writeFailed.actionTitle, "Попробовать снова")
    }

    /// Строка не бывает пустой: если состояние молчит, за него обязано говорить
    /// то, что стоит справа. Без этой проверки снятая подпись однажды оставит
    /// заголовок в одиночестве, и человек прочитает строку как незаполненную.
    func testМолчащаяСтрокаВсегдаЧтоТоПоказываетСправа() {
        for client in MCPClient.connectable {
            for state in MCPCellState.allCases where state.subtitle(for: client) == nil {
                XCTAssertTrue(
                    state.actionTitle != nil || state.showsCheckmark,
                    "\(state.rawValue) молчит и справа пуст"
                )
            }
        }
    }

    /// Просьба перезапустить — единственная строка, где имя приложения уместно:
    /// у неё есть адресат, а на экране в этот момент три приложения сразу.
    func testTheRestartLineNamesWhatToRestart() {
        XCTAssertEqual(MCPCellState.restartNeeded.subtitle(for: .claudeDesktop)?.contains(MCPClient.claudeDesktop.rowTitle), true)
    }

    /// Заголовок строки называет клиента и не зависит от состояния: группа
    /// называется «MCP», и рядом встанут другие строки — заголовок, меняющийся
    /// вместе со статусом, перестанет отвечать на «кто это».
    func testTheRowIsNamedAfterTheClientAndTheStateStaysInTheSecondLine() {
        XCTAssertEqual(MCPClient.claudeDesktop.rowTitle, "Claude Desktop")
        // Ни одна подпись не начинается с имени: оно уже стоит слева. Внутри
        // строки оно появляется там, где без адресата нельзя, — см.
        // `testTheRestartLineNamesWhatToRestart`.
        for state in MCPCellState.allCases {
            XCTAssertFalse(state.subtitle(for: .claudeDesktop)?.hasPrefix(MCPClient.claudeDesktop.rowTitle) == true,
                           "«\(state.subtitle(for: .claudeDesktop) ?? "")» начинается с заголовка строки")
        }
    }

    /// Русская типографика в интерфейсных строках (`checks.yaml`):
    /// однобуквенный предлог не остаётся в конце строки.
    func testOneLetterPrepositionsAreTiedToTheirWord() {
        for state in MCPCellState.allCases {
            guard let subtitle = state.subtitle(for: .claudeDesktop) else { continue }
            for preposition in [" с ", " о ", " в ", " к ", " и ", " у "] {
                XCTAssertFalse(subtitle.contains(preposition),
                               "«\(subtitle)» рвётся на «\(preposition.trimmingCharacters(in: .whitespaces))»")
            }
        }
    }

    /// Кнопка есть ровно там, где нажатие что-то меняет. «Перезапустите» и
    /// «подключён» кнопки не носят: в первом случае очередь за человеком и его
    /// открытыми чатами, во втором делать уже нечего.
    func testTheButtonIsOnlyWhereAPressWouldChangeSomething() {
        XCTAssertEqual(state().actionTitle, "Подключить")
        XCTAssertEqual(state(configured: false, marked: Date()).actionTitle, "Подключить")
        XCTAssertEqual(state(failed: true).actionTitle, "Попробовать снова")
        XCTAssertNil(state(configured: true).actionTitle)
        XCTAssertNil(state(configured: true, marked: Date()).actionTitle)
        XCTAssertNil(state(installed: false).actionTitle)
    }

    /// Подключение и переподключение — одно действие, поэтому подпись у них
    /// одна. Разные слова означали бы разные ветки в коде, которых нет.
    func testReconnectingIsTheSameActionAndSaysSo() {
        XCTAssertEqual(state().actionTitle, state(configured: false, marked: Date()).actionTitle)
    }

    /// У «не установлен» справа нет ничего: уводить человека в браузер за чужим
    /// приложением — не наше дело, и такой кнопки в приложении нет нигде.
    func testTheMissingAppOffersNoControlAtAll() {
        XCTAssertNil(state(installed: false).actionTitle)
        XCTAssertFalse(state(installed: false).showsCheckmark)
    }

    func testTheCheckmarkBelongsToConnectedAlone() {
        XCTAssertEqual(MCPCellState.allCases.filter(\.showsCheckmark), [.connected])
    }

    /// Ни одно состояние не просит человека разбираться: причина отказа записи
    /// уезжает в телеметрию, а не в строку под заголовком.
    func testNoStateAsksThePersonToDebugAnything() {
        for state in MCPCellState.allCases {
            guard let subtitle = state.subtitle(for: .claudeDesktop) else { continue }
            for word in ["Ошибка", "ажмите", "путь", "JSON"] {
                XCTAssertFalse(subtitle.contains(word), "«\(subtitle)» содержит «\(word)»")
            }
        }
    }
}
