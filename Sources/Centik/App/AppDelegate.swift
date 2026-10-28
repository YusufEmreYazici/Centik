import AppKit
import Carbon
import SwiftUI

@main
@MainActor
enum CentikMain {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        #if DEBUG
        Snapshot.runIfRequested()
        SysProbe.runIfRequested()
        ProcProbe.runIfRequested()
        ClaudeProbe.runIfRequested()
        if DemoRecorder.requested {
            let recorder = DemoRecorder()
            app.delegate = recorder
            app.setActivationPolicy(.accessory)
            app.run()
            return
        }
        #endif
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Pref.register()

        MusicService.shared.start()
        AudioService.shared.start()
        BrightnessService.shared.start()
        BatteryService.shared.start()
        NetworkService.shared.start()
        ClipboardService.shared.start()
        CalendarService.shared.start()
        AgentService.shared.start()
        WeatherService.shared.start()

        controller = NotchController()
        wireEvents()
        applyPreferences()

        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyPreferences()
        }

        // Scripting hook: post "com.emre.centik.open" (object: a tab name, or nil),
        // "com.emre.centik.close" or "com.emre.centik.settings" from Shortcuts or a script.
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.emre.centik.open"), object: nil, queue: .main) { note in
            IslandModel.shared.expand(tab: (note.object as? String).flatMap(IslandTab.init(rawValue:)))
        }
        dnc.addObserver(forName: .init("com.emre.centik.close"), object: nil, queue: .main) { _ in
            IslandModel.shared.collapse()
        }
        dnc.addObserver(forName: .init("com.emre.centik.settings"), object: nil, queue: .main) { note in
            SettingsWindow.shared.show(page: (note.object as? String).flatMap(SettingsPage.init(rawValue:)))
        }
    }

    private func applyPreferences() {
        updateStatusItem()
        if Pref.bool(Pref.hotKeyEnabled) {
            if hotKey == nil {
                // ⌃⌥N toggles the island from anywhere.
                hotKey = HotKey(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey)) {
                    IslandModel.shared.toggle()
                }
            }
        } else {
            hotKey = nil
        }
        controller?.preferencesChanged()
        IslandModel.shared.validateTab()
        CaptureService.shared.apply()
        IslandModel.shared.recompute()
    }

    private func wireEvents() {
        let model = IslandModel.shared
        let hudDuration = { max(0.8, Pref.double(Pref.hudDuration)) }

        AudioService.shared.onChange = { volume, muted in
            guard Pref.bool(Pref.volumeHUD), !model.isExpanded else { return }
            model.show(.volume(volume, muted: muted), for: hudDuration())
        }
        BrightnessService.shared.onChange = { value in
            guard Pref.bool(Pref.brightnessHUD), !model.isExpanded else { return }
            model.show(.brightness(value), for: hudDuration())
        }
        BatteryService.shared.onEvent = { event in
            guard Pref.bool(Pref.batteryAlerts), !model.isExpanded else { return }
            switch event {
            case .pluggedIn(let level, let charging):
                model.show(.battery(level: level, charging: charging || level < 100, low: false), for: 2.5)
            case .unplugged(let level):
                model.show(.battery(level: level, charging: false, low: false), for: 2)
            case .low(let level):
                model.show(.battery(level: level, charging: false, low: true), for: 4)
                NSSound(named: "Funk")?.play()
            }
        }
        NetworkService.shared.onEvent = { title, symbol, ok in
            guard Pref.bool(Pref.networkAlerts), !model.isExpanded else { return }
            model.show(.network(title: title, symbol: symbol, ok: ok), for: 3)
        }
        MusicService.shared.onTrackChange = {
            guard Pref.bool(Pref.trackPreview), !model.isExpanded else { return }
            // Let the artwork arrive before the preview pops.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { model.show(.track, for: 3) }
        }
        TimerService.shared.onFinish = {
            NSSound(named: "Glass")?.play()
            model.show(.timerDone, for: 6)
        }
        AgentService.shared.onEvent = { event in
            guard Pref.bool(Pref.agentAlerts) else { return }
            if Pref.bool(Pref.agentSound) {
                NSSound(named: event.needsAttention ? "Ping" : "Hero")?.play()
            }
            if !model.isExpanded {
                model.show(.agent(event), for: event.needsAttention ? 8 : 5)
            }
        }
        CaptureService.shared.onCapture = { event in
            guard !model.isExpanded else { return }
            model.show(.capture(event), for: 5)
        }
        CalendarService.shared.onMeetingSoon = { event in
            NSSound(named: "Purr")?.play()
            if !model.isExpanded { model.show(.meetingSoon(event), for: 6) }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            if Pref.bool(Pref.unlockSound) {
                NSSound(named: Pref.string(Pref.unlockSoundName))?.play()
            }
            if Pref.bool(Pref.unlockIcon) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.show(.unlock, for: 1.6) }
            }
        }
    }

    // MARK: Menu bar

    private func updateStatusItem() {
        let wanted = Pref.bool(Pref.showMenuBarIcon)
        if wanted, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "capsule.portrait.tophalf.filled", accessibilityDescription: "Çentik")
                ?? NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Çentik")
            let menu = NSMenu()
            menu.addItem(withTitle: "Çentiği Aç  (⌃⌥N)", action: #selector(openIsland), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Rafı Aç", action: #selector(openShelf), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Ayarlar…", action: #selector(openSettings), keyEquivalent: ",").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Çentik'ten Çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            item.menu = menu
            statusItem = item
        } else if !wanted, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc private func openIsland() { IslandModel.shared.expand(tab: .home) }
    @objc private func openShelf() { IslandModel.shared.expand(tab: .shelf) }
    @objc func openSettings() { SettingsWindow.shared.show() }
}

/// System-wide hot key through Carbon; needs no Accessibility permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static var action: (() -> Void)?

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        HotKey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x434E544B), id: 1)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show(page: SettingsPage? = nil) {
        if let page { SettingsRouter.shared.page = page }
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Çentik Ayarları"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
