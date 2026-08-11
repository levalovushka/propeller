import SwiftUI
import PropellerPure
import PropellerUI

/// Command-palette search (⌘K) — glass plate matching Figma Meetings chrome.
struct SearchPalette: View {
    @ObservedObject var state: AppState
    let onOpenRecording: (RecordingEntry) -> Void
    let onClose: () -> Void

    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var highlightedIndex = 0
    @FocusState private var fieldFocused: Bool

    /// Архив в виде, по которому ищут. Строится один раз при открытии палитры —
    /// это единственное место, где читается диск.
    ///
    /// Раньше и поиск, и чтение файлов конспектов жили в вычисляемом свойстве,
    /// которое `body` спрашивал шесть-семь раз за проход: три чипа фильтра,
    /// `items`, `groupedItems` через него и дважды `items.count`. На архиве из 29
    /// встреч это около двухсот файловых чтений и **281 мс на один проход** — и не
    /// только на нажатие клавиши, а на любое изменение `AppState`, которых во
    /// время записи двадцать в секунду.
    @State private var documents: [ArchiveSearch.Document] = []
    @State private var entriesByID: [String: RecordingEntry] = [:]
    /// Что нашлось. Пересчитывается на изменение запроса, а не на отрисовку.
    @State private var hits: [ArchiveSearch.Hit] = []

    enum Filter: String, CaseIterable, Identifiable {
        case all = "Все"
        case meetings = "Встречи"
        case transcripts = "Транскрипты"
        var id: String { rawValue }
    }

    private struct RecordingMatch {
        let entry: RecordingEntry
        let snippet: ArchiveSearch.Snippet?
        let matchCount: Int
        let inText: Bool
    }

    private enum Item: Identifiable {
        case recording(RecordingMatch)
        case startRecording

