import SwiftUI
import AppKit
import PropellerUI

/// Recording phase — same meeting chrome, tabs hidden (reqs 632:236).
struct RecordingInProgressView: View {
    @ObservedObject var state: AppState

    @State private var liveTitle: String = ""
    @State private var liveNotes: String = ""
    @FocusState private var titleFocused: Bool

    private static var pendingNotesSave: DispatchWorkItem?
    private static var pendingNotesCommit: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
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
        .onDisappear { flushNotes() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                TextField("Untitled", text: $liveTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 40, weight: .semibold))
                    .tracking(-0.8)
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
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.red.opacity(0.9))
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Color.red.opacity(0.12), in: Capsule())
            }

            HStack(spacing: 10) {
                Text(state.elapsedString)
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(Tokens.Ink.primary)
                    .contentTransition(.numericText())

                levelChip(
                    label: "Mic",
                    level: state.recorder.micLevelHistory.last ?? 0,
                    tint: .red,
                    warning: state.recorder.micCaptureWarning != nil
                )

                if Preferences.shared.captureSystemAudio {
                    levelChip(
                        label: "System",
                        level: state.recorder.systemLevelHistory.last ?? 0,
                        tint: .cyan,
                        warning: state.recorder.systemAudioWarning != nil
                    )
                }

                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.40))

            if let micWarning = state.recorder.micCaptureWarning {
                warningBanner(title: "Microphone not recording", detail: micWarning, tint: .red) {
                    state.openMicrophoneSettings()
                }
            } else if state.recorder.systemAudioWarning != nil, Preferences.shared.captureSystemAudio {
                // Only shown when capture failed to start (permissions / SCK throw).
                // Quiet Zoom or a live System meter never use this path.
                warningBanner(
                    title: "Can’t start system audio",
                    detail: "Screen Recording permission may be missing or stale. Mic is still recording.",
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
                .fill(Color.white.opacity(0.08))
                .frame(width: 48, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(warning ? Color.orange.opacity(0.85) : tint)
                        .frame(width: barWidth, height: 4)
                }
        }
        .foregroundStyle(warning ? Color.orange.opacity(0.9) : Color.white.opacity(0.40))
    }

    private func warningBanner(
        title: String, detail: String, tint: Color, action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                Text(detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.50))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Settings", action: action)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tokens.Ink.primary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Color.white.opacity(0.10), in: Capsule())
        }
        .padding(10)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Notepad

    private var notepad: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.30))
                .padding(.horizontal, 12)

            TextEditor(text: $liveNotes)
                .font(.system(size: 14, weight: .medium))
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

    private var stopBar: some View {
        HStack {
            Spacer()
            Button {
                flushNotes()
                state.stopRecording()
            } label: {
                Text("Stop")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Tokens.Ink.primary)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(Color.red.opacity(0.85), in: Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(".", modifiers: .command)
            .help("Stop and process")
            Spacer()
        }
        .padding(.vertical, 16)
    }

    private func flushNotes() {
        Self.pendingNotesSave?.cancel()
        Self.pendingNotesSave = nil
        Self.pendingNotesCommit?()
        Self.pendingNotesCommit = nil
        if let entry = state.selectedRecording {
            state.updateNotes(entry, to: liveNotes)
        }
    }
}
