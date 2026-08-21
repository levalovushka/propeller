import XCTest
@testable import PropellerPure

/// Что остаётся от прошлой версии движка саммари — `PropellerPure/EngineHousekeeping.swift`.
///
/// Названы по тому, что человек увидел бы, если правило ошибётся: пропавшие 3,4 ГБ
/// весов и повторная загрузка без спроса — с одной стороны, и полсотни мегабайт
/// мёртвых dylib после каждого подъёма версии — с другой.
final class EngineHousekeepingTests: XCTestCase {

    /// Реальный список каталога на установленной 1.16.7 (снят 2026-08-21).
    private let installed = [
        "installed-version.txt",
        "libggml-base.0.17.0.dylib", "libggml-base.0.dylib", "libggml-base.dylib",
        "libggml-blas.so", "libggml.0.17.0.dylib", "libggml.0.dylib", "libggml.dylib",
        "libllama-common.0.0.1.dylib", "libllama.0.0.1.dylib",
        "libllama-quantize-impl.dylib", "libllama-server-impl.dylib",
        "libmtmd.0.0.1.dylib",
        "llama-quantize", "llama-server", "ollama",
        "models", "ollama-serve.log",
    ]

    // MARK: - Чего нельзя лишать человека

    func testВесаМоделиНеУдаляютНикогда() {
        // 3,4 ГБ, скачанные по сети, и к версии движка они не относятся вовсе.
        // Удалить их — значит начать загрузку заново, не спросив.
        let stale = EngineHousekeeping.stalePaths(existing: installed, shipped: ["ollama"])
        XCTAssertFalse(stale.contains("models"))
    }

    func testЛогДвижкаНеУдаляют() {
        // Единственное, что человек может прислать, когда саммари не собралось.
        let stale = EngineHousekeeping.stalePaths(existing: installed, shipped: ["ollama"])
        XCTAssertFalse(stale.contains("ollama-serve.log"))
    }

    func testНеизвестныйТарболНеУдаляетНичего() {
        // Пустой список — это «мы не смогли прочитать архив», а не «архив пуст».
        // Второе прочтение вычистило бы каталог целиком, вместе с весами.
        XCTAssertEqual(EngineHousekeeping.stalePaths(existing: installed, shipped: []), [])
    }

    func testМеткуВерсииНеУдаляют() {
        // Её перепишут строкой ниже; удалить и не дописать — значит распаковывать
        // движок при каждом запуске.
        let stale = EngineHousekeeping.stalePaths(existing: installed, shipped: ["ollama"])
        XCTAssertFalse(stale.contains("installed-version.txt"))
    }

    // MARK: - Что и должно уйти

    func testВерсионированныеБиблиотекиПрошлогоДвижкаУходят() {
        // Ровно то, что раньше оставалось: имя с номером версии, которое новый
        // тарбол не перезаписывает, потому что у него номер другой.
        let shipped: Set<String> = [
            "ollama", "llama-server", "libggml-base.0.18.0.dylib", "models",
        ]
        let stale = EngineHousekeeping.stalePaths(existing: installed, shipped: shipped)
        XCTAssertTrue(stale.contains("libggml-base.0.17.0.dylib"))
        XCTAssertTrue(stale.contains("libllama.0.0.1.dylib"))
        XCTAssertFalse(stale.contains("llama-server"))   // новый тарбол его принёс
    }

    func testТоЧтоПринёсНовыйТарболОстаётся() {
        let shipped = Set(installed.filter { $0 != "models" && $0 != "ollama-serve.log" })
        XCTAssertEqual(EngineHousekeeping.stalePaths(existing: installed, shipped: shipped), [])
    }

    func testБрошенныйТарболПослеСорваннойЗагрузкиУходит() {
        let stale = EngineHousekeeping.stalePaths(
            existing: ["ollama", "ollama-darwin.tgz", "models"],
            shipped: ["ollama"]
        )
        XCTAssertEqual(stale, ["ollama-darwin.tgz"])
    }

    // MARK: - Модели, которые мы когда-то выдавали дефолтом

    func testПрошлыйДефолтныйТегСчитаетсяУстаревшим() {
        XCTAssertEqual(
            EngineHousekeeping.supersededModels(
                shippedDefaults: ["qwen2.5:7b", "qwen3.5:4b"],
                current: "qwen3.5:4b"
            ),
            ["qwen2.5:7b"]
        )
    }

    func testТекущийДефолтНикогдаНеУдаляют() {
        // Та самая ошибка, которую хранение «истории» вместо «исключений» и убирает:
        // список нельзя написать так, чтобы он снёс работающую модель.
        let stale = EngineHousekeeping.supersededModels(
            shippedDefaults: ["qwen3.5:4b"],
            current: "qwen3.5:4b"
        )
        XCTAssertEqual(stale, [])
    }

    func testПовторВИсторииНеПриводитКДвумУдалениям() {
        XCTAssertEqual(
            EngineHousekeeping.supersededModels(
                shippedDefaults: ["qwen2.5:7b", "qwen2.5:7b", "llama3:8b"],
                current: "qwen3.5:4b"
            ),
            ["qwen2.5:7b", "llama3:8b"]
        )
    }
}
