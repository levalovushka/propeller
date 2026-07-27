import SwiftUI
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

    enum Filter: String, CaseIterable, Identifiable {
        case all = "Все"
        case meetings = "Встречи"
        case transcripts = "Транскрипты"
        var id: String { rawValue }
    }

    private struct RecordingMatch {
        let entry: RecordingEntry
        let snippet: AttributedString?
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
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.40))
                TextField("Поиск встреч и транскриптов…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Tokens.Ink.primary)
                    .focused($fieldFocused)
                    .onSubmit { activate(highlightedIndex) }
                Text("esc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.30))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
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
                            .font(.system(size: 12, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Tokens.Ink.primary : Color.white.opacity(0.40))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(Color.white.opacity(selected ? 0.12 : 0.05))
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let sections = groupedItems
                        ForEach(sections, id: \.0) { title, sectionItems in
                            Text(title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.30))
                                .textCase(.uppercase)
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                                .padding(.bottom, 4)

                            ForEach(sectionItems, id: \.0) { flatIndex, item in
                                itemRow(item, highlighted: flatIndex == highlightedIndex)
                                    .id(flatIndex)
                                    .onTapGesture { activate(flatIndex) }
                                    .onHover { inside in
                                        if inside { highlightedIndex = flatIndex }
                                    }
                            }
                        }

                        if items.isEmpty {
                            Text("Ничего не найдено")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.30))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 28)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .onChange(of: highlightedIndex) { _, idx in
                    proxy.scrollTo(idx, anchor: nil)
                }
            }
            .frame(maxHeight: 380)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)

            HStack(spacing: 12) {
                hint("↑↓", "навигация")
                hint("↵", "открыть")
                Spacer()
                Text(Self.resultCountLabel(items.count))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.30))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 560)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: Tokens.Glass.fill))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear { fieldFocused = true }
        .onChange(of: query) { _, _ in highlightedIndex = 0 }
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

    private var matchedRecordings: [RecordingMatch] {
        let recordings = state.recordingStore.recordings
        if query.isEmpty {
            return recordings.prefix(8).map {
                RecordingMatch(entry: $0, snippet: nil, matchCount: 0, inText: false)
            }
        }
        let q = query.lowercased()
        return recordings.compactMap { rec in
            let inTitle = rec.title.lowercased().contains(q)
                || rec.dateFormatted.lowercased().contains(q)

            var snippet: AttributedString?
            var count = 0
            var texts = [rec.transcript, rec.notes].compactMap { $0 }
            if let recap = AppState.loadRecapText(for: rec) {
                texts.append(recap)
            }
            for text in texts {
                let hits = Self.occurrences(of: query, in: text)
                count += hits
                if snippet == nil, hits > 0 {
                    snippet = Self.snippet(around: query, in: text)
                }
            }

            guard inTitle || count > 0 else { return nil }
            return RecordingMatch(entry: rec, snippet: snippet, matchCount: count, inText: count > 0)
        }
    }

    private static let matchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let r = haystack.range(of: needle, options: matchOptions, range: searchRange) {
            count += 1
            searchRange = r.upperBound..<haystack.endIndex
        }
        return count
    }

    private static func snippet(around needle: String, in haystack: String) -> AttributedString? {
        guard let r = haystack.range(of: needle, options: matchOptions) else { return nil }
        let contextChars = 50

        var start = haystack.index(r.lowerBound, offsetBy: -contextChars, limitedBy: haystack.startIndex) ?? haystack.startIndex
        var end = haystack.index(r.upperBound, offsetBy: contextChars, limitedBy: haystack.endIndex) ?? haystack.endIndex
        while start > haystack.startIndex, !haystack[haystack.index(before: start)].isWhitespace {
            start = haystack.index(before: start)
        }
        while end < haystack.endIndex, !haystack[end].isWhitespace {
            end = haystack.index(after: end)
        }

        func clean(_ s: Substring) -> String {
            s.replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }

        let prefix = (start > haystack.startIndex ? "…" : "") + clean(haystack[start..<r.lowerBound])
        let match = String(haystack[r])
        let suffix = clean(haystack[r.upperBound..<end]) + (end < haystack.endIndex ? "…" : "")

        var result = AttributedString(prefix.isEmpty ? "" : prefix + " ")
        var highlighted = AttributedString(match)
        highlighted.font = .system(size: 12, weight: .semibold)
        highlighted.foregroundColor = Tokens.Ink.primary
        result += highlighted
        result += AttributedString(suffix.isEmpty ? "" : " " + suffix)
        return result
    }

    private func count(for f: Filter) -> Int {
        switch f {
        case .all, .meetings: return matchedRecordings.count
        case .transcripts: return matchedRecordings.filter(\.inText).count
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
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.40))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.title.isEmpty ? "Без названия" : entry.title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Tokens.Ink.primary)
                            .lineLimit(1)
                        if match.matchCount > 1 {
                            Text("\(match.matchCount) совп.")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.40))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.08), in: Capsule())
                        }
                    }
                    HStack(spacing: 4) {
                        Text(entry.dateFormatted)
                        if entry.duration > 0 { Text("·"); Text(entry.durationFormatted) }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.40))
                    if let snippet = match.snippet {
                        Text(snippet)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.40))
                            .lineLimit(2)
                    }
                }
            case .startRecording:
                Image(systemName: "record.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.red.opacity(0.9))
                    .frame(width: 20)
                Text("Записать")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Tokens.Ink.primary)
            }
            Spacer(minLength: 0)
            if highlighted {
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.30))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(highlighted ? 0.08 : 0))
        )
        .contentShape(Rectangle())
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                .foregroundStyle(Color.white.opacity(0.50))
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.30))
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
