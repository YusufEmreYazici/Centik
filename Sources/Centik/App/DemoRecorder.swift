#if DEBUG
import AppKit
import SwiftUI

/// `Centik --demo <dir> [scene ...]` plays scripted scenes of the real island over a mock
/// desktop and writes each one as PNG frames plus an ffmpeg concat list, for the README GIFs
/// (see tools/make-demo-gifs.sh). Only sample data is shown, never the user's own.
///
/// Frames come from rendering the window's layer tree, which needs no screen-recording
/// permission and catches animations mid-flight. The window sits off screen.
@MainActor
final class DemoRecorder: NSObject, NSApplicationDelegate {
    static var requested: Bool { CommandLine.arguments.contains("--demo") }

    static let stageSize = CGSize(width: 1100, height: 400)
    private static let fps = 25.0
    /// How much slower than real time scenes are played; each frame takes this many times longer
    /// to render than a 25 fps frame allows.
    private static var slowdown: Double { Double(ProcessInfo.processInfo.environment["CENTIK_DEMO_SLOWDOWN"] ?? "") ?? 12 }
    private static var scale: CGFloat { CGFloat(Double(ProcessInfo.processInfo.environment["CENTIK_DEMO_SCALE"] ?? "") ?? 2) }

    private let model = IslandModel.shared
    private var window: NSWindow!
    private let writer = DispatchQueue(label: "centik.demo.writer", qos: .userInitiated, attributes: .concurrent)
    private let writes = DispatchGroup()
    private var renderTime = 0.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--demo"), i + 1 < args.count else { exit(2) }
        let dir = URL(fileURLWithPath: args[i + 1])
        let wanted = Array(args.dropFirst(i + 2))
        let scenes = Self.scenes.filter { wanted.isEmpty || wanted.contains($0.name) }

