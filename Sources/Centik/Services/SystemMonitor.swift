import Darwin
import Foundation
import IOKit

enum Metric: String, CaseIterable, Identifiable {
    case cpu, memory, gpu, network

    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return String(localized: "Bellek")
        case .gpu: return "GPU"
        case .network: return String(localized: "Ağ")
        }
    }
    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .gpu: return "cube.transparent"
        case .network: return "arrow.up.arrow.down"
        }
    }
}

struct TopProcess: Equatable {
    let name: String
    let cpu: Double
}

/// Live CPU, memory, GPU and network figures. Sampling runs once a second, and only while
/// something on screen shows the numbers (see `demand`).
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()
    static let historyLength = 60

    private(set) var cpu: Double = 0                 // 0…1
    private(set) var cpuSystem: Double = 0
    private(set) var cores: [Double] = []
    private(set) var memoryUsed: UInt64 = 0
    private(set) var memoryCompressed: UInt64 = 0
    private(set) var memoryPressure = 1                // 1 normal, 2 warning, 4 critical
    private(set) var gpu: Double?                      // nil when the GPU doesn't report
    private(set) var downBytesPerSec: Double = 0
    private(set) var upBytesPerSec: Double = 0
    private(set) var diskFree: Int64 = 0
    private(set) var diskTotal: Int64 = 0
    private(set) var topProcesses: [TopProcess] = []
    private(set) var history: [Metric: [Double]] = [:]

    let memoryTotal = ProcessInfo.processInfo.physicalMemory
    let coreCount = ProcessInfo.processInfo.activeProcessorCount

    var memoryFraction: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0 }

    private var previousTicks: [[UInt32]] = []
    private var previousNet: (down: UInt64, up: UInt64, date: Date)?
    private var timer: Timer?
    private var tick = 0
    private var demands = Set<String>()
    /// Set while `--demo` feeds sample figures instead of real ones.
    private var previewTimer: Timer?

    /// Views register while visible; sampling stops when nobody is looking.
    func demand(_ key: String, _ on: Bool) {
        guard previewTimer == nil else { return }
        if on { demands.insert(key) } else { demands.remove(key) }
        IslandModel.log.debug("monitor demand \(key, privacy: .public)=\(on, privacy: .public) -> \(self.demands.sorted(), privacy: .public)")
        if demands.isEmpty {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            sample()
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
            t.tolerance = 0.2
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func sample() {
        // One change notification per tick: the properties below are plain stored values so a
        // dozen updates don't each invalidate the views separately.
        objectWillChange.send()
        sampleCPU()
        sampleMemory()
        gpu = Self.readGPU()
        sampleNetwork()
        record(.cpu, cpu)
        record(.memory, memoryFraction)
        record(.gpu, gpu ?? 0)
        record(.network, downBytesPerSec + upBytesPerSec)
        if tick % 10 == 0 { sampleDisk() }
        if tick % 3 == 0 && demands.contains("tab") { sampleTopProcesses() }
        tick += 1
    }

    private func record(_ metric: Metric, _ value: Double) {
        var values = history[metric] ?? []
        values.append(value)
        if values.count > Self.historyLength { values.removeFirst(values.count - Self.historyLength) }
        history[metric] = values
    }

    // MARK: CPU

    private func sampleCPU() {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        var ticks: [[UInt32]] = []
        for i in 0..<Int(count) {
            ticks.append((0..<states).map { UInt32(bitPattern: info[i * states + $0]) })
        }
        defer { previousTicks = ticks }
        guard previousTicks.count == ticks.count else { return }

        var perCore: [Double] = []
        var busy: UInt64 = 0, system: UInt64 = 0, total: UInt64 = 0
        for (now, before) in zip(ticks, previousTicks) {
            let d = (0..<states).map { UInt64(now[$0] &- before[$0]) }
            let user = d[Int(CPU_STATE_USER)] + d[Int(CPU_STATE_NICE)]
            let sys = d[Int(CPU_STATE_SYSTEM)]
            let all = d.reduce(0, +)
            perCore.append(all > 0 ? Double(user + sys) / Double(all) : 0)
            busy += user + sys
            system += sys
            total += all
        }
        cores = perCore
        cpu = total > 0 ? Double(busy) / Double(total) : 0
        cpuSystem = total > 0 ? Double(system) / Double(total) : 0
    }

    // MARK: Memory

    private func sampleMemory() {
        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let page = UInt64(vm_kernel_page_size)
        // Same definition as Activity Monitor's "Memory Used": app memory + wired + compressed.
        let app = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
        memoryCompressed = UInt64(stats.compressor_page_count) * page
        memoryUsed = (app + UInt64(stats.wire_count)) * page + memoryCompressed

        var level: Int32 = 0
        var len = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &len, nil, 0) == 0 {
            memoryPressure = Int(level)
        }
    }

    // MARK: GPU

    /// Utilisation reported by the GPU driver's performance statistics (Apple silicon and most
    /// discrete GPUs publish "Device Utilization %").
    static func readGPU() -> Double? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let perf = dict["PerformanceStatistics"] as? [String: Any] else { continue }
            let value = (perf["Device Utilization %"] as? NSNumber) ?? (perf["GPU Activity(%)"] as? NSNumber)
            if let value { best = max(best ?? 0, value.doubleValue / 100) }
        }
        return best
    }

    // MARK: Network

    private func sampleNetwork() {
        var down: UInt64 = 0, up: UInt64 = 0
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return }
        defer { freeifaddrs(addrs) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = ifa.pointee.ifa_data else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            // Physical and tunnel interfaces only; loopback and Apple's internal links would double count.
            guard name.hasPrefix("en") || name.hasPrefix("utun") || name.hasPrefix("pdp_ip") else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            down += UInt64(stats.ifi_ibytes)
            up += UInt64(stats.ifi_obytes)
        }
        let now = Date()
        if let previous = previousNet {
            let dt = max(0.2, now.timeIntervalSince(previous.date))
            // Counters are 32-bit per interface and wrap; a negative step is treated as no traffic.
            downBytesPerSec = down >= previous.down ? Double(down - previous.down) / dt : 0
            upBytesPerSec = up >= previous.up ? Double(up - previous.up) / dt : 0
        }
        previousNet = (down, up, now)
    }

    // MARK: Disk and processes

    private func sampleDisk() {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return }
        diskFree = values.volumeAvailableCapacityForImportantUsage ?? 0
        diskTotal = Int64(values.volumeTotalCapacity ?? 0)
    }

    private func sampleTopProcesses() {
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/ps")
            task.arguments = ["-Aceo", "pcpu=,comm=", "-r"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            guard (try? task.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let top = String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .prefix(3)
                .compactMap { line -> TopProcess? in
                    let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
                    guard parts.count == 2, let cpu = Double(parts[0]) else { return nil }
                    return TopProcess(name: String(parts[1]), cpu: cpu)
                }
            DispatchQueue.main.async {
                self.objectWillChange.send()
                self.topProcesses = top
            }
        }
    }

    // MARK: Formatting

    static func rate(_ bytesPerSec: Double) -> String {
        switch bytesPerSec {
        case ..<1_000: return "\(Int(bytesPerSec)) B/s"
        case ..<1_000_000: return String(format: "%.0f KB/s", bytesPerSec / 1_000)
        case ..<1_000_000_000: return String(format: "%.1f MB/s", bytesPerSec / 1_000_000)
        default: return String(format: "%.2f GB/s", bytesPerSec / 1_000_000_000)
        }
    }

    /// Very short rate for the side wings ("1.2M", "340K").
    static func shortRate(_ bytesPerSec: Double) -> String {
        switch bytesPerSec {
        case ..<1_000: return "\(Int(bytesPerSec))B"
        case ..<1_000_000: return String(format: "%.0fK", bytesPerSec / 1_000)
        default: return String(format: "%.1fM", bytesPerSec / 1_000_000)
        }
    }

    static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
}

