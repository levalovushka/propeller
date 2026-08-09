import SwiftUI
import PropellerPure

/// # Заметка внутри расшифровки
///
/// То, что человек написал во время встречи, стоит в ленте на своей секунде —
/// между репликами, среди которых это было написано. Отдельного списка заметок
/// больше нет: список рядом с разговором заставлял сводить их глазами, а место
/// в ленте отвечает на вопрос «про что это было» само.
///
/// Выделена ровно настолько, чтобы не спутать со сказанным. Расшифровка — запись
/// того, что услышал микрофон; заметка — то, чего он не слышал, и это должно
/// быть видно, не отвлекая. Отсюда плашка: она обводит текст, а не двигает его,
/// поэтому реплики и заметки стоят на одной левой границе и лента читается
/// одним столбцом.
public struct TranscriptNote: Identifiable, Equatable, Sendable {
    public let id: String
    /// `12:34` — та же метка, что у реплики, и в том же столбце.
    public let time: String
    public let text: String
    /// Секунда от начала записи. Nil — заметку дописали после встречи, и в
    /// ленте ей места нет (`NotePlacement.interleave`).
    public let seconds: Double?

    public init(id: String, time: String, text: String, seconds: Double?) {
        self.id = id
        self.time = time
        self.text = text
        self.seconds = seconds
    }
}

/// Одна заметка в ленте: метка времени там же, где у реплик, и текст на плашке.
struct TranscriptNoteRow: View {
    let note: TranscriptNote

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Pane.transcriptLineGap) {
            Text(note.time)
                .typoBlock(Tokens.Pane.Typo.transcriptMeta, monospacedDigit: true)
                .frame(width: Tokens.Pane.transcriptTimeWidth, alignment: .leading)
                .foregroundStyle(Tokens.Pane.meta)
            Text(note.text)
                .typoBlock(Tokens.Pane.Typo.transcriptBody)
                .foregroundStyle(Tokens.Pane.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        // Плашка растёт наружу от текста, а не отодвигает его внутрь. Внутренний
        // отступ сдвинул бы строку заметки относительно строк вокруг, и лента
        // перестала бы быть одним столбцом ради подсветки одного абзаца.
        .background(
            RoundedRectangle(cornerRadius: Tokens.Pane.noteRadius, style: .continuous)
                .fill(Tokens.Pane.notePlateFill)
                .padding(.horizontal, -Tokens.Pane.transcriptNotePlateBleedH)
                .padding(.vertical, -Tokens.Pane.transcriptNotePlateBleedV)
        )
    }
}
