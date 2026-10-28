import AppKit
import Darwin

/// One row in the process list: an app with all of its helper processes, or a single process.
struct ProcessGroup: Identifiable, Equatable {
    let id: String
    let name: String
    let bundlePath: String?
    let pids: [pid_t]
    let cpu: Double          // percent of one core, like Activity Monitor (can exceed 100)
    let memory: UInt64       // physical footprint in bytes

    static func == (a: ProcessGroup, b: ProcessGroup) -> Bool {
        a.id == b.id && a.cpu == b.cpu && a.memory == b.memory && a.pids == b.pids
    }

    var icon: NSImage {
        if let bundlePath { return NSWorkspace.shared.icon(forFile: bundlePath) }
        return NSWorkspace.shared.icon(for: .unixExecutable)
    }

    /// Processes the user should not end from here: the system and Çentik itself.
    var isProtected: Bool {
        if pids.contains(getpid()) { return true }
        // Finder, Dock, Notification Center, Control Center and the like.
        if bundlePath?.hasPrefix("/System/Library/CoreServices/") == true { return true }
        let critical: Set<String> = ["loginwindow", "WindowServer", "Dock", "SystemUIServer", "launchd", "kernel_task",
                                     "ControlCenter", "NotificationCenter", "Finder"]
        return critical.contains(name)
    }
}

/// Per-process CPU and memory for the current user's processes, read with libproc the way
/// Activity Monitor does. Helpers living inside an .app bundle are counted with that app.
/// Samples every two seconds, only while the list is on screen.
final class ProcessMonitor: ObservableObject {
    static let shared = ProcessMonitor()

    @Published private(set) var apps: [ProcessGroup] = []
    @Published private(set) var processes: [ProcessGroup] = []

    private var previous: [pid_t: (cpuTime: UInt64, date: Date)] = [:]
    private var timer: Timer?
    private var demands = 0
    private let queue = DispatchQueue(label: "centik.processes", qos: .utility)
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(1, info.denom)))
    }()

    func demand(_ on: Bool) {
        demands = max(0, demands + (on ? 1 : -1))
        if demands > 0, timer == nil {
            sample()
            let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.sample() }
            t.tolerance = 0.3
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if demands == 0 {
            timer?.invalidate()
            timer = nil
        }
    }

    private func sample() {
        queue.async { [weak self] in
            guard let self else { return }
            let (apps, processes) = self.read()
            DispatchQueue.main.async {
                self.apps = apps
                self.processes = processes
            }
        }
    }

    private func read() -> ([ProcessGroup], [ProcessGroup]) {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return ([], []) }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let now = Date()
        let uid = getuid()
        var next: [pid_t: (cpuTime: UInt64, date: Date)] = [:]
        var singles: [ProcessGroup] = []
        var byApp: [String: (pids: [pid_t], cpu: Double, memory: UInt64)] = [:]

        for pid in pids.prefix(Int(max(0, filled))) where pid > 0 {
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
                  bsd.pbi_uid == uid else { continue }
            var usage = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard ok == 0 else { continue }
            let cpuTime = (usage.ri_user_time + usage.ri_system_time) * timebase.numer / timebase.denom
            next[pid] = (cpuTime, now)
            var cpu = 0.0
            if let before = previous[pid], cpuTime >= before.cpuTime {
                let wall = now.timeIntervalSince(before.date)
                if wall > 0 { cpu = Double(cpuTime - before.cpuTime) / 1e9 / wall * 100 }
            }
            let memory = usage.ri_phys_footprint
            let path = Self.path(of: pid)
            let name = Self.name(of: pid, path: path)
            singles.append(ProcessGroup(id: "p\(pid)", name: name, bundlePath: path.flatMap(Self.outerApp), pids: [pid],
                                        cpu: cpu, memory: memory))
            if let app = path.flatMap(Self.outerApp) {
                var entry = byApp[app] ?? ([], 0, 0)
                entry.pids.append(pid)
                entry.cpu += cpu
                entry.memory += memory
                byApp[app] = entry
            }
        }
        previous = next
        let apps = byApp.map { path, e in
            ProcessGroup(id: path, name: FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""),
                         bundlePath: path, pids: e.pids.sorted(), cpu: e.cpu, memory: e.memory)
        }
        return (apps, singles)
    }

    private static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func name(of pid: pid_t, path: String?) -> String {
        if let app = NSRunningApplication(processIdentifier: pid)?.localizedName { return app }
        if let path { return (path as NSString).lastPathComponent }
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        return String(cString: buffer)
    }

    /// The outermost .app bundle a binary lives in ("/Applications/Google Chrome.app" for every
    /// Chrome helper), or nil for processes outside any app.
    static func outerApp(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    // MARK: Ending processes

    /// Asks the app to quit, like ⌘Q; with `force`, ends it immediately and unsaved work is lost.
    func quit(_ group: ProcessGroup, force: Bool) {
        guard !group.isProtected else { return }
        let running = NSWorkspace.shared.runningApplications.filter {
            guard let url = $0.bundleURL?.path else { return group.pids.contains($0.processIdentifier) }
            return url == group.bundlePath || group.pids.contains($0.processIdentifier)
        }
        if group.id.hasPrefix("/"), !running.isEmpty {
            for app in running {
                if force { app.forceTerminate() } else { app.terminate() }
            }
        } else {
            stillSame(group).forEach { kill($0, force ? SIGKILL : SIGTERM) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.sample() }
    }

    /// The group's process IDs that still belong to the same program and user. The list can be
    /// up to two seconds old, and an ID freed in that time may already belong to something else.
    private func stillSame(_ group: ProcessGroup) -> [pid_t] {
        group.pids.filter { pid in
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
                  bsd.pbi_uid == getuid() else { return false }
            let path = Self.path(of: pid)
            if let bundle = group.bundlePath { return path.flatMap(Self.outerApp) == bundle }
            return Self.name(of: pid, path: path) == group.name
        }
    }
}
