import SwiftUI
import AppKit
import PropellerUI
import PropellerPure

/// Во что превращается записанный звук: сначала в текст, потом в конспект.
///
/// Две вещи, и обе — не значения, а документы: список слов, которые
/// распознаватель обязан понимать, и промпт, по которому пишется саммари.
/// Поэтому обе стоят во всю ширину карточки, а не в правом слоте: в слот
/// шириной 164 не помещается ни то ни другое.
struct TranscriptSettingsPage: View {
    @ObservedObject var state: AppState
    @AppStorage("domainTerms") private var domainTerms = ""
    @State private var recapPrompt: String = Preferences.shared.recapPrompt
    @State private var restartStatus: String?
    @State private var pendingRestart: DispatchWorkItem?

    private var terms: [String] { Preferences.domainTermsList(from: domainTerms) }

    var body: some View {
        SettingsPage(SettingsSection.transcript.title) {
            SettingsCard {
                // Словарь стоит перед промптом: он про распознавание, то есть
                // про шаг раньше. Подпись называет, что сюда пишут, — не то, что
                // с этим потом случится: «ломает распознаватель» человек и так
                // знает, он потому и пришёл.
                SettingsWideCell(
                    "Личный словарь",
                    subtitle: "Имена, названия и сленг, которые модель должна понимать"
                ) {
                    VStack(alignment: .leading, spacing: Tokens.Settings.stackGap) {
                        // Слова, а не строка через запятую: в строке не видно,
                        // где кончается одно слово, и нельзя убрать одно, не
                        // перечитав все.
                        SettingsTagField(
                            tags: terms,
                            onRemove: { word in setTerms(terms.filter { $0 != word }) },
                            onAdd: { word in
                                guard !terms.contains(word) else { return }
                                setTerms(terms + [word])
                            }
                        )
                        if let restartStatus {
                            Text(restartStatus)
                                .typo(Tokens.Settings.Typo.subtitle)
                                .foregroundStyle(Tokens.Settings.subtitleProgress)
                        }
                    }
                }
            }

            // «Вернуть как было» появляется, только когда есть что возвращать.
            //
            // §7 канона запрещала кнопку сброса — «пустое поле и есть сброс», —
            // и §11 фиксировала эту кнопку как отвергнутую 2026-08-20. Решение
            // владельца 2026-08-26 пересмотрено, канон переписан: правило было
            // верно, пока промпт стоял в поле на 80 pt, где его целиком видно, и
            // перестало быть верным, когда он занял экран. Стереть тридцать
            // строк, чтобы вернуться к дефолту, — не «сброс», а «наберите
            // заново, если передумаете».
            SettingsGroup(
                "Промпт",
                actionTitle: promptIsCustom ? "Вернуть как было" : nil,
                actionSymbol: "arrow.counterclockwise",
                action: promptIsCustom ? resetPrompt : nil
            ) {
                SettingsWideCell("") {
                    SettingsEditor(text: $recapPrompt)
                }
            }
            .onChange(of: recapPrompt) { _, val in
                Preferences.shared.recapPrompt = val
            }
        }
        .onAppear {
            recapPrompt = Preferences.shared.recapPrompt
        }
    }

    /// Свой ли это промпт. Сравнение с текстом, а не флаг «изменено»: флаг
    /// пришлось бы хранить, а хранимое расходится с правдой в тот день, когда
    /// встроенный промпт поправят.
    private var promptIsCustom: Bool {
        recapPrompt != RecapService.defaultPrompt
    }

    private func resetPrompt() {
        // Пустая строка и есть дефолт: `Preferences.recapPrompt` отдаёт
        // встроенный, когда сохранённого нет. Кнопка не «пишет дефолт», она
        // убирает своё — иначе завтрашняя правка встроенного не доехала бы до
        // того, кто однажды нажал «Вернуть».
        Preferences.shared.recapPrompt = ""
        recapPrompt = Preferences.shared.recapPrompt
    }

    private func setTerms(_ words: [String]) {
        domainTerms = words.joined(separator: ", ")
        Preferences.shared.domainTerms = domainTerms
        scheduleRestart()
    }

    /// Hotwords are a server-launch argument for gigastt, not per-request, so
    /// picking up an edited term list means restarting the sidecar. Debounced
    /// so a whole typed phrase triggers one restart, not one per keystroke.
    private func scheduleRestart() {
        pendingRestart?.cancel()
        let work = DispatchWorkItem {
            restartStatus = "Перезапуск распознавателя…"
            Task {
                do {
                    try await GigasttSidecar.shared.restart()
                    await MainActor.run { restartStatus = nil }
                } catch {
                    await MainActor.run {
                        restartStatus = "Распознаватель не перезапустился: \(error.localizedDescription)"
                    }
                }
            }
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}
