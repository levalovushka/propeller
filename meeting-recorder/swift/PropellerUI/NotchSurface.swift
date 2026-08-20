import SwiftUI
import PropellerPure

/// Чёлка как поверхность записи: чёрная плита, вырастающая из выреза, со знаком
/// слева и заметкой справа.
///
/// Ничем не управляет и ничего не сообщает — показывает состояние и принимает
/// одно действие. Паузы и стопа здесь нет намеренно: полоса, через которую
/// ходит курсор к меню-бару, — худшее место для необратимого действия, а
/// четвёртая мишень у выреза перестаёт быть мишенью.

/// Силуэт. Вогнутая галтель сверху, где плита встречает кромку экрана;
/// выпуклые углы снизу, как у самого выреза.
///
/// Форма покрывает вырез целиком и той же чернотой — поэтому железо и рисунок
/// читаются одной фигурой. Ради этого здесь нет ни тени, ни обводки, ни
/// материала: всё, что даёт край, выдаёт накладку.
public struct NotchShape: Shape {
    public var topRadius: CGFloat
    public var bottomRadius: CGFloat

    public init(
        topRadius: CGFloat = NotchGeometry.topCornerRadius,
        bottomRadius: CGFloat = NotchGeometry.bottomCornerRadius
    ) {
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
    }

    public func path(in rect: CGRect) -> Path {
        var p = Path()
        let top = rect.minY, bottom = rect.maxY
        let left = rect.minX, right = rect.maxX
        let tr = min(topRadius, rect.width / 2)
        let br = min(bottomRadius, (rect.width - 2 * tr) / 2, rect.height / 2)

        p.move(to: CGPoint(x: left, y: top))
        p.addQuadCurve(to: CGPoint(x: left + tr, y: top + tr),
                       control: CGPoint(x: left + tr, y: top))
        p.addLine(to: CGPoint(x: left + tr, y: bottom - br))
        p.addQuadCurve(to: CGPoint(x: left + tr + br, y: bottom),
                       control: CGPoint(x: left + tr, y: bottom))
        p.addLine(to: CGPoint(x: right - tr - br, y: bottom))
        p.addQuadCurve(to: CGPoint(x: right - tr, y: bottom - br),
                       control: CGPoint(x: right - tr, y: bottom))
        p.addLine(to: CGPoint(x: right - tr, y: top + tr))
        p.addQuadCurve(to: CGPoint(x: right, y: top),
                       control: CGPoint(x: right - tr, y: top))
        p.closeSubpath()
        return p
    }
}

/// Лопасть, которую крутит записываемый звук.
///
/// Уровень приходит замыканием, а не значением: он меняется десятки раз в
/// секунду, и пробрасывать это через `@Published` значило бы перерисовывать
/// поверх всех окон ради числа, которое читает один шаг привода.
///
/// **Крутит лопасть слой, а не главный поток.** Так было не сразу: первая
/// версия считала угол покадрово в `TimelineView` и на громком разговоре
/// заметно дёргалась. Причина не в приводе — во время громкого разговора
/// главный поток занят живой расшифровкой, кадры приходят рвано, и хотя угол
/// считался по времени, а не по числу кадров, каждый пропущенный кадр давал
/// скачок картинки. Теперь поворот живёт в `CABasicAnimation`, то есть в
/// рендер-сервере: главный поток может встать на треть секунды, лопасть этого
/// не заметит. Он же трогает путь один раз, а не пересобирает шесть лепестков
/// на каждый кадр.
public struct NotchBlade: NSViewRepresentable {
    private let size: CGFloat
    private let level: () -> Float
    private let paused: Bool
    private let opacity: Double
    /// Сообщает, что тик привода опоздал: главный поток был занят настолько,
    /// что это стоило бы видеть в логе. Замер, а не догадка.
    private let onStall: ((Double) -> Void)?

    public init(
        size: CGFloat,
        paused: Bool,
        opacity: Double,
        onStall: ((Double) -> Void)? = nil,
        level: @escaping () -> Float
    ) {
        self.size = size
        self.paused = paused
        self.opacity = opacity
        self.onStall = onStall
        self.level = level
    }

