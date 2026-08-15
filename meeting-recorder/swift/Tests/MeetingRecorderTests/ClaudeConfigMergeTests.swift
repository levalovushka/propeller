import XCTest
import PropellerPure

/// Мы пишем в чужой файл. Всё, что здесь проверяется, — что после нашей кнопки
/// человек не потерял то, что настраивал руками.
final class ClaudeConfigMergeTests: XCTestCase {

    private let entry = ClaudeConfigMerge.Entry(
        name: "Propeller",
        command: "/Applications/Propeller.app/Contents/MacOS/PropellerMCP"
    )

    private func object(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func servers(_ data: Data) -> [String: Any] {
        object(data)["mcpServers"] as? [String: Any] ?? [:]
    }

    /// Живой файл с машины владельца (2026-08-15), сокращённый: два чужих
    /// сервера и два ключа верхнего уровня, про которые мы ничего не знаем.
    private let live = Data("""
        {
          "mcpServers": {
            "quantified-self": {
              "command": "/Users/x/.local/bin/uv",
              "args": ["--directory", "/Users/x/mcp-server", "run"],
              "env": {"QS_TIMEZONE": "Europe/Moscow"}
            },
            "talat": { "command": "/Applications/talat.app/Contents/MacOS/talat_mcp" }
          },
          "coworkUserFilesPath": "/Users/x/Claude",
          "preferences": { "dockBounceEnabled": true }
        }
        """.utf8)

    func testForeignServersSurvive() throws {
        let merged = try ClaudeConfigMerge.merged(into: live, entry: entry)
        let after = servers(merged)
        XCTAssertEqual(Set(after.keys), ["quantified-self", "talat", "Propeller"])
        let qs = after["quantified-self"] as? [String: Any]
        XCTAssertEqual(qs?["command"] as? String, "/Users/x/.local/bin/uv")
        XCTAssertEqual((qs?["args"] as? [String])?.count, 3)
        XCTAssertEqual((qs?["env"] as? [String: String])?["QS_TIMEZONE"], "Europe/Moscow")
    }

    /// Ключи верхнего уровня — не наши. Мы про них ничего не знаем, и это
    /// единственная причина, по которой они обязаны доехать нетронутыми.
    func testEverythingOutsideOurKeySurvives() throws {
        let merged = try ClaudeConfigMerge.merged(into: live, entry: entry)
        let root = object(merged)
        XCTAssertEqual(root["coworkUserFilesPath"] as? String, "/Users/x/Claude")
        XCTAssertEqual((root["preferences"] as? [String: Any])?["dockBounceEnabled"] as? Bool, true)
    }

    func testWritingTwiceChangesNothing() throws {
        let once = try ClaudeConfigMerge.merged(into: live, entry: entry)
        let twice = try ClaudeConfigMerge.merged(into: once, entry: entry)
        XCTAssertEqual(once, twice)
    }

    func testAMissingFileBecomesAFileWithOnlyUsInIt() throws {
        let merged = try ClaudeConfigMerge.merged(into: nil, entry: entry)
        XCTAssertEqual(Array(servers(merged).keys), ["Propeller"])
        XCTAssertEqual(Array(object(merged).keys), ["mcpServers"])
    }

    func testAnEmptyFileIsTreatedAsAMissingOne() throws {
        let merged = try ClaudeConfigMerge.merged(into: Data(), entry: entry)
        XCTAssertEqual(Array(servers(merged).keys), ["Propeller"])
    }

    /// Самый дорогой отказ: файл не разобрался. Уверенно записать поверх — это
    /// стереть всё, что человек настраивал, и узнает он об этом не сегодня.
    func testAFileWeCannotReadIsNotOverwritten() {
        XCTAssertThrowsError(try ClaudeConfigMerge.merged(into: Data("{не json".utf8), entry: entry)) {
            XCTAssertEqual($0 as? ClaudeConfigMerge.Failure, .unreadable)
        }
        XCTAssertThrowsError(try ClaudeConfigMerge.merged(into: Data("[1, 2]".utf8), entry: entry)) {
            XCTAssertEqual($0 as? ClaudeConfigMerge.Failure, .notAnObject)
        }
        XCTAssertThrowsError(
            try ClaudeConfigMerge.merged(into: Data(#"{"mcpServers": "нет"}"#.utf8), entry: entry)
        ) {
            XCTAssertEqual($0 as? ClaudeConfigMerge.Failure, .serversNotAnObject)
        }
    }

    /// Относительный путь Клод молча не запустит — значит это не «подключили»,
    /// а «написали и не сказали».
    func testARelativeCommandIsRefusedBeforeItReachesTheFile() {
        let relative = ClaudeConfigMerge.Entry(name: "Propeller", command: "PropellerMCP")
        XCTAssertThrowsError(try ClaudeConfigMerge.merged(into: nil, entry: relative)) {
            XCTAssertEqual($0 as? ClaudeConfigMerge.Failure, .relativeCommand)
        }
    }

    func testArgsAndEnvAreOnlyWrittenWhenThereAreAny() throws {
        let merged = try ClaudeConfigMerge.merged(into: nil, entry: entry)
        let ours = servers(merged)["Propeller"] as? [String: Any]
        XCTAssertEqual(Set((ours ?? [:]).keys), ["command"])
    }

    // MARK: - Чтение

    func testWeSeeOurselvesInTheFileAndAlsoSeeWhenWeAreGone() throws {
        let merged = try ClaudeConfigMerge.merged(into: live, entry: entry)
        XCTAssertTrue(ClaudeConfigMerge.contains("Propeller", in: merged))
        XCTAssertFalse(ClaudeConfigMerge.contains("Propeller", in: live))
        XCTAssertFalse(ClaudeConfigMerge.contains("Propeller", in: nil))
        XCTAssertFalse(ClaudeConfigMerge.contains("Propeller", in: Data("{не json".utf8)))
    }

    /// Запись без команды — не запись: запускать нечего, а «подключено» она бы
    /// показала.
    func testAnEntryWithoutACommandDoesNotCount() {
        let hollow = Data(#"{"mcpServers": {"Propeller": {"args": []}}}"#.utf8)
        XCTAssertFalse(ClaudeConfigMerge.contains("Propeller", in: hollow))
    }

    func testTheCommandCanBeReadBack() throws {
        let merged = try ClaudeConfigMerge.merged(into: live, entry: entry)
        XCTAssertEqual(ClaudeConfigMerge.command(of: "Propeller", in: merged), entry.command)
        XCTAssertNil(ClaudeConfigMerge.command(of: "Propeller", in: live))
    }
}
