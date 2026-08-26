import SwiftUI
import AppKit
import PropellerUI
import PropellerPure

// MARK: - Модели

/// Кто пишет саммари и на чём.
///
/// Раздел называется механизмом («Модели»), а не вопросом, и это исключение из
/// §5.12 — такое же, как «MCP» и «Хранилище»: за ключом от OpenAI приходят
/// именно с этим словом. Сам *вопрос* при этом стоит на строке: «Кто пишет
/// саммари», а не «Модель для саммари».
struct ModelsSettingsPage: View {
    @ObservedObject var state: AppState
    @AppStorage("recapProvider") private var recapProvider = RecapProviderKind.ollama.rawValue
    @AppStorage("recapOpenAIModel") private var recapOpenAIModel = "gpt-4o-mini"
    @AppStorage("recapClaudeModel") private var recapClaudeModel = "claude-sonnet-4-5"
    @AppStorage("recapOpenRouterModel") private var recapOpenRouterModel = "anthropic/claude-sonnet-4.5"
    // Пустые, а заполняются в `onAppear`. Инициализатор свойства выполняется на
    // *каждой* пересборке структуры, даже когда `@State` его результат уже
    // игнорирует, — а это поход в Keychain, и на открытых настройках во время
    // записи он случался бы каждую секунду вместе с тиком таймера.
    @State private var openAIKey: String = ""
    @State private var claudeKey: String = ""
    @State private var openRouterKey: String = ""
    @State private var ollamaReachable: Bool? = nil

    var body: some View {
        SettingsPage(SettingsSection.models.title) {
            SettingsCard {
            // Движка расшифровки здесь нет: он ровно один, выбрать другой
            // нельзя, а строка без выбора — не настройка.
            //
            // Заголовок — вопрос человека («кто пишет саммари»), а не имя поля.
            // Состояние движка — второй строкой у самого выбора: вопрос «кто
            // пишет саммари» и вопрос «отвечает ли он» — один вопрос.
            SettingsCell(
                "Кто пишет саммари",
                subtitle: providerStatus.text,
                tone: providerStatus.tone
            ) {
                SettingsMenu(
                    selection: $recapProvider,
                    options: RecapProviderKind.allCases.map { .init($0.rawValue, $0.displayName) }
                )
            }
            .onChange(of: recapProvider) { _, val in
                Preferences.shared.recapProvider = RecapProviderKind(rawValue: val) ?? .ollama
                // Meetings that were waiting on a summary can go now — and
                // ones that gave up waiting are un-parked.
                state.summaryProviderChanged()
            }

            // Настройки — только у выбранного провайдера. Ключ OpenAI рядом с
            // выбранной Ollama ничего не настраивает: он настраивает то, чем
            // приложение сейчас не пользуется.
            //
            // У Ollama не показывается ничего: имя модели приложение выбирает
            // само и само же её привозит (`AppState.ensureSummaryModel`,
            // `Preferences.recapOllamaModel` с миграцией старых дефолтов). Всё,
            // что человеку тут правда нужно знать, — едет модель или уже
            // отвечает, — стоит второй строкой у выбора.
            if provider == .openai {
                keyRow("Ключ OpenAI", placeholder: "sk-…", text: $openAIKey) { val in
                    Preferences.shared.openAIAPIKey = val
                }
                modelRow("Модель OpenAI", placeholder: "gpt-4o-mini", text: $recapOpenAIModel) { val in
                    Preferences.shared.recapOpenAIModel = val
                }
            }
            if provider == .claude {
                keyRow("Ключ Claude", placeholder: "sk-ant-…", text: $claudeKey) { val in
                    Preferences.shared.claudeAPIKey = val
                }
                modelRow("Модель Claude", placeholder: "claude-sonnet-4-5", text: $recapClaudeModel) { val in
                    Preferences.shared.recapClaudeModel = val
                }
            }
            // OpenRouter — та же пара строк, что у остальных облачных, и
            // намеренно без списка моделей: их там тысячи, они меняются каждую
            // неделю, и любой встроенный список устареет к следующему релизу.
            // Кто пришёл за OpenRouter, знает имя модели и приносит его с
            // собой; подсказка формата стоит в подписи — и только здесь, потому
            // что префикс вендора и есть единственное, чем это поле отличается
            // от соседних.
            if provider == .openrouter {
                keyRow("Ключ OpenRouter", placeholder: "sk-or-…", text: $openRouterKey) { val in
                    Preferences.shared.openRouterAPIKey = val
                }
                modelRow(
                    "Модель OpenRouter",
                    placeholder: "anthropic/claude-sonnet-4.5",
                    subtitle: "С префиксом вендора, как в\u{00A0}каталоге OpenRouter",
                    text: $recapOpenRouterModel
                ) { val in
                    Preferences.shared.recapOpenRouterModel = val
                }
            }

            }
        }
        // Модель доехала — строка состояния обязана это заметить сама: кнопки,
        // которой её можно было переспросить, больше нет.
        .onChange(of: state.ollamaSetupMessage) { _, msg in
            if msg == "Модель готова" {
                ollamaReachable = true
                state.refreshLocalRecapModelState()
            }
        }
        .onAppear {
            state.refreshLocalRecapModelState()
            // То же, что у автозаписи: миграция «Выкл» и «Авто» живёт в
            // `Preferences`, и пикер обязан читать провайдера через неё.
            recapProvider = Preferences.shared.recapProvider.rawValue
            openAIKey = Preferences.shared.openAIAPIKey ?? ""
            claudeKey = Preferences.shared.claudeAPIKey ?? ""
            openRouterKey = Preferences.shared.openRouterAPIKey ?? ""
            recapOpenAIModel = Preferences.shared.recapOpenAIModel
            recapClaudeModel = Preferences.shared.recapClaudeModel
            recapOpenRouterModel = Preferences.shared.recapOpenRouterModel
            Task { ollamaReachable = await RecapService.shared.probeOllama() }
        }
    }

