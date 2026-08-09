import SwiftUI

/// The whole of setup, on one plate — Figma `setup` (50:1223).
///
/// # What went, and why
///
/// There used to be six screens: a four-slide carousel, the name, the calendar,
/// the permissions, a page about the summary model, and a page saying «готово».
/// Five of them asked for nothing macOS needs asked. The carousel described the
/// app to someone who had just installed it and would learn more from one call
/// than from four slides; the model page announced a download that happens on its
/// own; «готово» was a screen whose only function was to be dismissed.
///
/// What is left is the one thing a person really has to do before the first call
/// records: hand over the microphone, and decide about notifications and launch.
/// The name and the calendar are neither — the app works without both — so they
/// ask from the rail afterwards (`SidebarPromptBlock`), one small block at a time.
///
/// # No back button, no pager, no «Далее»
///
/// A single plate has nowhere to go back to. «Начать» is the only control that
/// leaves it, and it is never disabled: a person who declines the microphone
/// still gets an app — one that says «Нет доступа к микрофону» on the row that
/// records, which is where that sentence belongs. The old flow disabled «Далее»
/// until the microphone was granted, which turned a decision into a wall.
///
/// Pure presentation: it knows nothing of TCC, EventKit or `AppState`. Every row
/// reflects a state handed to it, and every press goes back out as a closure —
/// which is what lets the gallery pose «микрофон есть, уведомлений нет» without
/// a permission dialogue.
public struct SetupView: View {
    var microphoneGranted: Bool
    var notificationsGranted: Bool
    var launchAtLogin: Bool
    var onGrantMicrophone: () -> Void
    var onGrantNotifications: () -> Void
    var onSetLaunchAtLogin: (Bool) -> Void
    var onStart: () -> Void

    public init(
        microphoneGranted: Bool = false,
        notificationsGranted: Bool = false,
        launchAtLogin: Bool = false,
        onGrantMicrophone: @escaping () -> Void = {},
        onGrantNotifications: @escaping () -> Void = {},
        onSetLaunchAtLogin: @escaping (Bool) -> Void = { _ in },
        onStart: @escaping () -> Void = {}
    ) {
        self.microphoneGranted = microphoneGranted
        self.notificationsGranted = notificationsGranted
        self.launchAtLogin = launchAtLogin
        self.onGrantMicrophone = onGrantMicrophone
        self.onGrantNotifications = onGrantNotifications
        self.onSetLaunchAtLogin = onSetLaunchAtLogin
        self.onStart = onStart
    }

    /// Mirrors the switch, because AppKit's `Toggle` needs a binding and the
    /// truth lives outside. Seeded from the caller and pushed back out on change.
    @State private var launchOn = false

    public var body: some View {
        content
            .frame(width: Tokens.Setup.width, height: Tokens.Setup.height)
            // No titlebar row to protect: the column starts at the plate's own
            // top inset, and the safe area would push it down by a titlebar.
            .ignoresSafeArea(.container, edges: .top)
            .onAppear { launchOn = launchAtLogin }
            .onChange(of: launchAtLogin) { _, on in launchOn = on }
    }

    // MARK: Body (50:1255) — p 20, one column, the action pinned to the foot

