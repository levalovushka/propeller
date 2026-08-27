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
    /// Левое крыло из макета (`350:11446`, 85,5×32). Правое — зеркало.
    private static let c1 = CGPoint(x: 6.80069, y: 0)
    private static let c2 = CGPoint(x: 12.8046, y: 4.43928)
    private static let p1 = CGPoint(x: 14.7977, y: 10.9413)
    private static let p2 = CGPoint(x: 18.6525, y: 23.5169)
    private static let c3 = CGPoint(x: 20.1978, y: 28.5581)
    private static let c4 = CGPoint(x: 24.8529, y: 32)
    private static let p3 = CGPoint(x: 30.1256, y: 32)

    public init() {}

    public func path(in rect: CGRect) -> Path {
        // Крыло масштабируется по обеим осям сразу: растянутое только по
        // горизонтали, оно ложится плашмя и перестаёт быть тем скосом, что
        // нарисован.
        let k = rect.height / NotchGeometry.designHeight
        func left(_ p: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + p.x * k, y: rect.minY + p.y * k)
        }
        func right(_ p: CGPoint) -> CGPoint {
            CGPoint(x: rect.maxX - p.x * k, y: rect.minY + p.y * k)
        }

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addCurve(to: left(Self.p1), control1: left(Self.c1), control2: left(Self.c2))
        path.addLine(to: left(Self.p2))
        path.addCurve(to: left(Self.p3), control1: left(Self.c3), control2: left(Self.c4))
        path.addLine(to: right(Self.p3))
        path.addCurve(to: right(Self.p2), control1: right(Self.c4), control2: right(Self.c3))
        path.addLine(to: right(Self.p1))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
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
        let live = stage == .open
        view.apply(screen: screen, stage: stage, buttons: [
            NotchButton(symbol: muted ? "microphone.slash.fill" : "microphone.fill",
                        enabled: canMute, interactive: live, action: onMute),
            // Вейвформа пока не движется, но и не притворяется недоступной
            // кнопкой: это прибор, нажимать его незачем.
            NotchButton(symbol: "waveform.mid", interactive: live, action: nil),
            NotchButton(symbol: paused ? "play.fill" : "pause.fill",
                        enabled: true, interactive: live, action: onPause),
            NotchButton(symbol: "stop.fill", enabled: true, interactive: live, action: onStop),
        ])
    }
}

public final class NotchPlateView: NSView {
    private let shape = CAShapeLayer()
    private var shown: NotchGeometry.Stage?
    private var screen: NotchGeometry.Screen?

