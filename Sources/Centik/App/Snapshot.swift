import AppKit
import SwiftUI

#if DEBUG
/// `Centik --snapshot <dir>` renders every island state to PNG files and exits.
/// Used to check the layout without screen-recording permission.
@MainActor
enum Snapshot {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Pref.register()

        let model = IslandModel.shared
        model.geometry = NotchGeometry(notchWidth: 185, notchHeight: 32, hasNotch: true,
                                       screenFrame: NSRect(x: 0, y: 0, width: 1512, height: 982))
        let agent = AgentService.parse(#"{"source":"claude","type":"notification","payload":{"message":"Claude needs your permission to use Bash","cwd":"/Users/demo/Projects/Centik"}}"#)!

        var states: [(String, Presentation)] = [
            ("01-idle", .idle),
            ("02-music", .music),
            ("02-system", .system),
            ("03-timer", .timer),
            ("04-volume", .transient(.volume(0.62, muted: false))),
            ("05-brightness", .transient(.brightness(0.4))),
            ("06-battery", .transient(.battery(level: 81, charging: true, low: false))),
            ("07-lowbattery", .transient(.battery(level: 9, charging: false, low: true))),
            ("08-network", .transient(.network(title: "İnternet geri geldi · Wi-Fi", symbol: "wifi", ok: true))),
            ("09-agent", .transient(.agent(agent))),
            ("10-track", .transient(.track)),
        ]
        for tab in IslandTab.allCases { states.append(("20-expanded-\(tab.rawValue)", .expanded)) }

        TimerService.shared.start(minutes: 25)
                let meeting = CalEvent(id: "m1", title: "Tasarım incelemesi", start: Date().addingTimeInterval(7 * 60),
                               end: Date().addingTimeInterval(37 * 60), allDay: false, color: .systemPurple,
                               joinURL: URL(string: "https://meet.google.com/abc-defg-hij"))
        let planning = CalEvent(id: "m2", title: "Sprint planlama", start: Date().addingTimeInterval(3 * 3600),
                                end: Date().addingTimeInterval(4 * 3600), allDay: false, color: .systemOrange, joinURL: nil)
        CalendarService.shared.loadPreview([meeting, planning])
        UserDefaults.standard.set("İstanbul", forKey: Pref.weatherCity)
        WeatherService.shared.loadPreview(temperature: 17, code: 2, high: 19, low: 12, rain: 40)
        NotesService.shared.loadPreview([
            QuickNote(text: "Sunum slaytlarını Cuma'ya bitir"),
            QuickNote(text: "Kargo iadesini yap", date: Date().addingTimeInterval(-3600)),
            QuickNote(text: "Spotify çalma listesini paylaş", done: true, date: Date().addingTimeInterval(-7200)),
        ])
                SystemMonitor.shared.demand("snapshot", true)
        SystemMonitor.shared.demand("tab", true)
        for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(1.05)) }
        ClipboardService.shared.start()
        ShelfStore.shared.add([URL(fileURLWithPath: "/Applications/Safari.app"), URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")])

        func render(_ name: String, _ p: Presentation) {
            let size = model.size(for: p)
            write(IslandBody(p: p)
                .frame(width: size.width + 40, height: size.height + 30, alignment: .top)
                .background(LinearGradient(colors: [Color(red: 0.3, green: 0.45, blue: 0.35), Color(red: 0.75, green: 0.8, blue: 0.7)],
                                           startPoint: .top, endPoint: .bottom))
                .environment(\.colorScheme, .dark), name)
        }

        func write(_ view: some View, _ name: String) {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let cg = renderer.cgImage {
                let rep = NSBitmapImageRep(cgImage: cg)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
            }
        }

        for (name, p) in states {
            if name.hasPrefix("20-"), let tab = IslandTab(rawValue: String(name.dropFirst("20-expanded-".count))) {
                model.tab = tab
            }
            render(name, p)
        }

                // The same tabs again with sample content.
        let art = NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
            NSGradient(colors: [.systemPink, .systemOrange, .systemPurple])!.draw(in: rect, angle: 35)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 95, dy: 95)).fill()
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 138, dy: 138)).fill()
            return true
        }
        MusicService.shared.loadPreview(title: "Gece Yarısı Sürüşü", artist: "Mavi Gri", artwork: art)
        let safari = ClipSource(name: "Safari", bundleID: "com.apple.Safari")
        let notes = ClipSource(name: "Notlar", bundleID: "com.apple.Notes")
        let finder = ClipSource(name: "Finder", bundleID: "com.apple.finder")
        let artData = art.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        let clipSamples: [ClipItem] = [
            ClipboardService.imageItem(artData ?? Data(), source: safari),
            ClipItem(kind: .link, text: "https://developer.apple.com/documentation/swiftui", source: safari, date: Date().addingTimeInterval(-90)),
            ClipItem(kind: .color, text: "#FF5E7A", source: notes, date: Date().addingTimeInterval(-300), pinned: true),
            ClipItem(kind: .code, text: "func makeIsland() -> some View {\n    IslandView()\n        .ignoresSafeArea()\n}", source: notes,
                     date: Date().addingTimeInterval(-600)),
            ClipItem(kind: .file, files: [URL(fileURLWithPath: "/Applications/Safari.app"), URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")],
                     source: finder, date: Date().addingTimeInterval(-900)),
            ClipItem(kind: .text, text: "Toplantı notları: tasarım gözden geçirme perşembe 14:00, ardından sürüm planlaması.",
                     rtf: Data(), source: notes, date: Date().addingTimeInterval(-1500)),
        ].compactMap { $0 }
        ClipboardService.shared.loadPreview(clipSamples)
        write(VStack(spacing: 4) {
            ForEach(Array(clipSamples.enumerated()), id: \.offset) { i, item in ClipListRow(item: item, selected: i == 0) {} }
        }.frame(width: 286).padding(10).background(Color.black).environment(\.colorScheme, .dark)
            .environment(\.islandAccent, .pink), "23-clip-rows")
        for item in clipSamples {
            write(ClipPreview(item: item).frame(width: 400, height: 168).padding(10).background(Color.black)
                .environment(\.colorScheme, .dark).environment(\.islandAccent, .pink), "23-clip-\(item.kind.rawValue)")
        }
        AgentService.shared.loadPreview([
            #"{"source":"claude","type":"notification","payload":{"message":"Claude needs your permission to use Bash","cwd":"/Users/demo/Projects/Centik"}}"#,
            #"{"source":"codex","type":"notify","payload":{"type":"agent-turn-complete","last-assistant-message":"Tüm testler geçti, PR hazır.","cwd":"/Users/demo/Projects/Kahin"}}"#,
        ])
        for tab in IslandTab.allCases {
            model.tab = tab
            render("21-full-\(tab.rawValue)", .expanded)
        }
        render("22-music-compact", .music)

        
                ProcessMonitor.shared.demand(true)
        RunLoop.main.run(until: Date().addingTimeInterval(4.5))
        model.tab = .system
        for view in ["overview", "apps", "charts"] {
            UserDefaults.standard.set(view, forKey: Pref.systemView)
            render("25-system-\(view)", .expanded)
        }
        let busiest = ProcessMonitor.shared.apps.sorted { $0.cpu > $1.cpu }.prefix(5)
        write(VStack(spacing: 3) { ForEach(Array(busiest)) { ProcessRow(group: $0, showsCount: true) } }
            .frame(width: 640).padding(10).background(Color.black).environment(\.colorScheme, .dark), "25-process-rows")
        UserDefaults.standard.removeObject(forKey: Pref.systemView)
        CalendarService.shared.loadPreview([meeting, planning])
        write(VStack(spacing: 8) { EventRow(event: meeting); EventRow(event: planning) }
            .frame(width: 200).padding(12).background(Color.black).environment(\.colorScheme, .dark), "24-event-rows")
        render("24-meeting-compact", .meeting)
        render("24-meeting-soon", .transient(.meetingSoon(meeting)))
        render("24-capture", .transient(.capture(CaptureEvent(url: URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/Ekran Resmi 2026-10-27 01.12.40.png"),
                                                              kind: .screenshot, thumbnail: art))))
        model.tab = .notes
        render("24-notes", .expanded)
        model.tab = .assistant
        AssistantService.shared.loadPreview([])
        render("26-claude-empty", .expanded)
        AssistantService.shared.loadPreview([
            ChatMessage(role: .user, text: "Bu hata ne demek: EXC_BAD_ACCESS?"),
            ChatMessage(role: .assistant, text: "Uygulama **erişmemesi gereken** bir bellek adresine dokundu. En sık nedenler:\n• serbest bırakılmış bir nesneyi kullanmak\n• `nil` bir işaretçiye erişmek\nXcode'da *Zombie Objects*'i açıp tekrar dene."),
        ])
        write(VStack(spacing: 6) { ForEach(AssistantService.shared.messages) { ChatBubble(message: $0, running: false) } }
            .frame(width: 600).padding(10).background(Color.black).environment(\.colorScheme, .dark), "26-claude-bubbles")
        AssistantService.shared.loadPreview([])
        
        // Every theme, expanded and as a peek, with a custom accent.
        let defaults = UserDefaults.standard
        let savedTheme = defaults.string(forKey: Pref.theme)
        let savedMode = defaults.string(forKey: Pref.accentMode)
        defaults.set("custom", forKey: Pref.accentMode)
        model.tab = .timer
        for kind in ThemeKind.allCases {
            defaults.set(kind.rawValue, forKey: Pref.theme)
            render("30-theme-\(kind.rawValue)", .expanded)
            render("31-peek-\(kind.rawValue)", .transient(.agent(agent)))
        }
        write(LazyVGrid(columns: Array(repeating: GridItem(.fixed(130)), count: 3)) {
            ForEach(ThemeKind.allCases) { ThemeCard(kind: $0, selected: $0 == .aurora, accent: .purple) }
        }.padding().background(Color(white: 0.92)).environment(\.colorScheme, .light), "40-theme-cards")
        defaults.set(savedTheme, forKey: Pref.theme)
        defaults.set(savedMode, forKey: Pref.accentMode)

        ShelfStore.shared.clear()
        print("Snapshots written to \(dir.path)")
        exit(0)
    }
}

