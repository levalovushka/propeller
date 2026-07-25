import Foundation
import PropellerPure
import SpeakerMatchingCore

@MainActor
class RecordingStore: ObservableObject {
    @Published var recordings: [RecordingEntry] = []

    private var pendingSaveWork: DispatchWorkItem?
    private let saveDebounceInterval: TimeInterval = 0.2

    private var indexURL: URL {
        URL(fileURLWithPath: Preferences.shared.recordingsPath)
            .appendingPathComponent("recordings.json")
    }

    // MARK: - Load / Save

    /// Schedule a debounced save. Multiple rapid mutations coalesce into one write.
    private func scheduleSave() {
        pendingSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.save() }
        }
        pendingSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDebounceInterval, execute: work)
    }

    /// Force-flush any pending debounced save immediately. Call on app quit.
    func flush() {
        pendingSaveWork?.cancel()
        pendingSaveWork = nil
        save()
    }

    func load() {
        let dir = URL(fileURLWithPath: Preferences.shared.recordingsPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            scanForOrphanRecordings()
            return
        }
        do {
            let data = try Data(contentsOf: indexURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            // Prefer all-or-nothing; on failure fall through to per-element recovery (C5).
            do {
                recordings = try decoder.decode([RecordingEntry].self, from: data)
            } catch {
                // One bad element must not wipe the archive — decode element-by-element.
                if let array = try JSONSerialization.jsonObject(with: data) as? [Any] {
                    var recovered: [RecordingEntry] = []
                    for item in array {
                        guard JSONSerialization.isValidJSONObject(item),
                              let itemData = try? JSONSerialization.data(withJSONObject: item),
                              let entry = try? decoder.decode(RecordingEntry.self, from: itemData) else {
                            continue
                        }
                        recovered.append(entry)
                    }
                    if recovered.isEmpty { throw error }
                    recordings = recovered
                    NSLog("[RecordingStore] Partial index recovery: \(recovered.count)/\(array.count) entries")
                } else {
                    throw error
                }
            }
            clearFalseManualTitleFlags()
            scanForOrphanRecordings()
        } catch {
            // Quarantine the corrupt file BEFORE any rewrite so we never destroy the only copy (C5).
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let quarantine = indexURL.deletingLastPathComponent()
                .appendingPathComponent("recordings.json.corrupt-\(stamp)")
            try? FileManager.default.moveItem(at: indexURL, to: quarantine)
            NSLog("[RecordingStore] Failed to load recordings index — quarantined to \(quarantine.lastPathComponent): \(error)")
            recordings = []
            scanForOrphanRecordings()
        }
    }

    /// Live title TextField used to call `rename()` on appear, latching every
    /// default "Recording …" title as manual and blocking LLM rename after recap.
    private func clearFalseManualTitleFlags() {
        var changed = false
        for i in recordings.indices {
            guard recordings[i].titleManuallySet == true else { continue }
            guard recordings[i].title.hasPrefix("Recording ") else { continue }
            recordings[i].titleManuallySet = false
            changed = true
        }
        if changed {
            NSLog("[RecordingStore] Cleared false titleManuallySet on auto-titled recordings")
            scheduleSave()
        }
    }

    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            // No prettyPrinted — multi-MB archives with embedded transcripts (P6).
            let data = try encoder.encode(recordings)
            // Keep a sidecar backup of the previous good index (C5).
            if FileManager.default.fileExists(atPath: indexURL.path) {
                let bak = indexURL.deletingPathExtension().appendingPathExtension("json.bak")
                try? FileManager.default.removeItem(at: bak)
                try? FileManager.default.copyItem(at: indexURL, to: bak)
            }
            try data.write(to: indexURL, options: .atomic)
        } catch {
            NSLog("[RecordingStore] Failed to save recordings index: \(error)")
        }
    }

    // MARK: - CRUD

    func add(_ entry: RecordingEntry) {
        recordings.insert(entry, at: 0)
        scheduleSave()
    }

    func update(id: String, transcript: String? = nil, status: String? = nil, duration: Double? = nil, language: String?? = nil, notes: String?? = nil, rawSegmentsJSON: String?? = nil, mergedSegmentsJSON: String?? = nil, title: String? = nil, topics: [String]? = nil, tags: [String]? = nil) {
        guard let idx = recordings.firstIndex(where: { $0.id == id }) else { return }
        if let t = transcript { recordings[idx].transcript = t }
        if let s = status { recordings[idx].status = s }
        if let d = duration { recordings[idx].duration = d }
        if let l = language { recordings[idx].language = l }
        if let n = notes { recordings[idx].notes = n }
        if let r = rawSegmentsJSON { recordings[idx].rawSegmentsJSON = r }
        if let m = mergedSegmentsJSON { recordings[idx].mergedSegmentsJSON = m }
        // Auto-title path: sets the title WITHOUT marking it manual (unlike rename()).
        if let tt = title { recordings[idx].title = tt }
        if let tp = topics { recordings[idx].topics = tp }
        if let tg = tags { recordings[idx].tags = tg }
        scheduleSave()
    }

    func rename(id: String, to newTitle: String) {
        guard let idx = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[idx].title = newTitle
        // Manual rename latches: LLM/calendar auto-title must not overwrite it.
        recordings[idx].titleManuallySet = true
        scheduleSave()
    }

    /// Delete only audio files; keep the recording entry with transcript
    func deleteAudioFile(for entry: RecordingEntry) {
        for url in audioFileURLs(for: entry) {
            try? FileManager.default.removeItem(at: url)
        }
        // Duration is preserved so the user still sees the original length
        scheduleSave()
    }

    /// Remove the recording entirely (audio files + index entry)
    func remove(_ entry: RecordingEntry) {
        for url in audioFileURLs(for: entry) {
            try? FileManager.default.removeItem(at: url)
        }
        recordings.removeAll { $0.id == entry.id }
        scheduleSave()
    }

    func recording(for id: String) -> RecordingEntry? {
        recordings.first { $0.id == id }
    }

    func audioURL(for entry: RecordingEntry) -> URL? {
        let url = URL(fileURLWithPath: Preferences.shared.recordingsPath)
            .appendingPathComponent(entry.filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func audioFileURLs(for entry: RecordingEntry) -> [URL] {
        let finalURL = URL(fileURLWithPath: Preferences.shared.recordingsPath)
            .appendingPathComponent(entry.filename)
        let stems = AudioSourceStemURLs.expectedSiblings(for: finalURL)
        return [finalURL, stems.microphoneURL, stems.systemURL]
    }

    // MARK: - Recovery

    @discardableResult
    func recoverInterruptedRecordings() -> Int {
        let dir = URL(fileURLWithPath: Preferences.shared.recordingsPath)
        var recoveredCount = 0
        for i in recordings.indices where recordings[i].status == "recording" {
            let url = dir.appendingPathComponent(recordings[i].filename)
            let stems = AudioSourceStemURLs.expectedSiblings(for: url)
            let hasFinal = FileManager.default.fileExists(atPath: url.path)
            let hasMic = FileManager.default.fileExists(atPath: stems.microphoneURL.path)
            if hasFinal || hasMic {
                if hasFinal {
                    recordings[i].duration = Self.wavDuration(url: url)
                } else if hasMic {
                    // Final mix pending — duration from mic stem until recoverMissingFinalMixes runs.
                    recordings[i].duration = Self.wavDuration(url: stems.microphoneURL)
                }
                if let next = RecordingRecovery.recoveredStatus(current: "recording", hasTranscript: false) {
                    recordings[i].status = next
                }
                recoveredCount += 1
            }
        }
        // Recover entries that crashed mid-transcription.
        // If they have a transcript (ASR finished), promote to "transcribed_raw"
        // so the diarization can resume without re-running the expensive ASR pass.
        // Otherwise reset to "recorded" so user can retry from scratch.
        for i in recordings.indices where recordings[i].status == "transcribing" {
            let hasTranscript = recordings[i].transcript != nil
            if let next = RecordingRecovery.recoveredStatus(current: "transcribing", hasTranscript: hasTranscript) {
                recordings[i].status = next
            }
            recoveredCount += 1
        }
        if recoveredCount > 0 { save() }
        return recoveredCount
    }

    /// Rebuild `<id>.wav` from surviving `.mic` / `.sys` stems after a hard quit (C3).
    @discardableResult
    func recoverMissingFinalMixes() async -> Int {
        let dir = URL(fileURLWithPath: Preferences.shared.recordingsPath)
        var rebuilt = 0
        for i in recordings.indices {
            let finalURL = dir.appendingPathComponent(recordings[i].filename)
            if FileManager.default.fileExists(atPath: finalURL.path) { continue }
            let stems = AudioSourceStemURLs.expectedSiblings(for: finalURL)
            guard FileManager.default.fileExists(atPath: stems.microphoneURL.path) else { continue }
            let sysURL = FileManager.default.fileExists(atPath: stems.systemURL.path)
                ? stems.systemURL : nil
            await AudioRecorder.produceFinalMix(
                micURL: stems.microphoneURL,
                sysURL: sysURL,
                finalURL: finalURL
            )
            if FileManager.default.fileExists(atPath: finalURL.path) {
                let dur = Self.wavDuration(url: finalURL)
                if dur > 0 { recordings[i].duration = dur }
                rebuilt += 1
            }
        }
        if rebuilt > 0 { save() }
        return rebuilt
    }

    // MARK: - Retention Cleanup

    /// Day-based auto-delete. **Not called** — plan-v2 6.1 replaces this with a
    /// size-based nudge that never deletes on its own (plan-optimization A4).
    /// Kept temporarily so Settings → Export retention prefs still decode;
    /// remove together with that UI when 6.1 lands.
    func performRetentionCleanup() {
        let days = Preferences.shared.retentionDays
        guard days > 0 else { return }

        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let mode = Preferences.shared.retentionMode
        let expired = recordings.filter { $0.date < cutoff }
        guard !expired.isEmpty else { return }

        let fm = FileManager.default
        for entry in expired {
            // Always delete audio files, including mic/system stems.
            for url in audioFileURLs(for: entry) {
                try? fm.removeItem(at: url)
            }

            if mode == "all" {
                // Also delete markdown (keyed by recordingID prefix) and remove from index
                let meetingsDir = URL(fileURLWithPath: Preferences.shared.meetingsPath)
                let prefix = entry.id + "-"
                if let files = try? fm.contentsOfDirectory(at: meetingsDir, includingPropertiesForKeys: nil) {
                    for file in files where file.pathExtension == "md" && file.lastPathComponent.hasPrefix(prefix) {
                        try? fm.removeItem(at: file)
                    }
                }
                recordings.removeAll { $0.id == entry.id }
            }
        }
        save()
    }

    // MARK: - Orphan Scanning

    private func scanForOrphanRecordings() {
        let dir = URL(fileURLWithPath: Preferences.shared.recordingsPath)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey]
        ) else { return }

        var changed = false
        let existingIDs = Set(recordings.map(\.id))
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"

        for file in files where file.pathExtension == "wav" {
            let id = file.deletingPathExtension().lastPathComponent
            if id.hasSuffix(".mic") || id.hasSuffix(".sys") { continue }
            if existingIDs.contains(id) { continue }

            let date = df.date(from: id) ?? ((try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date())
            recordings.append(RecordingEntry(
                id: id, filename: file.lastPathComponent, date: date,
                duration: Self.wavDuration(url: file), title: id,
                status: "recorded", transcript: nil
            ))
            changed = true
        }

        // Fill in missing durations
        for i in recordings.indices where recordings[i].duration == 0 {
            let url = dir.appendingPathComponent(recordings[i].filename)
            let dur = Self.wavDuration(url: url)
            if dur > 0 { recordings[i].duration = dur; changed = true }
        }

        if changed {
            recordings.sort { $0.date > $1.date }
            save()
        }
    }

    // MARK: - WAV Duration

    static func wavDuration(url: URL) -> Double {
        WavHeader.duration(url: url)
    }
}
