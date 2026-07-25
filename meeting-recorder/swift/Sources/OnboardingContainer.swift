import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics
import ServiceManagement
import ApplicationServices
import PropellerUI

/// Hosts `OnboardingFlowView` and wires steps to the app: name → Preferences,
/// calendar → EventKit, grants → TCC prompts, launch-at-login → SMAppService.
struct OnboardingContainer: View {
    @ObservedObject var state: AppState

    @State private var microphoneGranted = false
    @State private var systemAudioGranted = false
    @State private var notesGranted = false
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        OnboardingFlowView(
            onComplete: { name in
                Preferences.shared.userName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                Preferences.shared.onboardingCompleted = true
                // System audio capture is required for remote speakers — lock it on
                // once Screen Recording was granted in onboarding.
                Preferences.shared.captureSystemAudio = true
                state.showOnboarding = false
            },
            microphoneGranted: microphoneGranted,
            systemAudioGranted: systemAudioGranted,
            notesGranted: notesGranted,
            onConnectCalendar: {
                Preferences.shared.calendarEnabled = true
                Task { await CalendarService.shared.enableAndLoad() }
            },
            onGrantMicrophone: {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            },
            onGrantSystemAudio: {
                // First call shows the system prompt; if previously denied, open Settings.
                if CGPreflightScreenCaptureAccess() {
                    return
                }
                let prompted = CGRequestScreenCaptureAccess()
                if !prompted {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            },
            onGrantNotes: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            },
            onSetLaunchAtLogin: { on in
                do {
                    if on { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                } catch { NSLog("[Onboarding] launch-at-login failed: \(error)") }
            }
        )
        .onAppear(perform: refreshGrants)
        .onReceive(poll) { _ in refreshGrants() }
    }

    private func refreshGrants() {
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        systemAudioGranted = CGPreflightScreenCaptureAccess()
        notesGranted = AXIsProcessTrusted()
    }
}
