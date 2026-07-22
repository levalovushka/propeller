import Foundation
import AppKit

@main
struct VerifyMarkdown {
    static func main() throws {
        let sample = """
        [Alice] [00:12]
        Hello everyone

        [Bob] [00:45]
        Hi Alice
        """

        func fail(_ msg: String) -> Never {
            fputs("FAIL: \(msg)\n", stderr)
            exit(1)
        }
        func ok(_ msg: String) { print("OK \(msg)") }

        let simple = MarkdownWriter.render(
            title: "Sprint sync",
            transcript: sample,
            recordingID: "rec-1",
            duration: 1800,
            speakers: ["Alice", "Bob"],
            notes: "Follow up on API",
            format: .simple
        )

        if !simple.hasPrefix("# Sprint sync") { fail("simple missing H1") }
        if simple.contains("---\n") { fail("simple should not have YAML fence") }
        if simple.contains("[[") { fail("simple should not have wikilinks") }
        if !simple.contains("**Participants:** Alice, Bob") { fail("simple missing participants") }
        if !simple.contains("**Alice** · 00:12") { fail("simple missing speaker line") }
        if !simple.contains("## Notes") { fail("simple missing notes") }
        ok("simple format")

        let obsidian = MarkdownWriter.render(
            title: "Sprint sync",
            transcript: sample,
            recordingID: "rec-1",
            duration: 1800,
            speakers: ["Alice", "Bob"],
            notes: "Follow up on API",
            format: .obsidian
        )

        if !obsidian.hasPrefix("---") { fail("obsidian missing YAML") }
        if !obsidian.contains("title: \"Sprint sync\"") { fail("obsidian missing title") }
        if !obsidian.contains("speakers: [\"Alice\", \"Bob\"]") { fail("obsidian missing speakers") }
        if !obsidian.contains("[Alice] [00:12]") { fail("obsidian should keep raw transcript labels") }
        if obsidian.contains("**Alice** ·") { fail("obsidian should not use simple speaker formatting") }
        ok("obsidian format")

        let chat = MarkdownWriter.chatClipboardText(
            title: "Sprint sync",
            transcript: sample,
            duration: 1800
        )
        if chat.contains("---\n") { fail("chat clipboard should be simple") }
        if !chat.contains("**Alice** · 00:12") { fail("chat clipboard missing formatted speaker") }
        ok("chat clipboard")

        let outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("samples")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try simple.write(to: outDir.appendingPathComponent("simple.md"), atomically: true, encoding: .utf8)
        try obsidian.write(to: outDir.appendingPathComponent("obsidian.md"), atomically: true, encoding: .utf8)
        print("Wrote \(outDir.path)/{simple,obsidian}.md")
        print("ALL PASS")
    }
}

/// Stub so Preferences.swift compiles without the full PeopleStore.
enum PeopleStore {
    static let defaultAutoMatchThreshold: Float = 0.55
}
