import AppKit
import Combine
import OSLog
import SwiftUI

struct NotchGeometry: Equatable {
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var hasNotch: Bool
    var screenFrame: NSRect

    static func from(_ screen: NSScreen) -> NotchGeometry {
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return NotchGeometry(notchWidth: width, notchHeight: top, hasNotch: true, screenFrame: screen.frame)
        }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchGeometry(notchWidth: 180, notchHeight: max(24, menuBar), hasNotch: false, screenFrame: screen.frame)
    }
}

/// Short-lived things the island pops up for.
enum Transient: Equatable {
    case volume(Float, muted: Bool)
    case brightness(Float)
    case battery(level: Int, charging: Bool, low: Bool)
    case unlock
    case network(title: String, symbol: String, ok: Bool)
    case agent(AgentEvent)
    case meetingSoon(CalEvent)
    case capture(CaptureEvent)
    case track
    case timerDone

    /// Peek transients grow a text row below the notch; the rest live in the side wings.
    var isPeek: Bool {
        switch self {
        case .network, .agent, .track, .timerDone, .meetingSoon, .capture: return true
        default: return false
        }
    }
}

enum Presentation: Equatable {
    case idle, music, timer, system, meeting, expanded
    case transient(Transient)
}

enum IslandTab: String, CaseIterable, Identifiable {
    case home, system, shelf, clipboard, timer, notes
    case assistant = "claude"   // raw value kept so saved tab order and hidden tabs still match
    case agents
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .system: return "gauge.with.dots.needle.50percent"
        case .notes: return "checklist"
        case .assistant: return "bubble.left.and.text.bubble.right.fill"
        case .shelf: return "tray.full.fill"
        case .clipboard: return "doc.on.clipboard.fill"
        case .timer: return "timer"
        case .agents: return "sparkles"
        }
    }
    var title: String {
        switch self {
        case .home: return String(localized: "Ana")
        case .system: return String(localized: "Sistem")
        case .notes: return String(localized: "Notlar")
        case .assistant: return AssistantService.shared.name
        case .shelf: return String(localized: "Raf")
        case .clipboard: return String(localized: "Pano")
        case .timer: return String(localized: "Zamanlayıcı")
        case .agents: return String(localized: "Ajanlar")
        }
    }
}

final class IslandModel: ObservableObject {
    static let shared = IslandModel()

    static let log = Logger(subsystem: "com.emre.centik", category: "island")

    @Published var geometry = NotchGeometry(notchWidth: 180, notchHeight: 32, hasNotch: false, screenFrame: .zero)
    @Published private(set) var presentation: Presentation = .idle
    @Published var tab: IslandTab = .home {
        didSet { Self.log.debug("tab -> \(self.tab.rawValue, privacy: .public)") }
    }
    @Published var dropTargeted = false
    /// The pointer is over the collapsed island: it swells slightly, like it is about to open.
    @Published var hoverPeek = false
    /// The camera mirror replaces the tab content while on.
    @Published var mirrorOn = false
    /// Set while text is being typed, so moving the pointer away doesn't close the island.
    var keepOpen = false

