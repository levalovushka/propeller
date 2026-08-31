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
///
/// **Смена папки архива переносит архив** (`ArchiveRelocation`). До этого она
/// писала новый путь и молчала: индекс уезжал сам первой же правкой, аудио
/// оставалось позади и каждая встреча читалась как «аудио удалено», а
/// незакрытые удаления в старой папке не дочищались уже никогда. Что именно
/// переедет и почему перенос иногда невозможен — решается в `PropellerPure`,
/// здесь остаются чтение системы и нажатие.
struct StorageSettingsPage: View {
    @ObservedObject var state: AppState
    @AppStorage("markdownOutputFormat") private var markdownOutputFormat = MarkdownOutputFormat.simple.rawValue
    @AppStorage("meetingsPath") private var meetingsPath = ""
    @AppStorage("recordingsPath") private var recordingsPath = ""
    @AppStorage("peoplePagesPath") private var peoplePagesPath = ""
    @AppStorage("audioRetentionMode") private var audioRetentionMode = AudioRetentionMode.afterTranscript.rawValue
    @State private var showingClearConfirm = false

    /// Какую папку меняем. Слот, а не замыкание в состоянии: диалог живёт до
    /// следующего кадра, а нужный ему путь обязан читаться из `Preferences` в
    /// момент нажатия, а не из захваченной копии.
    private enum FolderSlot: Equatable { case meetings, recordings }

    /// Перенос, предложенный человеку и ещё не подтверждённый.
    private struct PendingMove: Equatable {
        let slot: FolderSlot
        let source: String
        let target: String
        let plan: ArchiveRelocation.Plan
    }

    /// Ответ на нажатие, который нечем показать в самой ячейке: отказ или
    /// неудавшийся перенос. Вторая строка ячейки занята путём, а путь —
    /// значение, которое подменять сообщением нельзя.
    private struct Notice: Equatable {
        let title: String
        let message: String
    }

    @State private var pendingMove: PendingMove?
    @State private var notice: Notice?
    /// Пока идёт перенос, у папки нет кнопки: второй `NSOpenPanel` поверх
    /// едущего архива — это две правды о том, где он лежит.
    @State private var movingSlot: FolderSlot?

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

