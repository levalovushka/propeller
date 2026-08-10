import Darwin
import Foundation

/// What a process actually spent — including a *child* process we did not write.
///
/// The live layer's work does not happen in our address space: frames go over a
/// socket into `gigastt`, and that is where the encoder runs. Measuring our own
/// RSS and CPU therefore says almost nothing about the cost of showing a live
/// transcript. `proc_pid_rusage` reads another process of the same user, so the
/// sidecar can be metered from here without instrumenting it.
///
/// Cycles, not just seconds. On Apple Silicon a P-core and an E-core burn very
/// different energy for the same wall-clock second, and DVFS moves the clock
/// under us — `ri_cycles` is the number that stays comparable between runs, and
/// it is the closest proxy for energy available without a private framework.
struct ProcessCost {
    /// User CPU time, seconds.
    var userSeconds: Double
    /// System CPU time, seconds.
    var systemSeconds: Double
    var cycles: UInt64
    var instructions: UInt64
    /// Resident size at the moment of sampling, bytes.
    var residentBytes: UInt64

    var cpuSeconds: Double { userSeconds + systemSeconds }

    static func of(pid: pid_t) -> ProcessCost? {
        var info = rusage_info_v4()
        let rc: Int32 = withUnsafeMutablePointer(to: &info) { pointer in
            // `rusage_info_t` is `void *`, and the call fills the struct the
            // pointer refers to. Handing it a pointer-to-pointer smashes the
            // stack — measured, it aborts.
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard rc == 0 else { return nil }
        return ProcessCost(
            userSeconds: machSeconds(info.ri_user_time),
            systemSeconds: machSeconds(info.ri_system_time),
            cycles: info.ri_cycles,
            instructions: info.ri_instructions,
            residentBytes: info.ri_resident_size
        )
    }

    /// Cost accrued between two samples. Counters are monotonic, so a negative
    /// difference means the pid was reused — reported as nil rather than as a
    /// plausible small number.
    func since(_ earlier: ProcessCost) -> ProcessCost? {
        guard userSeconds >= earlier.userSeconds,
              systemSeconds >= earlier.systemSeconds,
              cycles >= earlier.cycles,
              instructions >= earlier.instructions
        else { return nil }
        return ProcessCost(
            userSeconds: userSeconds - earlier.userSeconds,
            systemSeconds: systemSeconds - earlier.systemSeconds,
            cycles: cycles - earlier.cycles,
            instructions: instructions - earlier.instructions,
            residentBytes: residentBytes
        )
    }

    /// `ri_user_time` / `ri_system_time` are mach absolute units, not
    /// nanoseconds — on this machine one unit is 125/3 ns. Reading them as ns
    /// understates CPU time by ~42x, which reads as "the sidecar is free".
    private static func machSeconds(_ units: UInt64) -> Double {
        Double(units) * timebaseNanos / 1_000_000_000
    }

    private static let timebaseNanos: Double = {
        var tb = mach_timebase_info_data_t()
        guard mach_timebase_info(&tb) == KERN_SUCCESS, tb.denom != 0 else { return 1 }
        return Double(tb.numer) / Double(tb.denom)
    }()
}

/// Spawn a child pinned to the background QoS class.
///
/// The pipeline is work nobody sits in front of, and the measured alternative is
/// 3.2 of 10 cores taken the moment a meeting ends. On Apple Silicon the
/// background class confines a process to the efficiency cores and throttles its
/// disk I/O — the trade a background obligation is entitled to make.
///
/// It has to be done **at spawn**. `setpriority(PRIO_DARWIN_BG, …)` is refused
/// for another process and returns EINVAL even for self on this system, and
/// `taskpolicy` does not exist here — measured, all three.
func spawnBackground(_ binary: URL, _ arguments: [String], log: URL) -> pid_t? {
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    guard posix_spawnattr_set_qos_class_np(&attr, QOS_CLASS_BACKGROUND) == 0 else { return nil }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(
        &actions, 1, log.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644
    )
    posix_spawn_file_actions_adddup2(&actions, 1, 2)

    let argv = [binary.path] + arguments
    var pid: pid_t = 0
    let rc = withArrayOfCStrings(argv) { cargv in
        posix_spawn(&pid, binary.path, &actions, &attr, cargv, environ)
    }
    return rc == 0 ? pid : nil
}

/// `posix_spawn` wants a NULL-terminated `char *const *`; Swift will not hand
/// one over without this dance.
private func withArrayOfCStrings<R>(
    _ strings: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R
) -> R {
    var pointers = strings.map { strdup($0) }
    pointers.append(nil)
    defer { pointers.forEach { if let p = $0 { free(p) } } }
    return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
}

/// Samples a process while something else runs, keeping the high-water RSS.
///
/// Peak RSS matters more than the final number: the sidecar loads the encoder,
/// serves a meeting, and the interesting figure is the top of that curve, not
/// where it settled once we stopped feeding it.
final class ProcessSampler: @unchecked Sendable {
    private let pid: pid_t
    private let lock = NSLock()
    private var peakResident: UInt64 = 0
    private var timer: DispatchSourceTimer?

    init(pid: pid_t) {
        self.pid = pid
    }

    var peakResidentMB: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(peakResident) / 1_048_576
    }

    func start(interval: TimeInterval = 0.25) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, let cost = ProcessCost.of(pid: self.pid) else { return }
            self.lock.lock()
            self.peakResident = max(self.peakResident, cost.residentBytes)
            self.lock.unlock()
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
