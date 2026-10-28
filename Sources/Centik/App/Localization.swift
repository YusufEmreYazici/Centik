import AppKit

/// The interface language. It follows the Mac's language by default; Settings can pin Turkish
/// or English. The choice is stored as the app's own `AppleLanguages`, which macOS reads at
/// launch, so changing it restarts Çentik.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, tr, en

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return String(localized: "Sistem dili")
        case .tr: return "Türkçe"
        case .en: return "English"
        }
    }

    private static let key = "AppleLanguages"

    /// The choice saved in Çentik's own preferences, not the system-wide list.
    static var chosen: AppLanguage {
        guard let list = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key] as? [String],
              let first = list.first else { return .system }
        return first.hasPrefix("en") ? .en : first.hasPrefix("tr") ? .tr : .system
    }

    /// The language the interface is showing right now.
    static var active: String { Bundle.main.preferredLocalizations.first ?? "tr" }

    /// For case changes and formatting that must follow the interface, like "i" → "İ" in Turkish.
    static var locale: Locale { Locale(identifier: active) }

    /// "%40" in Turkish, "40%" in English.
    static func percent(_ value: Int) -> String { String(localized: "%\(value)") }

    static func choose(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: key)
        }
    }

    /// Starts a new copy of the app once this one has quit.
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The bundle path is passed as $0, not spliced into the script.
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