    // MARK: Провайдеры

    private var provider: RecapProviderKind {
        RecapProviderKind(rawValue: recapProvider) ?? .ollama
    }

    /// Ключ облачного провайдера. Пишется в Keychain и будит пайплайн: встреча,
    /// которая ждала саммари, может пойти сразу, как ключ появился.
    private func keyRow(
        _ title: String,
        placeholder: String,
        text: Binding<String>,
        onCommit: @escaping (String) -> Void
    ) -> some View {
        SettingsCell(title, subtitle: "Хранится в\u{00A0}Keychain") {
            SettingsField(placeholder, text: text, secure: true)
        }
        .onChange(of: text.wrappedValue) { _, val in
            onCommit(val)
            state.summaryProviderChanged()
        }
    }

    private func modelRow(
        _ title: String,
        placeholder: String,
        subtitle: String? = nil,
        text: Binding<String>,
        onCommit: @escaping (String) -> Void
    ) -> some View {
        SettingsCell(title, subtitle: subtitle) {
            SettingsField(placeholder, text: text)
        }
        .onChange(of: text.wrappedValue) { _, val in onCommit(val) }
    }

    /// Что сказать про выбранного провайдера и каким родом второй строки.
    ///
    /// Про локальный: едет, отвечает или не поднялся — и «не поднялся» это
    /// предупреждение, а не пояснение. Слова «транскрипт не уходит с мака» тут
    /// нет намеренно: «локально» ровно это и означает.
    ///
    /// Про облачный сказать есть что одно, и это не про качество: куда уедет
    /// транскрипт. Это же и есть цена выбора.
    private var providerStatus: (text: String?, tone: SettingsSubtitleTone) {
        switch provider {
        case .openai:     return ("Транскрипт уходит в\u{00A0}OpenAI", .help)
        case .claude:     return ("Транскрипт уходит в\u{00A0}Anthropic", .help)
        case .openrouter: return ("Транскрипт уходит в\u{00A0}OpenRouter, дальше — вендору модели", .help)
        case .ollama:
            // Пока установка едет — фаза и её собственный прогресс, никогда
            // композит из весов фаз (§10): «25%» при нуле скачанных байт модели
            // стоил диагностики дороже самой поломки (2026-08-22). Строку
            // диктует тот, кто фазу выполняет (`statusCallback` сайдкара):
            // «Запуск Ollama…» — это запуск, а не четверть модели.
            if state.ollamaSetupInFlight {
                let msg = state.ollamaSetupMessage
                return (msg.isEmpty ? "Готовим саммари…" : msg, .progress)
            }
            // Пауза между попытками лестницы — не тишина: исчезнувшая без слов
            // строка загрузки читалась как «приложение замолчало» — форма
            // инцидента 2026-08-22. Момент не тикает вживую и не должен:
            // сигналы мира умеют опередить его в любой миг.
            if let retry = state.ollamaRetryAt, retry.timeIntervalSinceNow > 1 {
                return ("Загрузка прервалась — продолжим \(Self.retryWhen(retry))", .progress)
            }
            switch ollamaReachable {
            case true: return ("Отвечает локально", .help)
            case false: return ("Не запущен", .warning)
            case nil: return ("Проверяем…", .progress)
            }
        }
    }

    /// «через 5 мин» / «через 40 с» — грубо и honestly: точная секунда не нужна,
    /// строка не тикает.
    private static func retryWhen(_ date: Date) -> String {
        let seconds = max(1, Int(date.timeIntervalSinceNow))
        return seconds < 90
            ? "через \(seconds)\u{00A0}с"
            : "через \(seconds / 60)\u{00A0}мин"
    }

}