    public func makeNSView(context: Context) -> BladeView {
        BladeView(size: size, level: level, onStall: onStall)
    }

    public func updateNSView(_ view: BladeView, context: Context) {
        view.level = level
        view.onStall = onStall
        view.apply(size: size, paused: paused, opacity: opacity)
    }
}

/// Слой с лопастью и привод к нему.
public final class BladeView: NSView {
    private let shape = CAShapeLayer()
    private var size: CGFloat
    private var paused = false
    private var envelope: Float = 0
    private var speed = BladeDrive.idleSpeed
    /// Скорость, под которую собрана текущая анимация. Пересобирать её на
    /// каждый тик незачем: между пересборками слой крутится сам.
    private var appliedSpeed = Double.nan
    private var tick: Timer?
    private var lastTick: Date?

    var level: () -> Float
    var onStall: ((Double) -> Void)?

    /// Как часто пересчитывается привод. Не кадры: 25 Гц хватает огибающей с
    /// постоянными в десятые доли секунды, а сам поворот от этого не зависит.
    private static let tickInterval: TimeInterval = 0.04

    /// Насколько скорость должна отойти от заложенной в анимацию, чтобы её
    /// стоило пересобрать. 1,5 % диапазона — граница видимого.
    private static var speedEpsilon: Double {
        abs(BladeDrive.topSpeed - BladeDrive.idleSpeed) * 0.015
    }

    /// Один оборот — столько по времени, что переставлять анимацию приходится
    /// только когда меняется скорость, а не когда кончается цикл.
    private static let spinSpan: Double = 600

    init(size: CGFloat, level: @escaping () -> Float, onStall: ((Double) -> Void)?) {
        self.size = size
        self.level = level
        self.onStall = onStall
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layer?.addSublayer(shape)
        shape.fillRule = .nonZero
        shape.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layoutShape()
        startTicking()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        tick?.invalidate()
    }

    func apply(size: CGFloat, paused: Bool, opacity: Double) {
        self.paused = paused
        shape.opacity = Float(opacity)
        guard size != self.size else { return }
        self.size = size
        needsLayout = true
        layoutShape()
    }

    public override func layout() {
        super.layout()
        layoutShape()
    }

    private func layoutShape() {
        // Размер знака задан снаружи и к размеру вьюхи отношения не имеет: она
        // шириной с ухо, а знак в ней — маленький и по центру.
        //
        // Через `bounds` + `position`, а не через `frame`: слой вращается вокруг
        // своей `anchorPoint`, и она обязана остаться серединой знака. Frame,
        // выставленный до того, как вьюха получила настоящий размер, однажды уже
        // уронил знак в левый нижний угол уха.
        let box = CGRect(x: 0, y: 0, width: size, height: size)
        shape.bounds = box
        shape.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        shape.position = CGPoint(x: bounds.midX, y: bounds.midY)
        shape.path = PropellerMark.cgPath(in: box)
        shape.fillColor = NSColor.white.cgColor
    }