        var id: String {
            switch self {
            case .recording(let m): return "rec-\(m.entry.id)"
            case .startRecording: return "action-record"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Tokens.Ink.quaternary)
                TextField("Поиск встреч и транскриптов…", text: $query)
                    .textFieldStyle(.plain)
                    .typo(Tokens.Typography.Label.mdMedium)
                    .foregroundStyle(Tokens.Ink.primary)
                    .focused($fieldFocused)
                    .onSubmit { activate(highlightedIndex) }
                Text("esc")
                    .typo(Tokens.Typography.Label.xsMedium)
                    .foregroundStyle(Tokens.Ink.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Tokens.Paint.Bg.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.xxxs, style: .continuous))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            HStack(spacing: 6) {
                ForEach(Filter.allCases) { f in
                    let count = count(for: f)
                    let selected = filter == f
                    Button {
                        filter = f
                        highlightedIndex = 0
                    } label: {
                        Text("\(f.rawValue) \(count)")
                            .typo(selected ? Tokens.Typography.Label.smMedium : Tokens.Typography.Label.smMedium)
                            .foregroundStyle(selected ? Tokens.Ink.primary : Tokens.Ink.quaternary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(selected ? Tokens.Neutral.aw12 : Tokens.Paint.Bg.surface)
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Rectangle()
                .fill(Tokens.Paint.Bg.surface)
                .frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let sections = groupedItems
                        ForEach(sections, id: \.0) { title, sectionItems in
                            Text(title)
                                .typo(Tokens.Typography.Label.xsMedium)
                                .foregroundStyle(Tokens.Ink.tertiary)
                                .textCase(.uppercase)
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                                .padding(.bottom, 4)

                            // Строка опознаётся собой, а не своим номером — и в
                            // `ForEach`, и в `.id()` для прокрутки.
                            //
                            // Номер здесь не идентификатор: секций две, номера в
                            // них общие, и `.id(0)` существовал сразу в обеих —
                            // в «Недавних» и в «Действиях». SwiftUI брал первую
                            // найденную, и первая встреча выходила нарисованной
                            // как «Записать». Раньше это не всплывало только
                            // потому, что список считался прямо в `body` и к
                            // первому проходу уже был полным.
                            ForEach(sectionItems, id: \.1.id) { flatIndex, item in
                                itemRow(item, highlighted: flatIndex == highlightedIndex)
                                    .id(item.id)
                                    .onTapGesture { activate(flatIndex) }
                                    .onHover { inside in
                                        if inside { highlightedIndex = flatIndex }
                                    }
                            }
                        }

                        if items.isEmpty {
                            Text("Ничего не найдено")
                                .typo(Tokens.Typography.Label.mdMedium)
                                .foregroundStyle(Tokens.Ink.tertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 28)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .onChange(of: highlightedIndex) { _, idx in
                    guard items.indices.contains(idx) else { return }
                    proxy.scrollTo(items[idx].id, anchor: nil)
                }
            }
            .frame(maxHeight: 380)

            Rectangle()
                .fill(Tokens.Paint.Bg.surface)
                .frame(height: 1)

            HStack(spacing: 12) {
                hint("↑↓", "навигация")
                hint("↵", "открыть")
                Spacer()
                Text(Self.resultCountLabel(items.count))
                    .typo(Tokens.Typography.Label.xsMedium)
                    .foregroundStyle(Tokens.Ink.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 560)
        .background {
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .fill(Color(nsColor: Tokens.Glass.fill))
        }
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
        .onAppear {
            fieldFocused = true
            buildIndex()
        }
        .onChange(of: query) { _, _ in refreshHits() }
        // Встреча могла закончиться, пока палитра открыта: тогда индекс её не
        // знает. Перестраивается по числу записей, а не по каждому изменению
        // хранилища — иначе вернулись бы к пересчёту на каждый тик записи.
        .onChange(of: state.recordingStore.recordings.count) { _, _ in buildIndex() }
        .onKeyPress(.downArrow) {
            if highlightedIndex < items.count - 1 { highlightedIndex += 1 }
            return .handled
        }
        .onKeyPress(.upArrow) {
            if highlightedIndex > 0 { highlightedIndex -= 1 }
            return .handled
        }
        .onExitCommand { onClose() }
    }

    // MARK: - Data

    /// Плоский список найденного. Читает только уже посчитанное — ни диска, ни
    /// поиска: их место в `refreshHits()`.
    private var matchedRecordings: [RecordingMatch] {
        hits.compactMap { hit in
            guard let entry = entriesByID[hit.id] else { return nil }
            return RecordingMatch(
                entry: entry, snippet: hit.snippet,
                matchCount: hit.matchCount, inText: hit.inText
            )
        }
    }

    /// Собрать архив для поиска. Единственное место, где читаются файлы
    /// конспектов, и происходит это на открытии палитры.
    private func buildIndex() {
        let recordings = state.recordingStore.recordings
        entriesByID = Dictionary(uniqueKeysWithValues: recordings.map { ($0.id, $0) })
        documents = recordings.map { entry in
            var bodies = [entry.transcript, entry.notes].compactMap { $0 }
            if let recap = AppState.loadRecapText(for: entry) { bodies.append(recap) }
            return ArchiveSearch.Document(
                id: entry.id, title: entry.title, dateLabel: entry.dateFormatted, bodies: bodies
            )
        }
        refreshHits()
    }

    private func refreshHits() {
        hits = ArchiveSearch.run(query: query, over: documents)
        highlightedIndex = 0
    }

    /// Подсветка собирается здесь, а не в поиске: шрифты и цвета живут во вьюхе.
    private static func attributed(_ snippet: ArchiveSearch.Snippet) -> AttributedString {
        var result = AttributedString(snippet.prefix)
        var highlighted = AttributedString(snippet.match)
        highlighted.font = Tokens.Typography.Label.smMedium.font
        highlighted.foregroundColor = Tokens.Ink.primary
        result += highlighted
        result += AttributedString(snippet.suffix)
        return result
    }

    private func count(for f: Filter) -> Int {
        switch f {
        case .all, .meetings: return hits.count
        case .transcripts: return hits.filter(\.inText).count
        }
    }

    private var items: [Item] {
        var result: [Item] = []
        switch filter {
        case .all, .meetings:
            result += matchedRecordings.map { .recording($0) }
        case .transcripts:
            result += matchedRecordings.filter(\.inText).map { .recording($0) }
        }
        result.append(.startRecording)
        return result
    }

    private var groupedItems: [(String, [(Int, Item)])] {
        var sections: [(String, [(Int, Item)])] = []
        var recordings: [(Int, Item)] = []
        var actions: [(Int, Item)] = []
        for (i, item) in items.enumerated() {
            switch item {
            case .recording: recordings.append((i, item))
            case .startRecording: actions.append((i, item))
            }
        }
        if !recordings.isEmpty {
            sections.append((query.isEmpty ? "Недавние" : "Записи", recordings))
        }
        if !actions.isEmpty { sections.append(("Действия", actions)) }
        return sections
    }

    // MARK: - Rows

    @ViewBuilder
    private func itemRow(_ item: Item, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            switch item {
            case .recording(let match):
                let entry = match.entry
                Image(systemName: "mic")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Tokens.Ink.quaternary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.title.isEmpty ? "Без названия" : entry.title)
                            .typo(Tokens.Typography.Label.mdMedium)
                            .foregroundStyle(Tokens.Ink.primary)
                            .lineLimit(1)
                        if match.matchCount > 1 {
                            Text("\(match.matchCount) совп.")
                                .typo(Tokens.Typography.Label.xsMedium)
                                .foregroundStyle(Tokens.Ink.quaternary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Tokens.Paint.Bg.surface, in: Capsule())
                        }
                    }
                    HStack(spacing: 4) {
                        Text(entry.dateFormatted)
                        if entry.duration > 0 { Text("·"); Text(entry.durationFormatted) }
                    }
                    .typo(Tokens.Typography.Label.smMedium)
                    .foregroundStyle(Tokens.Ink.quaternary)
                    if let snippet = match.snippet {
                        Text(Self.attributed(snippet))
                            .typo(Tokens.Typography.Label.smRegular)
                            .foregroundStyle(Tokens.Ink.quaternary)
                            .lineLimit(2)
                    }
                }
            case .startRecording:
                Image(systemName: "record.circle")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color.red.opacity(0.9))
                    .frame(width: 20)
                Text("Записать")
                    .typo(Tokens.Typography.Label.mdMedium)
                    .foregroundStyle(Tokens.Ink.primary)
            }
            Spacer(minLength: 0)
            if highlighted {
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(Tokens.Ink.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                .fill(highlighted ? Tokens.Paint.Bg.surface : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .typo(Tokens.Typography.Label.xsMedium)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Tokens.Paint.Bg.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.xxxxs, style: .continuous))
                .foregroundStyle(Tokens.Neutral.aw50)
            Text(label)
                .typo(Tokens.Typography.Label.xsMedium)
                .foregroundStyle(Tokens.Ink.tertiary)
        }
    }

    private static func resultCountLabel(_ count: Int) -> String {
        let mod100 = count % 100
        let mod10 = count % 10
        let word: String
        if (11...14).contains(mod100) {
            word = "результатов"
        } else if mod10 == 1 {
            word = "результат"
        } else if (2...4).contains(mod10) {
            word = "результата"
        } else {
            word = "результатов"
        }
        return "\(count) \(word)"
    }

    // MARK: - Activation

    private func activate(_ index: Int) {
        guard items.indices.contains(index) else { return }
        switch items[index] {
        case .recording(let match):
            onOpenRecording(match.entry)
        case .startRecording:
            onClose()
            state.startRecording()
        }
    }
}
