import Foundation

/// The name a meeting carries before anyone has given it one.
///
/// Three places used to know this rule separately: the one that writes the
/// placeholder, the one that asks the LLM for a real title only when the current
/// one is a placeholder, and the one that clears a stale «renamed by hand» flag.
/// Two of them spelled the two prefixes out inline. Change the wording in the
/// writer and both readers stop matching — silently, and the symptom is
/// meetings that never get titled, which nobody traces back to a string.
public enum MeetingTitle {

    /// What the app writes when the calendar has nothing to offer. The stamp is
    /// locale-dependent, so it arrives already formatted; the prefix is the part
    /// that has to stay in one place.
    public static let placeholderPrefix = "Запись "

    /// Kept for titles written before the interface spoke Russian. A person's
    /// archive outlives a wording decision, so a stale prefix is never dropped.
    public static let legacyPlaceholderPrefix = "Recording "

    public static func placeholder(stamp: String) -> String {
        "\(placeholderPrefix)\(stamp)"
    }

    /// Whether this title is one the app made up rather than one somebody chose.
    ///
    /// The prefix alone is not proof of anything: a person who renames a meeting
    /// to «Запись про бюджет» matches it. Callers that can be overruled by a
    /// human — the LLM rename — must check the manual-rename latch too, and the
    /// latch wins.
    public static func isPlaceholder(_ title: String) -> Bool {
        title.hasPrefix(placeholderPrefix) || title.hasPrefix(legacyPlaceholderPrefix)
    }
}
