import SwiftUI

/// Accessibility identifiers for Meetings chrome (visual layout tests).
public enum MeetingsChromeA11y {
    public static let record = "meetings.chrome.record"
    public static let filter = "meetings.chrome.filter"
}

/// Reports midY of chrome icon slots in the `meetingsTitle` coordinate space (layout tests).
public struct MeetingsChromeMidYKey: PreferenceKey {
    public static var defaultValue: [String: CGFloat] = [:]
    public static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Page title row for the Meetings home — Figma 640:1877.
/// Record and filter share the same `DSSize.sm` (32×32) slot so midY stays aligned.
public struct MeetingsTitleBlock: View {
    public var title: String = "Встречи"
    public var showRecord: Bool = true
    public var speakerOptions: [String] = []
    public var selectedSpeaker: String? = nil
    public var onRecord: () -> Void = {}
    public var onSelectSpeaker: (String?) -> Void = { _ in }

    public init(
        title: String = "Встречи",
        showRecord: Bool = true,
        speakerOptions: [String] = [],
        selectedSpeaker: String? = nil,
        onRecord: @escaping () -> Void = {},
        onSelectSpeaker: @escaping (String?) -> Void = { _ in }
    ) {
        self.title = title
        self.showRecord = showRecord
        self.speakerOptions = speakerOptions
        self.selectedSpeaker = selectedSpeaker
        self.onRecord = onRecord
        self.onSelectSpeaker = onSelectSpeaker
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Text(title)
                .typo(Tokens.Typography.Heading.lg)
                .foregroundStyle(Tokens.Ink.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .bottomLeading)

            if showRecord {
                IconButton(
                    systemName: "record.circle",
                    prominence: .minimal,
                    iconSize: 15,
                    weight: .medium,
                    action: onRecord
                )
                .help("Запись (⌘R)")
                .accessibilityIdentifier(MeetingsChromeA11y.record)
                .background(midYProbe(MeetingsChromeA11y.record))
            }

            MinimalIconMenu(
                systemName: "line.3.horizontal.decrease",
                iconSize: 15,
                emphasized: selectedSpeaker != nil,
                help: "Фильтр по спикеру"
            ) {
                Button("Все спикеры") { onSelectSpeaker(nil) }
                if !speakerOptions.isEmpty { Divider() }
                ForEach(speakerOptions, id: \.self) { name in
                    Button {
                        onSelectSpeaker(name)
                    } label: {
                        if selectedSpeaker == name {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            }
            .accessibilityIdentifier(MeetingsChromeA11y.filter)
            .background(midYProbe(MeetingsChromeA11y.filter))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: Tokens.Window.titleBlockHeight, alignment: .bottom)
        .coordinateSpace(name: "meetingsTitle")
    }

    private func midYProbe(_ id: String) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: MeetingsChromeMidYKey.self,
                value: [id: geo.frame(in: .named("meetingsTitle")).midY]
            )
        }
    }
}