#if DEBUG
extension SystemMonitor {
    /// Plausible, gently moving figures for `--demo`, so recordings don't show this Mac's own
    /// load or process names. Ticks once a second of demo time.
    func startPreview() {
        timer?.invalidate()
        timer = nil
        history = [:]
        for i in 0..<Self.historyLength { previewTick(Double(i) - Double(Self.historyLength)) }
        var t = 0.0
        let timer = Timer(timeInterval: DemoClock.slowdown, repeats: true) { [weak self] _ in
            t += 1
            self?.objectWillChange.send()
            self?.previewTick(t)
        }
        RunLoop.main.add(timer, forMode: .common)
        previewTimer = timer
    }

    private func previewTick(_ t: Double) {
        func wave(_ base: Double, _ amp: Double, _ speed: Double, _ phase: Double = 0) -> Double {
            max(0, base + amp * sin(t * speed + phase) + amp * 0.4 * sin(t * speed * 2.7 + phase * 1.3))
        }
        cpu = wave(0.24, 0.1, 0.35)
        cpuSystem = cpu * 0.3
        cores = (0..<12).map { wave(cpu, 0.12, 0.5, Double($0)) }
        memoryUsed = UInt64(wave(14.2, 0.25, 0.1) * 1_073_741_824)
        memoryCompressed = 2_100_000_000
        memoryPressure = 1
        gpu = wave(0.18, 0.08, 0.6, 2)
        downBytesPerSec = wave(380_000, 300_000, 0.8, 1)
        upBytesPerSec = wave(42_000, 30_000, 0.7, 3)
        diskTotal = 994_662_584_320
        diskFree = 412_316_860_416
        topProcesses = [TopProcess(name: "Xcode", cpu: 38), TopProcess(name: "Safari", cpu: 12)]
        record(.cpu, cpu)
        record(.memory, memoryFraction)
        record(.gpu, gpu ?? 0)
        record(.network, downBytesPerSec + upBytesPerSec)
    }
}
#endif
