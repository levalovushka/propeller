import CryptoKit
import XCTest
@testable import PropellerPure

/// Модель саммари по хешу, а не по имени тега — `PropellerPure/PinnedModel.swift`.
///
/// Названы по тому, что увидел бы человек: другая модель под тем же именем,
/// повторная загрузка 3,4 ГБ без нужды или приложение без саммари вовсе.
final class PinnedModelTests: XCTestCase {

    private let pin = PinnedModel.summary

    /// Все файлы закреплённого набора на месте и нужного размера.
    private var complete: [String: Int64] {
        Dictionary(uniqueKeysWithValues: pin.blobs.map { ($0.fileName, $0.size) })
    }

    /// Манифест, который раздавал тег после переезда 2026-10 (снят из реестра
    /// 2026-10-29): те же веса, другая упаковка.
    private let movedManifest = Data(#"{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json","config":{"mediaType":"application/vnd.docker.container.image.v1+json","digest":"sha256:788a4d94bc3f431ac0cd067005be4b838a09330427962952420b05d10ecf84db","size":177},"layers":[{"mediaType":"application/vnd.ollama.image.model","digest":"sha256:a9d0a3e1d8c91732a3812becd31f8d4a8ff57414903f226306069f0437e2ac50","size":2648593216}]}"#.utf8)

    // MARK: - Закреплённое описано верно

    func testМанифестТотЖеБайтВБайтЧтоУАвтора() {
        // Хеш файла, который Ollama записал у автора 2026-07-27. Поменяй
        // строку хоть на пробел — и это будет уже другой манифест.
        let digest = SHA256.hash(data: Data(pin.manifest.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "2a654d98e6fba55d452b7043684e9b57a947e393bbffa62485a7aac05ee4eefd")
    }

    func testСписокФайловСовпадаетСМанифестом() {
        // Скачанный набор обязан быть тем, что называет манифест, — иначе Ollama
        // увидит модель, а загрузить не сможет.
        let named = PinnedModel.layers(of: Data(pin.manifest.utf8))?.map(\.blob)
        XCTAssertEqual(named, pin.blobs)
    }

    func testЗакреплённаяСборкаСредиПринятых() {
        let model = PinnedModel.layers(of: Data(pin.manifest.utf8))?
            .first { $0.mediaType == "application/vnd.ollama.image.model" }?.blob.digest
        XCTAssertNotNil(model)
        XCTAssertTrue(pin.acceptedModelDigests.contains(model ?? ""))
    }

    func testИменаФайловКакУOllama() {
        XCTAssertEqual(pin.blobs[1].fileName,
                       "sha256-81fb60c7daa80fc1123380b98970b320ae233409f0f71a72ed7b9b0d62f40490")
        XCTAssertEqual(pin.manifestRelativePath, "manifests/registry.ollama.ai/library/qwen3.5/4b")
        XCTAssertEqual(pin.blobURL(pin.blobs[1]).absoluteString,
                       "https://registry.ollama.ai/v2/library/qwen3.5/blobs/sha256:81fb60c7daa80fc1123380b98970b320ae233409f0f71a72ed7b9b0d62f40490")
    }

    // MARK: - Что считается установленным

    func testНичегоНетЗначитКачать() {
        XCTAssertEqual(PinnedModel.installed(pin, manifest: nil, blobSizes: [:]), .absent)
    }

    func testЗакреплённаяНаМестеНичегоНеКачаем() {
        XCTAssertEqual(PinnedModel.installed(pin, manifest: Data(pin.manifest.utf8), blobSizes: complete), .accepted)
    }

    func testСкачавшимПослеПереездаТегаНеПерекачиваем3ГБ() {
        // Решение владельца 2026-10-29: веса одни, перекачивать ради одинаковости
        // у всех не стали.
        let sizes = ["sha256-788a4d94bc3f431ac0cd067005be4b838a09330427962952420b05d10ecf84db": Int64(177),
                     "sha256-a9d0a3e1d8c91732a3812becd31f8d4a8ff57414903f226306069f0437e2ac50": Int64(2_648_593_216)]
        XCTAssertEqual(PinnedModel.installed(pin, manifest: movedManifest, blobSizes: sizes), .accepted)
    }

    func testТегУехалЕщёРазПолучаемЗакреплённую() {
        // Третья сборка под тем же именем — то, от чего закрепление и защищает.
        let other = Data(#"{"config":{"mediaType":"application/vnd.docker.container.image.v1+json","digest":"sha256:aa","size":1},"layers":[{"mediaType":"application/vnd.ollama.image.model","digest":"sha256:ffff","size":10}]}"#.utf8)
        XCTAssertEqual(PinnedModel.installed(pin, manifest: other, blobSizes: ["sha256-aa": 1, "sha256-ffff": 10]), .foreign)
    }

    func testМанифестБезВесовЭтоОбрывНаПолпути() {
        // Ollama покажет такую модель в списке и не сможет её загрузить.
        var sizes = complete
        sizes[pin.blobs[1].fileName] = nil
        XCTAssertEqual(PinnedModel.installed(pin, manifest: Data(pin.manifest.utf8), blobSizes: sizes), .foreign)
    }

    func testНедокачанныйФайлВесовНеСчитаетсяМоделью() {
        var sizes = complete
        sizes[pin.blobs[1].fileName] = 1_000_000_000
        XCTAssertEqual(PinnedModel.installed(pin, manifest: Data(pin.manifest.utf8), blobSizes: sizes), .foreign)
    }

    func testИспорченныйМанифестЧужой() {
        XCTAssertEqual(PinnedModel.installed(pin, manifest: Data("{".utf8), blobSizes: complete), .foreign)
    }

    // MARK: - Что докачивать

    func testДокачиваетсяТолькоНедостающее() {
        // 3,4 ГБ уже на диске — второй раз их не тянем.
        var sizes = complete
        sizes[pin.blobs[2].fileName] = nil
        XCTAssertEqual(PinnedModel.missingBlobs(pin, blobSizes: sizes), [pin.blobs[2]])
    }

    func testВсёНаМестеКачатьНечего() {
        XCTAssertTrue(PinnedModel.missingBlobs(pin, blobSizes: complete).isEmpty)
    }

    func testОбрывПрошлойПопыткиКачаетсяЗаново() {
        var sizes = complete
        sizes[pin.blobs[1].fileName] = 42
        XCTAssertEqual(PinnedModel.missingBlobs(pin, blobSizes: sizes), [pin.blobs[1]])
    }

    // MARK: - Когда модель считается доставленной

    func testПослеОткатаНаТегЧужаяСборкаИЕстьМодель() {
        // Иначе выдача ходила бы по кругу: закреплённого нет → тег → чужая → снова.
        XCTAssertTrue(PinnedModel.satisfied(.foreign, fallbackTaken: true))
        XCTAssertFalse(PinnedModel.satisfied(.foreign, fallbackTaken: false))
        XCTAssertTrue(PinnedModel.satisfied(.accepted, fallbackTaken: false))
        XCTAssertFalse(PinnedModel.satisfied(.absent, fallbackTaken: true))
    }

    // MARK: - Что удалять после замены

    func testЗамещённаяСборкаНеОстаётсяНаДиске() {
        // Ollama сам ничего не чистит: 2,65 ГБ остались бы навсегда.
        let orphans = PinnedModel.orphanedBlobs(pin, replaced: movedManifest, others: [])
        XCTAssertEqual(Set(orphans), [
            "sha256-788a4d94bc3f431ac0cd067005be4b838a09330427962952420b05d10ecf84db",
            "sha256-a9d0a3e1d8c91732a3812becd31f8d4a8ff57414903f226306069f0437e2ac50",
        ])
    }

    func testОбщийСЗакреплённойФайлНеУдаляется() {
        // params у старой и новой сборки один и тот же файл.
        let shared = Data(#"{"config":{"mediaType":"application/vnd.docker.container.image.v1+json","digest":"sha256:cc","size":1},"layers":[{"mediaType":"application/vnd.ollama.image.params","digest":"sha256:9371364b27a52acac9d87f88bd93c9db1174d8d6ec57f6888925cdc1788871ff","size":65}]}"#.utf8)
        XCTAssertEqual(PinnedModel.orphanedBlobs(pin, replaced: shared, others: []), ["sha256-cc"])
    }

    func testМодельКоторуюПоставилиРукамиНеТрогаем() {
        let mine = Data(#"{"config":{"mediaType":"application/vnd.docker.container.image.v1+json","digest":"sha256:788a4d94bc3f431ac0cd067005be4b838a09330427962952420b05d10ecf84db","size":177},"layers":[]}"#.utf8)
        let orphans = PinnedModel.orphanedBlobs(pin, replaced: movedManifest, others: [mine])
        XCTAssertEqual(orphans, ["sha256-a9d0a3e1d8c91732a3812becd31f8d4a8ff57414903f226306069f0437e2ac50"])
    }

    func testНечитаемыйСоседНеДаётУдалитьНичего() {
        XCTAssertTrue(PinnedModel.orphanedBlobs(pin, replaced: movedManifest, others: [Data("{".utf8)]).isEmpty)
    }

    func testНечитаемыйЗамещённыйНеДаётУдалитьНичего() {
        XCTAssertTrue(PinnedModel.orphanedBlobs(pin, replaced: Data("{".utf8), others: []).isEmpty)
    }

    // MARK: - Когда откатываться на тег

    func testОткатТолькоКогдаРеестрГоворитЧтоФайлаНет() {
        XCTAssertTrue(PinnedModel.pinGone(status: 404))
        XCTAssertTrue(PinnedModel.pinGone(status: 410))
    }

    func testСбойСетиНеПодменяетМодель() {
        // Минутная поломка реестра не повод скачать другую сборку навсегда.
        for status in [0, 429, 500, 502, 503, 403] {
            XCTAssertFalse(PinnedModel.pinGone(status: status), "\(status)")
        }
    }

    func testВыбраннаяРукамиМодельНеЗакреплена() {
        XCTAssertNotNil(PinnedModel.pin(for: "qwen3.5:4b"))
        XCTAssertNil(PinnedModel.pin(for: "qwen3.5:9b"))
        XCTAssertNil(PinnedModel.pin(for: "llama3.2"))
    }
}
