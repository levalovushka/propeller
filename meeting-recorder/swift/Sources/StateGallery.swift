#if GALLERY
import PropellerPure
import PropellerUI
import SwiftUI

/// Every UI state, side by side, for screenshots and redesign reference.
///
/// Compiled only into `./build.sh --gallery`; the shipping app does not contain
/// a byte of it. That is deliberate — this can pose the pipeline in any state,
/// which is a debugging tool, not a user feature.
///
/// **It never writes.** Every meeting shown is fabricated in memory and passed
/// straight to the view; the store is never asked to update, rename or delete
/// anything, and `galleryPose` only touches `activity`, which is ephemeral by
/// design. The real archive is safe to run this against.
struct StateGallery: View {
    @ObservedObject var state: AppState
    @State private var selected: String = UIStateCatalog.meetingStates.first?.id ?? ""

    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                Section("Встреча — состояния пайплайна") {
                    ForEach(UIStateCatalog.meetingStates) { meeting in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meeting.label).font(.callout)
                            Text(caption(for: meeting))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .tag(meeting.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            if let meeting = UIStateCatalog.meetingStates.first(where: { $0.id == selected }) {
                RecordingDetailView(state: state, entry: Self.entry(for: meeting))
                    .id(meeting.id)   // rebuild on switch; no state leaks between poses
                    .onAppear { pose(meeting) }
                    .onChange(of: selected) { _, _ in pose(meeting) }
            } else {
                ContentUnavailableView("Выберите состояние", systemImage: "square.grid.2x2")
            }
        }
        .frame(minWidth: 1100, minHeight: 720)
    }

    private func caption(for meeting: UIStateCatalog.MeetingState) -> String {
        var parts = ["\(meeting.id) · \(meeting.stage.rawValue)"]
        switch meeting.involvement {
        case .idle: break
        case .working(let phase):   parts.append("работаем: \(phase.rawValue)")
        case .elsewhere(let phase): parts.append("занят другой: \(phase.rawValue)")
        }
        if meeting.hasFailure { parts.append("ошибка") }
        return parts.joined(separator: " · ")
    }

    /// Put the app into the pose this row describes. Ephemeral only.
    private func pose(_ meeting: UIStateCatalog.MeetingState) {
        switch meeting.involvement {
        case .idle:
            state.galleryPose(activity: .idle)
        case .working(let phase):
            state.galleryPose(activity: .working(
                recordingID: Self.entry(for: meeting).id, phase: phase, detail: nil
            ))
        case .elsewhere(let phase):
            // A different id on purpose: this is the row that must stay static
            // while something else is being worked on.
            state.galleryPose(activity: .working(
                recordingID: "gallery-other-meeting", phase: phase, detail: nil
            ))
        }
    }

    // MARK: - Fabricated meetings

    /// In-memory only. Never handed to `RecordingStore`.
    static func entry(for meeting: UIStateCatalog.MeetingState) -> RecordingEntry {
        let hasTranscript = meeting.stage >= .transcribed
        let hasSummary = meeting.stage >= .summarized
        return RecordingEntry(
            id: "gallery-\(meeting.id)",
            filename: "gallery-\(meeting.id).wav",
            date: Date(timeIntervalSince1970: 1_785_000_000),
            duration: 2_950,
            title: "Воркшоп по музыке",
            status: meeting.stage,
            transcript: hasTranscript ? Self.sampleTranscript : nil,
            notes: "созвониться с подрядчиком\nпроверить бюджет",
            language: "ru",
            rawSegmentsJSON: nil,
            mergedSegmentsJSON: nil,
            topics: hasSummary ? ["дизайн-система", "релиз бота", "корпус"] : nil,
            tags: hasSummary ? ["планирование"] : nil,
            titleManuallySet: nil,
            micOnlyCaptured: nil,
            lastFailure: meeting.hasFailure
                ? PipelineFailure(phase: .diarizing, message: "gigastt HTTP 413: тело запроса слишком большое")
                : nil
        )
    }

    private static let sampleTranscript = """
    **Левон** · 00:00
    Давайте начнём. Сегодня разбираем скоуп дизайн-системы под веб.

    **Speaker 1** · 00:12
    У меня вопрос по срокам — успеваем к понедельнику?

    **Левон** · 00:19
    Успеваем, если сегодня закроем компоненты.
    """
}
#endif
