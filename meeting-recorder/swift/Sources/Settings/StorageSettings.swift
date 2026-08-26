import SwiftUI
import AppKit
import PropellerUI
import PropellerPure

// MARK: - Хранилище

/// Где лежат файлы и сколько занимают.
///
/// Имя группы владелец оставил как было. Внутри изменилось одно, зато важное:
/// путь больше не набирают руками. Папка — это её имя, её путь второй строкой и
/// кнопка «Изменить…»; текстовое поле пути ничего не настраивало, а только
/// давало опечатке шанс — нормализация живёт на чтении
/// (`ArchivePath.normalized`), и сломанный путь выглядел как рабочий.
struct StorageSettingsPage: View {
    @ObservedObject var state: AppState
    @AppStorage("markdownOutputFormat") private var markdownOutputFormat = MarkdownOutputFormat.simple.rawValue
    @AppStorage("meetingsPath") private var meetingsPath = ""
    @AppStorage("recordingsPath") private var recordingsPath = ""
    @AppStorage("peoplePagesPath") private var peoplePagesPath = ""
    @AppStorage("audioRetentionMode") private var audioRetentionMode = AudioRetentionMode.afterTranscript.rawValue
    @State private var showingClearConfirm = false

    /// Сколько заберёт «Очистить» — не то же, что «Аудио на диске»: у идущей
    /// записи и у нерасшифрованной встречи звук не забирают (`AudioReclaim`).
    private var reclaimable: Int64 { state.storageReclaimableBytes }

    var body: some View {
        SettingsPage(SettingsSection.storage.title) {
            SettingsCard {
                SettingsCell("Формат заметок", subtitle: formatHelp) {
                    SettingsMenu(
                        selection: $markdownOutputFormat,
                        options: MarkdownOutputFormat.allCases.map {
                            .init($0.rawValue, $0.displayName)
                        }
                    )
                }
                .onChange(of: markdownOutputFormat) { _, val in
                    Preferences.shared.markdownOutputFormat =
                        MarkdownOutputFormat(rawValue: val) ?? .simple
                }

                pathCell("Папка заметок", path: $meetingsPath) {
                    Preferences.shared.meetingsPath = meetingsPath
                }
                if markdownOutputFormat == MarkdownOutputFormat.obsidian.rawValue {
                // Единственная папка, у которой есть пустое состояние: без неё
                // wikilinks просто не появятся. Поэтому и подпись у неё не про
                // путь, а про то, что даёт её выбор.
                SettingsCell(
                    "Страницы людей",
                    subtitle: peoplePagesPath.isEmpty
                        ? "Имена спикеров станут [[wikilinks]]"
                        : peoplePagesPath,
                    tone: peoplePagesPath.isEmpty ? .help : .value
                ) {
                        SettingsButton(peoplePagesPath.isEmpty ? "Выбрать…" : "Изменить…") {
                            choose($peoplePagesPath) { Preferences.shared.peoplePagesPath = peoplePagesPath }
                        }
                    }
                }
            }

            SettingsGroup("Аудио") {
                pathCell("Папка записей", path: $recordingsPath) {
                    Preferences.shared.recordingsPath = recordingsPath
                }

                // Подписи под строкой у режима нет: два пункта по слову-двум
                // объясняют себя сами, а абзац под ними объяснял бы выбор,
                // которого больше не осталось.
                SettingsCell("Сохранять аудиозаписи") {
                    SettingsMenu(
                        selection: $audioRetentionMode,
                        options: AudioRetentionMode.allCases.map {
                            .init($0.rawValue, $0.displayName)
                        }
                    )
                }
                .onChange(of: audioRetentionMode) { _, val in
                    // Через `Preferences`, а не только `@AppStorage`: там живёт
                    // разбор записанного (`AudioRetention.storedMode`), и выбор
                    // обязан проходить через то же место, что и чтение.
                    Preferences.shared.audioRetentionMode =
                        AudioRetentionMode(rawValue: val) ?? .afterTranscript
                }

                // Порога нет и у кнопки: пока чистить нечего, её просто нет, а
                // не «есть, но не работает».
                SettingsCell(
                    "Очистить папку с\u{00A0}аудиозаписями",
                    subtitle: Self.bytes(state.storageLibraryBytes),
                    tone: .value
                ) {
                    if reclaimable > 0 {
                        SettingsButton("Очистить", symbol: "trash", role: .destructive) {
                            showingClearConfirm = true
                        }
                    }
                }
            }

            // «Стереть человека» двери не получает намеренно (решение владельца
            // 2026-08-17): постоянных спикеров в продукте пока нет, а стирание
            // по имени не согласуется по падежу («с Иваном» → «с Участник») и
            // сливает двух стёртых в одного. Механизм есть и покрыт тестами
            // (`AppState.erasePerson`), поверхность появится вместе с людьми.
        }
        // Подтверждение необратимого действия, начатого человеком: он за
        // клавиатурой, окно возможности — его же клик. Единственная роль, в
        // которой `design/notifications.md` §5 разрешает модалку.
        .confirmationDialog(
            "Удалить аудио встреч?",
            isPresented: $showingClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) {
                state.deleteAllReclaimableAudio()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Освободится \(Self.bytes(reclaimable)). Расшифровки и саммари останутся, аудио вернуть будет нельзя.")
        }
        .onAppear {
            if meetingsPath.isEmpty { meetingsPath = Preferences.shared.meetingsPath }
            if recordingsPath.isEmpty { recordingsPath = Preferences.shared.recordingsPath }
            state.refreshStorageUsage()
        }
    }

    private var formatHelp: String {
        markdownOutputFormat == MarkdownOutputFormat.obsidian.rawValue
            ? "YAML и [[wikilinks]]; старые файлы не меняются"
            : "Читаемый markdown для обмена"
    }

    /// Папка: имя строкой, путь второй строкой, «Изменить…» справа.
    ///
    /// Путь — это значение, а не пояснение, поэтому тон `.value`: одна строка,
    /// обрезается серединой. У пути важны и начало (какой диск), и хвост (какая
    /// папка), а середина — как раз то, что человек и так знает.
    private func pathCell(
        _ title: String,
        path: Binding<String>,
        onUpdate: @escaping () -> Void
    ) -> some View {
        // Пустой путь — не пустая строка под заголовком, а её отсутствие: до
        // `onAppear` значение ещё не прочитано из `Preferences`, и пустая
        // вторая строка растила бы ячейку молча.
        SettingsCell(
            title,
            subtitle: path.wrappedValue.isEmpty ? nil : path.wrappedValue,
            tone: .value
        ) {
            SettingsButton("Изменить") { choose(path, onUpdate: onUpdate) }
        }
    }

    private func choose(_ path: Binding<String>, onUpdate: @escaping () -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            path.wrappedValue = url.path
            onUpdate()
        }
    }

    /// Байты человеку. `ByteCountFormatter` ставит между числом и единицей
    /// обычный пробел (U+0020), а в тексте диалога он попадает под перенос —
    /// «1,64» на одной строке, «ГБ» на следующей. `principles.md` §6 это
    /// запрещает, и починить это можно только здесь: строку собирает система.
    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
            .replacingOccurrences(of: " ", with: "\u{00A0}")
    }
}

