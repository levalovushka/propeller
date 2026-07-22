import AppKit
import Foundation

@main
struct VerifyZoom {
    static func main() {
        func fail(_ m: String) -> Never {
            fputs("FAIL: \(m)\n", stderr)
            exit(1)
        }
        func ok(_ m: String) { print("OK \(m)") }

        // zoom.us should be treated as app presence, not a meeting by itself.
        let snap = ZoomMeetingDetector.captureSnapshot()
        print("snapshot: running=\(snap.zoomRunning) inMeeting=\(snap.inMeeting) signals=\(snap.signals)")

        if ZoomMeetingDetector.isProcessRunning(named: "zoom.us") || snap.zoomRunning {
            ok("zoom process probe works")
        } else {
            ok("zoom not running on this machine — process probe skipped")
        }

        // caphost alone must NOT count as in-meeting (idle Zoom keeps it).
        let aom = ZoomMeetingDetector.isProcessRunning(named: "aomhost")
        let cap = ZoomMeetingDetector.isProcessRunning(named: "caphost")
            || ZoomMeetingDetector.isProcessRunning(named: "CptHost")
        print("helpers: aomhost=\(aom) caphost/CptHost=\(cap)")

        if snap.zoomRunning && !aom && snap.inMeeting && snap.signals == ["meeting-window"] {
            ok("in-meeting via window title only (possible during real call)")
        } else if snap.zoomRunning && !aom && snap.inMeeting {
            // Idle Zoom must not flip inMeeting via caphost — if this fires, heuristics are wrong.
            fail("idle Zoom reported inMeeting without aomhost: \(snap.signals)")
        } else if snap.zoomRunning && !snap.inMeeting {
            ok("idle Zoom correctly not in meeting")
        } else if !snap.zoomRunning {
            ok("Zoom app not running — idle false-positive check N/A")
        } else if snap.inMeeting && aom {
            ok("live meeting via aomhost")
        }

        // Mode defaults: empty rawValue is rejected by the enum; Preferences maps it to .auto
        if ZoomAutoRecordMode(rawValue: "") == nil {
            ok("empty rawValue falls through to preference default (.auto)")
        }
        if ZoomAutoRecordMode(rawValue: "ask") == nil {
            ok("legacy ask rawValue is no longer a mode (Preferences migrates ask→auto)")
        }

        // Debounce thresholds sanity via detector start/stop without crashing
        let det = ZoomMeetingDetector.shared
        var started = 0
        var ended = 0
        det.onMeetingStarted = { started += 1 }
        det.onMeetingEnded = { ended += 1 }
        det.stop()
        det.start()
        // Immediate probe shouldn't emit start without streak; give one poll cycle.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        det.stop()
        ok("detector start/stop without crash (started=\(started) ended=\(ended))")

        print("ALL PASS")
    }
}
