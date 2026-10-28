import AppKit

struct AgentEvent: Identifiable, Equatable {
    let id = UUID()
    let source: String
    let kind: String
    let title: String
    let message: String
    let project: String?
    let date: Date
    let needsAttention: Bool

    var sourceName: String {
        switch source {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "cursor": return "Cursor"
        default: return source.capitalized
        }
    }

    var symbol: String { needsAttention ? "hand.raised.fill" : "checkmark.circle.fill" }
}

/// Reads AI coding agent events from a local JSON-lines file.
///
/// Agents append to the file through `centik-hook.sh`, which the user installs as a hook from
/// Settings. Each line is `{"source": "...", "type": "...", "payload": {...}}`; any tool may also
/// write `{"source", "type", "title", "message"}` lines directly. Nothing leaves the machine.
final class AgentService: ObservableObject {
    static let shared = AgentService()

    @Published private(set) var events: [AgentEvent] = []

    var onEvent: ((AgentEvent) -> Void)?

    let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Centik", isDirectory: true)
    var eventsFile: URL { directory.appendingPathComponent("agent-events.jsonl") }
    var hookScript: URL { directory.appendingPathComponent("centik-hook.sh") }

    private var offset: UInt64 = 0
    private var timer: Timer?

    func start() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        writeHookScript()
        // Only show events that arrive after launch.
        offset = fileSize()
        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in self?.poll() }
    }

    func clear() { events.removeAll() }

    private func fileSize() -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: eventsFile.path)[.size] as? UInt64) ?? 0
    }

    private func poll() {
        let size = fileSize()
        if size < offset { offset = 0 }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: eventsFile) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        // Only consume complete lines; a half-written line is picked up next tick.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        offset += UInt64(lastNewline + 1)
        let lines = String(decoding: data[..<lastNewline], as: UTF8.self).split(separator: "\n")
        for line in lines {
            guard let event = Self.parse(String(line)) else { continue }
            events.insert(event, at: 0)
            if events.count > 40 { events.removeLast() }
            onEvent?(event)
        }
        if offset > 512_000 {
            try? Data().write(to: eventsFile)
            offset = 0
        }
    }

    static func parse(_ line: String) -> AgentEvent? {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let source = (obj["source"] as? String ?? "agent").lowercased()
        let type = (obj["type"] as? String ?? "event").lowercased()
        let payload = obj["payload"] as? [String: Any] ?? [:]

        let message = payload["message"] as? String
            ?? payload["last-assistant-message"] as? String
            ?? obj["message"] as? String
            ?? ""
        let project = (payload["cwd"] as? String ?? obj["cwd"] as? String)
            .map { URL(fileURLWithPath: $0).lastPathComponent }

        let attention = type == "notification" || type == "permission" || type == "approval"
        var event = AgentEvent(source: source, kind: type, title: "", message: message, project: project,
                               date: Date(), needsAttention: attention)
        let name = event.sourceName
        let title: String
        if let custom = obj["title"] as? String, !custom.isEmpty {
            title = custom
        } else if attention {
            title = message.localizedCaseInsensitiveContains("permission") ? "\(name) onay bekliyor" : "\(name) seni bekliyor"
        } else if type == "stop" || type == "agent-turn-complete" || type == "notify" {
            title = "\(name) işini bitirdi"
        } else {
            title = name
        }
        event = AgentEvent(source: source, kind: type, title: title, message: message, project: project,
                           date: event.date, needsAttention: attention)
        return event
    }

    private func writeHookScript() {
        let script = """
        #!/bin/sh
        # Çentik agent hook. Appends one JSON line to a local file; sends nothing anywhere.
        # Usage: centik-hook.sh <source> <type> [json]   (JSON is read from stdin when not given)
        src="${1:-agent}"
        type="${2:-event}"
        dir="$HOME/Library/Application Support/Centik"
        mkdir -p "$dir"
        if [ -n "$3" ]; then
            payload="$3"
        elif [ ! -t 0 ]; then
            payload=$(cat)
        fi
        payload=$(printf '%s' "$payload" | tr -d '\\n\\r')
        case "$payload" in
            \\{*) ;;
            *) payload='{}' ;;
        esac
        printf '{"source":"%s","type":"%s","payload":%s}\\n' "$src" "$type" "$payload" >> "$dir/agent-events.jsonl"
        exit 0
        """
        try? script.write(to: hookScript, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScript.path)
    }
}

