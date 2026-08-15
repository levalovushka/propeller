import XCTest
@testable import PropellerPure

/// The rule that keeps a backfill from growing an 8 GB resident: the serve
/// process the app spawns must carry the env that turns the runner's prompt
/// cache off, and must never overwrite what the sidecar already decided.
final class OllamaServeTuningTests: XCTestCase {

    func testБэкфиллНеКопитКэшПромптов() {
        // The whole fix is this one pair: llama.cpp reads LLAMA_ARG_CACHE_RAM
        // as the default for --cache-ram, and 0 disables retention outright.
        // Г4 2026-08-15: retention grew 5,2 → 10,2 ГБ over 12 meetings.
        XCTAssertEqual(OllamaServeTuning.extraEnvironment["LLAMA_ARG_CACHE_RAM"], "0")
    }

    func testТюнингНеСпоритСАдресомСервера() {
        // The sidecar's own keys are the ones a wrong value would break loudly
        // (server on the wrong port) or quietly (models pulled to ~/.ollama).
        let base = [
            "OLLAMA_HOST": "127.0.0.1:11434",
            "OLLAMA_MODELS": "/tmp/models",
            "DYLD_LIBRARY_PATH": "/tmp/libs",
        ]
        let env = OllamaServeTuning.apply(to: base)
        XCTAssertEqual(env["OLLAMA_HOST"], "127.0.0.1:11434")
        XCTAssertEqual(env["OLLAMA_MODELS"], "/tmp/models")
        XCTAssertEqual(env["DYLD_LIBRARY_PATH"], "/tmp/libs")
        XCTAssertEqual(env["LLAMA_ARG_CACHE_RAM"], "0")
    }

    func testЯвноВыставленноеСнаружиЗначениеВыигрывает() {
        // An operator who sets the var in the app's environment on purpose
        // (say, to re-measure with the cache on) must win over the default.
        let env = OllamaServeTuning.apply(to: ["LLAMA_ARG_CACHE_RAM": "8192"])
        XCTAssertEqual(env["LLAMA_ARG_CACHE_RAM"], "8192")
    }
}
