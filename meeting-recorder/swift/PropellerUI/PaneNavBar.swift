import SwiftUI

/// Шаг истории. Свой тип, а не пара аргументов, потому что у шага два
/// состояния, и второе — не «нет кнопки», а «кнопка есть, идти некуда».
///
/// Отдельно от `PaneNavBar`, а не вложенным типом: полоса параметризована
/// двумя слотами, и вложенный `Step` пришлось бы называть через них.
public struct PaneNavStep {
    public let enabled: Bool
    public let action: () -> Void

    public init(enabled: Bool, action: @escaping () -> Void) {
        self.enabled = enabled
        self.action = action
    }
}

/// # Полоса над правой панелью
///
/// Одна на все маршруты, и это вся её задача. До неё верх панели был занят
/// пятью разными решениями: у готовой встречи действия висели плавающим
/// оверлеем в углу окна, у идущей записи была своя полоса, у архива — третья,
/// с навигацией и шестернёй, у проекта действия стояли в правом слоте
/// заголовка страницы, а «Назад» из настроек жил вообще в шапке рельса. Пять
/// мест под две роли.
///
/// Ролей действительно две, и полоса разделена ровно по ним:
///
/// - **слева — хождение**: место под светофор, когда рельс убран, и два
///   шеврона истории;
/// - **справа — действия над тем, что открыто ниже**: у встречи «…»,
///   копирование и «Поделиться», у проекта его меню, у идущей записи таймер,
///   пауза и стоп.
///
/// Крошек здесь нет и не будет (решение владельца 2026-08-28): вложенной
/// структуры в приложении нет нигде, кроме проектов, а крошка, у которой
/// корень некликабельный, — это обещание страницы, которой не существует.
/// Ходить по истории умеет кнопка, а не путь.
///
/// Имя открытого живёт **в теле** страницы — у встречи, у проекта, у раздела
/// настроек. Левый слот `leading` заведён для единственного исключения: у
/// идущей записи тело — живая лента, а не документ, и поставить имя там некуда.
public struct PaneNavBar<Leading: View, Trailing: View>: View {

    private let back: PaneNavStep
    private let forward: PaneNavStep
    /// Держать ли место под светофор и кнопку рельса. Нужно ровно тогда, когда
    /// рельс убран: с рельсом на месте они стоят в **его** шапке.
    private let reservesWindowChrome: Bool
    private let leading: () -> Leading
    private let trailing: () -> Trailing

    public init(
        back: PaneNavStep,
        forward: PaneNavStep,
        reservesWindowChrome: Bool,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.back = back
        self.forward = forward
        self.reservesWindowChrome = reservesWindowChrome
        self.leading = leading
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: 0) {
            if reservesWindowChrome {
                Color.clear
                    .frame(
                        width: Tokens.Window.chromeReserve,
                        height: Tokens.Sidebar.toggleSide
                    )
            }
            HStack(spacing: Tokens.Pane.NavBar.stepGap) {
                PaneNavChevron(symbol: "chevron.left", help: "Назад", step: back)
                    .paneProbe(PaneProbe.back)
                PaneNavChevron(symbol: "chevron.right", help: "Вперёд", step: forward)
                    .paneProbe(PaneProbe.forward)
            }
            leading()
            // Пружина между хождением и действиями: правый край полосы — это
            // край окна, и действия прижаты к нему на любой ширине.
            Spacer(minLength: Tokens.Space.s8)
            trailing()
                .paneProbe(PaneProbe.actions)
        }
        .padding(.horizontal, Tokens.Pane.NavBar.hPadding)
        .frame(height: Tokens.Pane.NavBar.height)
        // Полоса меряет себя сама: зонды внутри отдают координаты **в ней**,
        // а не в панели под ней, — иначе тест на её геометрию зависел бы от
        // того, что нарисовано ниже.
        .coordinateSpace(name: PaneProbe.space)
    }
}

extension PaneNavBar where Leading == EmptyView {
    public init(
        back: PaneNavStep,
        forward: PaneNavStep,
        reservesWindowChrome: Bool,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.init(
            back: back, forward: forward,
            reservesWindowChrome: reservesWindowChrome,
            leading: { EmptyView() }, trailing: trailing
        )
    }
}

/// Шеврон истории.
///
/// Своя кнопка, а не `SidebarChromeButton`: у той нет состояния «идти некуда»,
/// а оно здесь главное. Всё остальное — коробка 32, радиус, ховер, движение —
/// взято у неё же, потому что это тот же ряд окна и кнопки в нём обязаны быть
/// одной породы.
struct PaneNavChevron: View {
    let symbol: String
    let help: String
    let step: PaneNavStep

    @State private var hovering = false

    var body: some View {
        Button(action: step.action) {
            Image(systemName: symbol)
                .font(.system(size: Tokens.Sidebar.chromeIconSize, weight: .regular))
                .foregroundStyle(paint)
                .frame(width: Tokens.Sidebar.toggleSide, height: Tokens.Sidebar.toggleSide)
                .background(
                    hovering && step.enabled ? Tokens.Sidebar.rowHover : .clear,
                    in: RoundedRectangle(
                        cornerRadius: Tokens.Sidebar.chromeRadius, style: .continuous
                    )
                )
                .contentShape(
                    RoundedRectangle(
                        cornerRadius: Tokens.Sidebar.chromeRadius, style: .continuous
                    )
                )
        }
        .buttonStyle(.press)
        .disabled(!step.enabled)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
        .animation(.easeOut(duration: Tokens.Motion.hover), value: step.enabled)
        .help(help)
        .accessibilityLabel(help)
    }

    private var paint: Color {
        guard step.enabled else { return Tokens.Pane.NavBar.stepQuiet }
        return hovering ? Tokens.Paint.Text.primary : Tokens.Sidebar.chromeIcon
    }
}
