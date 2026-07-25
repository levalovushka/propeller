import SwiftUI

struct MenuBarPanelView: View {
    @ObservedObject var state: AppState

    @State private var showingDiscardConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Record / Status section
            statusSection
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider()

            // Recent recordings
            recentRecordingsSection
                .padding(.vertical, 6)

            Divider()

            // Actions
            VStack(spacing: 2) {
                Button {
                    Self.showMainWindow()
                } label: {
                    Label("Open Propeller", systemImage: "macwindow")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

                Button {
                    SettingsOpener.open()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .padding(.vertical, 4)

            Divider()

            Button("Quit Propeller") {
                if state.isRecording {
                    Task {
                        await state.stopRecordingAndWait()
                        state.recordingStore.flush()
                        await MainActor.run { NSApplication.shared.terminate(nil) }
                    }
                } else {
                    state.recordingStore.flush()
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .padding(.bottom, 4)
        }
        .frame(width: 320)
    }

    // MARK: - Status Section

    @ViewBuilder
    private var statusSection: some View {
        if state.isRecording {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                        .symbolRenderingMode(.hierarchical)
                    Text("Recording").font(.headline)
                    Spacer()
                    Text(state.elapsedString)
                        .font(.system(.title3, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.red)
                }

                HStack(spacing: 8) {
                    Button {
                        state.stopRecording()
                    } label: {
                        Label("Stop", systemImage: "stop.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.regular)

                    Button {
                        showingDiscardConfirm = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .help("Stop & discard this recording")
                }
                .confirmationDialog(
                    "Discard this recording?",
                    isPresented: $showingDiscardConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Stop & Discard", role: .destructive) {
                        state.cancelRecording()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The recording will be deleted immediately. No transcript or summary will be created.")
                }
            }
        } else if state.zoomMeetingDetected && !state.isRecording {
            HStack(spacing: 6) {
                Image(systemName: "video.fill")
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Zoom call active").font(.headline)
                    Text("Recording not started").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    state.acceptZoomRecordingPrompt()
                } label: {
                    Label("Record", systemImage: "record.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
            }
        } else if state.transcribeStep == .running || state.saveStep == .running {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Processing…").font(.headline)
                    Text(state.statusMessage.isEmpty ? "Working…" : state.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Propeller").font(.headline)
                    Text("Ready to record").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    state.startRecording()
                } label: {
                    Label("Record", systemImage: "record.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.regular)
            }
        }
    }

    // MARK: - Recent Recordings

    private var recentRecordingsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recent")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .padding(.horizontal, 12)
                .padding(.bottom, 2)

            if state.recordingStore.recordings.isEmpty {
                Text("No recordings yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            } else {
                ForEach(state.recordingStore.recordings.prefix(4)) { entry in
                    Button {
                        state.selectRecording(entry)
                        Self.showMainWindow()
                    } label: {
                        HStack(spacing: 8) {
                            statusDot(entry)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.title)
                                    .font(.callout)
                                    .lineLimit(1)
                                HStack(spacing: 4) {
                                    Text(entry.dateFormatted)
                                    if entry.duration > 0 {
                                        Text("·")
                                        Text(entry.durationFormatted)
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if entry.status == "saved" {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                }
            }
        }
    }

    @ViewBuilder
    private func statusDot(_ entry: RecordingEntry) -> some View {
        switch entry.status {
        case "saved":
            Circle().fill(.green).frame(width: 7, height: 7)
        case "transcribed":
            Circle().fill(.blue).frame(width: 7, height: 7)
        case "transcribed_raw":
            Circle().fill(.yellow).frame(width: 7, height: 7)
        case "transcribing":
            // Stuck "transcribing" after a crash must not spin forever — only
            // the recording AppState is actually working on.
            if state.busyRecordingID == entry.id {
                ProgressView().controlSize(.mini).frame(width: 10, height: 10)
            } else {
                Circle().fill(.orange).frame(width: 7, height: 7)
            }
        case "recording":
            Circle().fill(.red).frame(width: 7, height: 7)
        default:
            Circle().fill(.quaternary).frame(width: 7, height: 7)
        }
    }

    // MARK: - Window Management

    static func showMainWindow() {
        AppWindowRegistry.showMain()
    }

}