    /// Ход плиты. Заметный ease-out: трогается резко, а последнюю четверть пути
    /// идёт почти стоя — так движение кончается само, а не обрывается.
    private static let openDuration: CFTimeInterval = 0.55
    private static let sealDuration: CFTimeInterval = 0.45
    private static let easeOut = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)

    /// Кнопки короче плиты: они догоняют её, а не тянут за собой.
    private static let buttonDuration: CFTimeInterval = 0.34
    /// Насколько крайняя кнопка отстаёт от внутренней. Больше — и пара
    /// перестаёт читаться парой; меньше — и разлёта не видно.
    private static let stagger: CFTimeInterval = 0.06
    /// Откуда кнопка приезжает: из-под выреза наружу, то есть к центру плиты.
    private static let drift: CGFloat = 14

    /// Кнопка и то, как она относится к центру.
    private enum Slot: CaseIterable {
        case mic, wave, pause, stop

        /// Крайние (микрофон и стоп) дальше от центра, поэтому и приезжают
        /// позже: разлёт читается только если он не одновременный.
        var outer: Bool { self == .mic || self == .stop }
        /// Левые едут вправо, правые влево — все из центра.
        var driftSign: CGFloat { (self == .mic || self == .wave) ? 1 : -1 }

        /// Левый край кнопки в координатах плиты.
        func x(in frame: NotchGeometry.Frame) -> CGFloat {
            let side = NotchGeometry.buttonSide
            switch self {
            case .mic: return frame.groupInset
            case .wave: return frame.groupInset + side
            case .pause: return frame.wingWidth + frame.notchWidth
            case .stop: return frame.wingWidth + frame.notchWidth + side
            }
        }
    }

    private var hosts: [Slot: NSHostingView<NotchButton>] = [:]

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(shape)
        shape.fillColor = NSColor.black.cgColor
        shape.fillRule = .nonZero

        for slot in Slot.allCases {
            let host = NSHostingView(rootView: NotchButton.placeholder)
            host.wantsLayer = true
            host.layer?.opacity = 0
            addSubview(host)
            hosts[slot] = host
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func apply(
        screen: NotchGeometry.Screen,
        stage: NotchGeometry.Stage,
        buttons: [NotchButton]
    ) {
        for (slot, button) in zip(Slot.allCases, buttons) {
            hosts[slot]?.rootView = button
        }
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
            for slot in Slot.allCases { settle(slot, opening: opening) }
            return
        }

        let move = CABasicAnimation(keyPath: "path")
        move.fromValue = shape.presentation()?.path ?? shape.path
        move.toValue = target
        move.duration = opening ? Self.openDuration : Self.sealDuration
        move.timingFunction = Self.easeOut
        shape.path = target
        shape.add(move, forKey: "plate")

        for slot in Slot.allCases { animate(slot, opening: opening) }
    }

    /// Поставить кнопку в конечное состояние без движения.
    private func settle(_ slot: Slot, opening: Bool) {
        guard let layer = hosts[slot]?.layer else { return }
        layer.opacity = opening ? 1 : 0
        layer.setValue(opening ? 0 : slot.driftSign * Self.drift,
                       forKeyPath: "transform.translation.x")
    }

    /// Кнопка выезжает из центра на своё место и проявляется по дороге; крайние
    /// отстают от внутренних. На уходе — то же самое задом наперёд, и первыми
    /// уходят как раз крайние.
    private func animate(_ slot: Slot, opening: Bool) {
        guard let layer = hosts[slot]?.layer else { return }
        let delay = opening
            ? (slot.outer ? Self.stagger : 0)
            : (slot.outer ? 0 : Self.stagger)
        let presented = layer.presentation()
        let shift = slot.driftSign * Self.drift

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = presented?.opacity ?? layer.opacity
        fade.toValue = opening ? 1 : 0

        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = presented?.value(forKeyPath: "transform.translation.x")
            ?? layer.value(forKeyPath: "transform.translation.x")
        slide.toValue = opening ? 0 : shift

        for animation in [fade, slide] {
            animation.duration = Self.buttonDuration
            animation.timingFunction = Self.easeOut
            if delay > 0 {
                animation.beginTime = CACurrentMediaTime() + delay
                // Иначе кнопка на время задержки прыгает в конечное состояние.
                animation.fillMode = .backwards
            }
        }
        settle(slot, opening: opening)
        layer.add(fade, forKey: "fade")
        layer.add(slide, forKey: "slide")
    }

    public override func layout() {
        super.layout()
        layoutContents()
        guard let screen, let shown else { return }
        shape.path = Self.path(on: screen, stage: shown, in: bounds)
    }

    /// Кнопки стоят в раскрытой плите; в свёрнутой их не видно, поэтому
    /// раскладка у них одна.
    private func layoutContents() {
        shape.frame = bounds
        guard let screen else { return }
        let frame = NotchGeometry.frame(on: screen, stage: .open)
        let plateLeft = (bounds.width - frame.width) / 2
        let side = NotchGeometry.buttonSide
        for slot in Slot.allCases {
            hosts[slot]?.frame = CGRect(
                x: plateLeft + slot.x(in: frame),
                y: bounds.maxY - frame.height + (frame.height - side) / 2,
                width: side, height: side
            )
        }
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

/// Кнопка в крыле: знак 16 в поле 32, без подложки.
///
/// Подложки нет намеренно: в чёрной плите любое пятно читается как вторая
/// фигура, а не как мишень. Наведение объявляет себя яркостью.
public struct NotchButton: View {
    var symbol: String
    /// Кнопка есть, но нажать её сейчас нельзя (мьют на микрофонном пути).
    var enabled: Bool = true
    /// Плита раскрыта — по кнопке можно попасть. В свёрнутой её не видно, и
    /// ловить клики она не должна.
    var interactive: Bool = true
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

    @ViewBuilder private var glyph: some View {
        ZStack {
            Image(systemName: shown.isEmpty ? symbol : shown)
                .font(.system(size: NotchGeometry.glyphSize, weight: .regular))
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

    static let placeholder = NotchButton(symbol: "waveform.mid", action: nil)

    public var body: some View {
        if let action {
            Button(action: action) {
                glyph.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .allowsHitTesting(interactive)
            .onHover { hovering = enabled && $0 }
        } else {
            glyph.allowsHitTesting(false)
        }
    }
}
