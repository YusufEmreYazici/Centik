import AppKit
import Combine
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // AppKit keeps ordinary windows out of the menu bar by shifting them down; the island must
    // sit in the menu bar, flush with the top edge, so the frame is taken as given.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

}

/// The panel never becomes key, so every click on it is a "first mouse" click. AppKit's
/// default spends that click on focusing the window; the island's controls must act on it.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The panel only takes keyboard focus where there is something to type into, so clicking
    /// play or a tab never pulls focus away from the app the user is working in.
    override var needsPanelToBecomeKey: Bool {
        let model = IslandModel.shared
        return model.isExpanded && (model.tab == .notes || model.tab == .assistant) && !model.mirrorOn
    }
}

/// Owns the transparent panel pinned over the notch and turns mouse movement into
/// hover, expand and collapse. The panel ignores the mouse everywhere except over the island,
/// so the menu bar and windows underneath keep working.
final class NotchController {
    private let model = IslandModel.shared
    private let panel: NotchPanel
    private var monitors: [Any] = []
    private var hoverWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var cancellables = Set<AnyCancellable>()
    private var hiddenForFullscreen = false

    private static let panelSize = NSSize(width: 900, height: 320)

    init() {
        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        // Set after isFloatingPanel, which would otherwise reset it to the floating level,
        // underneath the menu bar.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true

        let host = IslandHostingView(rootView: RootView())
        host.sizingOptions = []
        // The panel overlaps the notch, so AppKit reports a top safe area the height of the notch.
        // Left alone, SwiftUI pushes the island below the notch instead of onto it.
        host.safeAreaRegions = []
        panel.contentView = host

        reposition()
        panel.orderFrontRegardless()
        installMonitors()
        observeSystem()

        model.$presentation
            .sink { [weak self] p in
                DispatchQueue.main.async {
                    self?.handleMouse()
                    if p != .expanded { self?.releaseKeyboard() }
                }
            }
            .store(in: &cancellables)
    }

    /// Typing into the island makes the panel key. Once it closes, keystrokes must go back to the
    /// app the user was in; re-ordering the panel without making it key hands focus back.
    private func releaseKeyboard() {
        guard panel.isKeyWindow else { return }
        model.keepOpen = false
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    // MARK: Placement

    private func targetScreen() -> NSScreen? {
        if Pref.string(Pref.display) == "builtin" {
            if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) { return notched }
            if let builtin = NSScreen.screens.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }) { return builtin }
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    func reposition() {
        guard let screen = targetScreen() else { return }
        let geometry = NotchGeometry.from(screen)
        if geometry != model.geometry { model.geometry = geometry }
        let f = screen.frame
        panel.setFrame(NSRect(x: f.midX - Self.panelSize.width / 2, y: f.maxY - Self.panelSize.height,
                              width: Self.panelSize.width, height: Self.panelSize.height), display: true)
        IslandModel.log.debug("panel frame \(String(describing: self.panel.frame), privacy: .public) screen \(String(describing: f), privacy: .public)")
    }

    // MARK: Mouse

    private func installMonitors() {
        let moved: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: moved) { [weak self] event in
            if event.type == .leftMouseDragged { self?.handleFileDrag() }
            self?.handleMouse()
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: moved) { [weak self] event in
            self?.handleMouse()
            return event
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self else { return }
            self.dragChangeCount = NSPasteboard(name: .drag).changeCount
            // A click anywhere else closes the expanded island.
            if self.model.isExpanded, !self.model.hitRect().contains(NSEvent.mouseLocation) {
                self.model.collapse()
            }
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            self?.model.isDraggingOut = false
            self?.handleMouse()
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            DispatchQueue.main.async {
                self?.model.isDraggingOut = false
                self?.handleMouse()
            }
            return event
        } as Any)
    }

    private func handleMouse() {
        guard panel.isVisible else { return }
        let inside = model.hitRect().contains(NSEvent.mouseLocation)
        let ignore = !inside && !model.dropTargeted
        if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }

        if inside && !model.hovering {
            model.hovering = true
            collapseWork?.cancel()
            withAnimation(Motion.hover) { model.hoverPeek = true }
            if Pref.bool(Pref.haptics) {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            if Pref.bool(Pref.expandOnHover) && !model.isExpanded {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.model.hovering else { return }
                    self.model.expand()
                }
                hoverWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Pref.double(Pref.hoverDelay), execute: work)
            }
        } else if !inside && model.hovering {
            model.hovering = false
            hoverWork?.cancel()
            withAnimation(Motion.hover) { model.hoverPeek = false }
            if model.isExpanded && !model.isDraggingOut {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, !self.model.hovering, !self.model.isDraggingOut, !self.model.dropTargeted,
                          !self.model.keepOpen else { return }
                    self.model.collapse()
                }
                collapseWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Pref.double(Pref.collapseDelay), execute: work)
            }
        }
    }

    /// Opens the shelf when files are dragged up to the notch from Finder or anywhere else.
    private func handleFileDrag() {
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != dragChangeCount,
              pb.types?.contains(.fileURL) == true,
              !model.isDraggingOut else { return }
        let zone = model.hitRect().insetBy(dx: -50, dy: -40)
        guard zone.contains(NSEvent.mouseLocation) else { return }
        if !model.isExpanded || model.tab != .shelf {
            model.expand(tab: .shelf)
        }
        panel.ignoresMouseEvents = false
    }

    // MARK: System

    private func observeSystem() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.reposition() }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if Pref.string(Pref.display) == "main" { self.reposition() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.updateFullscreenVisibility() }
            }
        }
    }

    func preferencesChanged() {
        reposition()
        updateFullscreenVisibility()
    }

    private func updateFullscreenVisibility() {
        let hide = Pref.bool(Pref.hideInFullscreen) && frontmostAppIsFullscreen()
        guard hide != hiddenForFullscreen else { return }
        hiddenForFullscreen = hide
        if hide {
            model.collapse()
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    /// True when the frontmost app has a normal-level window covering the whole target screen.
    private func frontmostAppIsFullscreen() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != "com.apple.finder",
              let screen = targetScreen(),
              let primary = NSScreen.screens.first else { return false }
        let f = screen.frame
        let cgFrame = CGRect(x: f.minX, y: primary.frame.maxY - f.maxY, width: f.width, height: f.height)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { info in
            guard info[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier,
                  info[kCGWindowLayer as String] as? Int == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return false }
            return bounds.equalTo(cgFrame)
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }
}
