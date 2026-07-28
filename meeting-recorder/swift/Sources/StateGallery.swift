#if GALLERY
import PropellerPure
import PropellerUI
import SwiftUI

/// # State gallery — what it is
///
/// Every screen Propeller can show, in one window, so they can be compared,
/// screenshotted and handed to a redesign as the reference for *what exists
/// today*. Without it, "all the states" is something you reconstruct from
/// memory, which is how states get forgotten — the empty summary panel with no
/// model downloaded was shipped wrong for weeks because nobody had a place to
/// look at it next to its siblings.
///
/// # How it stays complete
///
/// It draws from `PropellerPure.UIStateCatalog`, and that catalogue is checked
/// against the *types*: every `RecordingStage` must have a screen or be named
/// unreachable, every `PipelineActivity.Phase` must have a progress screen. Add
/// a stage and forget its screen, and a test goes red — the gallery cannot
/// quietly fall behind the app.
///
/// # Why it is not in the shipping app
///
/// `./build.sh --gallery` compiles it in; a plain `./build.sh` leaves out every
/// byte (verified by symbol count in that script's own output). This code can
/// pose the pipeline in an arbitrary state, which is a debugging power, not a
/// user feature — in a shipped build it would be a way to confuse the app about
/// its own work.
///
/// # What it is not allowed to do
///
/// **It never writes.** Meetings shown here are fabricated in memory and passed
/// straight to the view, which takes an entry by value; `RecordingStore` is
/// never asked to update, rename or delete anything. `galleryPose` sets only
/// `activity` and `preferredDetailTab`, both ephemeral. The library screens do
/// read the real archive — that is deliberate, real data photographs better
/// than lorem ipsum — but read is all they do. Running this against a real
/// archive is safe.
struct StateGallery: View {
    @ObservedObject var state: AppState
    @State private var selected: String = UIStateCatalog.meetingStates.first?.id ?? ""

    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                section("Встреча — состояния пайплайна",
                        UIStateCatalog.meetingStates.map { ($0.id, $0.label, Self.caption(for: $0)) })
                section("Онбординг", UIStateCatalog.onboarding.map { ($0.id, $0.label, $0.id) })
                section("Вкладки карточки", UIStateCatalog.detailTabs.map { ($0.id, $0.label, $0.id) })
                section("Библиотека", UIStateCatalog.library.map { ($0.id, $0.label, $0.id) })
                section("Тосты", UIStateCatalog.toasts.map { ($0.id, $0.label, $0.id) })
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        } detail: {
            GalleryStage(state: state, id: selected)
        }
        .frame(minWidth: 1180, minHeight: 760)
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [(String, String, String)]) -> some View {
        Section(title) {
            ForEach(rows, id: \.0) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.1).font(.callout)
                    Text(row.2).font(.caption2).foregroundStyle(.secondary)
                }
                .tag(row.0)
            }
        }
    }

    static func caption(for meeting: UIStateCatalog.MeetingState) -> String {
        var parts = ["\(meeting.id) · \(meeting.stage.rawValue)"]
        switch meeting.involvement {
        case .idle: break
        case .working(let phase):   parts.append("работаем: \(phase.rawValue)")
        case .elsewhere(let phase): parts.append("занят другой: \(phase.rawValue)")
        }
        if meeting.hasFailure { parts.append("ошибка") }
        return parts.joined(separator: " · ")
    }
}

/// One screen, posed and drawn. Split out so the browser and the exporter render
/// through exactly the same path — a screenshot that differs from what the
/// window shows would be worse than no screenshot.
struct GalleryStage: View {
    @ObservedObject var state: AppState
    let id: String

    var body: some View {
        GalleryScreenFactory.view(id: id, state: state)
            .id(id)                                   // fresh view per pose; no leakage
            .onAppear { GalleryScreenFactory.pose(id: id, state: state) }
            .onChange(of: id) { _, new in GalleryScreenFactory.pose(id: new, state: state) }
    }
}

/// The single place that says "state `id` looks like this".
@MainActor
enum GalleryScreenFactory {

    /// Ephemeral app state this screen needs. Never persisted.
    static func pose(id: String, state: AppState) {
        if let meeting = UIStateCatalog.meetingStates.first(where: { $0.id == id }) {
            switch meeting.involvement {
            case .idle:
                state.galleryPose(activity: .idle)
            case .working(let phase):
                state.galleryPose(activity: .working(
                    recordingID: entry(for: meeting).id, phase: phase, detail: nil))
            case .elsewhere(let phase):
                // A different id on purpose — this is the row that must stay
                // static while the worker is busy with something else.
                state.galleryPose(activity: .working(
                    recordingID: "gallery-other-meeting", phase: phase, detail: nil))
            }
            state.preferredDetailTab = nil
            return
        }
        state.galleryPose(activity: .idle)
        state.preferredDetailTab = Self.tab(for: id)
    }

