import AVFoundation
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var step: OnboardingStep = .welcome
    @State private var userName = ""

    enum OnboardingStep: Int, CaseIterable {
        case welcome, microphone, ready
    }

    var body: some View {
        VStack(spacing: 0) {
            // Progress dots
            HStack(spacing: 8) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { s in
                    Circle()
                        .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 20)

            Spacer()

            Group {
                switch step {
                case .welcome:
                    welcomeStep
                case .microphone:
                    microphoneStep
                case .ready:
                    readyStep
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))

            Spacer()
        }
        .frame(width: 540, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(.tint)

            Text("Welcome to Propeller")
                .font(.title)
                .fontWeight(.semibold)

            Text("Record meetings locally, transcribe with on-device AI, and automatically identify who said what.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            VStack(spacing: 12) {
                featureRow(icon: "lock.shield", text: "Fully private — everything stays on your Mac")
                featureRow(icon: "person.wave.2", text: "Labels your voice automatically in transcripts")
                featureRow(icon: "video.fill", text: "Detects Zoom calls and records them automatically")
                featureRow(icon: "doc.text", text: "Saves readable transcripts (Obsidian optional)")
            }
            .padding(.top, 8)

            VStack(spacing: 8) {
                Text("What's your name?")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("Your name", text: $userName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .onSubmit { advanceFromWelcome() }
            }
            .padding(.top, 8)

            Button("Get Started") { advanceFromWelcome() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(userName.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.top, 4)
        }
        .padding(32)
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.tint)
            Text(text)
                .font(.callout)
            Spacer()
        }
        .frame(maxWidth: 400)
    }

    private func advanceFromWelcome() {
        let name = userName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Preferences.shared.userName = name
        withAnimation { step = .microphone }
    }

    // MARK: - Microphone Permission

    @State private var micGranted = false
    @State private var micDenied = false

    private var microphoneStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(.tint)

            Text("Microphone Access")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Propeller needs your microphone to capture audio. This is the only required permission.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            if micGranted {
                Label("Microphone access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)

                Button("Continue") { withAnimation { step = .ready } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 8)
            } else if micDenied {
                Label("Microphone access denied", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)

                Text("Enable it in System Settings > Privacy & Security > Microphone, then relaunch the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                HStack(spacing: 12) {
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Skip") { withAnimation { step = .ready } }
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            } else {
                Button("Allow Microphone") { requestMicPermission() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                Button("Skip for now") { withAnimation { step = .ready } }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .onAppear { checkMicStatus() }
    }

    private func checkMicStatus() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micGranted = true
        case .denied, .restricted:
            micDenied = true
        default:
            break
        }
    }

    private func requestMicPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                micGranted = granted
                micDenied = !granted
                if granted {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    withAnimation { step = .ready }
                }
            }
        }
    }

    // MARK: - Ready

    private var readyStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(.green)

            Text("You're all set!")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Here are a few things to know:")
                .font(.body)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                tipRow(icon: "record.circle.fill", color: .red,
                       title: "Record",
                       detail: "Click the red button in the app or from the menu bar")
                tipRow(icon: "text.bubble", color: .blue,
                       title: "Transcribe",
                       detail: "Recordings are transcribed automatically when you stop")
                tipRow(icon: "person.wave.2", color: .purple,
                       title: "Speakers",
                       detail: "Your segments are labeled with your name automatically; others show as \"Speaker N\" — rename them from the transcript.")
                tipRow(icon: "video.fill", color: .cyan,
                       title: "Zoom",
                       detail: "Zoom calls are recorded automatically — a notification lets you decline, and recording stops when the meeting ends. Turn this off in Settings.")
                tipRow(icon: "menubar.rectangle", color: .secondary,
                       title: "Menu bar",
                       detail: "The app lives in your menu bar — close the window and it keeps running")
            }
            .frame(maxWidth: 420)
            .padding(.top, 4)

            Button("Start Recording") {
                finishOnboarding()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 8)
        }
        .padding(32)
    }

    private func tipRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 24)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func finishOnboarding() {
        Preferences.shared.onboardingCompleted = true
        state.showOnboarding = false
        dismiss()
    }
}
