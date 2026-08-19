import XCTest
@testable import PropellerPure

/// Чужой TOML переживает нашу запись.
///
/// Файл `~/.codex/config.toml` человек правит руками: там его комментарии, его
/// порядок и его доверенные проекты. Поэтому проверяется не «получился валидный
/// TOML», а «всё, что было не нашим, осталось слово в слово».
final class CodexConfigMergeTests: XCTestCase {

    private let binary = "/Applications/Propeller.app/Contents/MacOS/PropellerMCP"

    private func entry(_ command: String? = nil) -> CodexConfigMerge.Entry {
        CodexConfigMerge.Entry(
            name: "Propeller",
            command: command ?? binary,
            env: ["PROPELLER_MCP_CLIENT": "chatgpt"]
        )
    }

    /// Снято с живого конфига владельца 2026-08-19: два чужих сервера — один
    /// stdio, один по url — и доверенные проекты после них.
    private let live = """
        model = "gpt-5.3-codex"
        model_reasoning_effort = "xhigh"
        personality = "pragmatic"

        [mcp_servers.playwright]
        args = ["@playwright/mcp@latest"]
        command = "npx"

        [mcp_servers.figma]
        url = "https://mcp.figma.com/mcp"

        [projects."/Users/levonlobanov/Desktop/Rostiks"]
        trust_level = "trusted"

        """

    // MARK: - Чужое цело

    func testЧужиеСерверыИНастройкиУцелели() throws {
        let merged = try CodexConfigMerge.merged(into: live, entry: entry())

        for line in live.components(separatedBy: "\n") where !line.isEmpty {
            XCTAssertTrue(merged.contains(line), "потеряна строка «\(line)»")
        }
        XCTAssertTrue(merged.contains("[mcp_servers.playwright]"))
        XCTAssertTrue(merged.contains("[mcp_servers.figma]"))
        XCTAssertTrue(merged.contains("[projects.\"/Users/levonlobanov/Desktop/Rostiks\"]"))
    }

    /// Комментарий — единственное, что теряется при разборе и сборке TOML, и
    /// единственная причина, по которой здесь дописывание, а не парсер.
    func testКомментарииНеТеряются() throws {
        let withComments = """
            # мой конфиг, не трогать
            model = "gpt-5.3-codex"  # и это тоже

            [mcp_servers.playwright]
            # ставил в апреле
            command = "npx"
            """
        let merged = try CodexConfigMerge.merged(into: withComments, entry: entry())
        XCTAssertTrue(merged.contains("# мой конфиг, не трогать"))
        XCTAssertTrue(merged.contains("# и это тоже"))
        XCTAssertTrue(merged.contains("# ставил в апреле"))
    }

    // MARK: - Наше на месте

    func testНашаСекцияПоявляетсяИЧитаетсяОбратно() throws {
        let merged = try CodexConfigMerge.merged(into: live, entry: entry())
        XCTAssertTrue(merged.contains("[mcp_servers.Propeller]"))
        XCTAssertEqual(CodexConfigMerge.command(of: "Propeller", in: merged), binary)
        XCTAssertTrue(CodexConfigMerge.contains("Propeller", in: merged))
        XCTAssertTrue(merged.contains("PROPELLER_MCP_CLIENT = \"chatgpt\""))
    }

    func testПустойФайлПревращаетсяВОднуСекцию() throws {
        let merged = try CodexConfigMerge.merged(into: nil, entry: entry())
        XCTAssertEqual(CodexConfigMerge.command(of: "Propeller", in: merged), binary)
        XCTAssertTrue(merged.hasSuffix("\n"))
    }

    /// Переподключение вызывается той же кнопкой, что подключение, и не должно
    /// плодить вторую нашу секцию: две записи с одним именем — это TOML, который
    /// Codex прочитает по-своему, а мы не узнаем как.
    func testПовторнаяЗаписьНеПлодитВторуюСекцию() throws {
        let once = try CodexConfigMerge.merged(into: live, entry: entry())
        let twice = try CodexConfigMerge.merged(into: once, entry: entry("/Applications/Другое.app/PropellerMCP"))

        XCTAssertEqual(twice.components(separatedBy: "[mcp_servers.Propeller]").count - 1, 1)
        XCTAssertEqual(
            CodexConfigMerge.command(of: "Propeller", in: twice),
            "/Applications/Другое.app/PropellerMCP"
        )
        XCTAssertTrue(twice.contains("[mcp_servers.playwright]"))
    }

    /// Секции не должны склеиться: наша перезапись стоит в середине файла, и
    /// съеденная пустая строка перед соседом — это TOML, где следующий заголовок
    /// прилипает к нашему значению.
    func testПерезаписьВСерединеНеСклеиваетСоседей() throws {
        let once = try CodexConfigMerge.merged(into: live, entry: entry())
        // Ставим чужую секцию после нашей и перезаписываем свою.
        let withNeighbour = once + "\n[mcp_servers.linear]\ncommand = \"linear\"\n"
        let twice = try CodexConfigMerge.merged(into: withNeighbour, entry: entry())

        let lines = twice.components(separatedBy: "\n")
        let neighbour = try XCTUnwrap(lines.firstIndex(of: "[mcp_servers.linear]"))
        XCTAssertTrue(lines[neighbour - 1].isEmpty, "секции склеились")
        XCTAssertEqual(CodexConfigMerge.command(of: "linear", in: twice), "linear")
    }

    // MARK: - Отказы

    func testОтносительныйПутьНеПишется() {
        XCTAssertThrowsError(try CodexConfigMerge.merged(into: live, entry: entry("PropellerMCP"))) {
            XCTAssertEqual($0 as? CodexConfigMerge.Failure, .relativeCommand)
        }
    }

    func testПутьСКавычкамиЭкранируетсяИЧитаетсяОбратно() throws {
        let odd = "/Applications/Про \"пеллер\".app/PropellerMCP"
        let merged = try CodexConfigMerge.merged(into: nil, entry: entry(odd))
        XCTAssertEqual(CodexConfigMerge.command(of: "Propeller", in: merged), odd)
    }

    func testНетСекцииНетКоманды() {
        XCTAssertNil(CodexConfigMerge.command(of: "Propeller", in: live))
        XCTAssertFalse(CodexConfigMerge.contains("Propeller", in: live))
        XCTAssertFalse(CodexConfigMerge.contains("Propeller", in: nil))
    }

    /// Человек мог записать нашу секцию руками в кавычках — это то же самое.
    func testЗаголовокВКавычкахЭтоТаЖеСекция() {
        let quoted = "[mcp_servers.\"Propeller\"]\ncommand = \"\(binary)\"\n"
        XCTAssertEqual(CodexConfigMerge.command(of: "Propeller", in: quoted), binary)
    }
}