    private static func tab(for id: String) -> String? {
        if id.hasPrefix("tab-summary")    { return "recap" }
        if id.hasPrefix("tab-notes")      { return "notes" }
        if id.hasPrefix("tab-transcript") { return "transcript" }
        if id.hasPrefix("tab-letter")     { return "letter" }
        return nil
    }

    @ViewBuilder
    static func view(id: String, state: AppState) -> some View {
        if GalleryScreens.ownedIDs.contains(id) {
            // Onboarding and toasts are PropellerUI's own screens — its step
            // views are internal to that module, so it draws them itself.
            GalleryScreens.view(for: id)
        } else if let meeting = UIStateCatalog.meetingStates.first(where: { $0.id == id }) {
            RecordingDetailView(state: state, entry: entry(for: meeting))
                .frame(width: 900, height: 640)
        } else if id.hasPrefix("tab-") {
            RecordingDetailView(state: state, entry: tabEntry(for: id))
                .frame(width: 900, height: 640)
        } else if id.hasPrefix("lib-") {
            MainView(state: state, recordingStore: state.recordingStore)
                .frame(width: 900, height: 700)
        } else {
            ContentUnavailableView("Нет экрана для \(id)", systemImage: "questionmark.square.dashed")
        }
    }

    // MARK: - Fabricated meetings (in memory only, never stored)

    static func entry(for meeting: UIStateCatalog.MeetingState) -> RecordingEntry {
        make(
            id: "gallery-\(meeting.id)",
            stage: meeting.stage,
            transcript: meeting.stage >= .transcribed ? sampleTranscript : nil,
            summarized: meeting.stage >= .summarized,
            failure: meeting.hasFailure
                ? PipelineFailure(phase: .diarizing,
                                  message: "gigastt HTTP 413: тело запроса слишком большое")
                : nil
        )
    }

    static func tabEntry(for id: String) -> RecordingEntry {
        switch id {
        case "tab-summary-empty-nomodel", "tab-summary-empty-ready":
            return make(id: "gallery-\(id)", stage: .saved, transcript: sampleTranscript,
                        summarized: false, failure: nil)
        case "tab-notes-empty":
            return make(id: "gallery-\(id)", stage: .summarized, transcript: sampleTranscript,
                        summarized: true, failure: nil, notes: nil)
        case "tab-transcript-empty":
            return make(id: "gallery-\(id)", stage: .recorded, transcript: nil,
                        summarized: false, failure: nil)
        case "tab-transcript-failed":
            return make(id: "gallery-\(id)", stage: .recorded, transcript: nil, summarized: false,
                        failure: PipelineFailure(phase: .transcribing,
                                                 message: "gigastt завершился до готовности"))
        default:
            return make(id: "gallery-\(id)", stage: .summarized, transcript: sampleTranscript,
                        summarized: true, failure: nil)
        }
    }

    private static func make(
        id: String,
        stage: RecordingStage,
        transcript: String?,
        summarized: Bool,
        failure: PipelineFailure?,
        notes: String? = "созвониться с подрядчиком\nпроверить бюджет к пятнице"
    ) -> RecordingEntry {
        RecordingEntry(
            id: id,
            filename: "\(id).wav",
            date: Date(timeIntervalSince1970: 1_785_000_000),
            duration: 2_950,
            title: "Воркшоп по музыке",
            status: stage,
            transcript: transcript,
            notes: notes,
            language: "ru",
            rawSegmentsJSON: nil,
            mergedSegmentsJSON: nil,
            topics: summarized ? ["дизайн-система", "релиз бота", "корпус"] : nil,
            tags: summarized ? ["планирование"] : nil,
            titleManuallySet: nil,
            micOnlyCaptured: nil,
            lastFailure: failure
        )
    }

    static let sampleTranscript = """
    **Левон** · 00:00
    Давайте начнём. Сегодня разбираем скоуп дизайн-системы под веб.

    **Speaker 1** · 00:12
    У меня вопрос по срокам — успеваем к понедельнику?

    **Левон** · 00:19
    Успеваем, если сегодня закроем компоненты и заведём сторибук.

    **Speaker 3** · 00:31
    Тогда я беру на себя токены, а ревью в четверг.
    """
}
#endif
