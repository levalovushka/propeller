import XCTest
@testable import PropellerPure

/// Что остаётся от прошлого набора весов распознавания — `PropellerPure/ASRModelSweep.swift`.
///
/// Названы по тому, что человек увидел бы: либо приложение, которое перестало
/// расшифровывать, потому что весов больше нет, либо 225 МБ, которые никто никогда
/// не заберёт. Первое хуже, поэтому правило узкое.
final class ASRModelSweepTests: XCTestCase {

    /// Реальное содержимое каталога весов на установленной 1.16.7 (снято 2026-08-21).
    private let installed = [
        "coreml_cache",
        "v3_e2e_rnnt_decoder.onnx",
        "v3_e2e_rnnt_encoder.onnx",        // наш нулевой маркер
        "v3_e2e_rnnt_encoder_int8.onnx",
        "v3_e2e_rnnt_joint.onnx",
        "v3_e2e_rnnt_vocab.txt",
        "wespeaker_resnet34.onnx",
    ]

    /// Набор, который несёт бандл 1.16.7.
    private let bundled: Set<String> = [
        "v3_e2e_rnnt_decoder.onnx",
        "v3_e2e_rnnt_encoder_int8.onnx",
        "v3_e2e_rnnt_joint.onnx",
        "v3_e2e_rnnt_vocab.txt",
        "wespeaker_resnet34.onnx",
    ]

    // MARK: - Чего нельзя трогать

    func testПриСовпадающемНабореНеУдаляетсяНичего() {
        XCTAssertEqual(ASRModelSweep.stalePaths(existing: installed, bundled: bundled), [])
    }

    func testСборкаБезВесовВБандлеНеУдаляетНичего() {
        // `swift build` не имеет Resources, и «в бандле весов нет» здесь означает
        // отсутствие знания. Прочитать это как знание об отсутствии — значит снести
        // веса разработчику, а на чужой машине — при любой поломке чтения бандла.
        XCTAssertEqual(ASRModelSweep.stalePaths(existing: installed, bundled: []), [])
    }

    func testНулевойМаркерFP32ЭнкодераОстаётся() {
        // Его нет в бандле и никогда не будет: это наш нулевой файл, которым
        // затыкается проверка наличия у `gigastt serve`. Удалить — значит вернуть
        // те самые 885 МБ, которые он и предотвращает.
        let stale = ASRModelSweep.stalePaths(existing: installed, bundled: bundled)
        XCTAssertFalse(stale.contains(ASRModelSweep.presenceMarker))
    }

    func testКешCoreMLИЛокФайлыНеТрогаем() {
        // Каталог принадлежит gigastt: он его пишет, читает и знает, что там
        // валидно. Правило удаляет только веса.
        let stale = ASRModelSweep.stalePaths(
            existing: installed + ["gigastt.lock", "coreml_cache"],
            bundled: bundled
        )
        XCTAssertFalse(stale.contains("coreml_cache"))
        XCTAssertFalse(stale.contains("gigastt.lock"))
    }

    // MARK: - Что и должно уйти

    func testСтарыйЭнкодерУходитКогдаСборкаПринеслаНовоеИмя() {
        // Ровно тот случай, из-за которого правило написано: имя поменялось, старый
        // файл на 225 МБ перестал кому-то принадлежать, и искать его некому.
        let next: Set<String> = [
            "v4_e2e_rnnt_decoder.onnx",
            "v4_e2e_rnnt_encoder_int8.onnx",
            "v4_e2e_rnnt_joint.onnx",
            "v3_e2e_rnnt_vocab.txt",
            "wespeaker_resnet34.onnx",
        ]
        let stale = ASRModelSweep.stalePaths(existing: installed, bundled: next)
        XCTAssertEqual(stale, [
            "v3_e2e_rnnt_decoder.onnx",
            "v3_e2e_rnnt_encoder_int8.onnx",
            "v3_e2e_rnnt_joint.onnx",
        ])
    }

    func testВесаОтДиаризатораТожеСчитаются() {
        let next = bundled.subtracting(["wespeaker_resnet34.onnx"])
            .union(["wespeaker_resnet50.onnx"])
        let stale = ASRModelSweep.stalePaths(existing: installed, bundled: next)
        XCTAssertEqual(stale, ["wespeaker_resnet34.onnx"])
    }
}