    var hovering = false
    var isDraggingOut = false
    private(set) var isExpanded = false
    private var transient: Transient?
    private var dismissWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        MusicService.shared.$isPlaying.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.recompute() } }
            .store(in: &cancellables)
        CalendarService.shared.$upcoming.map { $0?.id }.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.recompute() } }
            .store(in: &cancellables)
        TimerService.shared.$total.map { $0 > 0 }.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.recompute() } }
            .store(in: &cancellables)
    }

    /// Tabs in the user's order, without the ones turned off. Never empty.
    var visibleTabs: [IslandTab] {
        let hidden = Set(Pref.string(Pref.hiddenTabs).split(separator: ",").compactMap { IslandTab(rawValue: String($0)) })
        let saved = Pref.string(Pref.tabOrder).split(separator: ",").compactMap { IslandTab(rawValue: String($0)) }
        let ordered = saved + IslandTab.allCases.filter { !saved.contains($0) }
        let visible = ordered.filter { !hidden.contains($0) }
        return visible.isEmpty ? [.home] : visible
    }

    /// Moves off a tab that has just been turned off.
    func validateTab() {
        let visible = visibleTabs
        if !visible.contains(tab), let first = visible.first { tab = first }
    }

    func expand(tab: IslandTab? = nil) {
        let visible = visibleTabs
        if let tab, visible.contains(tab) {
            self.tab = tab
        } else if !isExpanded, let start = IslandTab(rawValue: Pref.string(Pref.openTab)), visible.contains(start) {
            self.tab = start
        }
        validateTab()
        isExpanded = true
        recompute()
    }

    func collapse() {
        isExpanded = false
        mirrorOn = false
        recompute()
    }

    func toggle() { isExpanded ? collapse() : expand() }

    func show(_ t: Transient, for seconds: TimeInterval) {
        transient = t
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.transient = nil
            self?.recompute()
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds * DemoClock.slowdown, execute: work)
        recompute()
    }

    private var liveMode: String { Pref.string(Pref.liveActivity) }

    private var showsMusic: Bool {
        Pref.bool(Pref.musicEnabled) && MusicService.shared.isPlaying && liveMode != "system" && liveMode != "off"
    }

    func recompute() {
        let next: Presentation
        if isExpanded {
            next = .expanded
        } else if let transient {
            next = .transient(transient)
        } else if CalendarService.shared.upcoming != nil && Pref.bool(Pref.meetingAlerts) {
            next = .meeting
        } else if TimerService.shared.isActive {
            next = .timer
        } else if showsMusic {
            next = .music
        } else if liveMode == "system" || liveMode == "musicThenSystem" {
            next = .system
        } else {
            next = .idle
        }
        guard next != presentation else { return }
        Self.log.debug("presentation -> \(String(describing: next), privacy: .public)")
        withAnimation(Motion.island) { presentation = next }
    }

    // MARK: Layout

    var wingWidth: CGFloat { geometry.notchHeight + 18 + CGFloat(Pref.double(Pref.islandExtraWidth)) / 2 }

    func radii(for p: Presentation) -> (top: CGFloat, bottom: CGFloat) {
        switch p {
        case .idle: return (6, 10)
        case .music, .timer, .system, .meeting: return (6, 13)
        case .transient(let t): return t.isPeek ? (8, 20) : (6, 13)
        case .expanded: return (10, 28)
        }
    }

    func size(for p: Presentation) -> CGSize {
        let base = baseSize(for: p)
        guard hoverPeek, p != .expanded, Pref.bool(Pref.hoverGrow) else { return base }
        let grow: (CGFloat, CGFloat) = p == .idle ? (18, 5) : (10, 3)
        return CGSize(width: base.width + grow.0, height: base.height + grow.1)
    }

    private func baseSize(for p: Presentation) -> CGSize {
        let nw = geometry.notchWidth, h = geometry.notchHeight
        let top = radii(for: p).top * 2
        let wings = nw + wingWidth * 2 + top
        switch p {
        case .idle:
            return CGSize(width: nw + top, height: h)
        case .music, .timer, .system, .meeting:
            return CGSize(width: wings, height: h)
        case .transient(let t):
            return t.isPeek ? CGSize(width: max(wings, 400), height: h + 46) : CGSize(width: wings, height: h)
        case .expanded:
            return CGSize(width: max(nw + 460, 760), height: h + 216)
        }
    }

    /// Island rectangle in screen coordinates, used for hover and click hit-testing.
    func hitRect() -> NSRect {
        let s = size(for: presentation)
        let f = geometry.screenFrame
        var rect = NSRect(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height)
        if presentation == .idle && !hoverPeek {
            // Generous target around the hardware notch; a thin strip at the top edge without one.
            rect = geometry.hasNotch
                ? rect.insetBy(dx: -12, dy: 0)
                : NSRect(x: f.midX - 110, y: f.maxY - 6, width: 220, height: 6)
        }
        return rect
    }
}