    private func startTicking() {
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        timer.tolerance = Self.tickInterval * 0.5
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    private func step() {
        let now = Date()
        defer { lastTick = now }
        guard let last = lastTick else { return }
        let dt = now.timeIntervalSince(last)
        // Тик опоздал вдвое — значит главный поток стоял, и это ровно тот
        // случай, ради которого поворот отдан слою.
        if dt > Self.tickInterval * 2 { onStall?(dt) }

        envelope = BladeDrive.envelope(envelope, level: level(), dt: dt)
        speed = BladeDrive.advance(speed: speed, level: envelope, paused: paused, dt: dt)
        if appliedSpeed.isNaN || abs(speed - appliedSpeed) > Self.speedEpsilon || speed == 0 {
            applySpeed(speed)
        }
    }

    /// Переложить вращение под новую скорость, не сбив текущий угол.
    private func applySpeed(_ degreesPerSecond: Double) {
        let current = (shape.presentation() ?? shape)
            .value(forKeyPath: "transform.rotation.z") as? Double ?? 0
        shape.removeAnimation(forKey: "spin")
        shape.setValue(current, forKeyPath: "transform.rotation.z")
        appliedSpeed = degreesPerSecond
        // Ноль — это пауза, и она обязана быть полной неподвижностью.
        guard abs(degreesPerSecond) > 0.01 else { return }

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = current
        spin.toValue = current + degreesPerSecond * .pi / 180 * Self.spinSpan
        spin.duration = Self.spinSpan
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        spin.isRemovedOnCompletion = false
        spin.fillMode = .forwards
        shape.add(spin, forKey: "spin")
    }
}

/// Что нарисовано на плите.
///
/// Плита меняет размер сама, внутри SwiftUI, а окно под ней стоит неподвижно и
/// всегда максимального габарита. Первая версия анимировала `NSWindow.setFrame`
/// — и раскрытие дёргалось, а сворачивание выглядело как отлипание от кромки:
/// окно и его содержимое ехали по разным кривым. Единственный способ, которым
/// плита может смыкаться с железом всё время движения, — быть одной анимируемой
/// фигурой, а не окном, внутри которого что-то ещё перекладывается.
public struct NotchFace: View {
    private let screen: NotchGeometry.Screen
    private let stage: NotchGeometry.Stage
    private let paused: Bool
    private let level: () -> Float
    private let onStall: ((Double) -> Void)?
    private let onNote: () -> Void
    private let onCommit: (String) -> Void
    private let onCancel: () -> Void

    /// `noteDraft` — только для съёмки состояния с набранным текстом; в
    /// приложении поле всегда открывается пустым.
    public init(
        screen: NotchGeometry.Screen,
        stage: NotchGeometry.Stage,
        paused: Bool,
        noteDraft: String = "",
        level: @escaping () -> Float,
        onStall: ((Double) -> Void)? = nil,
        onNote: @escaping () -> Void,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.screen = screen
        self.stage = stage
        self.paused = paused
        self.level = level
        self.onStall = onStall
        self.onNote = onNote
        self.onCommit = onCommit
        self.onCancel = onCancel
        _draft = State(initialValue: noteDraft)
    }

    /// Набираемая заметка. Живёт здесь, а не в поле, потому что отправить её
    /// умеют двое: Enter и знак ⏎ в ухе.
    @State private var draft: String

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { onCancel() } else { onCommit(text) }
    }

    /// Стадия, по которой плита нарисована сейчас.
    ///
    /// Отдельная от входящей намеренно. Стадию меняет контроллер — снаружи
    /// SwiftUI, заменой всего дерева, — и такое изменение анимируется через раз:
    /// у отправки заметки рядом менялось состояние поля и вытягивало ход за
    /// собой, а у отмены менять было нечего, и плита схлопывалась рывком.
    /// Здесь любой приход стадии становится обычной транзакцией с явной
    /// пружиной, поэтому Enter, ⏎, Esc, повторный ⌃⌥N и конец записи идут по
    /// одной кривой.
    @State private var shownStage: NotchGeometry.Stage = .sealed

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Раскрытие и сворачивание поля — пружина без перелёта: чёлка не пружинит,
    /// она раздаётся.
    private static let move = Animation.spring(response: 0.34, dampingFraction: 0.92)
    /// Рост при старте длиннее: это единственное движение, которое человек
    /// увидит краем глаза, уже сидя в звонке.
    private static let arrive = Animation.spring(response: 0.58, dampingFraction: 0.94)
    /// Уход в железо на стопе — ещё спокойнее и без единого колебания: последнее,
    /// что делает запись, не должно выглядеть как захлопнувшаяся дверь.
    private static let leave = Animation.spring(response: 0.46, dampingFraction: 1.0)
    /// Значки идут за плитой, а не вместе с ней: сначала место, потом то, что в
    /// нём стоит. Задержка меньше половины хода — иначе читается как рассинхрон.
    private static let glyphs = Animation.spring(response: 0.4, dampingFraction: 0.9)
        .delay(Tokens.Motion.Step.t120)

