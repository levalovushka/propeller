import SwiftUI

/// # Плита, на которой стоит вызванный инструмент
///
/// Их три: панель действий над выделением, переключатель встреч на ⌥Tab и поле
/// заметки, когда в нём каретка. В грамматике приложения это один и тот же
/// предмет — то, что приложение не поднимало само, что существует, только пока
/// держат позвавший его жест, и что поэтому обязано читаться как парящее над
/// интерфейсом, а не как его часть (`design/notifications.md`).
///
/// Один контейнер — значит это чтение решено один раз: стекло, угол, тень,
/// отступ. Второй инструмент не заводит своей копии этих четырёх решений и не
/// заводит своих токенов: он берёт `Tokens.Pane.Bar`, потому что это метрики
/// плиты, а не метрики кнопок на ней.
public struct SummonedPlate<Content: View>: View {
    private let cornerRadius: CGFloat
    private let padding: CGFloat
    private let minHeight: CGFloat?
    /// Поднята ли она сейчас.
    ///
    /// Есть инструмент, который стоит на своём месте и до того, как его позвали:
    /// поле заметки внизу экрана записи. Опущенное, оно не плита, а строка —
    /// но **та же самая строка**, и это здесь единственное, что важно. Геометрия
    /// не зависит от `raised`, поэтому текст в момент фокуса не сдвигается ни на
    /// точку: появляется только стекло под ним.
    private let raised: Bool
    private let content: Content

    /// `minHeight` — для инструмента в один ряд: он задаёт высоту плиты, когда
    /// содержимое ниже её (панель действий — 40 при items 32 + padding 4).
    ///
    /// `cornerRadius` и `padding` — свои у каждого инструмента, потому что они не
    /// про плиту, а про то, что на ней лежит: ряду кнопок хватает четырёх, абзацу
    /// в три строки — нет. Радиус должен быть концентричен углу содержимого, то
    /// есть его радиус плюс этот отступ.
    public init(
        cornerRadius: CGFloat = Tokens.Pane.Bar.radius,
        padding: CGFloat = Tokens.Pane.Bar.padding,
        minHeight: CGFloat? = nil,
        raised: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.minHeight = minHeight
        self.raised = raised
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(minHeight: minHeight)
            .background { plate }
            .clipShape(shape)
    }

    /// Сама плита: стекло в своей форме и тень под ним.
    ///
    /// Отдельным слоем, и это не украшательство. Она **гаснет**, а не
    /// вставляется и удаляется: вставка — не свойство, анимировать её нечем, и
    /// плита под кареткой возникала в один кадр, сколько бы времени ей ни
    /// отвели. К тому же внутри AppKit'ов вид, а он умеет появляться постепенно
    /// только прозрачностью.
    ///
    /// И анимация сидит здесь, на слое, а не снаружи всего: надетая на плиту
    /// целиком, она обнимает и содержимое — а содержимое тут бывает
    /// редактором, и тогда текст в нём моргает на каждую перемену.
    private var plate: some View {
        glass
            .clipShape(shape)
            .shadow(color: Tokens.Pane.Bar.shadow,
                    radius: Tokens.Pane.Bar.shadowRadius,
                    y: Tokens.Pane.Bar.shadowY)
            .opacity(raised ? 1 : 0)
            .animation(
                .easeOut(duration: raised ? Tokens.Pane.Bar.fadeIn : Tokens.Pane.Bar.fadeOut),
                value: raised
            )
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    /// Тот же стек, что у окна: материал + подкрас. Liquid glass на 26+, общий
    /// `GlassBackground` ниже — сплошная плита `#212121` над саммари была другим
    /// материалом, чем всё остальное в приложении.
    ///
    /// Подкрас — единственное, чем плита отличается от окна, и он светлее
    /// (`Tokens.Glass.summonedFill`). Тем же почти чёрным, что и окно, она
    /// читалась как дырка в колонке, а не как предмет над ней.
    ///
    /// Под системным стеклом лежит ещё слой матовости, и он там не для красоты.
    /// Liquid glass по замыслу **прозрачен**: сквозь панель действий, поднятую
    /// над саммари, читается само саммари, и буквы под ней спорят с буквами на
    /// ней. Стекло не умеет быть мутнее — у него нет такой ручки, — поэтому
    /// мутность добавляется тем, что лежит ниже. У поля заметки эффект не виден
    /// вовсе: под ним колонка уже погашена маской, и мутить нечего.
    @ViewBuilder
    private var glass: some View {
        if #available(macOS 26.0, *) {
            ZStack {
                GlassBackground(material: .ultraThickMaterial, tinted: false)
                LiquidGlassBackdrop(cornerRadius: cornerRadius, tint: Tokens.Glass.summonedTint)
            }
        } else {
            GlassBackground(
                material: .ultraThickMaterial, tinted: true, wash: Tokens.Glass.summonedFill
            )
        }
    }
}
