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

/// Плита и её кнопки — слои, а не SwiftUI-иерархия.
///
/// Оба движения приходятся ровно на самый занятый момент главного потока:
/// «Стоп» останавливает запись, сводит микс и сохраняет архив, а
/// `RecordingStore` кодирует его синхронно. Всё, что анимируется в SwiftUI, там
/// лагает — та же болезнь, от которой в своё время увезли лопасть. Здесь
/// `CAShapeLayer` интерполирует `path`, а слой с кнопками гасится своей
/// `CABasicAnimation`: главный поток может стоять, движение всё равно пройдёт
/// ровно.
///
/// Оба пути плиты строит один `NotchShape`, и структура у них одинаковая
/// (четыре кривые и три прямые) — иначе интерполяции не будет и плита прыгнет.
public struct NotchFace: NSViewRepresentable {
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

    public func makeNSView(context: Context) -> NotchPlateView {
        NotchPlateView()
    }

    public func updateNSView(_ view: NotchPlateView, context: Context) {
        view.apply(
            screen: screen, stage: stage,
            controls: NotchControls(
                paused: paused, muted: muted, canMute: canMute,
                interactive: stage == .open,
                onMute: onMute, onPause: onPause, onStop: onStop
            )
        )
    }
}

public final class NotchPlateView: NSView {
    private let shape = CAShapeLayer()
    private let controls = NSHostingView(rootView: NotchControls.placeholder)
    private var shown: NotchGeometry.Stage?
    private var screen: NotchGeometry.Screen?

    /// Ход плиты. Раскрытие чуть длиннее ухода: она вырастает при старте записи,
    /// когда на неё смотрят краем глаза, и уходит на стопе, когда уже не смотрят.
    private static let openDuration: CFTimeInterval = 0.5
    private static let sealDuration: CFTimeInterval = 0.42
    /// Кнопки гаснут быстрее, чем уезжает плита, и появляются позже, чем она
    /// раздалась: сначала место, потом то, что в нём стоит.
    private static let controlsFade: CFTimeInterval = 0.22
    private static let controlsDelay: CFTimeInterval = 0.12
    private static let timing = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(shape)
        shape.fillColor = NSColor.black.cgColor
        shape.fillRule = .nonZero

        controls.wantsLayer = true
        controls.layer?.opacity = 0
        addSubview(controls)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func apply(screen: NotchGeometry.Screen, stage: NotchGeometry.Stage, controls rootView: NotchControls) {
        controls.rootView = rootView
        let geometryChanged = self.screen != screen
        self.screen = screen
        layoutContents()
        guard stage != shown || geometryChanged else { return }
        let first = shown == nil
        let opening = stage == .open
        shown = stage

        let target = Self.path(on: screen, stage: stage, in: bounds)
        // Первый показ и смена железа — без анимации: это не движение
        // интерфейса, а то, из чего оно начинается.
        guard !first, !geometryChanged else {
            shape.path = target
            controls.layer?.opacity = opening ? 1 : 0
            return
        }

        let move = CABasicAnimation(keyPath: "path")
        move.fromValue = shape.presentation()?.path ?? shape.path
        move.toValue = target
        move.duration = opening ? Self.openDuration : Self.sealDuration
        move.timingFunction = Self.timing
        shape.path = target
        shape.add(move, forKey: "plate")

        guard let controlsLayer = controls.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = controlsLayer.presentation()?.opacity ?? controlsLayer.opacity
        fade.toValue = opening ? 1 : 0
        fade.duration = Self.controlsFade
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        if opening {
            fade.beginTime = CACurrentMediaTime() + Self.controlsDelay
            fade.fillMode = .backwards
        }
        controlsLayer.opacity = opening ? 1 : 0
        controlsLayer.add(fade, forKey: "controls")
    }

    public override func layout() {
        super.layout()
        layoutContents()
        guard let screen, let shown else { return }
        shape.path = Self.path(on: screen, stage: shown, in: bounds)
    }

    /// Кнопки стоят в раскрытой плите: между скосами, по высоте выреза. В
    /// свёрнутой их не видно, поэтому раскладка у них одна.
    private func layoutContents() {
        shape.frame = bounds
        guard let screen else { return }
        let frame = NotchGeometry.frame(on: screen, stage: .open)
        let inset = frame.slopeWidth + NotchGeometry.edgeGap
        let width = frame.width - 2 * inset
        controls.frame = CGRect(
            x: (bounds.width - width) / 2,
            y: bounds.maxY - frame.height,
            width: width, height: frame.height
        )
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

/// Четыре кнопки: микрофон и вейвформа слева, пауза/плей и стоп справа.
public struct NotchControls: View {
    var paused: Bool
    var muted: Bool
    var canMute: Bool
    var interactive: Bool
    var onMute: () -> Void
    var onPause: () -> Void
    var onStop: () -> Void

    static let placeholder = NotchControls(
        paused: false, muted: false, canMute: false, interactive: false,
        onMute: {}, onPause: {}, onStop: {}
    )

    public var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: NotchGeometry.buttonGap) {
                NotchButton(symbol: muted ? "microphone.slash.fill" : "microphone.fill",
                            enabled: canMute, action: onMute)
                // Вейвформа пока не движется, но и не притворяется недоступной
                // кнопкой: это прибор, нажимать его незачем.
                NotchButton(symbol: "waveform.mid", action: nil)
            }
            Spacer(minLength: 0)
            HStack(spacing: NotchGeometry.buttonGap) {
                NotchButton(symbol: paused ? "play.fill" : "pause.fill",
                            enabled: true, action: onPause)
                NotchButton(symbol: "stop.fill", enabled: true, action: onStop)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Плита чёрная при любой теме системы, значит и всё, что AppKit рисует
        // внутри неё сам, должно считать себя тёмным.
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(interactive)
    }
}

/// Кнопка в крыле: знак 16 в поле 32, без подложки.
///
/// Подложки нет намеренно: в чёрной плите любое пятно читается как вторая
/// фигура, а не как мишень. Наведение объявляет себя яркостью.
struct NotchButton: View {
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