/// `Centik --sysprobe` prints a few seconds of SystemMonitor readings and exits.
enum SysProbe {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--sysprobe") else { return }
        let m = SystemMonitor.shared
        m.demand("probe", true)
        for _ in 0..<3 { RunLoop.main.run(until: Date().addingTimeInterval(1.05)) }
        print(String(format: "cpu %.1f%% (sys %.1f%%) cores %d", m.cpu * 100, m.cpuSystem * 100, m.cores.count))
        print("mem used", SystemMonitor.gigabytes(m.memoryUsed), "of", SystemMonitor.gigabytes(m.memoryTotal),
              "compressed", SystemMonitor.gigabytes(m.memoryCompressed), "pressure", m.memoryPressure)
        print("gpu", m.gpu.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a")
        print("net down", SystemMonitor.rate(m.downBytesPerSec), "up", SystemMonitor.rate(m.upBytesPerSec))
        print("disk free", ByteCountFormatter.string(fromByteCount: m.diskFree, countStyle: .file), "of",
              ByteCountFormatter.string(fromByteCount: m.diskTotal, countStyle: .file))
        exit(0)
    }
}

/// `Centik --procprobe` prints the busiest apps and processes after two samples.
enum ProcProbe {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--procprobe") else { return }
        let m = ProcessMonitor.shared
        m.demand(true)
        RunLoop.main.run(until: Date().addingTimeInterval(4.6))
        func line(_ g: ProcessGroup) -> String {
            String(format: "%-28@ cpu %5.1f%%  mem %7.1f MB  pids %d", g.name as NSString, g.cpu, Double(g.memory) / 1_048_576, g.pids.count)
        }
        print("APPS by CPU"); m.apps.sorted { $0.cpu > $1.cpu }.prefix(6).forEach { print(line($0)) }
        print("APPS by memory"); m.apps.sorted { $0.memory > $1.memory }.prefix(5).forEach { print(line($0)) }
        print("count apps \(m.apps.count) processes \(m.processes.count)")
        if let i = CommandLine.arguments.firstIndex(of: "--quit"), i + 1 < CommandLine.arguments.count {
            let name = CommandLine.arguments[i + 1]
            guard let target = m.apps.first(where: { $0.name == name }) else { print("no app named \(name)"); exit(1) }
            print("quitting \(target.name) pids \(target.pids) protected \(target.isProtected)")
            m.quit(target, force: false)
            RunLoop.main.run(until: Date().addingTimeInterval(2))
            print("still running:", target.pids.filter { kill($0, 0) == 0 })
        }
        if let finder = m.apps.first(where: { $0.bundlePath?.hasSuffix("Finder.app") == true }) { print("Finder protected:", finder.isProtected) }
        if let nc = m.apps.first(where: { $0.bundlePath?.contains("NotificationCenter") == true }) { print("Notification Center protected:", nc.isProtected) }
        exit(0)
    }
}

