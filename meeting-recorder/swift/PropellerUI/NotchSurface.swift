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
/// Уровень приходит замыканием, а не значением: он меняется двадцать раз в
/// секунду, и пробрасывать это через `@Published` значило бы перерисовывать
/// поверх всех окон ради числа, которое читает один кадр анимации.
public struct NotchBlade: View {
    private let size: CGFloat
    private let level: () -> Float
    private let paused: Bool

    public init(size: CGFloat, paused: Bool, level: @escaping () -> Float) {
        self.size = size
        self.paused = paused
        self.level = level
    }

    /// Состояние лопасти держится в ссылке, а не в `@State`-значении: кадр
    /// обязан его менять, но не обязан из-за этого перерисовывать вьюху.
    private final class Motion {
        var angle: Double = 0
        var speed: Double = BladeDrive.idleSpeed
        var last: Date?
    }

    @State private var motion = Motion()
    /// Лопасть встала — кадры больше не нужны. Отдельный флаг, потому что до
    /// нуля она едет ещё почти секунду после нажатия паузы.
    @State private var still = false

    public var body: some View {
        // 60, а не 30: на полной мощности лопасть проходит 7° за кадр, и на
        // тридцати это уже видно ступенями.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: still)) { context in
            PropellerMark(size: size)
                .rotationEffect(.degrees(advance(to: context.date)))
        }
        .frame(width: size, height: size)
        .task(id: paused) {
            guard paused else {
                still = false
                return
            }
            // Выбег плюс запас: раньше этого лопасть ещё едет, позже —
            // тридцать кадров в секунду тратятся на неподвижную картинку.
            try? await Task.sleep(for: .seconds(BladeDrive.pauseRelease * 2 + 0.3))
            guard !Task.isCancelled else { return }
            still = true
        }
    }

    private func advance(to date: Date) -> Double {
        defer { motion.last = date }
        guard let last = motion.last else { return motion.angle }
        let dt = date.timeIntervalSince(last)
        motion.speed = BladeDrive.advance(
            speed: motion.speed, level: level(), paused: paused, dt: dt
        )
        motion.angle += motion.speed * dt
        return motion.angle
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
    private let onNote: () -> Void
    private let onCommit: (String) -> Void
    private let onCancel: () -> Void

    public init(
        screen: NotchGeometry.Screen,
        stage: NotchGeometry.Stage,
        paused: Bool,
        level: @escaping () -> Float,
        onNote: @escaping () -> Void,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.screen = screen
        self.stage = stage
        self.paused = paused
        self.level = level
        self.onNote = onNote
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    /// Плита вырастает из выреза, а не появляется в готовом виде: запись
    /// начинается тихо, и её знак не имеет права возникнуть щелчком.
    @State private var grown = false

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
    private static let glyphs = Animation.spring(response: 0.4, dampingFraction: 0.9).delay(0.1)

    private var shown: NotchGeometry.Stage { grown ? stage : .sealed }
    private var frame: NotchGeometry.Frame { NotchGeometry.frame(on: screen, stage: shown) }
    /// Габарит окна — всегда максимальный; плита живёт внутри него.
    private var bounds: NotchGeometry.Frame { NotchGeometry.frame(on: screen, stage: .composing) }

    /// Знак и значок в ухе: 16 pt при высоте выреза 32, меньше — на экранах,
    /// где вырез ниже (масштабированное разрешение, Air).
    private var glyphSize: CGFloat { max(11, min(16, frame.notchHeight - 14)) }
    private var composing: Bool { shown == .composing }
    private var revealed: Bool { shown != .sealed }

    /// Насколько ход плиты сейчас плавен — по нему же идут значки и поле, чтобы
    /// всё движение читалось одним жестом, а не тремя.
    private var motion: Animation {
        if !grown { return Self.arrive }
        return stage == .sealed ? Self.leave : Self.move
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                NotchBlade(size: glyphSize, paused: paused, level: level)
                    .frame(width: frame.earWidth, height: frame.notchHeight)
                    .foregroundStyle(.white.opacity(paused ? 0.45 : 0.85))
                    // Знак ничего не обещает и ничего не принимает: клик по нему
                    // уходит в меню-бар под плитой, как если бы её не было.
                    .allowsHitTesting(false)
                    .modifier(EarReveal(revealed: revealed, from: 10))

                // Сам вырез. Под ним камера — рисовать здесь нельзя ничего.
                Color.clear
                    .frame(width: frame.notchWidth, height: frame.notchHeight)
                    .allowsHitTesting(false)

                NoteEar(size: glyphSize, composing: composing, onTap: onNote)
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
            .animation(revealed ? Self.glyphs : Self.leave, value: revealed)

            if composing {
                NotchNoteField(onCommit: onCommit, onCancel: onCancel)
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
        .animation(motion, value: stage)
        .animation(motion, value: grown)
        .onAppear {
            guard !grown else { return }
            // Следующим тактом, а не этим: рост, начатый в том же проходе, что
            // и первая укладка, случается мгновенно и без анимации.
            DispatchQueue.main.async { grown = true }
        }
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

    func body(content: Content) -> some View {
        content
            .scaleEffect(revealed ? 1 : 0.7)
            .offset(x: revealed ? 0 : from)
            .blur(radius: revealed ? 0 : 3)
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
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.smooth(duration: 0.28), value: composing)
    }
}

/// Строка заметки внутри опустившейся чёлки.
private struct NotchNoteField: View {
    var onCommit: (String) -> Void
    var onCancel: () -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        // Подсказка своя, а не `prompt:`: у поля без рамки AppKit рисует
        // placeholder собственным слоем и не убирает его под набранным текстом
        // — буквы ложатся поверх подсказки. Здесь она просто исчезает, как
        // только появляется первый символ.
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text("Начните печатать…")
                    .foregroundStyle(.white.opacity(0.35))
                    .allowsHitTesting(false)
            }
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
        }
        .font(.system(size: 13))
        .tint(.white.opacity(0.6))
        .focused($focused)
        .onSubmit {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = ""
            if t.isEmpty { onCancel() } else { onCommit(t) }
        }
        // Esc выходит из заметки и ничего не сохраняет.
        .onExitCommand { onCancel() }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}
