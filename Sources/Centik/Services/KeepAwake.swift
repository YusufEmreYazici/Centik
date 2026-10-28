import AppKit
import EventKit
import IOKit.pwr_mgt

/// Keeps the Mac and its display awake, like `caffeinate -d`, until turned off or the timer ends.
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()

    @Published private(set) var isOn = false
    @Published private(set) var until: Date?

    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?

    func toggle() { isOn ? stop() : start() }

    func start(for duration: TimeInterval? = nil) {
        if !isOn {
            let reason = "Çentik: Uyanık tut" as CFString
            guard IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                              IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &assertion) == kIOReturnSuccess
            else { return }
            isOn = true
        }
        timer?.invalidate()
        until = duration.map { Date().addingTimeInterval($0) }
        if let duration {
            timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in self?.stop() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if isOn { IOPMAssertionRelease(assertion) }
        isOn = false
        until = nil
    }
}

/// Current state of the permissions Çentik uses, read without triggering a system prompt.
enum PermissionState: Equatable {
    case granted, denied, notAsked, appNotRunning, unavailable

    var label: String {
        switch self {
        case .granted: return "İzin verildi"
        case .denied: return "Reddedildi"
        case .notAsked: return "Henüz sorulmadı"
        case .appNotRunning: return "Uygulama kapalı"
        case .unavailable: return "Yüklü değil"
        }
    }
}

enum Permissions {
    /// Automation permission for controlling another app.
    ///
    /// The Apple Events call blocks until the target answers, and it never returns when the
    /// target isn't running, so it is only made for running apps, off the main thread, with a
    /// time limit. `ask` shows the system prompt if the user hasn't decided yet.
    static func automation(_ bundleID: String, ask: Bool = false, completion: @escaping (PermissionState) -> Void) {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
            return completion(.unavailable)
        }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
            return completion(.appNotRunning)
        }
        let lock = NSLock()
        var finished = false
        let finish: (PermissionState) -> Void = { state in
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            DispatchQueue.main.async { completion(state) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
            let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
            switch status {
            case noErr: finish(.granted)
            case OSStatus(errAEEventNotPermitted): finish(.denied)
            case OSStatus(procNotFound): finish(.appNotRunning)
            default: finish(.notAsked)
            }
        }
        // Waiting on the user's answer to a prompt can take a while; a plain check should not.
        DispatchQueue.main.asyncAfter(deadline: .now() + (ask ? 60 : 3)) { finish(.notAsked) }
    }

    static var calendar: PermissionState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .denied, .restricted, .writeOnly: return .denied
        default: return .notAsked
        }
    }

    static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