    private var shown: NotchGeometry.Stage { shownStage }
    private var frame: NotchGeometry.Frame { NotchGeometry.frame(on: screen, stage: shown) }
    /// Габарит окна — всегда максимальный; плита живёт внутри него.
    private var bounds: NotchGeometry.Frame { NotchGeometry.frame(on: screen, stage: .composing) }

    /// Знак и значок в ухе: 16 pt при высоте выреза 32, меньше — на экранах,
    /// где вырез ниже (масштабированное разрешение, Air).
    private var glyphSize: CGFloat { max(11, min(16, frame.notchHeight - 14)) }
    private var composing: Bool { shown == .composing }
    private var revealed: Bool { shown != .sealed }

    /// Каким ходом плита идёт к стадии, в которую её позвали. По нему же идут
    /// значки и поле, чтобы всё движение читалось одним жестом, а не тремя.
    ///
    /// С «уменьшить движение» — та же хореография, но без пружин: плита всё
    /// равно должна доехать (иначе поле появляется в воздухе над кромкой), а вот
    /// доводка на пружине — как раз то, от чего эту настройку включают.
    private func motion(from: NotchGeometry.Stage, to: NotchGeometry.Stage) -> Animation {
        if reduceMotion { return .easeOut(duration: Tokens.Motion.Step.t180) }
        if from == .sealed { return Self.arrive }
        if to == .sealed { return Self.leave }
        return Self.move
    }

    /// Значки приходят с задержкой и уходят без неё — и то и другое остаётся при
    /// «уменьшить движение», потому что это очерёдность, а не движение.
    private var glyphMotion: Animation {
        if reduceMotion {
            let step = Tokens.Motion.Step.t180
            return revealed
                ? .easeOut(duration: step).delay(Tokens.Motion.Step.t120)
                : .easeOut(duration: step)
        }
        return revealed ? Self.glyphs : Self.leave
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                NotchBlade(size: glyphSize, paused: paused,
                           opacity: paused ? 0.45 : 0.85,
                           onStall: onStall, level: level)
                    .frame(width: frame.earWidth, height: frame.notchHeight)
                    // Знак ничего не обещает и ничего не принимает: клик по нему
                    // уходит в меню-бар под плитой, как если бы её не было.
                    .allowsHitTesting(false)
                    .modifier(EarReveal(revealed: revealed, from: 10))

                // Сам вырез. Под ним камера — рисовать здесь нельзя ничего.
                Color.clear
                    .frame(width: frame.notchWidth, height: frame.notchHeight)
                    .allowsHitTesting(false)

                // В покое ухо открывает заметку, в раскрытой чёлке — отправляет
                // её. Знак там ⏎, и делать он обязан ровно то, что называет:
                // клик по нему сначала отменял набранное, что читалось как
                // «нажал Enter — текст пропал».
                NoteEar(size: glyphSize, composing: composing,
                        onTap: composing ? submit : onNote)
                    .frame(width: frame.earWidth, height: frame.notchHeight)
                    .modifier(EarReveal(revealed: revealed, from: -10))
            }
            // Оптический центр уха выше геометрического: снизу у плиты есть
            // скругление, сверху — прямая кромка экрана.
            .offset(y: -1)
            .padding(.horizontal, frame.contentInset)
            .frame(height: frame.notchHeight)
            .clipped()
            // Появляются с задержкой — место сначала, содержимое следом;
            // уходят без неё, вместе с плитой, чтобы не оставаться висеть в
            // воздухе там, где уха уже нет.
            .animation(glyphMotion, value: revealed)

