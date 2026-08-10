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
