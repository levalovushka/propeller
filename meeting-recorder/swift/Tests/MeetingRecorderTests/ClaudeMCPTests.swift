import XCTest
import PropellerPure

/// Имена инструментов — единственное в этой фиче, что ограничено формально:
/// спека разрешает `A-Za-z0-9_-.`, практический потолок Клода жёстче
/// (`^[a-zA-Z0-9_-]{1,64}$`, без точек), и имя сервера склеивается с именем
/// инструмента в один идентификатор. Нарушение не видно ни в сборке, ни в
/// тестах сервера: инструмент просто не появляется у человека в разговоре.
final class ClaudeMCPTests: XCTestCase {

    func testToolNamesFitTheNarrowestRule() {
        for tool in ClaudeMCP.tools {
            XCTAssertTrue(ClaudeMCP.isLegalName(tool.name), "имя \(tool.name) вне [a-z0-9_]")
        }
    }

    func testQualifiedNamesFitTheSixtyFourCharacterCeiling() {
        for tool in ClaudeMCP.tools {
            let qualified = ClaudeMCP.qualifiedName(tool.name)
            XCTAssertLessThanOrEqual(qualified.count, 64, qualified)
        }
    }

    func testNamesAreUnique() {
        let names = ClaudeMCP.tools.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testIllegalNamesAreRejected() {
        XCTAssertFalse(ClaudeMCP.isLegalName(""))
        XCTAssertFalse(ClaudeMCP.isLegalName("search.meetings"))   // точку Клод не берёт
        XCTAssertFalse(ClaudeMCP.isLegalName("searchMeetings"))    // мы решили без верхнего регистра
        XCTAssertFalse(ClaudeMCP.isLegalName("поиск_встреч"))      // имена латиницей
        XCTAssertFalse(ClaudeMCP.isLegalName(String(repeating: "a", count: 65)))
    }

    /// Описание — несущая конструкция: по нему модель решает, лезть ли к нам.
    /// Пустое или односложное описание — это выключенный инструмент, и заметить
    /// это можно только в живом разговоре, то есть поздно.
    func testEveryToolExplainsItselfAtLength() {
        for tool in ClaudeMCP.tools {
            XCTAssertGreaterThan(tool.description.count, 80, tool.name)
        }
    }

    /// Обязательные аргументы должны быть среди объявленных — иначе клиент
    /// требует поле, которого в схеме нет.
    func testRequiredArgumentsExist() {
        for tool in ClaudeMCP.tools {
            for name in tool.inputSchema.required {
                XCTAssertNotNil(tool.inputSchema.properties[name], "\(tool.name).\(name)")
            }
            XCTAssertEqual(tool.inputSchema.type, "object")
        }
    }

    /// Точка входа обязана быть дешёвой и широкой: у неё не может быть
    /// обязательных аргументов, иначе модель не может начать с неё разговор.
    func testTheEntryPointAsksForNothing() {
        let search = ClaudeMCP.tool(named: ClaudeMCP.searchMeetings)
        XCTAssertNotNil(search)
        XCTAssertTrue(search?.inputSchema.required.isEmpty == true)
    }

    /// Глубина требует адреса: рекап и расшифровка — всегда про конкретную
    /// встречу, и id обязателен именно поэтому.
    func testDepthToolsRequireAMeeting() {
        for name in [ClaudeMCP.getRecap, ClaudeMCP.getTranscript] {
            XCTAssertEqual(ClaudeMCP.tool(named: name)?.inputSchema.required, ["id"])
        }
    }

    func testProtocolVersionIsEchoedOnlyWhenKnown() {
        XCTAssertEqual(ClaudeMCP.negotiatedProtocol(requested: "2024-11-05"), "2024-11-05")
        XCTAssertEqual(ClaudeMCP.negotiatedProtocol(requested: "2099-01-01"), ClaudeMCP.protocolVersion)
        XCTAssertEqual(ClaudeMCP.negotiatedProtocol(requested: nil), ClaudeMCP.protocolVersion)
    }

    /// Схема уезжает клиенту как JSON — значит она обязана в него собираться.
    func testToolsEncodeToJSON() throws {
        let data = try JSONEncoder().encode(ClaudeMCP.tools)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [Any]
        XCTAssertEqual(parsed?.count, ClaudeMCP.tools.count)
    }
}
