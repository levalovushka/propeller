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
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: still)) { context in
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
public struct NotchFace: View {
    private let frame: NotchGeometry.Frame
    private let composing: Bool
    private let paused: Bool
    private let savedCount: Int?
    private let level: () -> Float
    private let onNote: () -> Void
    private let onCommit: (String) -> Void
    private let onCancel: () -> Void

    public init(
        frame: NotchGeometry.Frame,
        composing: Bool,
        paused: Bool,
        savedCount: Int?,
        level: @escaping () -> Float,
        onNote: @escaping () -> Void,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.frame = frame
        self.composing = composing
        self.paused = paused
        self.savedCount = savedCount
        self.level = level
        self.onNote = onNote
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    /// Знак и значок в ухе: 16 pt при высоте выреза 32.
    private var glyphSize: CGFloat { min(16, frame.notchHeight - 14) }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                NotchBlade(size: glyphSize, paused: paused, level: level)
                    .frame(width: frame.earWidth, height: frame.notchHeight)
                    .foregroundStyle(.white.opacity(paused ? 0.45 : 0.85))
                    // Знак ничего не обещает и ничего не принимает: клик по нему
                    // уходит в меню-бар под плитой, как если бы её не было.
                    .allowsHitTesting(false)

                // Сам вырез. Под ним камера — рисовать здесь нельзя ничего.
                Color.clear
                    .frame(width: frame.bodyWidth, height: frame.notchHeight)
                    .allowsHitTesting(false)

                NoteEar(size: glyphSize, active: composing, savedCount: savedCount, onTap: onNote)
                    .frame(width: frame.earWidth, height: frame.notchHeight)
            }
            .padding(.horizontal, frame.contentInset)

            if composing {
                NotchNoteField(onCommit: onCommit, onCancel: onCancel)
                    .frame(height: NotchGeometry.composeDrop)
                    .padding(.horizontal, frame.contentInset)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .background(Color.black, in: NotchShape())
        .clipShape(NotchShape())
    }
}

/// Правое ухо: вход в заметку, и оно же подтверждение.
///
/// Сохранённая заметка не подтверждается сообщением — на 0,7 с значок
/// становится числом заметок за эту встречу. Подтверждение принадлежит тому
/// месту, где печатали, и говорит не «сохранено», а «их теперь три».
private struct NoteEar: View {
    var size: CGFloat
    var active: Bool
    var savedCount: Int?
    var onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(.white.opacity(hovering || active ? 0.16 : 0))
                    .frame(width: size + 10, height: size + 10)
                if let savedCount {
                    Text("\(savedCount)")
                        .font(.system(size: size - 2, weight: .medium, design: .rounded))
                        .monospacedDigit()
                } else {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: size - 2, weight: .regular))
                }
            }
            .foregroundStyle(.white.opacity(active || savedCount != nil ? 0.95 : 0.7))
            .contentShape(Circle().size(width: size + 14, height: size + 14))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Строка заметки внутри опустившейся чёлки.
private struct NotchNoteField: View {
    var onCommit: (String) -> Void
    var onCancel: () -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt:
            Text("Заметка…").foregroundStyle(.white.opacity(0.35))
        )
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .foregroundStyle(.white)
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