                pathCell("Папка заметок", path: $meetingsPath, slot: .meetings)
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
                pathCell("Папка записей", path: $recordingsPath, slot: .recordings)

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
        // Выбор из трёх, а не подтверждение из двух: «перенести» и «начать с
        // пустой» — оба законные намерения, и до этой правки продукт выбирал
        // второе за человека молча.
        .confirmationDialog(
            "Перенести архив в новую папку?",
            isPresented: Binding(
                get: { pendingMove != nil },
                set: { if !$0 { pendingMove = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingMove
        ) { move in
            Button("Перенести") { startMove(move) }
            Button("Начать с пустой папки") { commit(move.slot, move.target) }
            Button("Отмена", role: .cancel) {}
        } message: { move in
            Text(Self.moveMessage(move))
        }
        // Отказ и неудача — тоже ответ на нажатие, сделанное человеком за
        // клавиатурой, поэтому окно возможности его же (`notifications.md` §5).
        // В ячейку это не помещается: её вторая строка занята путём, а путь —
        // значение, а не место для сообщений.
        .alert(
            notice?.title ?? "",
            isPresented: Binding(
                get: { notice != nil },
                set: { if !$0 { notice = nil } }
            ),
            presenting: notice
        ) { _ in
            Button("Понятно", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
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
        slot: FolderSlot
    ) -> some View {
        let moving = movingSlot == slot
        // Пустой путь — не пустая строка под заголовком, а её отсутствие: до
        // `onAppear` значение ещё не прочитано из `Preferences`, и пустая
        // вторая строка растила бы ячейку молча.
        return SettingsCell(
            title,
            subtitle: moving
                ? "Переносим архив…"
                : (path.wrappedValue.isEmpty ? nil : path.wrappedValue),
            tone: moving ? .progress : .value
        ) {
            if !moving {
                SettingsButton("Изменить") { chooseArchiveFolder(slot) }
            }
        }
    }

    private func choose(_ path: Binding<String>, onUpdate: @escaping () -> Void) {
        guard let url = Self.pickFolder() else { return }
        path.wrappedValue = url.path
        onUpdate()
    }

    private static func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Смена папки архива

    /// Путь, по которому архив лежит **сейчас**. Через `Preferences`, а не через
    /// `@AppStorage`: у пустого ключа зеркало пустое, а настоящий путь —
    /// значение по умолчанию, и перенос из «» унёс бы не тот архив.
    private func currentPath(_ slot: FolderSlot) -> String {
        switch slot {
        case .meetings: return Preferences.shared.meetingsPath
        case .recordings: return Preferences.shared.recordingsPath
        }
    }

    /// Записать новый путь. И в `Preferences`, и в зеркало `@AppStorage` —
    /// ключ у них общий, но вторая строка ячейки читает именно зеркало.
    @MainActor
    private func commit(_ slot: FolderSlot, _ path: String) {
        switch slot {
        case .meetings:
            meetingsPath = path
            Preferences.shared.meetingsPath = path
        case .recordings:
            recordingsPath = path
            Preferences.shared.recordingsPath = path
        }
        state.refreshStorageUsage()
    }

    @MainActor
    private func chooseArchiveFolder(_ slot: FolderSlot) {
        guard let url = Self.pickFolder() else { return }
        let source = currentPath(slot)
        let target = url.path
        switch ArchiveRelocation.verdict(
            from: ArchiveRelocation.survey(source),
            to: ArchiveRelocation.survey(target)
        ) {
        case .sameFolder:
            // Ткнули в ту же папку — говорить не о чем.
            break
        case .nothingToCarry:
            commit(slot, target)
        case .carry(let plan):
            pendingMove = PendingMove(slot: slot, source: source, target: target, plan: plan)
        case .refused(let obstacle):
            notice = Self.notice(for: obstacle, source: source, target: target)
        }
    }

    /// Перенести и только потом переключить путь.
    ///
    /// Не на главном потоке: внутри тома это переименования, но между томами —
    /// настоящая копия мегабайтов, и окно на это время замерло бы.
    /// Путь переключается **после** переноса и только если доехало всё:
    /// путь, указывающий на половину архива, — это то самое молчание, ради
    /// которого всё и переделано.
    @MainActor
    private func startMove(_ move: PendingMove) {
        movingSlot = move.slot
        let (plan, source, target) = (move.plan, move.source, move.target)
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                ArchiveRelocation.perform(plan, from: source, to: target)
            }.value
            movingSlot = nil
            if outcome.isComplete {
                commit(move.slot, target)
            } else {
                notice = Self.notice(for: outcome, source: source, target: target)
                state.refreshStorageUsage()
            }
        }
    }

    // MARK: - Тексты

    private static func moveMessage(_ move: PendingMove) -> String {
        var parts = ["Переедет \(files(move.plan.carried.count)) из \(move.source)."]
        if move.plan.joins > 0 {
            parts.append("В новой папке уже лежит \(files(move.plan.joins)) — они останутся на месте.")
        }
        if !move.plan.leftBehind.isEmpty {
            parts.append("\(files(move.plan.leftBehind.count)) не наших останутся в старой папке.")
        }
        parts.append(
            "«Начать с пустой» ничего не переносит: встречи останутся в старой папке, и в приложении их не будет."
        )
        return parts.joined(separator: " ")
    }

    private static func notice(
        for obstacle: ArchiveRelocation.Obstacle, source: String, target: String
    ) -> Notice {
        switch obstacle {
        case .targetNotWritable:
            return Notice(
                title: "В эту папку нельзя писать",
                message: "\(target) недоступна для записи — туда не ляжет и следующая запись. "
                    + "Папка не изменилась: архив остался в \(source)."
            )
        case .targetHoldsArchive(let colliding):
            return Notice(
                title: "Там уже лежит архив",
                message: "В \(target) уже есть \(files(colliding.count)) с теми же именами: "
                    + "\(sample(colliding)). Перенос затёр бы их, а вместе с recordings.json — "
                    + "и все расшифровки, которые лежат строками в нём. "
                    + "Выберите пустую папку; архив остался в \(source)."
            )
        }
    }

    private static func notice(
        for outcome: ArchiveRelocation.Outcome, source: String, target: String
    ) -> Notice {
        let stopped = outcome.stoppedAt ?? "первом файле"
        if outcome.stranded.isEmpty {
            return Notice(
                title: "Перенести не получилось",
                message: "Встали на «\(stopped)». Всё, что успело переехать, вернулось назад: "
                    + "архив цел и лежит в \(source), папка не изменилась."
            )
        }
        return Notice(
            title: "Перенести не получилось, и вернулось не всё",
            message: "Встали на «\(stopped)», а \(files(outcome.stranded.count)) не удалось "
                + "вернуть: \(sample(outcome.stranded)). Они лежат в \(target). "
                + "Папка не изменилась — приложение читает \(source); перенесите их обратно руками."
        )
    }

    /// Несколько имён вместо списка на весь экран: человеку нужно узнать
    /// файлы, а не пересчитать их.
    private static func sample(_ names: [String]) -> String {
        let head = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? head + " и ещё \(names.count - 3)" : head
    }

    /// «1 файл», «2 файла», «5 файлов». Число и слово держатся вместе
    /// неразрывным пробелом по тому же доводу, что и в `bytes`.
    private static func files(_ count: Int) -> String {
        let hundreds = count % 100
        let ones = count % 10
        let word: String
        if (11...14).contains(hundreds) { word = "файлов" }
        else if ones == 1 { word = "файл" }
        else if (2...4).contains(ones) { word = "файла" }
        else { word = "файлов" }
        return "\(count)\u{00A0}\(word)"
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

