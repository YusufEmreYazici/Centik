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

    // CPU, process and network figures are averages over Activity Monitor's update period,
    // so the two show the same numbers; the charts still move every second.
    private(set) var cpu: Double = 0                 // 0…1
    private(set) var cpuUser: Double = 0
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

    private var tickHistory: [[[UInt32]]] = []
    private var netHistory: [(down: UInt64, up: UInt64, date: Date)] = []
    private var netCounters: [String: (down: UInt64, up: UInt64)] = [:]
    private var netLast: [String: (down: UInt64, up: UInt64)] = [:]
    private var processHistory: [(times: [Int32: (name: String, seconds: Double)], date: Date)] = []
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
        record(.memory, memoryFraction)
        record(.gpu, gpu ?? 0)
        if tick % 10 == 0 { sampleDisk() }
        if demands.contains("tab") { sampleTopProcesses() }
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
        tickHistory.append(ticks)
        if tickHistory.count > Self.window + 1 { tickHistory.removeFirst(tickHistory.count - Self.window - 1) }
        guard tickHistory.count > 1, tickHistory.allSatisfy({ $0.count == ticks.count }) else { return }
        let previous = tickHistory[tickHistory.count - 2]

        // The chart gets this second's load; the figures get the load over the whole period.
        record(.cpu, Self.load(from: previous, to: ticks).busy)
        let load = Self.load(from: tickHistory[0], to: ticks)
        cpu = load.busy
        cpuUser = load.user
        cpuSystem = load.system
        cores = load.cores
    }

    private static func load(from before: [[UInt32]], to now: [[UInt32]]) -> (busy: Double, user: Double, system: Double, cores: [Double]) {
        let states = Int(CPU_STATE_MAX)
        var perCore: [Double] = []
        var user: UInt64 = 0, system: UInt64 = 0, total: UInt64 = 0
        for (n, b) in zip(now, before) {
            // Tick counters are 32-bit and wrap; the wrapping subtraction still gives the step.
            let d = (0..<states).map { UInt64(n[$0] &- b[$0]) }
            let u = d[Int(CPU_STATE_USER)] + d[Int(CPU_STATE_NICE)]
            let s = d[Int(CPU_STATE_SYSTEM)]
            let all = d.reduce(0, +)
            perCore.append(all > 0 ? Double(u + s) / Double(all) : 0)
            user += u
            system += s
            total += all
        }
        guard total > 0 else { return (0, 0, 0, perCore) }
        return (Double(user + system) / Double(total), Double(user) / Double(total), Double(system) / Double(total), perCore)
    }

    /// Activity Monitor's View → Update Frequency, in seconds (5 unless changed there).
    static var window: Int {
        let period = UserDefaults(suiteName: "com.apple.ActivityMonitor")?.integer(forKey: "UpdatePeriod") ?? 0
        return [1, 2, 5].contains(period) ? period : 5
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

    /// Bytes through the physical interfaces (Wi-Fi, Ethernet, cellular), read as 64-bit
    /// counters. VPN tunnels are left out: their traffic also crosses the physical interface,
    /// so counting both would double it.
    private func sampleNetwork() {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return }
        var seen: [String: (down: UInt64, up: UInt64)] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.load(fromByteOffset: offset, as: if_msghdr.self)
                defer { offset += Int(header.ifm_msglen) }
                guard header.ifm_msglen > 0 else { offset = length; return }
                guard Int32(header.ifm_type) == RTM_IFINFO2 else { continue }
                let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                guard if_indextoname(UInt32(message.ifm_index), &name) != nil else { continue }
                let interface = String(cString: name)
                guard interface.hasPrefix("en") || interface.hasPrefix("pdp_ip") else { continue }
                seen[interface] = (message.ifm_data.ifi_ibytes, message.ifm_data.ifi_obytes)
            }
        }
        // Keep running totals so an interface that disappears or resets doesn't count as a jump.
        for (interface, now) in seen {
            if let last = netLast[interface], now.down >= last.down, now.up >= last.up {
                var total = netCounters[interface] ?? (0, 0)
                total.down += now.down - last.down
                total.up += now.up - last.up
                netCounters[interface] = total
            }
            netLast[interface] = now
        }
        let down = netCounters.values.reduce(0) { $0 + $1.down }
        let up = netCounters.values.reduce(0) { $0 + $1.up }
        let now = Date()
        netHistory.append((down, up, now))
        if netHistory.count > Self.window + 1 { netHistory.removeFirst(netHistory.count - Self.window - 1) }
        guard netHistory.count > 1 else { return }
        let last = netHistory[netHistory.count - 2], first = netHistory[0]
        record(.network, Double(down - last.down + up - last.up) / max(0.2, now.timeIntervalSince(last.date)))
        let span = max(0.2, now.timeIntervalSince(first.date))
        downBytesPerSec = Double(down - first.down) / span
        upBytesPerSec = Double(up - first.up) / span
    }

    // MARK: Disk and processes

    private func sampleDisk() {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return }
        diskFree = values.volumeAvailableCapacityForImportantUsage ?? 0
        diskTotal = Int64(values.volumeTotalCapacity ?? 0)
    }

    /// The busiest processes system-wide, like Activity Monitor's "% CPU" column. `ps` can
    /// read every process (it runs as root); its own %CPU is a decaying estimate, so the
    /// figure comes from the change in each process's CPU time over the update period.
    private func sampleTopProcesses() {
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/ps")
            task.arguments = ["-Aceo", "pid=,time=,comm="]
            // Fixed number format: under a Turkish locale ps writes "1:09,49".
            task.environment = ["LC_ALL": "C"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            guard (try? task.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            var times: [Int32: (name: String, seconds: Double)] = [:]
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard parts.count == 3, let pid = Int32(parts[0]), let seconds = Self.seconds(parts[1]) else { continue }
                times[pid] = (String(parts[2]), seconds)
            }
            DispatchQueue.main.async { self.updateTopProcesses(times) }
        }
    }

    private func updateTopProcesses(_ times: [Int32: (name: String, seconds: Double)]) {
        let now = Date()
        processHistory.append((times, now))
        processHistory.removeAll { now.timeIntervalSince($0.date) > Double(Self.window) + 0.5 }
        guard let first = processHistory.first, first.date < now else { return }
        let span = now.timeIntervalSince(first.date)
        let top = times.compactMap { pid, entry -> TopProcess? in
            guard let before = first.times[pid], before.name == entry.name else { return nil }
            return TopProcess(name: entry.name, cpu: max(0, entry.seconds - before.seconds) / span * 100)
        }
        .sorted { $0.cpu > $1.cpu }
        objectWillChange.send()
        topProcesses = Array(top.prefix(3))
    }

    /// "[[dd-]hh:]mm:ss.cc" from ps.
    private static func seconds(_ field: Substring) -> Double? {
        var days = 0.0
        var rest = field
        if let dash = field.firstIndex(of: "-") {
            guard let d = Double(field[..<dash]) else { return nil }
            days = d
            rest = field[field.index(after: dash)...]
        }
        var total = 0.0
        for part in rest.split(separator: ":") {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return days * 86_400 + total
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

    /// Two decimals in the interface language's number format, as Activity Monitor shows memory.
    static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.2f GB", locale: AppLanguage.locale, Double(bytes) / 1_073_741_824)
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
        cpuUser = cpu - cpuSystem
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