/// `Centik --claudeprobe [provider]` asks a live-data question and a follow-up through the
/// assistant and prints the replies. The provider defaults to the one chosen in Settings.
enum ClaudeProbe {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--claudeprobe") else { return }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--claudeprobe"), i + 1 < args.count, AIProvider(rawValue: args[i + 1]) != nil {
            UserDefaults.standard.set(args[i + 1], forKey: Pref.aiProvider)
        }
        let claude = AssistantService.shared
        claude.newChat()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        claude.providerChanged()
        print("provider: \(claude.resolve()?.title ?? "none")")
        WeatherService.shared.refresh()
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        func ask(_ q: String) {
            claude.draft = q
            claude.send()
            var chunks = 0
            var last = ""
            let deadline = Date().addingTimeInterval(90)
            while (claude.isRunning || claude.messages.last?.text.isEmpty == true), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                if let t = claude.messages.last?.text, t != last { chunks += 1; last = t }
            }
            print("Q: \(q)\nA: \(claude.messages.last?.text ?? "-") [updates: \(chunks), error: \(claude.messages.last?.isError ?? false)]")
        }
        ask("hava kaç derece")
        ask("Bugün günlerden ne? Az önce sana ne sordum?")
        claude.newChat()
        exit(0)
    }
}
#endif
