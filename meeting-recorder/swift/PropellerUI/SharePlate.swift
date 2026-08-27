import SwiftUI
import PropellerPure

/// # Плита публикации по ссылке — Figma `summary/share-link`
///
/// Два состояния одной плиты, а не две плиты: у встречи либо есть живая ссылка,
/// либо нет, и человек, нажавший «Поделиться», хочет видеть то, что есть
/// сейчас. Переключается это содержимым, потому что шапка, стекло и края у них
/// общие — и переход между состояниями не должен читаться как новое окно.
///
/// Плита ничего не знает про сеть, ключи и сервер: что можно нажать, ей
/// сообщают (`obstacle`), а что случится по нажатию — решает вызывающий.
public struct SharePlate: View {

    /// Что показывает плита.
    public enum Mode: Equatable {
        /// Ссылки нет — выбрать срок и опубликовать.
        case compose
        /// Ссылка есть: показать, скопировать, открыть, снять.
        case published(URL)
    }

    /// Срок жизни ссылки — как его называет вызывающий.
    ///
    /// Плита не знает типа: перечисление сроков живёт в `ShareService`, а он в
    /// `Sources/`, куда `PropellerUI` не смотрит. Заводить здесь второе такое
    /// же перечисление значило бы завести второй ответ на вопрос «какие бывают
    /// сроки» — а их и так уже не три, как в макете, а два.
    public struct Lifetime: Identifiable, Equatable {
        public let id: String
        public let title: String
        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    private let mode: Mode
    @Binding private var lifetime: String
    private let lifetimes: [Lifetime]
    /// Почему кнопка публикации не нажимается. `nil` — нажимается.
    private let obstacle: SharePlateState.Obstacle?
    /// Идёт публикация или снятие: обе кнопки замирают, чтобы второе нажатие
    /// не завело вторую ссылку.
    private let isBusy: Bool
    /// То, что заранее не увидишь: ответ сервера, оборванная сеть.
    private let failure: String?
    private let preview: SharedSummaryPreview.Model
    private let onPublish: () -> Void
    private let onCopy: () -> Void
    private let onOpen: () -> Void
    private let onUnpublish: () -> Void
    private let onClose: () -> Void

    public init(
        mode: Mode,
        lifetime: Binding<String>,
        lifetimes: [Lifetime],
        obstacle: SharePlateState.Obstacle? = nil,
        isBusy: Bool = false,
        failure: String? = nil,
        preview: SharedSummaryPreview.Model,
        onPublish: @escaping () -> Void = {},
        onCopy: @escaping () -> Void = {},
        onOpen: @escaping () -> Void = {},
        onUnpublish: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {}
    ) {
        self.mode = mode
        self._lifetime = lifetime
        self.lifetimes = lifetimes
        self.obstacle = obstacle
        self.isBusy = isBusy
        self.failure = failure
        self.preview = preview
        self.onPublish = onPublish
        self.onCopy = onCopy
        self.onOpen = onOpen
        self.onUnpublish = onUnpublish
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Share.blockGap) {
            header
            switch mode {
            case .compose: composeBody
            case .published(let url): publishedBody(url)
            }
        }
        .frame(width: Tokens.Share.width)
        .background(
            Tokens.Share.plate,
            in: RoundedRectangle(cornerRadius: Tokens.Share.radius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Share.radius, style: .continuous)
                .strokeBorder(Tokens.Share.plateBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Share.radius, style: .continuous))
    }

    // MARK: - Шапка

