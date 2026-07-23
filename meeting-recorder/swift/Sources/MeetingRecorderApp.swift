import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Warm the ASR sidecar in the background so first Transcribe is faster.
        Task.detached(priority: .utility) {
            do {
                try await GigasttSidecar.shared.ensureReady()
            } catch {
                NSLog("[AppDelegate] gigastt sidecar warm-up failed: \(error)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        GigasttSidecar.shared.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // Re-open the main window when the user clicks the dock icon.
            for window in NSApp.windows where window.frame.width > 400 {
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }
}

@main
struct MeetingRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        // WindowGroup is the primary scene — auto-opens on launch.
        WindowGroup("Propeller") {
            MainView(state: state, recordingStore: state.recordingStore)
        }
        .defaultSize(width: 900, height: 680)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        Settings {
            SettingsView()
                .environmentObject(state)
        }

        MenuBarExtra {
            MenuBarPanelView(state: state)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        if state.isRecording {
            HStack(spacing: 4) {
                Image(systemName: "record.circle.fill")
                    .foregroundColor(.red)
                Text(state.elapsedString)
                    .monospacedDigit()
            }
        } else if state.transcribeStep == .running || state.saveStep == .running {
            HStack(spacing: 4) {
                Image(systemName: "mic.fill")
                Text("...")
            }
        } else {
            Image(systemName: "mic.fill")
        }
    }
}
