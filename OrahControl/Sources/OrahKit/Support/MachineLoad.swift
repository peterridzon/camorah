import Foundation
import IOKit

/// What the machine is doing, sampled cheaply.
///
/// A desk that decodes twenty-four cameras and encodes four lanes is only ever
/// one camera away from running out of machine, and the first sign of that is a
/// dropped frame nobody can explain afterwards. So the load is on the bar next
/// to the camera count, where it can be watched before the show rather than
/// reconstructed after it.
public struct MachineLoad: Sendable, Equatable {
    /// 0…1 across all cores.
    public var cpu: Double = 0
    /// 0…1, or `nil` when the machine will not say.
    public var gpu: Double?

    public init(cpu: Double = 0, gpu: Double? = nil) {
        self.cpu = cpu
        self.gpu = gpu
    }
}

/// Samples CPU and GPU without spawning anything.
///
/// `top` and `powermetrics` were the obvious way and both are wrong here: one
/// costs a process per second, the other needs root. Both numbers are already
/// in the kernel — CPU as tick counters, GPU in the accelerator's own
/// statistics — so they are read directly.
public final class LoadMeter: @unchecked Sendable {

    public init() {}

    private var previous: (busy: Double, total: Double)?

    public func sample() -> MachineLoad {
        MachineLoad(cpu: cpu(), gpu: Self.gpu())
    }

    // MARK: - CPU

    /// The counters are cumulative since boot, so a single reading says nothing.
    /// Load is the difference between this reading and the last one.
    private func cpu() -> Double {
        var size = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info()

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return previousLoad }

        let user = Double(info.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle

        defer { previous = (busy, total) }
        guard let last = previous else { return 0 }

        let deltaTotal = total - last.total
        guard deltaTotal > 0 else { return previousLoad }
        return min(max((busy - last.busy) / deltaTotal, 0), 1)
    }

    private var previousLoad: Double = 0

    // MARK: - GPU

    /// Read from the accelerator's `PerformanceStatistics`, which is where the
    /// driver already publishes it. The key differs between machines, so a few
    /// spellings are tried and the busiest device wins — on a Mac with more than
    /// one GPU the quiet one says nothing useful.
    private static func gpu() -> Double? {
        guard let matching = IOServiceMatching("IOAccelerator") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
                == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var best: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                    service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = unmanaged?.takeRetainedValue() as? [String: Any],
                  let statistics = properties["PerformanceStatistics"] as? [String: Any]
            else { continue }

            for key in ["Device Utilization %", "GPU Activity(%)", "Renderer Utilization %"] {
                if let value = statistics[key] as? NSNumber {
                    let load = min(max(value.doubleValue / 100, 0), 1)
                    best = max(best ?? 0, load)
                    break
                }
            }
        }
        return best
    }
}
