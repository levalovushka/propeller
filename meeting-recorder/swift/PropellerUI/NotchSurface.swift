import SwiftUI
import PropellerPure

/// Чёлка как поверхность записи: чёрная плита, вырастающая из выреза.
///
/// Слева — микрофон и вейвформа, справа — пауза и стоп (Figma 299:26711).
/// Ничего не сообщает: показывает состояние записи и принимает четыре действия,
/// каждое из которых человек в звонке может захотеть за секунду.

/// Силуэт плиты.
///
/// Верх лежит на кромке экрана во всю ширину, боковые края уходят книзу
/// S-образной кривой — плита не обрывается вертикально, а стекает к низу. Кривые
/// сняты с макета один в один (`Frame 319`, 423×47); при другой высоте они
/// тянутся по вертикали, при другой ширине выреза раздаётся только середина.
///
/// Форма покрывает вырез целиком и той же чернотой — поэтому железо и рисунок
/// читаются одной фигурой. Ради этого здесь нет ни тени, ни обводки, ни
/// материала: всё, что даёт край, выдаёт накладку.
public struct NotchShape: Shape {
    /// Точки левого крыла из макета, в его собственных координатах (47 pt по
    /// высоте). Правое — зеркало.
    private static var designHeight: CGFloat { NotchGeometry.designHeight }
    private static let topInset: CGFloat = 0.697479
    private static let c1 = CGPoint(x: 10.706, y: 0)
    private static let c2 = CGPoint(x: 19.5656, y: 6.47235)
    private static let p1 = CGPoint(x: 22.6086, y: 16.0071)
    private static let p2 = CGPoint(x: 27.8356, y: 32.3848)
    private static let c3 = CGPoint(x: 30.614, y: 41.0905)
    private static let c4 = CGPoint(x: 38.7032, y: 47)
    private static let p3 = CGPoint(x: 47.8414, y: 47)

    public init() {}

    public func path(in rect: CGRect) -> Path {
        // Скос сжимается по обеим осям сразу: растянутый только по горизонтали,
        // он ложится плашмя и перестаёт быть тем скосом, что нарисован.
        let k = rect.height / Self.designHeight
        func left(_ p: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + p.x * k, y: rect.minY + p.y * k)
        }
        func right(_ p: CGPoint) -> CGPoint {
            CGPoint(x: rect.maxX - p.x * k, y: rect.minY + p.y * k)
        }

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + Self.topInset * (rect.height / Self.designHeight),
                              y: rect.minY))
        path.addCurve(to: left(Self.p1), control1: left(Self.c1), control2: left(Self.c2))
        path.addLine(to: left(Self.p2))
        path.addCurve(to: left(Self.p3), control1: left(Self.c3), control2: left(Self.c4))
        path.addLine(to: right(Self.p3))
        path.addCurve(to: right(Self.p2), control1: right(Self.c4), control2: right(Self.c3))
        path.addLine(to: right(Self.p1))
        path.addCurve(to: CGPoint(x: rect.maxX - Self.topInset * (rect.height / Self.designHeight),
                                  y: rect.minY),
                      control1: right(Self.c2), control2: right(Self.c1))
        path.closeSubpath()
        return path
    }
}

/// Плита — слой, а не SwiftUI-фигура.
///
/// Уход в вырез приходится ровно на самый занятый момент главного потока:
/// «Стоп» останавливает запись, сводит микс и сохраняет архив, а `RecordingStore`
/// кодирует его синхронно. Анимация, живущая в SwiftUI, в этот момент лагает —
/// та же болезнь, от которой в своё время увезли лопасть. `CAShapeLayer`
/// интерполирует `path` в рендер-сервере: главный поток может стоять, плита всё
/// равно уедет ровно.
///
/// Оба пути строит один `NotchShape` и структура у них одинаковая (четыре кривые
/// и три прямые) — иначе интерполяции не будет и плита прыгнет.
public struct NotchPlate: NSViewRepresentable {
    private let screen: NotchGeometry.Screen
    private let stage: NotchGeometry.Stage

    public init(screen: NotchGeometry.Screen, stage: NotchGeometry.Stage) {
        self.screen = screen
        self.stage = stage
    }

    public func makeNSView(context: Context) -> PlateView { PlateView() }

    public func updateNSView(_ view: PlateView, context: Context) {
        view.apply(screen: screen, stage: stage)
    }
}

