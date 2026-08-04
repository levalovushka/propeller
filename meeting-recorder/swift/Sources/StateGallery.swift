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
/// **It never touches the real archive.** Meetings, markdown and index all come
/// from `GalleryFixture`, a temp directory the whole process is pointed at
/// before `AppState` exists. Reads land there, and so would any write. The
/// library screens used to photograph whatever the machine happened to hold;
/// that was unreproducible — "список встреч — пусто" showed six meetings — and
/// it put private meeting titles into a shared Figma file.
struct StateGallery: View {
    @ObservedObject var state: AppState
    @State private var selected: String = UIStateCatalog.meetingStates.first?.id ?? ""

    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                // The rail is a component, not a screen — its boards put a whole
                // axis in one frame instead of nine near-identical windows.
                section("Сайдбар",
                        SidebarGallery.ids.map { ($0, SidebarGallery.label(for: $0), $0) })
                section("Встреча — состояния пайплайна",
                        UIStateCatalog.meetingStates.map { ($0.id, $0.label, Self.caption(for: $0)) })
                section("Онбординг", UIStateCatalog.onboarding.map { ($0.id, $0.label, $0.id) })
                section("Вкладки карточки", UIStateCatalog.detailTabs.map { ($0.id, $0.label, $0.id) })
                section("Библиотека", UIStateCatalog.library.map { ($0.id, $0.label, $0.id) })
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

    /// Ephemeral app state this screen needs. Never persisted — and never the
    /// user's own archive either: the data behind every screen is
    /// `GalleryFixture`, which explains why at length.
    static func pose(id: String, state: AppState) {
        GalleryFixture.pose(id: id, state: state)
    }

    /// The app's own window size. Every screen that lives in the window is shot
    /// at it, so the reference shows states of one surface rather than a pile of
    /// differently-sized crops.
    static let windowSize = CGSize(width: 940, height: 700)

    @ViewBuilder
    static func view(id: String, state: AppState) -> some View {
        if SidebarGallery.ids.contains(id) {
            // Component boards need no posed pipeline — they are drawn straight
            // from `SidebarStateCatalog`, which is the point of keeping the
            // rail's states as data rather than as app state.
            SidebarGallery.view(for: id)
        } else if GalleryScreens.ownedIDs.contains(id) {
            // Onboarding screens are PropellerUI's own — its step
            // views are internal to that module, so it draws them itself.
            GalleryScreens.view(for: id)
        } else if id == "lib-search" {
            // ⌘K is presented as a sheet, and a sheet is a window of its own —
            // capturing the list window would miss it entirely. Drawn in place
            // over the list it covers, which is what a person sees anyway.
            ZStack {
                window(state: state)
                Rectangle().fill(Color.black.opacity(0.45)).ignoresSafeArea()
                SearchPalette(state: state, onOpenRecording: { _ in }, onClose: {})
            }
            .frame(width: windowSize.width, height: windowSize.height)
            .background(Color.black)
        } else if UIStateCatalog.meetingStates.contains(where: { $0.id == id })
                    || id.hasPrefix("tab-") || id.hasPrefix("lib-") {
            // Pipeline states are rows in the list; tab states are the detail
            // inside the same chrome. Both are `MainView` deciding what to show
            // from the posed state — photographing `RecordingDetailView` on its
            // own left out the frame around it and made eleven pipeline states
            // look like one screen.
            window(state: state)
        } else {
            ContentUnavailableView("Нет экрана для \(id)", systemImage: "questionmark.square.dashed")
        }
    }

    private static func window(state: AppState) -> some View {
        MainView(state: state, recordingStore: state.recordingStore)
            .frame(width: windowSize.width, height: windowSize.height)
    }
}
#endif