    private var header: some View {
        HStack(spacing: 0) {
            Text(title)
                .typo(Tokens.Share.Typo.title)
                .foregroundStyle(Tokens.Share.title)
                // Боксы названы макетом, а не выведены из шрифта: плита
                // собрана из отступов, и лишняя точка в каждой строке
                // складывается в чужую высоту. Та же ловушка, что у заголовка
                // страницы настроек и у имени встречи в панели.
                .frame(height: Tokens.Share.Typo.title.lineHeight, alignment: .leading)
            Spacer(minLength: Tokens.Share.rowGap)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: Tokens.Share.iconSize, weight: .regular))
                    .foregroundStyle(Tokens.Share.quiet)
                    .frame(width: Tokens.Share.linkIconWidth, height: Tokens.Share.linkIconWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Закрыть")
        }
        .padding(.top, Tokens.Share.padding)
        .padding(.horizontal, Tokens.Share.padding)
    }

    private var title: String {
        switch mode {
        case .compose: return "Поделиться ссылкой"
        case .published: return "Опубликовано"
        }
    }

    // MARK: - Ещё не опубликовано

    private var composeBody: some View {
        VStack(alignment: .leading, spacing: Tokens.Share.bodyGap) {
            SharedSummaryPreview(model: preview)
                .frame(height: Tokens.Share.previewHeight)
                .padding(.horizontal, Tokens.Share.padding)

            lifetimeRow
                .padding(.horizontal, Tokens.Share.padding)

            VStack(spacing: Tokens.Share.bodyGap) {
                action("Опубликовать", enabled: obstacle == nil && !isBusy, action: onPublish)
                    .padding(.horizontal, Tokens.Share.padding)
                footnote
                    .padding(.horizontal, Tokens.Share.padding)
            }
            .padding(.bottom, Tokens.Share.padding)
        }
    }

    private var lifetimeRow: some View {
        HStack(spacing: Tokens.Share.rowGap) {
            VStack(alignment: .leading, spacing: Tokens.Share.rowLineGap) {
                Text("Срок жизни ссылки")
                    .typo(Tokens.Share.Typo.row)
                    .foregroundStyle(Tokens.Share.rowTitle)
                    .frame(height: Tokens.Share.Typo.row.lineHeight, alignment: .leading)
                Text("Через сколько исчезнет")
                    .typo(Tokens.Share.Typo.quiet)
                    .foregroundStyle(Tokens.Share.quiet)
                    .frame(height: Tokens.Share.Typo.quiet.lineHeight, alignment: .leading)
            }
            Spacer(minLength: Tokens.Share.rowGap)
            SettingsMenu(
                selection: $lifetime,
                options: lifetimes.map { .init($0.id, $0.title) }
            )
            .disabled(isBusy)
        }
        .frame(height: Tokens.Share.rowHeight)
        .padding(.vertical, Tokens.Share.rowVPadding)
    }

    /// Подпись под кнопкой: причина, почему не нажимается, ответ сервера — или
    /// обещание того, что произойдёт. Одно место, а не три: человек смотрит
    /// сюда один раз, и там должно стоять самое важное на этот момент.
    private var footnote: some View {
        Text(failure ?? obstacle?.reason ?? "Будет доступно для просмотра всем,\nкому дадите ссылку")
            .typo(Tokens.Share.Typo.quiet)
            .multilineTextAlignment(.center)
            .foregroundStyle(failure == nil ? Tokens.Share.quiet : Tokens.Paint.Status.destructive)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: Tokens.Share.footnoteHeight)
            .frame(height: Tokens.Share.footnoteHeight)
    }

    // MARK: - Уже опубликовано

    private func publishedBody(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Share.bodyGap) {
            linkRow(url)
                .padding(.horizontal, Tokens.Share.padding)

            VStack(spacing: Tokens.Share.footerGap) {
                action("Перейти по ссылке", enabled: !isBusy, action: onOpen)
                quietAction("Снять с публикации", action: onUnpublish)
            }
            .padding(.horizontal, Tokens.Share.padding)

            if failure != nil {
                footnote.padding(.horizontal, Tokens.Share.padding)
            }
        }
        .padding(.bottom, Tokens.Share.padding)
    }

    private func linkRow(_ url: URL) -> some View {
        HStack(spacing: Tokens.Share.rowGap) {
            Image(systemName: "link")
                .font(.system(size: Tokens.Share.iconSize, weight: .regular))
                .foregroundStyle(Tokens.Share.quiet)
                .frame(width: Tokens.Share.linkIconWidth)
            // Ссылка длиннее строки — не многоточие, а затухание: у ссылки
            // важен её конец не меньше начала, и «…» соврало бы, что там
            // что-то отрезано ровно на этом знаке.
            Text(shown(url))
                .typo(Tokens.Share.Typo.row)
                .foregroundStyle(Tokens.Share.linkText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: Tokens.Share.linkFadeStart),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
            Button(action: onCopy) {
                Text("Скопировать")
                    .typo(Tokens.Share.Typo.row)
                    .foregroundStyle(Tokens.Share.linkText)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Tokens.Share.controlHPadding)
        .padding(.vertical, Tokens.Share.linkVPadding)
        .frame(height: Tokens.Share.controlHeight)
        .background(
            Tokens.Share.linkFill,
            in: RoundedRectangle(cornerRadius: Tokens.Share.controlRadius, style: .continuous)
        )
    }

    /// Ссылка без схемы: `https://` в узкой строке занимает место и не несёт
    /// ничего — человек проверяет по домену и хвосту.
    private func shown(_ url: URL) -> String {
        var text = url.absoluteString
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        return text
    }

    // MARK: - Кнопки

    private func action(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .typo(Tokens.Share.Typo.action)
                .foregroundStyle(enabled ? Tokens.Share.actionLabel : Tokens.Share.actionDisabledLabel)
                .frame(maxWidth: .infinity)
                .frame(height: Tokens.Share.controlHeight)
                .background(
                    enabled ? Tokens.Share.actionFill : Tokens.Share.actionDisabledFill,
                    in: RoundedRectangle(cornerRadius: Tokens.Share.controlRadius, style: .continuous)
                )
                .contentShape(
                    RoundedRectangle(cornerRadius: Tokens.Share.controlRadius, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func quietAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .typo(Tokens.Share.Typo.action)
                .foregroundStyle(Tokens.Share.quiet)
                .frame(maxWidth: .infinity)
                .frame(height: Tokens.Share.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }
}

/// Что увидит открывший ссылку — коротко, на самой плите.
///
/// В макете здесь снимок страницы. Снимка у нас нет и делать его ради превью
/// дорого; вместо него — настоящее начало саммари тем же порядком, что и на
/// странице: имя встречи, строка атрибутов, первые строки текста. Это не
/// картинка того, что будет, а то же самое, только меньше, — и врать ему
/// нечем.
public struct SharedSummaryPreview: View {

    public struct Model: Equatable {
        public let title: String
        public let meta: String
        public let lines: [String]

        public init(title: String, meta: String, lines: [String]) {
            self.title = title
            self.meta = meta
            self.lines = lines
        }
    }

    private let model: Model

    public init(model: Model) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Share.rowLineGap * 2) {
            Text(model.title)
                .typo(Tokens.Share.Typo.row)
                .foregroundStyle(Tokens.Share.title)
                .lineLimit(1)
            if !model.meta.isEmpty {
                Text(model.meta)
                    .typo(Tokens.Share.Typo.quiet)
                    .foregroundStyle(Tokens.Share.quiet)
            }
            ForEach(Array(model.lines.enumerated()), id: \.offset) { line in
                Text(line.element)
                    .typo(Tokens.Share.Typo.quiet)
                    .foregroundStyle(Tokens.Share.linkText)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Share.controlHPadding)
        .background(
            Tokens.Share.linkFill,
            in: RoundedRectangle(cornerRadius: Tokens.Share.previewRadius, style: .continuous)
        )
        // Низ уходит в ничто: превью показывает начало, а не обрезанный кусок.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0.72),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
    }
}
