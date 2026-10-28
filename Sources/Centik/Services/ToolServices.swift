import AppKit
import EventKit
import UniformTypeIdentifiers

// MARK: - Timer

final class TimerService: ObservableObject {
    static let shared = TimerService()

    @Published private(set) var total: TimeInterval = 0
    @Published private(set) var remaining: TimeInterval = 0
    @Published private(set) var isRunning = false

    var onFinish: (() -> Void)?
    var isActive: Bool { total > 0 }
    var progress: Double { total > 0 ? 1 - remaining / total : 0 }

    private var endDate: Date?
    private var tick: Timer?

    func start(minutes: Double) {
        cancel()
        total = minutes * 60
        remaining = total
        resume()
    }

    func resume() {
        guard remaining > 0 else { return }
        endDate = Date().addingTimeInterval(remaining)
        isRunning = true
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(t, forMode: .common)
        tick = t
    }

    func pause() {
        tick?.invalidate()
        if let endDate { remaining = max(0, endDate.timeIntervalSinceNow.rounded()) }
        isRunning = false
    }

    func cancel() {
        tick?.invalidate()
        tick = nil
        endDate = nil
        total = 0
        remaining = 0
        isRunning = false
    }

    func add(minutes: Double) {
        guard isActive else { return start(minutes: minutes) }
        total += minutes * 60
        remaining += minutes * 60
        if isRunning, let endDate { self.endDate = endDate.addingTimeInterval(minutes * 60) }
    }

    private func update() {
        guard let endDate else { return }
        let left = max(0, endDate.timeIntervalSinceNow.rounded(.up))
        if left != remaining { remaining = left }
        if left <= 0 {
            cancel()
            onFinish?()
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - File shelf

/// Files parked on the island. Only references are stored; the files stay where they are.
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    @Published private(set) var urls: [URL] = []

    private init() {
        let paths = UserDefaults.standard.stringArray(forKey: Pref.shelfPaths) ?? []
        urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ new: [URL]) {
        for url in new where !urls.contains(url) { urls.append(url) }
        save()
    }

    @discardableResult
    func add(providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                var url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let u = item as? URL { url = u }
                if let url { DispatchQueue.main.async { self.add([url]) } }
            }
        }
        return !fileProviders.isEmpty
    }

    func remove(_ url: URL) { urls.removeAll { $0 == url }; save() }
    func clear() { urls.removeAll(); save() }
    func open(_ url: URL) { NSWorkspace.shared.open(url) }
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func airDrop(_ items: [URL]? = nil) {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: items ?? urls)
    }

    private func save() {
        UserDefaults.standard.set(urls.map(\.path), forKey: Pref.shelfPaths)
    }
}

// MARK: - Calendar

struct CalEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let color: NSColor
    /// Video call link found in the event's URL, location or notes.
    let joinURL: URL?

    var isOngoing: Bool { !allDay && start <= .now && end > .now }

    private static let meetingPattern = try? NSRegularExpression(
        pattern: #"https?://(?:[\w-]+\.)*(?:zoom\.us/(?:j|my|w|s)/|meet\.google\.com/[a-z]|teams\.microsoft\.com/l/meetup-join/|teams\.live\.com/meet/|webex\.com/|facetime\.apple\.com/join|whereby\.com/)[^\s<>"')\]]*"#,
        options: [.caseInsensitive])

    static func meetingLink(in texts: [String?]) -> URL? {
        for text in texts.compactMap({ $0 }) {
            let range = NSRange(text.startIndex..., in: text)
            if let match = meetingPattern?.firstMatch(in: text, range: range), let r = Range(match.range, in: text) {
                return URL(string: String(text[r]))
            }
        }
        return nil
    }

    var joinServiceName: String {
        let host = joinURL?.host()?.lowercased() ?? ""
        if host.contains("zoom") { return "Zoom" }
        if host.contains("meet.google") { return "Meet" }
        if host.contains("teams") { return "Teams" }
        if host.contains("webex") { return "Webex" }
        if host.contains("facetime") { return "FaceTime" }
        return String(localized: "Toplantı")
    }
}

final class CalendarService: ObservableObject {
    static let shared = CalendarService()

    @Published private(set) var events: [CalEvent] = []
    @Published private(set) var authorized = false
    @Published private(set) var denied = false
    /// The next timed event that starts within the alert window, or is under way.
    @Published private(set) var upcoming: CalEvent?

    /// Fires once per event when it enters the alert window.
    var onMeetingSoon: ((CalEvent) -> Void)?
    private var announced = Set<String>()
    private var tickTimer: Timer?

    private let store = EKEventStore()
    private var timer: Timer?

    func start() {
        updateStatus()
        reload()
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.reload()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.reload() }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// Picks the event to count down to and announces it once.
    func tick() {
        let lead = max(1, Pref.double(Pref.meetingLead)) * 60
        let now = Date()
        let next = events.first { e in
            !e.allDay && e.start.timeIntervalSince(now) <= lead && now < min(e.end, e.start.addingTimeInterval(5 * 60))
        }
        if next?.id != upcoming?.id || next?.start != upcoming?.start { upcoming = next }
        if let next, next.start > now, !announced.contains(next.id), Pref.bool(Pref.meetingAlerts) {
            announced.insert(next.id)
            onMeetingSoon?(next)
        }
    }

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateStatus()
                self?.reload()
            }
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    private func updateStatus() {
        let status = EKEventStore.authorizationStatus(for: .event)
        authorized = status == .fullAccess
        denied = status == .denied || status == .restricted
    }

    func reload() {
        guard authorized, Pref.bool(Pref.calendarEnabled) else { events = []; return }
        let now = Date()
        let cal = Calendar.current
        guard let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) else { return }
        // Late in the evening, still look a couple of hours ahead for the countdown.
        let end = max(midnight, now.addingTimeInterval(2 * 3600))
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        events = store.events(matching: predicate)
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
            .map {
                CalEvent(id: $0.calendarItemIdentifier + "\($0.startDate.timeIntervalSince1970)",
                         title: $0.title ?? String(localized: "Etkinlik"), start: $0.startDate, end: $0.endDate,
                         allDay: $0.isAllDay, color: $0.calendar.color ?? .systemBlue,
                         joinURL: CalEvent.meetingLink(in: [$0.url?.absoluteString, $0.location, $0.notes]))
            }
        tick()
    }
}

#if DEBUG
extension CalendarService {
    func loadPreview(_ preview: [CalEvent]) {
        authorized = true
        events = preview
        upcoming = preview.first { !$0.allDay }
    }
}
#endif