public final class PlateView: NSView {
    private let shape = CAShapeLayer()
    private var shown: NotchGeometry.Stage?
    private var screen: NotchGeometry.Screen?

    /// Ход плиты. Раскрытие чуть длиннее ухода: она вырастает при старте записи,
    /// когда на неё смотрят краем глаза, и уходит на стопе, когда уже не смотрят.
    private static let openDuration: CFTimeInterval = 0.5
    private static let sealDuration: CFTimeInterval = 0.42

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(shape)
        shape.fillColor = NSColor.black.cgColor
        shape.fillRule = .nonZero
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func apply(screen: NotchGeometry.Screen, stage: NotchGeometry.Stage) {
        let geometryChanged = self.screen != screen
        self.screen = screen
        guard stage != shown || geometryChanged else { return }
        let first = shown == nil
        let sealing = stage == .sealed
        shown = stage
        shape.frame = bounds

        let target = Self.path(on: screen, stage: stage, in: bounds)
        // Первый показ и смена железа — без анимации: это не движение
        // интерфейса, а то, из чего оно начинается.
        guard !first, !geometryChanged else {
            shape.path = target
            return
        }
        let move = CABasicAnimation(keyPath: "path")
        move.fromValue = shape.presentation()?.path ?? shape.path
        move.toValue = target
        move.duration = sealing ? Self.sealDuration : Self.openDuration
        move.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        shape.path = target
        shape.add(move, forKey: "plate")
    }

    public override func layout() {
        super.layout()
        shape.frame = bounds
        guard let screen, let shown else { return }
        shape.path = Self.path(on: screen, stage: shown, in: bounds)
    }

