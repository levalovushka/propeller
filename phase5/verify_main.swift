import Foundation

/// Stub so Preferences.swift compiles without the full PeopleStore.
enum PeopleStore {
    static let defaultAutoMatchThreshold: Float = 0.55
}

@main
struct VerifyRecap {
    static func main() async {
        func fail(_ msg: String) -> Never {
            fputs("FAIL: \(msg)\n", stderr)
            exit(1)
        }
        func ok(_ msg: String) { print("OK \(msg)") }

        let service = RecapService.shared

        // 1) Skip when provider off / no backend
        switch await service.resolveBackend(kind: .off, openAIKey: nil, claudeKey: nil) {
        case .failure(.disabled): ok("skip: disabled")
        default: fail("expected disabled")
        }

        switch await service.resolveBackend(kind: .auto, openAIKey: nil, claudeKey: nil) {
        case .failure(.noProvider): ok("skip: auto with no provider")
        case .success(let name):
            // Ollama might be up on the machine
            ok("auto resolved to \(name) (live)")
        default:
            fail("unexpected auto resolve")
        }

        switch await service.resolveBackend(kind: .openai, openAIKey: nil, claudeKey: nil) {
        case .failure(.noProvider): ok("skip: openai without key")
        default: fail("expected openai noProvider")
        }

        switch await service.resolveBackend(kind: .claude, openAIKey: nil, claudeKey: "sk-test") {
        case .success("claude"): ok("resolve: claude with key")
        default: fail("expected claude success")
        }

        // 2) End-to-end generate via mock Ollama if port free, else skip live generate
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase5-recap-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let transcriptPath = tmp.appendingPathComponent("rec-1-sprint-sync.md")
        let transcript = """
        # Sprint sync

        **Participants:** Alice, Bob

        ## Transcript

        **Alice** · 00:12
        Давайте закроем тикет по API и назначим владельца.

        **Bob** · 00:45
        Беру на себя, сделаю к пятнице.
        """
        try! transcript.write(to: transcriptPath, atomically: true, encoding: .utf8)

        // Empty transcript skip
        let empty = try! await service.generateRecap(
            title: "x",
            transcriptMarkdown: "  ",
            transcriptPath: transcriptPath.path,
            notes: nil,
            speakers: [],
            duration: 60,
            recordingID: "rec-1",
            prefs: RecapPreferences(
                provider: .auto,
                prompt: RecapService.defaultPrompt,
                ollamaModel: "llama3.2",
                openAIModel: "gpt-4o-mini",
                claudeModel: "claude-sonnet-4-5",
                openAIKey: nil,
                claudeKey: nil,
                outputFormat: .simple
            )
        )
        if case .failure(.emptyTranscript) = empty { ok("skip: empty transcript") }
        else { fail("expected emptyTranscript") }

        // No provider → skip, no throw
        let skipped = try! await service.generateRecap(
            title: "Sprint sync",
            transcriptMarkdown: transcript,
            transcriptPath: transcriptPath.path,
            notes: "Личная пометка",
            speakers: ["Alice", "Bob"],
            duration: 1800,
            recordingID: "rec-1",
            prefs: RecapPreferences(
                provider: .auto,
                prompt: RecapService.defaultPrompt,
                ollamaModel: "llama3.2",
                openAIModel: "gpt-4o-mini",
                claudeModel: "claude-sonnet-4-5",
                openAIKey: nil,
                claudeKey: nil,
                outputFormat: .simple
            )
        )
        switch skipped {
        case .failure(.noProvider):
            ok("generate skips when no Ollama/API")
        case .success(let r):
            ok("generate succeeded via \(r.provider) (live provider present)")
            assertNotesPreserved(r.body)
        case .failure(let reason):
            fail("unexpected skip \(reason)")
        }

        // Live OpenAI if key in env
        if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty {
            do {
                let live = try await service.generateRecap(
                    title: "Sprint sync",
                    transcriptMarkdown: transcript,
                    transcriptPath: transcriptPath.path,
                    notes: "Личная пометка",
                    speakers: ["Alice", "Bob"],
                    duration: 1800,
                    recordingID: "rec-1",
                    prefs: RecapPreferences(
                        provider: .openai,
                        prompt: RecapService.defaultPrompt,
                        ollamaModel: "llama3.2",
                        openAIModel: "gpt-4o-mini",
                        claudeModel: "claude-sonnet-4-5",
                        openAIKey: key,
                        claudeKey: nil,
                        outputFormat: .simple
                    )
                )
                switch live {
                case .success(let r):
                    ok("live OpenAI recap → \(r.path)")
                    assertNotesPreserved(r.body)
                    try? FileManager.default.copyItem(
                        at: URL(fileURLWithPath: r.path),
                        to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                            .appendingPathComponent("samples/openai-recap.md")
                    )
                case .failure(let reason):
                    fail("OpenAI skipped unexpectedly: \(reason)")
                }
            } catch {
                fail("OpenAI error: \(error)")
            }
        } else {
            ok("OpenAI live test skipped (no OPENAI_API_KEY)")
        }

        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty {
            do {
                let live = try await service.generateRecap(
                    title: "Sprint sync",
                    transcriptMarkdown: transcript,
                    transcriptPath: transcriptPath.path,
                    notes: "Личная пометка",
                    speakers: ["Alice", "Bob"],
                    duration: 1800,
                    recordingID: "rec-1",
                    prefs: RecapPreferences(
                        provider: .claude,
                        prompt: RecapService.defaultPrompt,
                        ollamaModel: "llama3.2",
                        openAIModel: "gpt-4o-mini",
                        claudeModel: "claude-sonnet-4-5",
                        openAIKey: nil,
                        claudeKey: key,
                        outputFormat: .simple
                    )
                )
                switch live {
                case .success(let r):
                    ok("live Claude recap → \(r.path)")
                    assertNotesPreserved(r.body)
                case .failure(let reason):
                    fail("Claude skipped unexpectedly: \(reason)")
                }
            } catch {
                fail("Claude error: \(error)")
            }
        } else {
            ok("Claude live test skipped (no ANTHROPIC_API_KEY)")
        }

        print("ALL PASS")
    }

    static func assertNotesPreserved(_ body: String) {
        if !body.contains("## Заметки") || !body.contains("Личная пометка") {
            fputs("FAIL: notes block missing or rewritten\n\(body)\n", stderr)
            exit(1)
        }
        print("OK notes preserved verbatim")
    }
}
