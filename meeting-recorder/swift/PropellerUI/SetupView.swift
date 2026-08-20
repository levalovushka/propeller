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
    var accessibilityGranted: Bool
    var notificationsGranted: Bool
    var launchAtLogin: Bool
    var onGrantMicrophone: () -> Void
    var onGrantAccessibility: () -> Void
    var onGrantNotifications: () -> Void
    var onSetLaunchAtLogin: (Bool) -> Void
    var onStart: () -> Void

    public init(
        microphoneGranted: Bool = false,
        accessibilityGranted: Bool = false,
        notificationsGranted: Bool = false,
        launchAtLogin: Bool = false,
        onGrantMicrophone: @escaping () -> Void = {},
        onGrantAccessibility: @escaping () -> Void = {},
        onGrantNotifications: @escaping () -> Void = {},
        onSetLaunchAtLogin: @escaping (Bool) -> Void = { _ in },
        onStart: @escaping () -> Void = {}
    ) {
        self.microphoneGranted = microphoneGranted
        self.accessibilityGranted = accessibilityGranted
        self.notificationsGranted = notificationsGranted
        self.launchAtLogin = launchAtLogin
        self.onGrantMicrophone = onGrantMicrophone
        self.onGrantAccessibility = onGrantAccessibility
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
            // Above the pushes by decision (2026-08-20): permissions grouped by
            // weight, and this one earns names in the feed. Optional — the app
            // works whole without it, and a wall is legal only where there is
            // no product behind it (`design/no-dead-ends.md`); whether it stays
            // optional is an open question the plan carries (§6).
            cell("Доступ к приложениям", "Чтобы узнавать спикеров") {
                grantControl(granted: accessibilityGranted, action: onGrantAccessibility)
            }
            // «Только важное» — owner's wording (2026-08-20). The old line
            // explained the mechanism; this one states the promise, and the
            // promise is held by `PushPolicy.Kind` being five reasons, none
            // of them noise.
            cell("Push-уведомления", "Только важное") {
                grantControl(granted: notificationsGranted, action: onGrantNotifications)
            }
            // No second line, and the title is the one the settings pane already
            // uses («Запускать Propeller при входе»). It had a subtitle twice —
            // «чтобы не забыть включить запись», then «Закрытый Propeller не
            // заметит звонок» — and both explained a consequence of a login item
            // to someone who has not met the app yet: two clauses to hold in
            // mind, under a row that is the only optional switch on the plate.
            // The other two rows earn their second line because a permission is
            // a request and a request owes a reason; this one is a preference,
            // and a preference is named, not argued.
            cell("Запускать Propeller при входе") {
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

    /// A row keeps its height whether or not it has a second line: the three
    /// rows are one list, and a shorter row would put the switch off the grid the
    /// two pills above it stand on.
    private func cell<Control: View>(
        _ title: String, _ subtitle: String? = nil, @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: Tokens.Space.s8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .typoBlock(Tokens.Setup.Typo.cell)
                    .foregroundStyle(Tokens.Setup.cellTitle)
                if let subtitle {
                    Text(subtitle)
                        .typoBlock(Tokens.Setup.Typo.cell)
                        .foregroundStyle(Tokens.Setup.cellSubtitle)
                        .lineLimit(1)
                }
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
    /// Настроечная плита и экран пустого архива держат марку разного кегля — на
    /// плите она открывает колонку, в окне стоит одна. Крутится в обоих случаях
    /// одинаково: скорость — свойство марки, а не места.
    var size: CGFloat = Tokens.Setup.markSize

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            PropellerMark(size: size)
                .rotationEffect(.degrees(angle(at: context.date)))
        }
        .foregroundStyle(Tokens.Setup.mark)
        .frame(width: size, height: size)
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
