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
/// # The microphone is required, and «Дальше» says so by not working
///
/// Decision 2026-08-07, and a reversal: «Начать» used to leave the plate whatever
/// the microphone said, on the grounds that a wall is worse than a degraded app.
/// It is now blocked until the grant lands, because the degraded app is not
/// really an app — it records nothing, and every screen in it is about a
/// recording. There is deliberately **no** «продолжить без микрофона»: an escape
/// that leaves you with a Propeller that cannot propel is a choice nobody would
/// knowingly make.
///
/// The wall has one door and it is always open: refusing the system prompt turns
/// the row's pill into a route to System Settings, the grant is polled once a
/// second, and «Дальше» lights up the moment it lands. That door is the whole
/// reason this does not violate `design/no-dead-ends.md` — but it leads *out of
/// the app*, which is a stronger claim on a person than anything else here makes,
/// and it is the one place where the app refuses to go on without them.
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

    // MARK: Body — one centred column, the action and its consequence at the foot

    /// Mark, sentence, rows, button, and the line about the model.
    ///
    /// The column is centred and the rows are not, and that is not an oversight:
    /// a permission row is a sentence on the left with its answer on the right,
    /// and centring *that* would put the pills in the middle of the plate with
    /// nothing to align to. So the head of the plate is centred and the list
    /// under it keeps its two edges — which is why the silence around the list
    /// (`listGap`) is bigger than the gaps inside it.
    private var content: some View {
        VStack(spacing: 0) {
            SetupMark()
            Spacer().frame(height: Tokens.Setup.markGap)

            SetupText.title(
                "Чтобы записать звонок, нужен микрофон. Остальное — по\u{00A0}желанию.",
                alignment: .center
            )
            .fixedSize(horizontal: false, vertical: true)

            // Fixed, not `Spacer(minLength:)`. A flexible gap here divides
            // whatever the plate has left over between the two silences, so the
            // 28 the comps draw came out at 38 and drifted again the moment the
            // headline changed its line count. The column is now exactly as tall
            // as its contents and the plate centres it.
            Spacer().frame(height: Tokens.Setup.listGap)
            cells
            Spacer().frame(height: Tokens.Setup.listGap)

            SetupActionButton(title: "Дальше", action: onStart, enabled: microphoneGranted)

            Spacer().frame(height: Tokens.Setup.captionGap)
            // Said once, here, and nowhere else: the first-run screen behind this
            // one deliberately does not mention it. Not a question and not a
            // progress bar — the model is part of the install
            // (`PropellerPure/ModelProvisioning`), and the only thing wrong with
            // it was that 3,4 ГБ of someone's disk left without a word.
            Text("После старта скачаем модель\nдля саммари — 3,4\u{00A0}ГБ")
                .typoBlock(Tokens.Setup.Typo.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(Tokens.Setup.caption)
        }
        .padding(.horizontal, Tokens.Setup.insetH)
        .padding(.vertical, Tokens.Setup.insetV)
    }

    private var cells: some View {
        VStack(spacing: 0) {
            cell("Доступ к микрофону", "Без него запись не начнётся") {
                grantControl(granted: microphoneGranted, action: onGrantMicrophone)
            }
            // Not «скажем, если что-то сломается», which was the old line and was
            // simply untrue: none of the five reasons the app notifies about is a
            // breakage (`PushPolicy.Kind`). The one that matters is this — without
            // the grant there is nowhere to press «Не записывать», so an
            // auto-started recording pulls the window over whatever you are doing
            // instead (`PushPolicy.surface`).
            cell("Push-уведомления", "Отказаться, если запись началась") {
                grantControl(granted: notificationsGranted, action: onGrantNotifications)
            }
            // Also rewritten: «чтобы не забыть включить запись» described the
            // manual path, and auto-record is the default.
            cell("Запуск при входе", "Закрытый Propeller не заметит звонок") {
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

/// «Дальше» — the full width of the plate's content, 36 pt.
///
/// Not a primary (inverted) fill: it is the only button on the screen, so it has
/// nothing to out-rank, and a white slab at the foot of a glass plate reads as a
/// system alert's default button.
///
/// Disabled until the microphone is granted, and disabled *visibly* — the label
/// dims and the hover stops answering, because a button that looks live and does
/// nothing is worse than one that admits it is waiting. What it is waiting for is
/// the row directly above it, which is the whole reason the wall is legible: the
/// only enabled control on the plate is the one that unblocks it.
private struct SetupActionButton: View {
    let title: String
    let action: () -> Void
    var enabled: Bool = true

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .typo(Tokens.Setup.Typo.action)
                .foregroundStyle(enabled ? Tokens.Setup.controlLabel : Tokens.Setup.caption)
                .frame(maxWidth: .infinity)
                .frame(height: Tokens.Setup.actionHeight)
                .background(
                    (hovering && enabled) ? Tokens.Setup.controlHoverFill : Tokens.Setup.controlFill,
                    in: RoundedRectangle(cornerRadius: Tokens.Setup.actionRadius, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: Tokens.Setup.actionRadius, style: .continuous))
        }
        .buttonStyle(.press)
        .disabled(!enabled)
        // Enter must not walk past the microphone either — `.defaultAction` on a
        // disabled button is inert, which is exactly what is wanted here.
        .keyboardShortcut(.defaultAction)
        .onHover { hovering = $0 && enabled }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
        .animation(.easeOut(duration: Tokens.Motion.hover), value: enabled)
    }
}

#Preview("Setup") {
    SetupView()
        .background(GlassBackground(cornerRadius: Tokens.Setup.radius))
}
