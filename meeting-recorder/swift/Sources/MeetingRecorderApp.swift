import SwiftUI
import AppKit

/// Weak hook so AppDelegate can flush recording on ⌘Q / logout (plan-optimization C3).
enum AppStateRegistry {
    @MainActor static weak var shared: AppState?
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var isTerminatingAfterFlush = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ASR sidecar is started lazily on first transcription (plan-optimization E1).

        // `--tap-probe`: какой состав агрегата система принимает и какой канал
        // чей. Раскладка каналов ничем не задокументирована, а промах по ней
        // молчаливый, поэтому она измеряется, а не выводится из рассуждений.
        // Живёт в релизном бинарнике, а не отдельной утилитой: разрешение на
        // захват звука выдано **этому** бандлу.
        if TapProbe.isRequested {
            Task { @MainActor in
                await TapProbe.run()
                exit(0)
            }
            return
        }

        // Прогрев захвата на общих часах. Самое первое открытие входа Core
        // Audio ждёт решения TCC — замерено, шестьдесят секунд, — и заплатить
        // его на старте записи означает записать встречу без первой минуты.
        // Платим сейчас, в фоне, когда никто ничего не ждёт.
        if Preferences.shared.captureSystemAudio {
            Task.detached(priority: .utility) {
                await ProcessTapCapture.warmUpIfNeeded()
            }
        }
#if GALLERY
        // `--gallery-export <dir>`: render every state to PNG and quit. Runs
        // after launch so SwiftUI is up, and exits without touching the archive.
        if let dir = GalleryExport.requestedDirectory {
            Task { @MainActor in
                // The registry is populated when the main window appears, which
                // happens after launch — wait for it rather than racing it.
                var state: AppState?
                for _ in 0..<50 {
                    if let s = AppStateRegistry.shared { state = s; break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                guard let state else {
                    NSLog("[GalleryExport] AppState never appeared — export aborted")
                    NSApp.terminate(nil)
                    return
                }
                _ = await GalleryExport.exportAll(state: state, to: dir)
                // exit(), not NSApp.terminate: the terminate path runs the
                // pipeline-flush delegate, which hangs an export-only launch.
                exit(0)
            }
        }
#endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminatingAfterFlush { return .terminateNow }
        Task { @MainActor in
            if let state = AppStateRegistry.shared, state.isRecording {
                await state.stopRecordingAndWait(runPipeline: false)
            }
            AppStateRegistry.shared?.recordingStore.flush()
            GigasttSidecar.shared.stop()
            OllamaSidecar.shared.stop()
            Analytics.flush()
            OnboardingPanelController.shared.close()
            self.isTerminatingAfterFlush = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Finish any «Удалить» whose undo was still on offer: the entry is
        // already out of the index, so leaving it would strand the audio with
        // nothing pointing at it.
        AppStateRegistry.shared?.commitPendingDeletion()
        Analytics.flush()
        GigasttSidecar.shared.stop()
        OllamaSidecar.shared.stop()
        OnboardingPanelController.shared.close()
        AppStateRegistry.shared?.recordingStore.flush()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppWindowRegistry.showMain(centered: true)
        }
        return true
    }
}

@main
struct MeetingRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    init() {
#if GALLERY
        // Before `AppState`: the store reads its index during init, and a store
        // pointed at the real archive stays pointed at it for the whole run.
        GalleryFixture.installIfRequested()
#endif
        Analytics.bootstrap()
    }

    var body: some Scene {
        // Main app only. Onboarding is a separate NSPanel (see
        // OnboardingPanelController) so we never resize one window into another.
        WindowGroup("Propeller", id: AppWindowRole.main.rawValue) {
            RootWindow(state: state)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("Проверить обновления…") {
                    SparkleUpdater.shared.checkForUpdates()
                }
                .disabled(!SparkleUpdater.shared.canCheckForUpdates)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(state)
        }

#if GALLERY
        // Screenshot/redesign tool. Absent from shipping builds — see StateGallery.
        // A `Window` scene with a title gets its own entry under the Window menu,
        // so it needs no command of its own.
        Window("Галерея состояний", id: "state-gallery") {
            StateGallery(state: state)
        }
        .windowResizability(.contentSize)
#endif

        MenuBarExtra {
            MenuBarContentView(state: state)
        } label: {
            Image(nsImage: Self.menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }

    /// Template PDF — HIG menu-bar extra is 18×18 pt (vector scales; no re-export).
    private static let menuBarIcon: NSImage = {
        let image = NSImage(named: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Propeller")
            ?? NSImage()
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}

/// Always hosts the main app UI. Onboarding is shown via `OnboardingPanelController`.
private struct RootWindow: View {
    @ObservedObject var state: AppState

    var body: some View {
        MainView(state: state, recordingStore: state.recordingStore)
            // Height only. The width minimum is whatever the content needs —
            // rail plus pane when the rail is out, pane alone when it is away —
            // and stating it here would keep reserving the rail's 300 after the
            // user has put it away.
            .frame(minHeight: AppWindowRegistry.minSize.height)
            // Same GlassBackground / Tokens.Glass stack as the onboarding panel.
            .background(VisualEffectBackground().ignoresSafeArea())
            .background(SceneWindowChrome(role: .main, startHidden: state.showOnboarding))
            .onAppear {
                AppStateRegistry.shared = state
                state.bootstrap()
                syncPresentation()
            }
            .onChange(of: state.showOnboarding) { _, _ in
                syncPresentation()
            }
    }

    private func syncPresentation() {
        if state.showOnboarding {
            // Hide main *before* the panel appears so Meetings never flashes.
            AppWindowRegistry.hideMain()
            OnboardingPanelController.shared.show(state: state)
        } else {
            OnboardingPanelController.shared.close()
            AppWindowRegistry.showMain(centered: true)
        }
    }
}