        Pref.register()
        DemoClock.slowdown = Self.slowdown
        setUpSampleData()
        window = NSWindow(contentRect: NSRect(x: -8000, y: -8000, width: Self.stageSize.width, height: Self.stageSize.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: DemoStage())
        host.safeAreaRegions = []
        window.contentView = host
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.speed = Float(1 / Self.slowdown)   // Core Animation effects
        window.orderFrontRegardless()

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))   // let the monitors take a first reading
            for scene in scenes {
                await record(scene, into: dir.appendingPathComponent(scene.name, isDirectory: true))
            }
            await withCheckedContinuation { done in writes.notify(queue: .main) { done.resume() } }
            print("Demo frames written to \(dir.path)")
            exit(0)
        }
    }

    // MARK: Recording

    typealias Action = @MainActor (DemoRecorder) -> Void
    typealias Step = (Double, Action)

    struct Scene {
        let name: String
        let duration: Double
        let setup: Action
        let steps: [Step]
    }

    private func record(_ scene: Scene, into dir: URL) async {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        reset()
        scene.setup(self)
        try? await Task.sleep(for: .seconds(1.2 * Self.slowdown))   // settle into the starting state

        let k = Self.slowdown
        let start = Date()
        var pending = scene.steps.sorted { $0.0 < $1.0 }
        var stamps: [Double] = []
        while true {
            let t = Date().timeIntervalSince(start) / k   // scene time
            if t >= scene.duration { break }
            while let next = pending.first, next.0 <= t {
                pending.removeFirst()
                next.1(self)
            }
            capture(to: dir.appendingPathComponent(String(format: "f%04d.png", stamps.count)))
            stamps.append(t)
            let nextFrame = Double(stamps.count) / Self.fps * k
            // Always leave the main thread some time, or SwiftUI never gets to advance animations.
            let wait = max(0.06, nextFrame - Date().timeIntervalSince(start))
            try? await Task.sleep(for: .seconds(wait))
        }
        // ffmpeg concat list with each frame held until the next one was taken.
        var list = ""
        for (i, t) in stamps.enumerated() {
            let next = i + 1 < stamps.count ? stamps[i + 1] : scene.duration
            list += "file 'f\(String(format: "%04d", i)).png'\nduration \(String(format: "%.4f", max(0.01, next - t)))\n"
        }
        list += "file 'f\(String(format: "%04d", stamps.count - 1)).png'\n"
        try? list.write(to: dir.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8)
        print("\(scene.name): \(stamps.count) frames in \(String(format: "%.1f", scene.duration)) s, render \(String(format: "%.0f", renderTime / Double(max(1, stamps.count)) * 1000)) ms/frame")
        renderTime = 0
    }

    private func capture(to url: URL) {
        guard let view = window.contentView, let layer = view.layer else { return }
        let size = Self.stageSize
        let width = Int(size.width * Self.scale), height = Int(size.height * Self.scale)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: Self.scale, y: Self.scale)
        if layer.isGeometryFlipped {
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        let t0 = CACurrentMediaTime()
        (layer.presentation() ?? layer).render(in: ctx)
        renderTime += CACurrentMediaTime() - t0
        guard let image = ctx.makeImage() else { return }
        writes.enter()
        writer.async { [writes] in
            if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
            }
            writes.leave()
        }
    }

    // MARK: State

    private func reset() {
        model.collapse()
        model.hoverPeek = false
        model.show(.unlock, for: 0)   // clears any transient
        let d = UserDefaults.standard
        d.set("night", forKey: Pref.theme)
        d.set("artwork", forKey: Pref.accentMode)
        d.set("music", forKey: Pref.liveActivity)
        d.set("overview", forKey: Pref.systemView)
        d.set("bar", forKey: Pref.hudStyle)
        d.set(false, forKey: Pref.meetingAlerts)
        MusicService.shared.loadPreview(title: "Gece Yarısı Sürüşü", artist: "Neon Sahil", artwork: Self.artwork(0))
        AssistantService.shared.loadPreview([], running: false, provider: .claudeCode)
        AssistantService.shared.draft = ""
    }

    private func setUpSampleData() {
        let d = UserDefaults.standard
        d.set(true, forKey: Pref.hoverGrow)
        d.set("İstanbul", forKey: Pref.weatherCity)
        d.set("", forKey: Pref.hiddenTabs)
        d.set("", forKey: Pref.tabOrder)
        model.geometry = NotchGeometry(notchWidth: 185, notchHeight: 32, hasNotch: true,
                                       screenFrame: NSRect(origin: .zero, size: Self.stageSize))
        WeatherService.shared.loadPreview(temperature: 18, code: 2, high: 21, low: 13, rain: 20)
        CalendarService.shared.loadPreview([
            CalEvent(id: "d1", title: "Tasarım incelemesi", start: Date().addingTimeInterval(3 * 3600),
                     end: Date().addingTimeInterval(4 * 3600), allDay: false, color: .systemPurple,
                     joinURL: URL(string: "https://meet.google.com/abc-defg-hij")),
        ])
        NotesService.shared.loadPreview([
            QuickNote(text: "Lansman sunumunu bitir"),
            QuickNote(text: "Deniz'e beta için dön", date: Date().addingTimeInterval(-3600)),
            QuickNote(text: "Çalma listesini paylaş", done: true, date: Date().addingTimeInterval(-7200)),
        ])
        let safari = ClipSource(name: "Safari", bundleID: "com.apple.Safari")
        let notes = ClipSource(name: "Notlar", bundleID: "com.apple.Notes")
        let xcode = ClipSource(name: "Xcode", bundleID: "com.apple.dt.Xcode")
        let art = Self.artwork(1).tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        ClipboardService.shared.loadPreview([
            ClipboardService.imageItem(art ?? Data(), source: safari),
            ClipItem(kind: .code, text: "struct Island: View {\n    var body: some View {\n        NotchShape().fill(.black)\n    }\n}",
                     source: xcode, date: Date().addingTimeInterval(-120)),
            ClipItem(kind: .link, text: "https://github.com/YusufEmreYazici/Centik", source: safari, date: Date().addingTimeInterval(-300)),
            ClipItem(kind: .color, text: "#A97CFF", source: notes, date: Date().addingTimeInterval(-600), pinned: true),
            ClipItem(kind: .text, text: "Lansman listesi: simgeler, sürüm notları, duyuru.", source: notes,
                     date: Date().addingTimeInterval(-1200)),
        ].compactMap { $0 })
        AgentService.shared.loadPreview([
            #"{"source":"claude","type":"notification","payload":{"message":"Claude needs your permission to use Bash","cwd":"/Users/demo/Projects/Centik"}}"#,
            #"{"source":"codex","type":"notify","payload":{"type":"agent-turn-complete","last-assistant-message":"Tüm testler geçti, PR hazır.","cwd":"/Users/demo/Projects/Atlas"}}"#,
        ])
        ShelfStore.shared.clear()
        SystemMonitor.shared.startPreview()
    }

    /// Album art drawn in code, so no real covers end up in the repo.
    static func artwork(_ variant: Int) -> NSImage {
        let palettes: [[NSColor]] = [[.systemPink, .systemOrange, .systemPurple], [.systemTeal, .systemBlue, .systemIndigo],
                                     [.systemYellow, .systemRed, .systemPink]]
        let colors = palettes[variant % palettes.count]
        return NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
            NSGradient(colors: colors)!.draw(in: rect, angle: 35 + CGFloat(variant) * 50)
            NSColor.white.withAlphaComponent(0.18).setFill()
            for k in 0..<4 {
                NSBezierPath(ovalIn: rect.insetBy(dx: CGFloat(20 + k * 30), dy: CGFloat(20 + k * 30))
                    .offsetBy(dx: CGFloat(variant * 30 - 30), dy: 40)).fill()
            }
            NSColor.white.withAlphaComponent(0.9).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 110, dy: 110)).fill()
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 140, dy: 140)).fill()
            return true
        }
    }

    // MARK: Actions used by the scenes

    func hover(_ on: Bool) { withAnimation(Motion.hover) { model.hoverPeek = on } }
    func open(_ tab: IslandTab) { model.expand(tab: tab) }
    func tab(_ tab: IslandTab) { withAnimation(Motion.content) { model.tab = tab } }
    func close() { model.collapse() }
    func set(_ key: String, _ value: Any) { withAnimation(Motion.content) { UserDefaults.standard.set(value, forKey: key) } }

    // MARK: Scenes

    static let scenes: [Scene] = [
        Scene(name: "hero", duration: 10.5, setup: { _ in }, steps: [
            (0.6, { $0.hover(true) }),
            (1.3, { $0.open(.home) }),
            (3.0, { $0.tab(.system) }),
            (4.6, { $0.tab(.clipboard) }),
            (6.2, { $0.tab(.notes) }),
            (7.8, { $0.close() }),
            (8.3, { $0.hover(false) }),
        ]),
        Scene(name: "music", duration: 9, setup: { _ in }, steps: [
            (1.6, { _ in
                MusicService.shared.previewSkip(title: "Cam Bahçeler", artist: "Kuzey Işığı", artwork: DemoRecorder.artwork(1))
                IslandModel.shared.show(.track, for: 2.6)
            }),
            (4.8, { $0.open(.home) }),
            (6.4, { _ in MusicService.shared.previewSkip(title: "Gün Batımı", artist: "Mavi Gri", artwork: DemoRecorder.artwork(2)) }),
            (8.1, { $0.close() }),
        ]),
        Scene(name: "hud", duration: 8, setup: { _ in MusicService.shared.previewPlaying(false) }, steps: hudSteps()),
        Scene(name: "system", duration: 9, setup: { r in
            MusicService.shared.previewPlaying(false)
            UserDefaults.standard.set("system", forKey: Pref.liveActivity)
            IslandModel.shared.recompute()
        }, steps: [
            (1.8, { $0.open(.system) }),
            (4.4, { $0.set(Pref.systemView, "charts") }),
            (7.2, { $0.close() }),
        ]),
        Scene(name: "assistant", duration: 11, setup: { r in r.open(.assistant) }, steps: assistantSteps()),
        Scene(name: "themes", duration: 8.5, setup: { r in r.open(.home) }, steps: [
            (1.4, { $0.set(Pref.theme, "aurora") }),
            (2.8, { $0.set(Pref.theme, "glass") }),
            (4.2, { $0.set(Pref.theme, "neon") }),
            (5.6, { $0.set(Pref.theme, "minimal") }),
            (7.0, { $0.set(Pref.theme, "night") }),
        ]),
        Scene(name: "alerts", duration: 9, setup: { _ in }, steps: [
            (0.6, { _ in
                if let event = AgentService.parse(#"{"source":"claude","type":"notification","payload":{"message":"Claude needs your permission to use Bash","cwd":"/Users/demo/Projects/Centik"}}"#) {
                    IslandModel.shared.show(.agent(event), for: 2.6)
                }
            }),
            (3.6, { _ in
                // A filled symbol: outline symbols like "wifi" don't reach the recorder's renderer.
                IslandModel.shared.show(.network(title: "İnternet geri geldi · Wi-Fi", symbol: "checkmark.circle.fill", ok: true), for: 2.2)
            }),
            (6.2, { _ in
                let meeting = CalEvent(id: "d2", title: "Tasarım incelemesi", start: Date().addingTimeInterval(5 * 60),
                                       end: Date().addingTimeInterval(35 * 60), allDay: false, color: .systemPurple,
                                       joinURL: URL(string: "https://meet.google.com/abc-defg-hij"))
                IslandModel.shared.show(.meetingSoon(meeting), for: 2.6)
            }),
        ]),
    ]

    private static func hudSteps() -> [Step] {
        var steps: [Step] = []
        for i in 0..<14 {
            let level = 0.25 + Float(i) * 0.04
            steps.append((0.5 + Double(i) * 0.1, { _ in IslandModel.shared.show(.volume(level, muted: false), for: 1.6) }))
        }
        for i in 0..<12 {
            let level = 0.9 - Float(i) * 0.05
            steps.append((3.2 + Double(i) * 0.1, { _ in IslandModel.shared.show(.brightness(level), for: 1.6) }))
        }
        steps.append((5.9, { _ in IslandModel.shared.show(.battery(level: 86, charging: true, low: false), for: 2) }))
        return steps
    }

    private static let question = "Son git commit'imi değişiklikler kalacak şekilde nasıl geri alırım?"
    private static let answer = "**`git reset --soft HEAD~1`** çalıştır. Commit geri alınır, değişiklikler hazırlık alanında kalır; düzenleyip yeniden commit'leyebilirsin. Hazırlıktan da çıkarmak istersen `--mixed` kullan."

    private static func assistantSteps() -> [Step] {
        var steps = typeSteps(question, from: 0.6, perChar: 0.035)
        steps.append((2.9, { _ in
            AssistantService.shared.draft = ""
            AssistantService.shared.loadPreview([ChatMessage(role: .user, text: question), ChatMessage(role: .assistant, text: "")],
                                                running: true)
        }))
        // The text field sometimes keeps showing a draft cleared in the same update as the send.
        steps.append((3.1, { _ in AssistantService.shared.draft = " " }))
        steps.append((3.2, { _ in AssistantService.shared.draft = "" }))
        steps += streamSteps(answer, from: 3.8, perWord: 0.12)
        return steps
    }

    private static func typeSteps(_ text: String, from start: Double, perChar: Double) -> [Step] {
        (1...text.count).map { n in (start + Double(n) * perChar, { _ in AssistantService.shared.draft = String(text.prefix(n)) }) }
    }

    private static func streamSteps(_ text: String, from start: Double, perWord: Double) -> [Step] {
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        return (1...words.count).map { n in
            (start + Double(n) * perWord, { _ in
                let question = AssistantService.shared.messages.first ?? ChatMessage(role: .user, text: "")
                let answer = ChatMessage(role: .assistant, text: words.prefix(n).joined(separator: " "))
                AssistantService.shared.loadPreview([question, answer], running: n < words.count)
            })
        }
    }
}

