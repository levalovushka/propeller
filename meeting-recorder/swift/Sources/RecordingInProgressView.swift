import SwiftUI
import AppKit
import PropellerUI

/// Recording phase — same meeting chrome, tabs hidden (reqs 632:236).
struct RecordingInProgressView: View {
    @ObservedObject var state: AppState
    /// Observed directly: `AppState.recorder` only republishes when the whole
    /// object is replaced, so level meters updated ~1×/s instead of 10 (P3).
    @ObservedObject var recorder: AudioRecorder

    @State private var liveTitle: String = ""
    @State private var liveNotes: String = ""
    @FocusState private var titleFocused: Bool

    private static var pendingNotesSave: DispatchWorkItem?
    private static var pendingNotesCommit: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Tokens.Paint.Bg.surface)
            notepad
                .frame(maxHeight: .infinity)
            stopBar
        }
        .frame(maxWidth: Tokens.Window.contentWidth)
        .frame(maxWidth: .infinity)
        .foregroundStyle(Tokens.Ink.primary)
        .onAppear {
            liveTitle = state.selectedRecording?.title ?? ""
            liveNotes = state.selectedRecording?.notes ?? ""
        }
        .onChange(of: state.selectedRecording?.notes) { _, stored in
            adoptExternalNotes(stored)
        }
        .onDisappear { flushNotes() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                TextField("Без названия", text: $liveTitle)
                    .textFieldStyle(.plain)
                    .typo(Tokens.Typography.Heading.lg)
                    .foregroundStyle(Tokens.Ink.primary)
                    .focused($titleFocused)
                    .onChange(of: liveTitle) { _, val in
                        // Only latch titleManuallySet when the user actually edits.
                        // Syncing the auto title onAppear used to call rename() and
                        // permanently block LLM rename after summary.
                        guard let entry = state.selectedRecording else { return }
                        let trimmed = val.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty, trimmed != entry.title else { return }
                        state.renameRecording(entry, to: trimmed)
                    }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    TimelineView(.animation(minimumInterval: 0.9, paused: !state.isRecording)) { context in
                        let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.9) % 2
                        Circle()
                            .fill(Color.red.opacity(phase == 0 ? 1 : 0.35))
                            .frame(width: 8, height: 8)
                    }
                    Text("REC")
                        .typo(Tokens.Typography.Label.smMedium)
                        .foregroundStyle(Color.red.opacity(0.9))
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Color.red.opacity(0.12), in: Capsule())
            }

            HStack(spacing: 10) {
                Text(state.elapsedString)
                    .typo(Tokens.Typography.Label.mdMedium, monospacedDigit: true)
                    .foregroundStyle(Tokens.Ink.primary)
                    .contentTransition(.numericText())

                levelChip(
                    label: "Мик",
                    level: recorder.micLevelHistory.last ?? 0,
                    tint: .red,
                    warning: recorder.micCaptureWarning != nil
                )

                if Preferences.shared.captureSystemAudio {
                    levelChip(
                        label: "Система",
                        level: recorder.systemLevelHistory.last ?? 0,
                        tint: .cyan,
                        warning: recorder.systemAudioWarning != nil
                    )
                }

                Spacer(minLength: 0)
            }
            .typo(Tokens.Typography.Label.smMedium)
            .foregroundStyle(Tokens.Ink.quaternary)

            if let micWarning = recorder.micCaptureWarning {
                warningBanner(title: "Микрофон не пишет", detail: micWarning, tint: .red) {
                    state.openMicrophoneSettings()
                }
            } else if recorder.systemAudioWarning != nil, Preferences.shared.captureSystemAudio {
                // Only shown when capture failed to start (permissions / SCK throw).
                // Quiet Zoom or a live System meter never use this path.
                warningBanner(
                    title: "Не удалось записать систему",
                    detail: "Нет доступа к записи экрана или он устарел. Мик пишет.",
                    tint: .orange
                ) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func levelChip(label: String, level: Float, tint: Color, warning: Bool) -> some View {
        // Always show the real level. Warning only recolors the label — never
        // fake a full bar (that looked like System was hot while .sys was empty).
        let barWidth: CGFloat = level <= 0.001 ? 0 : max(2, 48 * CGFloat(level))
        return HStack(spacing: 6) {
            Text(label)
            Capsule()
                .fill(Tokens.Paint.Bg.surface)
                .frame(width: 48, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(warning ? Color.orange.opacity(0.85) : tint)
                        .frame(width: barWidth, height: 4)
                }
        }
        .foregroundStyle(warning ? Color.orange.opacity(0.9) : Tokens.Ink.quaternary)
    }

    private func warningBanner(
        title: String, detail: String, tint: Color, action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .typo(Tokens.Typography.Label.smMedium)
                    .foregroundStyle(tint)
                Text(detail)
                    .typo(Tokens.Typography.Label.smMedium)
                    .foregroundStyle(Tokens.Neutral.aw50)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Настройки", action: action)
                .buttonStyle(.plain)
                .typo(Tokens.Typography.Label.smMedium)
                .foregroundStyle(Tokens.Ink.primary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Tokens.Neutral.aw10, in: Capsule())
        }
        .padding(10)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
    }

    // MARK: - Notepad

    private var notepad: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Заметки")
                .typo(Tokens.Typography.Label.smMedium)
                .foregroundStyle(Tokens.Ink.tertiary)
                .padding(.horizontal, 12)

            TextEditor(text: $liveNotes)
                .typo(Tokens.Typography.Body.md)
                .foregroundStyle(Tokens.Ink.primary)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .onChange(of: liveNotes) { _, newValue in
                    Self.pendingNotesSave?.cancel()
                    let commit: () -> Void = {
                        if let entry = state.selectedRecording {
                            state.updateNotes(entry, to: newValue)
                        }
                        Self.pendingNotesCommit = nil
                    }
                    Self.pendingNotesCommit = commit
                    let work = DispatchWorkItem(block: commit)
                    Self.pendingNotesSave = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
                }
        }
        .padding(.top, 16)
    }

    // MARK: - Stop

    @State private var showingDiscardConfirm = false

    private var stopBar: some View {
        HStack(spacing: 12) {
            Spacer()
            Button {
                showingDiscardConfirm = true
            } label: {
                Text("Сбросить")
                    .typo(Tokens.Typography.Label.mdMedium)
                    .foregroundStyle(Tokens.Ink.secondary)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(Tokens.Paint.Bg.surface, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Стоп и удалить")

            Button {
                flushNotes()
                state.stopRecording()
            } label: {
                Text("Стоп")
                    .typo(Tokens.Typography.Label.mdMedium)
                    .foregroundStyle(Tokens.Ink.primary)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(Color.red.opacity(0.85), in: Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(".", modifiers: .command)
            .help("Стоп и обработать")
            Spacer()
        }
        .padding(.vertical, 16)
        .confirmationDialog(
            "Сбросить запись?",
            isPresented: $showingDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button("Стоп и сбросить", role: .destructive) {
                flushNotes()
                state.cancelRecording()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Аудио и заметки этой записи удалятся.")
        }
    }

    /// The ⌃⌥N overlay appends straight to the store while this editor holds its
    /// own copy of the text. Without adopting that append, the flush on Stop
    /// wrote the stale copy back and the overlay note vanished (release-review
    /// rev-6 — the one confirmed data loss). Only a pure append is adopted, so
    /// this can never clobber what the user is typing.
    private func adoptExternalNotes(_ stored: String?) {
        let stored = stored ?? ""
        guard stored != liveNotes,
              stored.count > liveNotes.count,
              stored.hasPrefix(liveNotes) else { return }
        liveNotes = stored
    }

    private func flushNotes() {
        Self.pendingNotesSave?.cancel()
        Self.pendingNotesSave = nil
        Self.pendingNotesCommit = nil
        guard let entry = state.selectedRecording else { return }
        let stored = entry.notes ?? ""
        // An overlay note landed after the last keystroke — don't overwrite it.
        if stored.count > liveNotes.count, stored.hasPrefix(liveNotes) { return }
        state.updateNotes(entry, to: liveNotes)
    }
}
