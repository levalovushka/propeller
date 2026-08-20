import XCTest
import SwiftUI
import AppKit
import PropellerUI

/// Scratch tool, same idea as `TempRailShotTests`: renders the settings kit to a
/// PNG so it can be looked at. Skipped unless `SETTINGS_SHOT` names a path.
final class TempSettingsShotTests: XCTestCase {

    @MainActor
    func testShoot() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["SETTINGS_SHOT"] == nil,
            "SETTINGS_SHOT is not set"
        )
        let output = ProcessInfo.processInfo.environment["SETTINGS_SHOT"]!
        let light = ProcessInfo.processInfo.environment["SETTINGS_SHOT_LIGHT"] != nil
        let width = ProcessInfo.processInfo.environment["SETTINGS_SHOT_W"]
            .flatMap { Double($0) } ?? 760
        let size = CGSize(width: width, height: 1500)

        let root = ZStack {
            light ? Color.white : Color(red: 0.07, green: 0.07, blue: 0.08)
            VStack(spacing: 0) {
                SettingsPaneHeader()
                Board()
            }
        }
        .environment(\.colorScheme, light ? .light : .dark)
        .frame(width: size.width, height: size.height)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        let hosting = NSHostingView(rootView: root)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: output))
    }

    private struct Board: View {
        @State var on = true
        @State var terms = ""
        @State var model = "qwen3.5:4b"
        @State var prompt = "Ты — эксперт по ведению конспектов встреч.\nНа основе транскрипта ниже составь конспект."
        @State var provider = "ollama"
        @State var format = "simple"
        @State var path = "/Users/leva/.meeting-recorder/recordings"

        var body: some View {
            SettingsColumn {
                SettingsGroup("Основное") {
                    SettingsCell("Запускать Propeller при входе") {
                        SettingsSwitch(isOn: $on)
                    }
                    SettingsCell(
                        "Автоматическая запись",
                        subtitle: "Стартует и заканчивается вместе со звонком в\u{00A0}Zoom"
                    ) {
                        SettingsSwitch(isOn: $on)
                    }
                    SettingsCell("Показывать Propeller в меню баре") {
                        SettingsSwitch(isOn: $on)
                    }
                }
                SettingsGroup("Приватность") {
                    SettingsCell(
                        "Делиться аналитикой",
                        subtitle: "Только обезличенные данные"
                    ) {
                        SettingsSwitch(isOn: $on)
                    }
                }
                SettingsGroup("Нейросети") {
                    SettingsCell("Модель для саммари", subtitle: "Отвечает на\u{00A0}:11434") {
                        Picker("", selection: $provider) {
                            Text("Ollama").tag("ollama")
                            Text("OpenAI").tag("openai")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                    SettingsStack("Промпт") {
                        SettingsEditor(text: $prompt)
                    }
                    SettingsStack(
                        "Личный словарь",
                        subtitle: "Сленг и англицизмы для распознавания"
                    ) {
                        SettingsField("напр. Газпромнефть, Аэрофлот", text: $terms)
                    }
                }
                SettingsGroup("Хранилище") {
                    SettingsCell(
                        "Формат Markdown",
                        subtitle: "Читаемый markdown: заголовок, участники, расшифровка."
                    ) {
                        Picker("", selection: $format) {
                            Text("Простой").tag("simple")
                            Text("Obsidian").tag("obsidian")
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                    SettingsStack("Записи") {
                        HStack(spacing: Tokens.Space.s8) {
                            SettingsField("Записи", text: $path)
                            SettingsButton("Выбрать") {}
                        }
                    }
                    SettingsCell("Аудио на диске") {
                        HStack(spacing: Tokens.Space.s8) {
                            SettingsValue("1,64 ГБ")
                            SettingsButton("Очистить") {}
                        }
                    }
                }
                SettingsGroup("О программе") {
                    SettingsCell("Версия") { SettingsValue("1.16") }
                    SettingsCell("Обновления") { SettingsButton("Проверить обновления…") {} }
                }
            }
        }
    }
}
