import XCTest
@testable import PropellerPure

/// Второй клиент не должен зажигать галочку у первого — и наоборот.
final class MCPClientTests: XCTestCase {

    // MARK: - Кто нас запустил

    /// Подпись в окружении написали мы сами, когда подключали. Она точнее любого
    /// `clientInfo`, и поэтому старше его.
    func testОкружениеСтаршеИмениКлиента() {
        let resolved = MCPClient.resolve(
            env: [MCPClient.envKey: "chatgpt"], clientName: "claude-ai"
        )
        XCTAssertEqual(resolved, .chatGPT)
    }

    /// Запись могли добавить руками мимо кнопки — тогда подписи нет, и остаётся
    /// то, как клиент назвался сам.
    func testБезПодписиУзнаёмПоИмени() {
        XCTAssertEqual(MCPClient.resolve(env: [:], clientName: "claude-ai"), .claudeDesktop)
        XCTAssertEqual(MCPClient.resolve(env: [:], clientName: "Claude Desktop"), .claudeDesktop)
        XCTAssertEqual(MCPClient.resolve(env: [:], clientName: "codex"), .chatGPT)
        XCTAssertEqual(MCPClient.resolve(env: [:], clientName: "ChatGPT"), .chatGPT)
    }

    /// Незнакомый клиент — не повод писать отметку наугад: она зажгла бы галочку
    /// не у того. «Никто не подключён» честнее и поправимо кнопкой.
    func testНезнакомыйКлиентНеОпознаётся() {
        XCTAssertNil(MCPClient.resolve(env: [:], clientName: "cursor"))
        XCTAssertNil(MCPClient.resolve(env: [:], clientName: nil))
        XCTAssertNil(MCPClient.resolve(env: [MCPClient.envKey: "перплексити"], clientName: nil))
    }

    // MARK: - Ничего общего, кроме сервера

    func testУКаждогоКлиентаСвояОтметкаИСвойКонфиг() {
        let markers = Set(MCPClient.allCases.map(\.markerFileName))
        XCTAssertEqual(markers.count, MCPClient.allCases.count)
        let configs = Set(MCPClient.allCases.map(\.configLocation))
        XCTAssertEqual(configs.count, MCPClient.allCases.count)
    }

    /// Имя отметки Клода лежит на дисках людей, подключившихся до появления
    /// второго клиента. Переименование стоило бы им вечного «перезапустите».
    func testИмяОтметкиКлодаНеМенялось() {
        XCTAssertEqual(MCPClient.claudeDesktop.markerFileName, "claude-mcp-seen")
    }

    /// `rawValue` уезжает в чужие конфиги как значение переменной окружения —
    /// поменять его значит перестать узнавать уже подключённых.
    func testТокеныКлиентовЗакреплены() {
        XCTAssertEqual(MCPClient.claudeDesktop.rawValue, "claude")
        XCTAssertEqual(MCPClient.chatGPT.rawValue, "chatgpt")
    }

    // MARK: - Слова

    /// Единственное место, где строки клиентов расходятся, и расходятся не
    /// косметически: Клода просят перезапустить, потому что это ускорит дело;
    /// у ChatGPT просить нечего — Codex возьмёт сервер сам, когда понадобится.
    func testОжиданиеОбъясняетсяПоРазномуИНеПроситЛишнего() {
        let claude = MCPCellState.restartNeeded.subtitle(for: .claudeDesktop)
        let chatGPT = MCPCellState.restartNeeded.subtitle(for: .chatGPT)

        XCTAssertEqual(claude?.contains("Перезапустите"), true)
        XCTAssertEqual(chatGPT?.contains("Перезапустите"), false)
        XCTAssertNotEqual(claude, chatGPT)
    }

    func testОстальныеСостоянияГоворятОдноИТоЖе() {
        for state in MCPCellState.allCases where state != .restartNeeded && state != .notInstalled {
            XCTAssertEqual(
                state.subtitle(for: .claudeDesktop), state.subtitle(for: .chatGPT),
                "\(state.rawValue) разошлось без причины"
            )
        }
    }

    func testНеУстановленНазываетЧьёПриложение() {
        XCTAssertEqual(
            MCPCellState.notInstalled.subtitle(for: .claudeDesktop)?.contains("Anthropic"), true
        )
        XCTAssertEqual(
            MCPCellState.notInstalled.subtitle(for: .chatGPT)?.contains("OpenAI"), true
        )
    }

    // MARK: - Инструменты

    /// Клод остаётся при пяти: два почти-дубля в его списке разбавили бы
    /// описания, на которых всё держится.
    func testSearchИFetchВидитТолькоChatGPT() {
        XCTAssertEqual(ClaudeMCP.tools(for: .claudeDesktop).count, ClaudeMCP.tools.count)
        XCTAssertEqual(ClaudeMCP.tools(for: nil).count, ClaudeMCP.tools.count)

        let names = ClaudeMCP.tools(for: .chatGPT).map(\.name)
        XCTAssertTrue(names.contains(ClaudeMCP.searchDocuments))
        XCTAssertTrue(names.contains(ClaudeMCP.fetchDocument))
        XCTAssertEqual(names.count, ClaudeMCP.tools.count + 2)
    }

    /// Инструмент, которого этому клиенту не показывали, он и позвать не может.
    func testНеПоказанныйИнструментНеВызывается() {
        XCTAssertNil(ClaudeMCP.tool(named: ClaudeMCP.searchDocuments, for: .claudeDesktop))
        XCTAssertNotNil(ClaudeMCP.tool(named: ClaudeMCP.searchDocuments, for: .chatGPT))
    }

    /// Контракт OpenAI: единственный строковый параметр у каждого.
    func testSearchИFetchДержатКонтрактOpenAI() throws {
        let search = try XCTUnwrap(ClaudeMCP.tool(named: ClaudeMCP.searchDocuments, for: .chatGPT))
        XCTAssertEqual(search.inputSchema.required, ["query"])
        XCTAssertEqual(search.inputSchema.properties.count, 1)
        XCTAssertEqual(search.inputSchema.properties["query"]?.type, "string")

        let fetch = try XCTUnwrap(ClaudeMCP.tool(named: ClaudeMCP.fetchDocument, for: .chatGPT))
        XCTAssertEqual(fetch.inputSchema.required, ["id"])
        XCTAssertEqual(fetch.inputSchema.properties.count, 1)
        XCTAssertEqual(fetch.inputSchema.properties["id"]?.type, "string")
    }

    /// Codex читает `instructions` и просит уложить самодостаточное в первые
    /// 512 знаков. У нас всё короче — проверка стоит, чтобы так и осталось.
    func testПодсказкаСервераВлезаетВБюджетCodex() {
        XCTAssertLessThanOrEqual(ClaudeMCP.instructions.count, 512)
    }
}
