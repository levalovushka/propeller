import SwiftUI

/// Command-palette style search (⌘K), talat-like: query field, filter chips,
/// recordings / people / transcript matches, and quick actions.
struct SearchPalette: View {
    @ObservedObject var state: AppState
    let onOpenRecording: (RecordingEntry) -> Void
    let onOpenPerson: (Person) -> Void
    let onClose: () -> Void

    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var highlightedIndex = 0
    @FocusState private var fieldFocused: Bool

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case meetings = "Meetings"
        case people = "People"
        case transcripts = "Transcripts"
        var id: String { rawValue }
    }

    /// A recording matched by full-text search, with context around the hit.
    private struct RecordingMatch {
        let entry: RecordingEntry
        /// Snippet around the first text match (transcript or notes), with the
        /// query occurrence highlighted. Nil when the match is title/date-only.
        let snippet: AttributedString?
        /// Number of occurrences across transcript + notes.
        let matchCount: Int
        /// True when the query was found in the transcript/notes text.
        let inText: Bool
    }

    private enum Item: Identifiable {
        case recording(RecordingMatch)
        case person(Person)
        case startRecording

        var id: String {
            switch self {
            case .recording(let m): return "rec-\(m.entry.id)"
            case .person(let p): return "person-\(p.id.uuidString)"
            case .startRecording: return "action-record"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Query field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search meetings and transcripts…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { activate(highlightedIndex) }
                Text("esc")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Filter chips
            HStack(spacing: 6) {
                ForEach(Filter.allCases) { f in
                    let count = count(for: f)
                    Button {
                        filter = f
                        highlightedIndex = 0
                    } label: {
                        Text("\(f.rawValue) \(count)")
                            .font(.caption.weight(filter == f ? .semibold : .regular))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                filter == f ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.4)),
                                in: Capsule()
                            )
                            .foregroundStyle(filter == f ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()

            // Results
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let sections = groupedItems
                        ForEach(sections, id: \.0) { title, sectionItems in
                            Text(title)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.tertiary)
                                .textCase(.uppercase)
                                .padding(.horizontal, 16)
                                .padding(.top, 10)
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
                            Text("No results")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .onChange(of: highlightedIndex) { _, idx in
                    proxy.scrollTo(idx, anchor: nil)
                }
            }
            .frame(maxHeight: 380)

            Divider()

            // Footer hints
            HStack(spacing: 12) {
                hint("↑↓", "navigate")
                hint("↵", "open")
                Spacer()
                Text("\(items.count) result\(items.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 560)
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

            // Full-text: transcript + notes of every recording.
            var snippet: AttributedString?
            var count = 0
            for text in [rec.transcript, rec.notes].compactMap({ $0 }) {
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

    /// Context snippet around the first occurrence: ~50 chars each side,
    /// newlines collapsed, the match itself bolded.
    private static func snippet(around needle: String, in haystack: String) -> AttributedString? {
        guard let r = haystack.range(of: needle, options: matchOptions) else { return nil }
        let contextChars = 50

        var start = haystack.index(r.lowerBound, offsetBy: -contextChars, limitedBy: haystack.startIndex) ?? haystack.startIndex
        var end = haystack.index(r.upperBound, offsetBy: contextChars, limitedBy: haystack.endIndex) ?? haystack.endIndex
        // Snap to word boundaries so the snippet doesn't cut words in half.
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
        highlighted.font = .caption.weight(.bold)
        highlighted.foregroundColor = .primary
        result += highlighted
        result += AttributedString(suffix.isEmpty ? "" : " " + suffix)
        return result
    }

    private var matchedPeople: [Person] {
        let people = state.peopleStore.people
        if query.isEmpty { return [] }
        return people.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func count(for f: Filter) -> Int {
        switch f {
        case .all: return matchedRecordings.count + matchedPeople.count
        case .meetings: return matchedRecordings.count
        case .people: return matchedPeople.count
        case .transcripts: return matchedRecordings.filter { $0.inText }.count
        }
    }

    private var items: [Item] {
        var result: [Item] = []
        switch filter {
        case .all:
            result += matchedRecordings.map { .recording($0) }
            result += matchedPeople.map { .person($0) }
        case .meetings:
            result += matchedRecordings.map { .recording($0) }
        case .people:
            result += matchedPeople.map { .person($0) }
        case .transcripts:
            result += matchedRecordings.filter { $0.inText }.map { .recording($0) }
        }
        result.append(.startRecording)
        return result
    }

    /// Items grouped into titled sections, each entry carrying its flat index
    /// so keyboard highlight works across sections.
    private var groupedItems: [(String, [(Int, Item)])] {
        var sections: [(String, [(Int, Item)])] = []
        var recordings: [(Int, Item)] = []
        var people: [(Int, Item)] = []
        var actions: [(Int, Item)] = []
        for (i, item) in items.enumerated() {
            switch item {
            case .recording: recordings.append((i, item))
            case .person: people.append((i, item))
            case .startRecording: actions.append((i, item))
            }
        }
        if !recordings.isEmpty {
            sections.append((query.isEmpty ? "Recent recordings" : "Recordings", recordings))
        }
        if !people.isEmpty { sections.append(("People", people)) }
        if !actions.isEmpty { sections.append(("Actions", actions)) }
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
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(entry.title.isEmpty ? "Untitled" : entry.title)
                            .lineLimit(1)
                        if match.matchCount > 1 {
                            Text("\(match.matchCount) matches")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary.opacity(0.5), in: Capsule())
                        }
                    }
                    HStack(spacing: 4) {
                        Text(entry.dateFormatted)
                        if entry.duration > 0 { Text("·"); Text(entry.durationFormatted) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let snippet = match.snippet {
                        Text(snippet)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            case .person(let person):
                AvatarCircle(name: person.name, size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(person.name).lineLimit(1)
                    Text("\(person.sampleCount) sample\(person.sampleCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .startRecording:
                Image(systemName: "record.circle")
                    .foregroundStyle(.red)
                    .frame(width: 20)
                Text("Start recording")
            }
            Spacer()
            if highlighted {
                Image(systemName: "return")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(highlighted ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Activation

    private func activate(_ index: Int) {
        guard items.indices.contains(index) else { return }
        switch items[index] {
        case .recording(let match):
            onOpenRecording(match.entry)
        case .person(let person):
            onOpenPerson(person)
        case .startRecording:
            onClose()
            state.startRecording()
        }
    }
}
