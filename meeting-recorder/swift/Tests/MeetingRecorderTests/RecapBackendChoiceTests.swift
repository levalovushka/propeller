import XCTest
@testable import PropellerPure

/// Три решения, которые до 21 августа жили в executable-таргете и проверялись
/// руками: кто отвечает за саммари, каким путём пойдёт встреча, и какой ответ
/// сервера считать отказом.
final class RecapBackendChoiceTests: XCTestCase {

    // MARK: - Кто отвечает

    /// Поднятая Ollama и пригодная Ollama — не одно и то же. Пока модели нет,
    /// саммари умирало на `HTTP 404` после каждой записи; правильный ответ —
    /// «провайдера нет» и честная пустота с предложением скачать.
    func testOllamaWithoutAModelIsNoProviderAtAll() {
        XCTAssertEqual(
            RecapBackendChoice.resolve(
                kind: .ollama, ollamaUsable: false,
                openAIKey: nil, claudeKey: nil, openRouterKey: nil
            ),
            .failure(.noProvider)
        )
        XCTAssertEqual(
            RecapBackendChoice.resolve(
                kind: .ollama, ollamaUsable: true,
                openAIKey: nil, claudeKey: nil, openRouterKey: nil
            ),
            .success("ollama")
        )
    }

    /// Ключ чужого провайдера своего не выручает: выбран `openai` — смотрят
    /// только на его ключ. Иначе транскрипт уехал бы не туда, куда человек
    /// выбрал, а туда, где нашёлся ключ.
    func testEachCloudProviderLooksOnlyAtItsOwnKey() {
        let cases: [(RecapProviderKind, String)] = [
            (.openai, "openai"), (.claude, "claude"), (.openrouter, "openrouter")
        ]
        for (kind, backend) in cases {
            XCTAssertEqual(
                RecapBackendChoice.resolve(
                    kind: kind, ollamaUsable: true,
                    openAIKey: kind == .openai ? "k" : nil,
                    claudeKey: kind == .claude ? "k" : nil,
                    openRouterKey: kind == .openrouter ? "k" : nil
                ),
                .success(backend),
                "\(kind) со своим ключом"
            )
            XCTAssertEqual(
                RecapBackendChoice.resolve(
                    kind: kind, ollamaUsable: true,
                    openAIKey: kind == .openai ? nil : "k",
                    claudeKey: kind == .claude ? nil : "k",
                    openRouterKey: kind == .openrouter ? nil : "k"
                ),
                .failure(.noProvider),
                "\(kind) с чужими ключами"
            )
        }
    }

    /// Пустая строка — это отсутствие ключа, а не ключ. Она заводится сама:
    /// поле в настройках очищают, и в Keychain остаётся `""`.
    func testAnEmptyKeyIsNotAKey() {
        XCTAssertEqual(
            RecapBackendChoice.resolve(
                kind: .openai, ollamaUsable: false,
                openAIKey: "", claudeKey: nil, openRouterKey: nil
            ),
            .failure(.noProvider)
        )
    }

    // MARK: - Каким путём пойдёт встреча

    /// Порог был покрыт тестами, а то, что им **пользуются**, — нет: выбор пути
    /// ловился руками. Здесь он и проверяется, всеми тремя ветками.
    func testTheRouteIsTheThresholdActuallyBeingUsed() {
        let short = 1_000
        let overflows = 400_000

        XCTAssertEqual(RecapRoute.of(backend: "ollama", promptCharacters: short), .localSingle)
        XCTAssertEqual(RecapRoute.of(backend: "ollama", promptCharacters: overflows), .chunked)

        // Облако нарезки не знает при любой длине: длину ответа оно не сообщает,
        // порога схлопывания у него нет, и путь его не тронут.
        for cloud in ["openai", "claude", "openrouter"] {
            XCTAssertEqual(RecapRoute.of(backend: cloud, promptCharacters: short), .cloudSingle, cloud)
            XCTAssertEqual(RecapRoute.of(backend: cloud, promptCharacters: overflows), .cloudSingle, cloud)
        }
    }

    /// Маршрут обязан отвечать тем же, что порог: если они разойдутся, встреча
    /// поедет мимо нарезки молча — так это и ловилось руками.
    func testTheRouteAgreesWithTheThresholdItAsks() {
        for characters in [0, 1_000, 40_000, 60_000, 200_000, 400_000] {
            let needed = TranscriptChunking.needed(backend: "ollama", promptCharacters: characters)
            XCTAssertEqual(
                RecapRoute.of(backend: "ollama", promptCharacters: characters),
                needed ? .chunked : .localSingle,
                "\(characters) символов"
            )
        }
    }

    // MARK: - Что считать отказом сервера

    func testOnlyOutsideTwoHundredsIsAFailure() {
        XCTAssertNil(RecapBackendChoice.httpFailure(status: 200, body: { "" }))
        XCTAssertNil(RecapBackendChoice.httpFailure(status: 299, body: { "" }))
        XCTAssertNotNil(RecapBackendChoice.httpFailure(status: 199, body: { "" }))
        XCTAssertNotNil(RecapBackendChoice.httpFailure(status: 300, body: { "" }))
        XCTAssertNotNil(RecapBackendChoice.httpFailure(status: 404, body: { "" }))
    }

    /// Тело читается только у отказа. Ответы бывают в мегабайты, и декодировать
    /// их на успешном пути — плата за строку, которую никто не прочитает.
    func testTheBodyIsOnlyReadWhenTheAnswerIsBad() {
        var reads = 0
        _ = RecapBackendChoice.httpFailure(status: 200, body: { reads += 1; return "тело" })
        XCTAssertEqual(reads, 0)
        _ = RecapBackendChoice.httpFailure(status: 500, body: { reads += 1; return "тело" })
        XCTAssertEqual(reads, 1)
    }

    /// Ошибка человеку показывается, значит её текст — тоже поведение. Двести
    /// символов тела: больше не читают, меньше — не хватает, чтобы узнать причину.
    func testTheHTTPFailureSaysTheCodeAndClipsTheBody() {
        let long = String(repeating: "я", count: 500)
        guard let failure = RecapBackendChoice.httpFailure(status: 502, body: { long }) else {
            return XCTFail("502 обязан быть отказом")
        }
        let text = failure.errorDescription ?? ""
        XCTAssertTrue(text.hasPrefix("LLM HTTP 502: "), text)
        XCTAssertEqual(text.count, "LLM HTTP 502: ".count + 200)
    }
}