            if composing {
                NotchNoteField(text: $draft, onSubmit: submit, onCancel: onCancel)
                    .frame(height: NotchGeometry.composeDrop)
                    .padding(.horizontal, frame.contentInset)
                    // Поле не возникает в опустившейся чёлке, а проявляется в
                    // ней: тем же размытием, каким меняются значки.
                    .transition(.blurReplace)
            }
        }
        .frame(width: frame.width, height: frame.height, alignment: .top)
        .background(Color.black, in: NotchShape())
        .clipShape(NotchShape())
        // Плита прижата к верхней кромке окна: расти и уменьшаться она может
        // только вниз и вбок, иначе отрывается от железа.
        .frame(width: bounds.width, height: bounds.height, alignment: .top)
        // Плита чёрная при любой теме системы, значит и всё, что AppKit рисует
        // внутри неё сам — курсор, выделение, контекстное меню поля, — должно
        // считать себя тёмным.
        .environment(\.colorScheme, .dark)
        .onAppear {
            guard shownStage == .sealed, stage != .sealed else { return }
            // Следующим тактом, а не этим: рост, начатый в том же проходе, что
            // и первая укладка, случается мгновенно и без анимации.
            DispatchQueue.main.async { go(to: stage) }
        }
        .onChange(of: stage) { _, now in go(to: now) }
    }

    private func go(to next: NotchGeometry.Stage) {
        guard next != shownStage else { return }
        // Черновик не переживает закрытие чёлки ни одним из путей: заметка,
        // всплывшая в поле через полчаса после того, как её бросили, — это уже
        // не заметка, а чужая реплика из прошлой встречи.
        if next != .composing { draft = "" }
        withAnimation(motion(from: shownStage, to: next)) { shownStage = next }
    }
}

/// Как значок появляется, когда плита отращивает под него ухо, и как уходит,
/// когда она сворачивается обратно в вырез.
///
/// Не просто прозрачность: значок выезжает из-под выреза наружу, растёт из 0.7
/// и на ходу теряет размытие — то есть выглядит вынесенным движением плиты, а
/// не проявленным поверх неё. `from` — сторона, с которой он приходит.
private struct EarReveal: ViewModifier {
    var revealed: Bool
    var from: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            // Вынесенный движением значок с «уменьшить движение» просто
            // проявляется: выезд из-под выреза — единственное здесь, что
            // движется само по себе, а не вслед за плитой.
            .scaleEffect(revealed || reduceMotion ? 1 : 0.7)
            .offset(x: revealed || reduceMotion ? 0 : from)
            .blur(radius: revealed || reduceMotion ? 0 : 3)
            .opacity(revealed ? 1 : 0)
    }
}

/// Правое ухо: вход в заметку, а в раскрытой чёлке — то, чем она кончается.
///
/// Счётчика заметок здесь больше нет. Он задумывался подтверждением, а оказался
/// вопросом: человек, печатающий на встрече, свои заметки не считает, и число,
/// которое он не спрашивал, читается как «а это что». Подтверждение осталось
/// одно и достаточное — поле закрылось.
private struct NoteEar: View {
    var size: CGFloat
    var composing: Bool
    var onTap: () -> Void

    @State private var hovering = false

    /// Подложки нет: в чёрной плите любое пятно читается как вторая фигура, а
    /// не как мишень. Наведение объявляет себя яркостью — этого хватает, потому
    /// что кроме знака слева здесь не с чем спутать. Открытое поле яркости не
    /// добавляет: знак ⏎ там не активен, он просто называет, чем это кончится.
    private var opacity: Double { hovering ? 0.95 : 0.55 }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                // Один знак сменяет другой не подстановкой, а уходом: старый
                // уменьшается, размывается и гаснет, новый приходит тем же
                // путём назад. `blurReplace` — ровно эта пара.
                if composing {
                    // ⏎ у SF рисуется в полную высоту кегля, а карандаш — с
                    // полями, поэтому на одном размере он выглядит крупнее.
                    // Сравнивались по видимой высоте, а не по числу.
                    Image(systemName: "return")
                        .font(.system(size: size - 5, weight: .medium))
                        .transition(.blurReplace)
                } else {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: size - 2, weight: .regular))
                        .transition(.blurReplace)
                }
            }
            .foregroundStyle(.white.opacity(opacity))
            .frame(width: size + 14, height: size + 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
        .animation(.smooth(duration: Tokens.Motion.Step.t240), value: composing)
    }
}

