import XCTest
import SwiftUI
import AppKit
import PropellerPure
import PropellerUI

/// Скретч-инструмент, а не проверка: рисует словарь контролов настроек в PNG,
/// чтобы его можно было положить рядом с макетом. Пропускается, пока
/// `SETTINGS_SHOT` не назовёт путь.
///
///     SETTINGS_SHOT=/tmp/settings.png swift test --filter SettingsShot
///
/// Здесь **словарь**, а не экран: настоящие разделы живут в `Sources/Settings/`
/// и держатся на `AppState`, который в тестовом процессе не поднять. До
/// 2026-08-26 этот файл рисовал доску из групп «Основное», «Приватность» и
/// «Нейросети», которых в приложении не было уже полгода, — то есть врал ровно
/// тем способом, ради которого его и завели.
final class SettingsShotTests: XCTestCase {

    @MainActor
    func testShoot() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["SETTINGS_SHOT"] == nil,
            "SETTINGS_SHOT is not set — nothing to render into"
        )
        let output = ProcessInfo.processInfo.environment["SETTINGS_SHOT"]!

        let size = CGSize(width: 649, height: 760)
        let root = ControlsBoard()
            .environment(\.colorScheme, .dark)
            .frame(width: size.width, height: size.height)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingView(rootView: root)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: output))
    }
}

/// Каждый контрол правого слота ровно по разу — так и видно, стоят ли они на
/// одной линии.
private struct ControlsBoard: View {
    @State private var name = "Константин"
    @State private var empty = ""
    @State private var key = ""
    @State private var language = "ru"
    @State private var retention = "afterTranscript"
    @State private var calendarOn = false
    @State private var launchOn = true
    @State private var tags = ["Автолейаут", "Синк", "Бэкенд"]
    @State private var prompt = "Ты ведёшь конспект рабочей встречи.\nПо транскрипту ниже собери то, о чём договорились."

    var body: some View {
        SettingsPage("Основные") {
            SettingsCard {
                SettingsCell("Ваше имя", subtitle: "Для подписи в саммари") {
                    SettingsField("Имя", text: $name)
                }
                SettingsCell("Язык приложения", subtitle: "Меняется только интерфейс") {
                    SettingsMenu(
                        selection: $language,
                        options: [.init("ru", "Русский"), .init("en", "Английский")]
                    )
                }
                SettingsCell("Доступ к календарю", subtitle: "Смотрим названия и людей") {
                    SettingsSwitch(isOn: $calendarOn)
                }
                SettingsCell("Запускать Propeller при входе") {
                    SettingsSwitch(isOn: $launchOn)
                }
            }

            SettingsGroup("Хранилище") {
                SettingsCell("Папка для заметок", subtitle: "/Users/kot/Propeller/meetings", tone: .value) {
                    SettingsButton("Изменить") {}
                }
                SettingsCell("Сохранять аудиозаписи") {
                    SettingsMenu(
                        selection: $retention,
                        options: [.init("afterTranscript", "Никогда"), .init("afterDays", "Месяц")]
                    )
                }
                SettingsCell("Очистить папку с аудиозаписями", subtitle: "767,6 МБ", tone: .value) {
                    SettingsButton("Очистить", symbol: "trash", role: .destructive) {}
                }
                SettingsCell("Ключ OpenAI", subtitle: "Хранится в Keychain") {
                    SettingsField("sk-…", text: $key, secure: true)
                }
                SettingsCell("Claude Desktop", subtitle: "Подключено") {
                    SettingsCheck()
                }
                SettingsCell("ChatGPT", subtitle: "Хранится в Keychain") {
                    SettingsButton("Подключить", role: .prominent) {}
                }
                SettingsCell("Claude Code", subtitle: "Копируется одной кнопкой") {
                    SettingsCommandField("claude mcp add Propeller -- /Applications/Propeller.app") {}
                }
            }

            SettingsGroup("Промпт", actionTitle: "Вернуть как было", actionSymbol: "arrow.counterclockwise", action: {}) {
                SettingsWideCell("Личный словарь", subtitle: "Имена, названия и сленг") {
                    SettingsTagField(
                        tags: tags,
                        onRemove: { word in tags.removeAll { $0 == word } },
                        onAdd: { word in tags.append(word) }
                    )
                }
                SettingsWideCell("") {
                    SettingsEditor(text: $prompt)
                }
            }
        }
        .background(Tokens.Paint.Bg.page)
    }
}
