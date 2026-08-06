import SwiftUI
import PropellerUI

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
                    Label("Открыть Propeller", systemImage: "macwindow")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

                Button {
                    SettingsOpener.open()
                } label: {
                    Label("Настройки", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .padding(.vertical, 4)

            Divider()

            Button("Выйти из Propeller") {
                if state.isRecording {
                    Task {
                        // Quit path: keep the WAV, don't start gigastt mid-terminate.
                        // The recording lands at `.recorded`, so the next launch's
                        // first `kickPipeline` owes it a transcript and picks it up.
                        await state.stopRecordingAndWait(runPipeline: false)
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
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.red)
                        .symbolRenderingMode(.hierarchical)
                    // Пауза ставится в окне записи, а меню-бар обязан говорить
                    // то же самое: «Запись» над остановившимся таймером — то же
                    // враньё, что и в строке рельса.
                    Text(state.isRecordingPaused ? "Пауза" : "Запись")
                        .typo(Tokens.Typography.Label.mdMedium)
                    Spacer()
                    Text(state.elapsedString)
                        .typo(Tokens.Typography.Label.mdMedium, monospacedDigit: true)
                        .monospacedDigit()
                        .foregroundStyle(.red)
                }

                HStack(spacing: 8) {
                    Button {
                        state.stopRecording()
                    } label: {
                        Label("Стоп", systemImage: "stop.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.regular)

                    Button {
                        showingDiscardConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .regular))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .help("Стоп и сбросить эту запись")
                }
                .confirmationDialog(
                    "Сбросить эту запись?",
                    isPresented: $showingDiscardConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Стоп и сбросить", role: .destructive) {
                        state.cancelRecording()
                    }
                    Button("Отмена", role: .cancel) {}
                } message: {
                    Text("Запись будет удалена сразу. Расшифровка и саммари не создаются.")
                }
            }
        } else if state.meetingDetected && !state.isRecording {
            HStack(spacing: 6) {
                Image(systemName: "video.fill")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Идёт звонок").typo(Tokens.Typography.Label.mdMedium)
                    Text("Запись не начата").typo(Tokens.Typography.Label.smRegular).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    state.acceptDetectedCallPrompt()
                } label: {
                    Label("Записать", systemImage: "record.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
            }
        } else if let progress = state.activity.message {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Обработка…").typo(Tokens.Typography.Label.mdMedium)
                    Text(progress)
                        .typo(Tokens.Typography.Label.smRegular)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Propeller").typo(Tokens.Typography.Label.mdMedium)
                    Text("Готов к записи").typo(Tokens.Typography.Label.smRegular).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    state.startRecording()
                } label: {
                    Label("Записать", systemImage: "record.circle.fill")
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
            Text("Недавние")
                .typo(Tokens.Typography.Label.xsMedium)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .padding(.horizontal, 12)
                .padding(.bottom, 2)

            if state.recordingStore.recordings.isEmpty {
                Text("Пока нет записей")
                    .typo(Tokens.Typography.Label.smRegular)
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
                                    .typo(Tokens.Typography.Label.mdRegular)
                                    .lineLimit(1)
                                HStack(spacing: 4) {
                                    Text(entry.dateFormatted)
                                    if entry.duration > 0 {
                                        Text("·")
                                        Text(entry.durationFormatted)
                                    }
                                }
                                .typo(Tokens.Typography.Label.xsRegular)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if entry.status >= .saved {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12, weight: .regular))
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
        case .saved, .summarized:
            Circle().fill(.green).frame(width: 7, height: 7)
        case .transcribed:
            Circle().fill(.blue).frame(width: 7, height: 7)
        case .transcribedRaw:
            Circle().fill(.yellow).frame(width: 7, height: 7)
        case .transcribing:
            // Stuck "transcribing" after a crash must not spin forever — only
            // the recording the pipeline is actually working on.
            if state.activity.concerns(entry.id) {
                ProgressView().controlSize(.mini).frame(width: 10, height: 10)
            } else {
                Circle().fill(.orange).frame(width: 7, height: 7)
            }
        case .recording:
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