/// Заметка внутри опустившейся чёлки: три видимые строки, набор идёт по нижней.
///
/// Текст растёт **вверх**, а не вниз. Активная строка всегда у нижнего края, а
/// написанное раньше поднимается и гаснет под градиентом. Обратный порядок —
/// набор в верхней строке, текст вниз — ставил бы курсор в самое тёмное место
/// плиты и упирал бы его в кромку, из-под которой ничего не видно.
public struct NotchNoteField: View {
    /// Текст живёт снаружи: его должен уметь отправить не только Enter, но и
    /// знак ⏎ в ухе, который стоит вне поля.
    @Binding private var text: String
    private let onSubmit: () -> Void
    private let onCancel: () -> Void

    public init(
        text: Binding<String>,
        onSubmit: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        _text = text
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    @FocusState private var focused: Bool

    /// Где по высоте поля начинается вторая строка и где — последняя, долями от
    /// его высоты. Всё, что ниже последней, обязано быть непрозрачным: по этой
    /// строке идёт набор, и она же держит подсказку.
    private static func lineTop(_ index: Int) -> CGFloat {
        (NotchGeometry.notePaddingTop + CGFloat(index) * NotchGeometry.noteLineHeight)
            / NotchGeometry.composeDrop
    }
    private static var secondLineTop: CGFloat { lineTop(1) }
    private static var lastLineTop: CGFloat { lineTop(NotchGeometry.noteVisibleLines - 1) }

    public var body: some View {
        VStack(spacing: 0) {
            // Пока строк меньше трёх, текст не висит вверху плиты, а стоит там,
            // куда человек смотрит.
            Spacer(minLength: 0)
            ZStack(alignment: .bottomLeading) {
                // Подсказка своя, а не `prompt:`: у поля без рамки AppKit рисует
                // placeholder собственным слоем и не убирает его под набранным
                // текстом — буквы ложатся поверх подсказки.
                if text.isEmpty {
                    Text("Начните печатать…")
                        .foregroundStyle(.white.opacity(0.35))
                        .allowsHitTesting(false)
                }
                TextField("", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
                    .lineLimit(NotchGeometry.noteVisibleLines)
                    // Многострочное поле подкладывает под себя скролл с фоном по
                    // теме системы. Плита чёрная всегда, а тема бывает светлой —
                    // и тогда в ней оказывалось бы белое окно.
                    .scrollContentBackground(.hidden)
            }
            // Ровно три строки и ни пикселем больше: без явной высоты поле
            // рисует четвёртую, и она вылезает за нижний край плиты.
            .frame(
                height: CGFloat(NotchGeometry.noteVisibleLines) * NotchGeometry.noteLineHeight,
                alignment: .bottomLeading
            )
            .clipped()
        }
        .font(.system(size: 13))
        .lineSpacing(NotchGeometry.noteLineHeight - 13)
        .tint(.white.opacity(0.6))
        .focused($focused)
        .onSubmit(onSubmit)
        // Esc выходит из заметки и ничего не сохраняет.
        .onExitCommand { onCancel() }
        .padding(.horizontal, 16)
        .padding(.top, NotchGeometry.notePaddingTop)
        .padding(.bottom, NotchGeometry.notePaddingBottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        // Уехавшая наверх строка не обрезается кромкой, а гаснет: обрез читается
        // как «поле кончилось», угасание — как «это было раньше».
        //
        // Стопы стоят на строках, а не на глазок по высоте. Достаточно было
        // ошибиться на десятую, чтобы градиент заходил на верх нижней строки —
        // на бегущем тексте это почти не видно, а на неподвижной подсказке
        // читается как затенённые макушки букв.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0), location: 0),
                    .init(color: .black.opacity(0.3), location: Self.secondLineTop),
                    .init(color: .black, location: Self.lastLineTop),
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}