    /// Плита прижата к верхней кромке и стоит по центру выреза; окно под ней
    /// всегда размером с раскрытую.
    private static func path(
        on screen: NotchGeometry.Screen, stage: NotchGeometry.Stage, in bounds: CGRect
    ) -> CGPath {
        let frame = NotchGeometry.frame(on: screen, stage: stage)
        // Фигура рисуется сверху вниз (у `Shape` начало — верхний край), а
        // слой живёт в координатах AppKit, где верх — это `maxY`. Отражаем
        // готовый путь, а не перекладываем форму: форма одна и та же.
        let box = CGRect(x: (bounds.width - frame.width) / 2, y: 0,
                         width: frame.width, height: frame.height)
        var flip = CGAffineTransform(scaleX: 1, y: -1)
            .translatedBy(x: 0, y: -bounds.height)
        let path = NotchShape().path(in: box).cgPath
        return path.copy(using: &flip) ?? path
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
    private let muted: Bool
    private let canMute: Bool
    private let onMute: () -> Void
    private let onPause: () -> Void
    private let onStop: () -> Void

    public init(
        screen: NotchGeometry.Screen,
        stage: NotchGeometry.Stage,
        paused: Bool,
        muted: Bool,
        canMute: Bool,
        onMute: @escaping () -> Void,
        onPause: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        self.screen = screen
        self.stage = stage
        self.paused = paused
        self.muted = muted
        self.canMute = canMute
        self.onMute = onMute
        self.onPause = onPause
        self.onStop = onStop
    }

    /// Стадия, по которой плита нарисована сейчас.
    ///
    /// Отдельная от входящей намеренно. Стадию меняет контроллер — снаружи
    /// SwiftUI, заменой всего дерева, — и такое изменение анимируется через раз.
    /// Здесь любой приход стадии становится обычной транзакцией с явной
    /// пружиной, поэтому старт записи и её конец идут по одной кривой.
    @State private var shownStage: NotchGeometry.Stage = .sealed

    /// Рост при старте: единственное движение, которое человек увидит краем
    /// глаза, уже сидя в звонке.
    private static let arrive = Animation.spring(response: 0.58, dampingFraction: 0.94)
    /// Уход в железо на стопе — спокойнее и без единого колебания.
    private static let leave = Animation.spring(response: 0.46, dampingFraction: 1.0)
    /// Кнопки идут за плитой, а не вместе с ней: сначала место, потом то, что в
    /// нём стоит.
    private static let controls = Animation.spring(response: 0.4, dampingFraction: 0.9).delay(0.1)

    private var frame: NotchGeometry.Frame { NotchGeometry.frame(on: screen, stage: shownStage) }
    /// Габарит окна — всегда максимальный; плита живёт внутри него.
    private var bounds: NotchGeometry.Frame { NotchGeometry.frame(on: screen, stage: .open) }
    private var open: Bool { shownStage == .open }

    public var body: some View {
        ZStack(alignment: .top) {
            NotchPlate(screen: screen, stage: shownStage)

            HStack(spacing: 0) {
                pair(
                    NotchButton(symbol: muted ? "microphone.slash.fill" : "microphone.fill",
                                enabled: canMute, action: onMute),
                    // Вейвформа пока не движется, но и не притворяется
                    // недоступной кнопкой: это прибор, нажимать его незачем.
                    NotchButton(symbol: "waveform.mid", action: nil)
                )
                Spacer(minLength: 0)
                pair(
                    NotchButton(symbol: paused ? "play.fill" : "pause.fill",
                                enabled: true, action: onPause),
                    NotchButton(symbol: "stop.fill", enabled: true, action: onStop)
                )
            }
            .frame(width: frame.width - 2 * (frame.slopeWidth + NotchGeometry.edgeGap),
                   height: frame.height)
            .opacity(open ? 1 : 0)
            .scaleEffect(open ? 1 : 0.8)
            .blur(radius: open ? 0 : 3)
            .allowsHitTesting(open)
        }
        // Плита прижата к верхней кромке окна: расти и уменьшаться она может
        // только вниз и вбок, иначе отрывается от железа.
        .frame(width: bounds.width, height: bounds.height, alignment: .top)
        // Плита чёрная при любой теме системы, значит и всё, что AppKit рисует
        // внутри неё сам, должно считать себя тёмным.
        .environment(\.colorScheme, .dark)
        .onAppear {
            guard shownStage == .sealed, stage != .sealed else { return }
            // Следующим тактом, а не этим: рост, начатый в том же проходе, что
            // и первая укладка, случается мгновенно и без анимации.
            DispatchQueue.main.async { go(to: stage) }
        }
        .onChange(of: stage) { _, now in go(to: now) }
    }

    private func pair(_ first: NotchButton, _ second: NotchButton) -> some View {
        HStack(spacing: NotchGeometry.buttonGap) {
            first
            second
        }
        .animation(open ? Self.controls : Self.leave, value: open)
    }

    private func go(to next: NotchGeometry.Stage) {
        guard next != shownStage else { return }
        withAnimation(next == .sealed ? Self.leave : Self.arrive) { shownStage = next }
    }
}

/// Кнопка в крыле: знак 16 в поле 32, без подложки.
///
/// Подложки нет намеренно: в чёрной плите любое пятно читается как вторая
/// фигура, а не как мишень. Наведение объявляет себя яркостью.
private struct NotchButton: View {
    var symbol: String
    /// Кнопка есть, но нажать её сейчас нельзя (мьют на микрофонном пути).
    var enabled: Bool = true
    /// `nil` — это не кнопка вовсе, а показание прибора: яркость обычная,
    /// наведения нет, нажимать нечего.
    var action: (() -> Void)?

    @State private var hovering = false

    private var opacity: Double {
        guard action != nil else { return 0.55 }
        guard enabled else { return 0.35 }
        return hovering ? 0.95 : 0.55
    }

    /// Знак, который нарисован сейчас.
    ///
    /// Отдельный от входящего по той же причине, что и стадия у плиты: символ
    /// приходит извне, заменой всего дерева, а такая замена не транзакция — и
    /// `.transition` при ней просто не включается, знак моргает. Здесь смена
    /// делается своей `withAnimation`, и тогда переход отрабатывает.
    @State private var shown: String = ""

    private var glyph: some View {
        ZStack {
            Image(systemName: shown.isEmpty ? symbol : shown)
                .font(.system(size: NotchGeometry.buttonSide - 13, weight: .regular))
                .transition(.blurReplace)
                .id(shown.isEmpty ? symbol : shown)
        }
        .foregroundStyle(.white.opacity(opacity))
        .frame(width: NotchGeometry.buttonSide, height: NotchGeometry.buttonSide)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onAppear { shown = symbol }
        .onChange(of: symbol) { _, new in
            withAnimation(.smooth(duration: 0.26)) { shown = new }
        }
    }

    var body: some View {
        if let action {
            Button(action: action) {
                glyph.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .onHover { hovering = enabled && $0 }
        } else {
            glyph.allowsHitTesting(false)
        }
    }
}
