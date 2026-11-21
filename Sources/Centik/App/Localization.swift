import AppKit

/// The interface language follows the Mac by default or can be set in Settings.
/// macOS reads the app's own `AppleLanguages` at launch, so changing it restarts Çentik.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, tr, en
    case zhHans = "zh-Hans"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return String(localized: "Sistem dili")
        case .tr: return "Türkçe"
        case .en: return "English"
        case .zhHans: return "简体中文"
        }
    }

    private static let key = "AppleLanguages"

    /// The choice saved in Çentik's own preferences, not the system-wide list.
    static var chosen: AppLanguage {
        guard let list = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key] as? [String],
              let first = list.first else { return .system }
        if first.hasPrefix("en") { return .en }
        if first.hasPrefix("tr") { return .tr }
        if first.hasPrefix("zh-Hans") { return .zhHans }
        return .system
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