/// A desktop for the island to sit on: wallpaper, a menu bar and the notch.
struct DemoStage: View {
    var body: some View {
        ZStack(alignment: .top) {
            // Drawn once: redrawing the gradients made each frame several times slower.
            Image(nsImage: Self.backdrop).resizable()
            RootView().frame(width: 900, height: 320)
        }
        .frame(width: DemoRecorder.stageSize.width, height: DemoRecorder.stageSize.height)
        .environment(\.colorScheme, .dark)
    }

    @MainActor static let backdrop: NSImage = {
        let renderer = ImageRenderer(content: ZStack(alignment: .top) { DemoWallpaper(); DemoMenuBar() }
            .frame(width: DemoRecorder.stageSize.width, height: DemoRecorder.stageSize.height)
            .environment(\.colorScheme, .dark))
        renderer.scale = 2
        return renderer.nsImage ?? NSImage()
    }()
}

struct DemoWallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.06, blue: 0.16), Color(red: 0.13, green: 0.07, blue: 0.22),
                                    Color(red: 0.05, green: 0.1, blue: 0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(red: 0.55, green: 0.3, blue: 1).opacity(0.55), .clear], center: UnitPoint(x: 0.18, y: 0.95),
                           startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Color(red: 1, green: 0.35, blue: 0.55).opacity(0.4), .clear], center: UnitPoint(x: 0.85, y: 0.8),
                           startRadius: 0, endRadius: 380)
            RadialGradient(colors: [Color(red: 0.2, green: 0.65, blue: 1).opacity(0.35), .clear], center: UnitPoint(x: 0.55, y: 1.25),
                           startRadius: 0, endRadius: 460)
        }
    }
}

struct DemoMenuBar: View {
    /// The recording's own time, so it matches the clock in the island's header.
    static let clock: String = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "EEE d MMM  HH:mm"
        return f.string(from: Date())
    }()

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "apple.logo").font(.system(size: 14, weight: .semibold))
            Text("Finder").font(.system(size: 13, weight: .bold))
            ForEach(["Dosya", "Düzen", "Görüntü", "Git", "Pencere", "Yardım"], id: \.self) { Text($0).font(.system(size: 13)) }
            Spacer()
            Image(systemName: "battery.75percent").font(.system(size: 14))
            Image(systemName: "wifi").font(.system(size: 13, weight: .semibold))
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold))
            Text(Self.clock).font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 18)
        .frame(height: 32)
        .background(Color.black.opacity(0.28))
    }
}
#endif
