import SwiftUI
import PropellerPure
import PropellerUI

/// Панель встречи, которая пишется прямо сейчас.
///
/// Здесь только подписка: живой транскрипт приходит несколько раз в секунду, и
/// подписан на него ровно этот вид — не окно и не рельс, иначе список встреч
/// перерисовывался бы на каждое слово.
///
/// Всё остальное — та же панель, что у готовой встречи (`RecordingPaneBody`).
struct RecordingPaneView: View {
    @ObservedObject var live: LiveTranscriptService
    let entry: RecordingEntry
    let isPaused: Bool
    let ownerName: String
    let notes: [MeetingNote]
    let transcriptNotes: [TranscriptNote]
    let composer: MeetingPaneBody.NoteComposer
    let onRevealNotes: () -> Void
    let onHideNotes: () -> Void
    let notesHidden: Bool
    let notesInk: Double
    @Binding var notesFocusRequest: Bool
    @Binding var travel: WindowReveal.NotesTravel?

    var body: some View {
        RecordingPaneBody(
            turns: live.recordingID == entry.id ? live.transcript.turns : [],
            ownerName: ownerName,
            // Без системной дорожки канал один, и он слышит всех: подписывать
            // его владельцем — значит отдать ему каждую чужую реплику до конца
            // встречи. Имена появляются только там, где их есть из чего вывести.
            namesSpeakers: live.attributesSpeakers,
            placeholder: placeholder,
            isPaused: isPaused,
            notes: notes,
            transcriptNotes: transcriptNotes,
            composer: composer,
            onRevealNotes: onRevealNotes,
            onHideNotes: onHideNotes,
            notesHidden: notesHidden,
            notesInk: notesInk,
            notesFocusRequest: $notesFocusRequest,
            travel: $travel
        )
    }

    /// Что стоит на месте текста, пока его нет.
    ///
    /// Две разные вещи, и путать их нельзя: «ещё никто не сказал ни слова» и
    /// «живой строки на этой записи не будет вовсе» — второе случается, когда
    /// захват ушёл на микрофонный путь, где буферов нет. Ни то, ни другое не
    /// отказ: встреча пишется, и её расшифруют после остановки
    /// (`design/no-dead-ends.md`).
    private var placeholder: String {
        live.recordingID == entry.id
            ? "Слушаю…"
            : "Расшифровка появится после встречи"
    }
}