    /// Mark, sentence, rows — three blocks 20 apart, and «Начать» at the foot.
    ///
    /// The mark opens the column rather than sitting in a titlebar. There is no
    /// titlebar: the plate is 400 × 410 of content and nothing else, so the mark
    /// is on the same left margin as the sentence it introduces and reads as part
    /// of it (Figma 91:934).
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Tokens.Setup.blockGap) {
                SetupMark()

                SetupText.title("Начался звонок и Propeller уже пишет. Все данные остаются на вашем Mac.")
                    .fixedSize(horizontal: false, vertical: true)

                cells
            }

            // The comps leave 22 pt here at a three-line sentence; a longer one
            // eats into it. The button never comes closer than the column's own
            // gap, which is what keeps it from touching the last row.
            Spacer(minLength: Tokens.Setup.blockGap)

            SetupActionButton(title: "Начать", action: onStart)
        }
        .padding(Tokens.Setup.inset)
    }

    private var cells: some View {
        VStack(spacing: 0) {
            cell("Доступ к микрофону", "Без него ничего не запишется") {
                grantControl(granted: microphoneGranted, action: onGrantMicrophone)
            }
            cell("Push-уведомления", "Скажем, если что-то сломается") {
                grantControl(granted: notificationsGranted, action: onGrantNotifications)
            }
            cell("Запуск при входе", "Чтобы не забыть включить запись") {
                Toggle("", isOn: $launchOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.regular)
                    .tint(Tokens.Paint.Status.accent)
                    .onChange(of: launchOn) { _, on in
                        guard on != launchAtLogin else { return }
                        onSetLaunchAtLogin(on)
                    }
                    .frame(width: Tokens.Setup.controlWidth, alignment: .trailing)
            }
        }
    }

    private func cell<Control: View>(
        _ title: String, _ subtitle: String, @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: Tokens.Space.s8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .typoBlock(Tokens.Setup.Typo.cell)
                    .foregroundStyle(Tokens.Setup.cellTitle)
                Text(subtitle)
                    .typoBlock(Tokens.Setup.Typo.cell)
                    .foregroundStyle(Tokens.Setup.cellSubtitle)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .frame(height: Tokens.Setup.cellHeight)
        .padding(.vertical, Tokens.Setup.cellVPadding)
    }

    /// A pill until the grant lands, then a tick. The column is a fixed width so
    /// the swap does not move the two lines beside it.
    @ViewBuilder
    private func grantControl(granted: Bool, action: @escaping () -> Void) -> some View {
        if granted {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Tokens.Setup.cellSubtitle)
                .frame(width: Tokens.Setup.controlWidth,
                       height: Tokens.Setup.controlHeight,
                       alignment: .trailing)
                .accessibilityLabel("Разрешено")
        } else {
            SetupGrantButton(action: action)
                .frame(width: Tokens.Setup.controlWidth, alignment: .trailing)
        }
    }
}

// MARK: - The mark

/// The Propeller mark opening the plate's column, turning counter-clockwise.
///
/// Same direction as the one in the rail's record row, and six times slower. It
/// is not a spinner and must not be read as one: nothing on this screen is
/// waiting, and the download that *is* running has deliberately been given no
/// indicator at all.
struct SetupMark: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            PropellerMark(size: Tokens.Setup.markSize)
                .rotationEffect(.degrees(angle(at: context.date)))
        }
        .foregroundStyle(Tokens.Setup.mark)
        .frame(width: Tokens.Setup.markSize, height: Tokens.Setup.markSize)
        .accessibilityHidden(true)
    }

    /// Off the clock, not off an accumulated frame count: a plate that lost a few
    /// frames to a permission dialogue should come back where it would have been,
    /// not where it stopped.
    private func angle(at date: Date) -> Double {
        let turns = date.timeIntervalSinceReferenceDate / Tokens.Setup.markTurn
        return -360 * turns.truncatingRemainder(dividingBy: 1)
    }
}

// MARK: - Controls

/// «Разрешить» — 32 pt, r 10, the surface wash.
private struct SetupGrantButton: View {
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("Разрешить")
                .typo(Tokens.Setup.Typo.grant)
                .foregroundStyle(Tokens.Setup.controlLabel)
                .padding(.horizontal, Tokens.Setup.controlHPadding + Tokens.Space.s2)
                .frame(height: Tokens.Setup.controlHeight)
                .background(
                    hovering ? Tokens.Setup.controlHoverFill : Tokens.Setup.controlFill,
                    in: RoundedRectangle(cornerRadius: Tokens.Setup.controlRadius, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: Tokens.Setup.controlRadius, style: .continuous))
        }
        .buttonStyle(.press)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
    }
}

/// «Начать» — the full width of the plate's content, 36 pt.
///
/// Not a primary (inverted) fill: it is the only button on the screen, so it has
/// nothing to out-rank, and a white slab at the foot of a glass plate reads as a
/// system alert's default button.
private struct SetupActionButton: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .typo(Tokens.Setup.Typo.action)
                .foregroundStyle(Tokens.Setup.controlLabel)
                .frame(maxWidth: .infinity)
                .frame(height: Tokens.Setup.actionHeight)
                .background(
                    hovering ? Tokens.Setup.controlHoverFill : Tokens.Setup.controlFill,
                    in: RoundedRectangle(cornerRadius: Tokens.Setup.actionRadius, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: Tokens.Setup.actionRadius, style: .continuous))
        }
        .buttonStyle(.press)
        .keyboardShortcut(.defaultAction)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
    }
}

#Preview("Setup") {
    SetupView()
        .background(GlassBackground(cornerRadius: Tokens.Setup.radius))
}