// MARK: - Hook installation

enum HookError: LocalizedError {
    case invalidFile(String)
    case notifyInUse

    var errorDescription: String? {
        switch self {
        case .invalidFile(let path): return "\(path) geçerli bir JSON nesnesi değil; dosyaya dokunulmadı."
        case .notifyInUse: return "config.toml içinde zaten başka bir `notify` tanımlı; dosyaya dokunulmadı."
        }
    }
}

/// Adds and removes Çentik's entries in agent configuration files. Every write is preceded by
/// a `.centik-backup` copy, and entries that aren't ours are left exactly as they were.
enum HookInstaller {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var claudeSettings: URL { home.appendingPathComponent(".claude/settings.json") }
    static var codexConfig: URL { home.appendingPathComponent(".codex/config.toml") }
    private static let marker = "centik-hook.sh"
    private static let claudeEvents = [("Notification", "notification"), ("Stop", "stop")]

    private static func command(_ source: String, _ type: String) -> String {
        "\"\(AgentService.shared.hookScript.path)\" \(source) \(type)"
    }

    // Claude Code: ~/.claude/settings.json → hooks.<Event>[].hooks[].command

    static var claudeInstalled: Bool {
        guard let data = try? Data(contentsOf: claudeSettings) else { return false }
        return String(decoding: data, as: UTF8.self).contains(marker)
    }

    static func installClaude() throws {
        var root = try readClaude()
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, type) in claudeEvents {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.removeAll(where: isOurs)
            groups.append(["hooks": [["type": "command", "command": command("claude", type)]]])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        try writeClaude(root)
    }

    static func uninstallClaude() throws {
        var root = try readClaude()
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for (event, _) in claudeEvents {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            groups.removeAll(where: isOurs)
            hooks[event] = groups.isEmpty ? nil : groups
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        try writeClaude(root)
    }

    private static func isOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(marker) == true }
    }

    private static func readClaude() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: claudeSettings), !data.isEmpty else { return [:] }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw HookError.invalidFile(claudeSettings.path)
        }
        return obj
    }

    private static func writeClaude(_ root: [String: Any]) throws {
        try backup(claudeSettings)
        try FileManager.default.createDirectory(at: claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: claudeSettings, options: .atomic)
    }

    // Codex: top-level `notify = [...]` in ~/.codex/config.toml; Codex appends a JSON argument.

    static var codexInstalled: Bool {
        ((try? String(contentsOf: codexConfig, encoding: .utf8)) ?? "").contains(marker)
    }

    static func installCodex() throws {
        let text = (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? ""
        if text.contains(marker) { return }
        let hasNotify = text.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("notify")
                && $0.replacingOccurrences(of: " ", with: "").hasPrefix("notify=")
        }
        if hasNotify { throw HookError.notifyInUse }
        let line = "notify = [\"\(AgentService.shared.hookScript.path)\", \"codex\", \"notify\"]"
        try backup(codexConfig)
        try FileManager.default.createDirectory(at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Top-level keys must come before the first [table], so the line goes first.
        try (line + "\n" + text).write(to: codexConfig, atomically: true, encoding: .utf8)
    }

    static func uninstallCodex() throws {
        guard let text = try? String(contentsOf: codexConfig, encoding: .utf8), text.contains(marker) else { return }
        try backup(codexConfig)
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.contains(marker) }
        try kept.joined(separator: "\n").write(to: codexConfig, atomically: true, encoding: .utf8)
    }

    private static func backup(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let dest = url.appendingPathExtension("centik-backup")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: url, to: dest)
    }
}

#if DEBUG
extension AgentService {
    func loadPreview(_ lines: [String]) {
        events = lines.compactMap(Self.parse)
    }
}
#endif
