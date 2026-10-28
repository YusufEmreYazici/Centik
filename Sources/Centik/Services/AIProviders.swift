import Foundation
import Security

/// Where the assistant tab's answers come from. Every provider uses the person's own account:
/// a command-line tool they're signed in to, an API key they paste, or a local Ollama server.
enum AIProvider: String, CaseIterable, Identifiable {
    case auto, claudeCode, geminiCLI, anthropicAPI, geminiAPI, ollama

    var id: String { rawValue }

    /// The providers `auto` picks from, in the order it tries them. Ollama is only used when
    /// chosen: anything listening on its port would otherwise receive the conversation.
    static let concrete: [AIProvider] = [.claudeCode, .geminiCLI, .anthropicAPI, .geminiAPI]

    var title: String {
        switch self {
        case .auto: return String(localized: "Otomatik")
        case .claudeCode: return "Claude Code"
        case .geminiCLI: return "Gemini CLI"
        case .anthropicAPI: return "Claude API"
        case .geminiAPI: return "Gemini API"
        case .ollama: return "Ollama"
        }
    }

    /// The name shown on the tab and in the chat.
    var assistantName: String {
        switch self {
        case .auto: return String(localized: "Asistan")
        case .claudeCode, .anthropicAPI: return "Claude"
        case .geminiCLI, .geminiAPI: return "Gemini"
        case .ollama: return "Ollama"
        }
    }

    /// AgentAvatar source for the provider's logo color.
    var avatar: String {
        switch self {
        case .auto: return "assistant"
        case .claudeCode, .anthropicAPI: return "claude"
        case .geminiCLI, .geminiAPI: return "gemini"
        case .ollama: return "ollama"
        }
    }

    var summary: String {
        switch self {
        case .auto: return String(localized: "Önce kurulu araçlara, sonra kayıtlı anahtarlara bakar.")
        case .claudeCode: return String(localized: "Bilgisayardaki Claude Code oturumu. Claude aboneliği ya da API kredisi kullanır.")
        case .geminiCLI: return String(localized: "Bilgisayardaki Gemini CLI. Google hesabıyla giriş ücretsizdir.")
        case .anthropicAPI: return String(localized: "Anthropic API anahtarı. Kullandıkça ücretlendirilir.")
        case .geminiAPI: return String(localized: "Google AI Studio anahtarı. Ücretsiz katmanı vardır.")
        case .ollama: return String(localized: "Bilgisayarda çalışan yerel modeller. Ücretsiz, internete bir şey gitmez.")
        }
    }

    /// Keychain account for providers that take an API key.
    var keyAccount: String? {
        switch self {
        case .anthropicAPI: return "anthropic"
        case .geminiAPI: return "gemini"
        default: return nil
        }
    }

    /// Where to get a key, or how to install the tool.
    var helpURL: URL? {
        switch self {
        case .anthropicAPI: return URL(string: "https://console.anthropic.com/settings/keys")
        case .geminiAPI: return URL(string: "https://aistudio.google.com/apikey")
        case .claudeCode: return URL(string: "https://claude.com/claude-code")
        case .geminiCLI: return URL(string: "https://github.com/google-gemini/gemini-cli")
        case .ollama: return URL(string: "https://ollama.com/download")
        case .auto: return nil
        }
    }

    var modelPref: String { "aiModel.\(rawValue)" }
}

struct ModelOption: Identifiable, Hashable {
    let id: String     // "" is the provider's own default
    let name: String
}

struct ProviderStatus: Equatable {
    let ready: Bool
    let text: String
}

// MARK: - Keychain

/// API keys live in the login keychain, never in preferences or files.
enum Keychain {
    private static let service = "com.emre.centik.ai"

    static func get(_ account: String) -> String? {
        #if DEBUG
        // Lets probes try a key without touching the keychain.
        if let key = ProcessInfo.processInfo.environment["CENTIK_KEY_\(account.uppercased())"] { return key }
        #endif
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for account: String) {
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(match as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = match
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - Finding command-line tools

/// Apps started from Finder get a minimal PATH, so tools installed with Homebrew, npm or a Node
/// version manager aren't visible. This reads the PATH the user's own shell sets up, once.
enum ShellEnvironment {
    static let path: String = {
        let fallback = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let marker = "__CENTIK_PATH__"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: shell)
        task.arguments = ["-ilc", "printf '%s\\n' \"\(marker)$PATH\""]
        task.standardInput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        let out = Pipe()
        task.standardOutput = out
        let done = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in done.signal() }
        guard (try? task.run()) != nil else { return fallback }
        if done.wait(timeout: .now() + 4) == .timedOut {
            task.terminate()
            return fallback
        }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix(marker) }) else { return fallback }
        var found = String(line.dropFirst(marker.count))
        #if DEBUG
        if let extra = ProcessInfo.processInfo.environment["CENTIK_EXTRA_PATH"] { found = extra + ":" + found }
        #endif
        return found.isEmpty ? fallback : found + ":" + fallback
    }()

    static func find(_ name: String, extra: [String] = []) -> URL? {
        let home = NSHomeDirectory()
        let dirs = extra.map { $0.replacingOccurrences(of: "~", with: home) } + path.split(separator: ":").map(String.init)
        return dirs.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The environment for a child tool: the user's PATH, so `#!/usr/bin/env node` scripts start.
    static var childEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        return env
    }
}

// MARK: - Backends

struct ChatRequest {
    let history: [ChatMessage]   // earlier turns, oldest first, without the new message
    let prompt: String           // the new message, with the context line in front
    let model: String            // "" for the provider's default
    let system: String
    let sessionID: String?       // command-line tools keep the conversation themselves
}

enum BackendEvent {
    case text(String)
    case session(String)
    case failed(String)
    case finished
}

/// One answer being produced. Events arrive on the main queue; `finished` or `failed` comes last.
protocol ChatBackend: AnyObject {
    func start(_ request: ChatRequest, emit: @escaping (BackendEvent) -> Void)
    func cancel()
}

/// Runs a signed-in command-line tool and reads its newline-delimited JSON stream.
class CLIBackend: ChatBackend {
    let executable: URL
    let directory: URL
    private var process: Process?
    private var buffer = Data()
    private var errorOutput = Data()
    private var cancelled = false
    private(set) var gotText = false
    private var ended = false
    private var emit: (BackendEvent) -> Void = { _ in }

    init(executable: URL, directory: URL) {
        self.executable = executable
        self.directory = directory
    }

    func arguments(for request: ChatRequest) -> [String] { [] }
    func environment(for request: ChatRequest) -> [String: String] { ShellEnvironment.childEnvironment }
    func handle(_ event: [String: Any]) {}
    /// Turns the tool's error output into something a person can act on.
    func explain(stderr: String, status: Int32) -> String {
        stderr.isEmpty ? String(localized: "Yanıt gelmedi (çıkış kodu \(status)).") : String(stderr.suffix(400))
    }

    func send(_ event: BackendEvent) {
        guard !ended else { return }
        switch event {
        case .text: gotText = true
        case .failed, .finished: ended = true
        case .session: break
        }
        emit(event)
    }

    func start(_ request: ChatRequest, emit: @escaping (BackendEvent) -> Void) {
        self.emit = emit
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let task = Process()
        task.executableURL = executable
        task.arguments = arguments(for: request)
        task.environment = environment(for: request)
        task.currentDirectoryURL = directory
        task.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            DispatchQueue.main.async { self?.consume(chunk) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            DispatchQueue.main.async { self?.errorOutput.append(chunk) }
        }
        task.terminationHandler = { [weak self] finished in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let status = finished.terminationStatus
            DispatchQueue.main.async { self?.finish(status: status) }
        }
        do {
            try task.run()
            process = task
        } catch {
            send(.failed(String(localized: "\(executable.lastPathComponent) başlatılamadı: \(error.localizedDescription)")))
        }
    }

    func cancel() {
        cancelled = true
        process?.terminate()
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            handle(event)
        }
    }

    private func finish(status: Int32) {
        consume(Data("\n".utf8))
        process = nil
        if cancelled {
            send(.failed(String(localized: "Durduruldu.")))
        } else if status != 0 && !gotText {
            let detail = String(decoding: errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            send(.failed(explain(stderr: detail, status: status)))
        } else {
            send(.finished)
        }
    }
}

/// Claude Code in print mode, with every tool off and its agent prompt replaced by a chat prompt.
/// Its agent prompt describes tools; without them the model writes tool calls out as text and loops.
final class ClaudeCodeBackend: CLIBackend {
    static var executable: URL? {
        ShellEnvironment.find("claude", extra: ["~/.local/bin", "~/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"])
    }

    static let models = [ModelOption(id: "", name: String(localized: "Claude Code varsayılanı")), ModelOption(id: "opus", name: String(localized: "Opus (en güçlü)")),
                         ModelOption(id: "sonnet", name: String(localized: "Sonnet (hızlı)")), ModelOption(id: "haiku", name: String(localized: "Haiku (en hızlı)"))]

    override func arguments(for request: ChatRequest) -> [String] {
        // Only project settings load, so the user's hooks (Çentik's own included) don't fire.
        var args = ["-p", request.prompt, "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--tools", "", "--setting-sources", "project", "--disable-slash-commands", "--strict-mcp-config",
                    "--system-prompt", request.system]
        if let id = request.sessionID {
            args += ["--resume", id]
        } else {
            let id = UUID().uuidString.lowercased()
            send(.session(id))
            args += ["--session-id", id]
        }
        if !request.model.isEmpty { args += ["--model", request.model] }
        return args
    }

    override func handle(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "stream_event":
            let inner = event["event"] as? [String: Any]
            if inner?["type"] as? String == "content_block_delta",
               let delta = inner?["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                send(.text(text))
            }
        case "result":
            if let id = event["session_id"] as? String { send(.session(id)) }
            if event["is_error"] as? Bool == true {
                send(.failed(event["result"] as? String ?? String(localized: "Claude bir hata döndürdü.")))
            } else if !gotText, let full = event["result"] as? String {
                send(.text(full))   // some runs only report the final text
            }
        default:
            break
        }
    }

    override func explain(stderr: String, status: Int32) -> String {
        if stderr.localizedCaseInsensitiveContains("login") || stderr.localizedCaseInsensitiveContains("auth") {
            return String(localized: "Claude Code'a giriş yapılmamış. Terminalde claude yazıp bir kez giriş yap.")
        }
        return super.explain(stderr: stderr, status: status)
    }
}

/// Gemini CLI in headless mode. Its system prompt is replaced through GEMINI_SYSTEM_MD, and a
/// policy file limits its tools to Google Search: no files, no shell. The person's extensions
/// and MCP servers are left out.
final class GeminiCLIBackend: CLIBackend {
    static var executable: URL? {
        ShellEnvironment.find("gemini", extra: ["/opt/homebrew/bin", "/usr/local/bin", "~/.npm-global/bin",
                                                "~/.local/share/fnm/aliases/default/bin", "~/.volta/bin"])
    }

    static var signedIn: Bool {
        // Gemini CLI finds its folder through HOME, so look where it will.
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let dir = URL(fileURLWithPath: home).appendingPathComponent(".gemini")
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("oauth_creds.json").path) { return true }
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".env").path) { return true }
        let settings = (try? String(contentsOf: dir.appendingPathComponent("settings.json"), encoding: .utf8)) ?? ""
        return settings.contains("selectedType")
    }

    /// Gemini CLI's own aliases, so new model versions are picked up without a Çentik update.
    static let models = [ModelOption(id: "", name: String(localized: "Otomatik (önerilen)")), ModelOption(id: "pro", name: String(localized: "Pro (en güçlü)")),
                         ModelOption(id: "flash", name: String(localized: "Flash (hızlı)")), ModelOption(id: "flash-lite", name: String(localized: "Flash-Lite (en hızlı)"))]

    /// Denies every tool except web search. Denied tools aren't shown to the model at all; the
    /// `tools.core` setting alone still leaves the read-only file tools on.
    private static let policy = """
    [[rule]]
    toolName = "*"
    decision = "deny"
    priority = 900

    [[rule]]
    toolName = "google_web_search"
    decision = "allow"
    priority = 950
    """

    private var systemFile: URL { directory.appendingPathComponent(".gemini/system.md") }

    override func arguments(for request: ChatRequest) -> [String] {
        let config = directory.appendingPathComponent(".gemini", isDirectory: true)
        try? FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let settings: [String: Any] = ["tools": ["core": ["google_web_search"]]]
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted]) {
            try? data.write(to: config.appendingPathComponent("settings.json"), options: .atomic)
        }
        let policyFile = config.appendingPathComponent("centik-policy.toml")
        try? Self.policy.write(to: policyFile, atomically: true, encoding: .utf8)
        try? (request.system + "\n\nYou may use Google Search for live information such as news or exchange rates. "
              + "You can't read or write files or run commands.").write(to: systemFile, atomically: true, encoding: .utf8)

        var args = ["-p", request.prompt, "--output-format", "stream-json", "--skip-trust",
                    "--extensions", "none", "--allowed-mcp-server-names", "centik-none", "--policy", policyFile.path]
        if let id = request.sessionID {
            args += ["--resume", id]
        } else {
            let id = UUID().uuidString.lowercased()
            send(.session(id))
            args += ["--session-id", id]
        }
        if !request.model.isEmpty { args += ["--model", request.model] }
        return args
    }

    override func environment(for request: ChatRequest) -> [String: String] {
        var env = super.environment(for: request)
        env["GEMINI_SYSTEM_MD"] = systemFile.path
        return env
    }

    override func handle(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "init":
            if let id = event["session_id"] as? String { send(.session(id)) }
        case "message":
            guard event["role"] as? String == "assistant", let text = event["content"] as? String else { return }
            // Deltas stream the answer; a whole message only counts if nothing streamed.
            if event["delta"] as? Bool == true || !gotText { send(.text(text)) }
        case "result":
            if event["status"] as? String == "error" || event["error"] != nil {
                let error = event["error"] as? [String: Any]
                send(.failed(error?["message"] as? String ?? String(localized: "Gemini bir hata döndürdü.")))
            }
        default:
            break
        }
    }

    override func explain(stderr: String, status: Int32) -> String {
        if stderr.localizedCaseInsensitiveContains("auth") || stderr.localizedCaseInsensitiveContains("login") {
            return String(localized: "Gemini CLI'ya giriş yapılmamış. Terminalde gemini yazıp Google hesabınla giriş yap.")
        }
        if stderr.contains("env: node") || stderr.localizedCaseInsensitiveContains("node: No such file") {
            return String(localized: "Gemini CLI için Node.js bulunamadı.")
        }
        return super.explain(stderr: stderr, status: status)
    }
}

/// Streams an answer over HTTPS. Subclasses build the request and read one line of the stream.
class HTTPBackend: ChatBackend {
    private var task: Task<Void, Never>?
    private(set) var gotText = false
    private var ended = false
    private var emit: (BackendEvent) -> Void = { _ in }

    func makeRequest(_ request: ChatRequest) throws -> URLRequest { fatalError("override") }
    func handle(line: String) {}
    func errorMessage(status: Int, body: Data) -> String {
        Self.apiError(body) ?? String(localized: "Sunucu \(status) hatası döndürdü.")
    }

    static func apiError(_ body: Data) -> String? {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        if let error = json?["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let error = json?["error"] as? String { return error }
        return nil
    }

    func send(_ event: BackendEvent) {
        DispatchQueue.main.async { [self] in
            guard !ended else { return }
            switch event {
            case .text: gotText = true
            case .failed, .finished: ended = true
            case .session: break
            }
            emit(event)
        }
    }

    func start(_ request: ChatRequest, emit: @escaping (BackendEvent) -> Void) {
        self.emit = emit
        let urlRequest: URLRequest
        do { urlRequest = try makeRequest(request) } catch {
            send(.failed(error.localizedDescription))
            return
        }
        task = Task { [weak self] in
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status != 200 {
                    var body = Data()
                    for try await byte in bytes { body.append(byte) }
                    self?.send(.failed(self?.errorMessage(status: status, body: body) ?? ""))
                    return
                }
                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    self?.handle(line: line)
                }
                self?.send(Task.isCancelled ? .failed(String(localized: "Durduruldu.")) : .finished)
            } catch is CancellationError {
                self?.send(.failed(String(localized: "Durduruldu.")))
            } catch let error as URLError where error.code == .cancelled {
                self?.send(.failed(String(localized: "Durduruldu.")))
            } catch {
                self?.send(.failed(self?.connectionError(error) ?? error.localizedDescription))
            }
        }
    }

    func connectionError(_ error: Error) -> String { String(localized: "Bağlanılamadı: \(error.localizedDescription)") }

    func cancel() { task?.cancel() }

    /// Earlier turns as alternating user/assistant pairs, starting with the user, errors left out.
    static func turns(_ history: [ChatMessage]) -> [(role: ChatMessage.Role, text: String)] {
        var turns: [(role: ChatMessage.Role, text: String)] = []
        for message in history where !message.isError && !message.text.isEmpty {
            if turns.isEmpty && message.role != .user { continue }
            if turns.last?.role == message.role {
                turns[turns.count - 1].text += "\n\n" + message.text
            } else {
                turns.append((message.role, message.text))
            }
        }
        if turns.last?.role == .user { turns.removeLast() }   // its answer failed; the new prompt follows
        return turns.suffix(40).drop(while: { $0.role != .user }).map { $0 }
    }
}

/// The Claude Messages API with the person's own key.
final class AnthropicBackend: HTTPBackend {
    static let defaultModel = "claude-opus-5-5"
    private static let version = "2026-10-21"

    static func headers(_ key: String) -> [String: String] {
        ["x-api-key": key, "anthropic-version": version, "content-type": "application/json"]
    }

    static func models(key: String) async throws -> [ModelOption] {
        var request = URLRequest(url: URL(string: "\(Endpoint.anthropic)/v1/models?limit=100")!)
        headers(key).forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        let list = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["data"] as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return ModelOption(id: id, name: item["display_name"] as? String ?? id)
        }
    }

    override func makeRequest(_ request: ChatRequest) throws -> URLRequest {
        guard let key = Keychain.get("anthropic") else { throw ProviderError(String(localized: "Claude API anahtarı kayıtlı değil.")) }
        let model = request.model.isEmpty ? Self.defaultModel : request.model
        var messages: [[String: Any]] = Self.turns(request.history).map { ["role": $0.role.rawValue, "content": $0.text] }
        messages.append(["role": "user", "content": request.prompt])
        var body: [String: Any] = ["model": model, "max_tokens": 16000, "stream": true, "system": request.system, "messages": messages]
        // Chat answers don't need deep thinking; low effort keeps them quick and cheap.
        let effortFamilies = ["claude-opus-5", "claude-sonnet-5", "claude-haiku-5", "claude-fable-5",
                              "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-sonnet-4-6"]
        if effortFamilies.contains(where: model.hasPrefix) { body["output_config"] = ["effort": "low"] }
        var url = URLRequest(url: URL(string: "\(Endpoint.anthropic)/v1/messages")!)
        url.httpMethod = "POST"
        Self.headers(key).forEach { url.setValue($1, forHTTPHeaderField: $0) }
        // A declined request is retried on Anthropic's recommended fallback model instead of failing.
        if ["claude-opus-5", "claude-fable-5-1", "claude-sonnet-5-5"].contains(where: model.hasPrefix) {
            body["fallbacks"] = "default"
            url.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        url.httpBody = try JSONSerialization.data(withJSONObject: body)
        return url
    }

    override func handle(line: String) {
        guard line.hasPrefix("data:"), let event = Self.json(line.dropFirst(5)) else { return }
        switch event["type"] as? String {
        case "content_block_delta":
            if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String { send(.text(text)) }
        case "message_delta":
            let delta = event["delta"] as? [String: Any]
            if delta?["stop_reason"] as? String == "refusal" {
                send(.failed(String(localized: "Claude bu isteği yanıtlamadı.")))
            }
        case "error":
            let error = event["error"] as? [String: Any]
            send(.failed(error?["message"] as? String ?? String(localized: "Claude API bir hata döndürdü.")))
        default:
            break
        }
    }

    override func errorMessage(status: Int, body: Data) -> String {
        if status == 401 { return String(localized: "Claude API anahtarı geçersiz.") }
        return super.errorMessage(status: status, body: body)
    }

    static func json(_ text: Substring) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.trimmingCharacters(in: .whitespaces).utf8))) as? [String: Any]
    }
}

/// The Gemini API with a Google AI Studio key.
final class GeminiAPIBackend: HTTPBackend {
    private static var base: String { Endpoint.gemini }

    static func models(key: String) async throws -> [ModelOption] {
        var request = URLRequest(url: URL(string: "\(base)/models?pageSize=200")!)
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        let list = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["models"] as? [[String: Any]] ?? []
        let skip = ["embedding", "image", "tts", "live", "audio", "robotics", "computer-use", "aqa"]
        return list.compactMap { item in
            guard let name = item["name"] as? String, name.contains("gemini"),
                  (item["supportedGenerationMethods"] as? [String])?.contains("generateContent") == true,
                  !skip.contains(where: name.contains) else { return nil }
            let id = name.replacingOccurrences(of: "models/", with: "")
            return ModelOption(id: id, name: item["displayName"] as? String ?? id)
        }
    }

    /// A stable Flash model: fast, and inside the free tier.
    static func preferred(_ models: [ModelOption]) -> String? {
        let stable = models.filter { !$0.id.contains("preview") && !$0.id.contains("exp") && !$0.id.contains("lite") }
        return (stable.filter { $0.id.contains("flash") }.max { $0.id < $1.id } ?? stable.first ?? models.first)?.id
    }

    override func makeRequest(_ request: ChatRequest) throws -> URLRequest {
        guard let key = Keychain.get("gemini") else { throw ProviderError(String(localized: "Gemini API anahtarı kayıtlı değil.")) }
        let model = request.model.isEmpty ? "gemini-2.5-flash" : request.model
        var contents: [[String: Any]] = Self.turns(request.history).map {
            ["role": $0.role == .user ? "user" : "model", "parts": [["text": $0.text]]]
        }
        contents.append(["role": "user", "parts": [["text": request.prompt]]])
        let body: [String: Any] = ["systemInstruction": ["parts": [["text": request.system]]], "contents": contents]
        let name = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        guard let endpoint = URL(string: "\(Self.base)/models/\(name):streamGenerateContent?alt=sse") else {
            throw ProviderError(String(localized: "Geçersiz model adı: \(model)"))
        }
        var url = URLRequest(url: endpoint)
        url.httpMethod = "POST"
        url.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        url.setValue("application/json", forHTTPHeaderField: "content-type")
        url.httpBody = try JSONSerialization.data(withJSONObject: body)
        return url
    }

    override func handle(line: String) {
        guard line.hasPrefix("data:"), let event = AnthropicBackend.json(line.dropFirst(5)) else { return }
        if let error = event["error"] as? [String: Any] {
            send(.failed(error["message"] as? String ?? String(localized: "Gemini API bir hata döndürdü.")))
            return
        }
        let candidate = (event["candidates"] as? [[String: Any]])?.first
        let parts = (candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        // Thought summaries are marked with "thought"; only the answer is shown.
        let text = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
        if !text.isEmpty { send(.text(text)) }
        if let blocked = (event["promptFeedback"] as? [String: Any])?["blockReason"] as? String {
            send(.failed(String(localized: "Gemini bu isteği yanıtlamadı (\(blocked)).")))
        }
    }

    override func errorMessage(status: Int, body: Data) -> String {
        if status == 400 || status == 403, String(decoding: body, as: UTF8.self).contains("API_KEY") {
            return String(localized: "Gemini API anahtarı geçersiz.")
        }
        if status == 429 { return String(localized: "Gemini kullanım sınırına ulaşıldı. Biraz sonra tekrar dene.") }
        return super.errorMessage(status: status, body: body)
    }
}

/// Models served by a local Ollama.
final class OllamaBackend: HTTPBackend {
    private static var base: String { Endpoint.ollama }

    static func models() async throws -> [ModelOption] {
        var request = URLRequest(url: URL(string: "\(base)/api/tags")!)
        request.timeoutInterval = 2
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        let list = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["models"] as? [[String: Any]] ?? []
        return list.compactMap { ($0["name"] as? String).map { ModelOption(id: $0, name: $0) } }
    }

    override func makeRequest(_ request: ChatRequest) throws -> URLRequest {
        guard !request.model.isEmpty else { throw ProviderError(String(localized: "Ollama'da kurulu model yok. Terminalde ollama pull llama3.2 gibi bir model indir.")) }
        var messages: [[String: Any]] = [["role": "system", "content": request.system]]
        messages += Self.turns(request.history).map { ["role": $0.role.rawValue, "content": $0.text] }
        messages.append(["role": "user", "content": request.prompt])
        var url = URLRequest(url: URL(string: "\(Self.base)/api/chat")!)
        url.httpMethod = "POST"
        url.setValue("application/json", forHTTPHeaderField: "content-type")
        url.httpBody = try JSONSerialization.data(withJSONObject: ["model": request.model, "stream": true, "messages": messages])
        return url
    }

    override func handle(line: String) {
        guard let event = AnthropicBackend.json(Substring(line)) else { return }
        if let error = event["error"] as? String {
            send(.failed(error))
        } else if let text = (event["message"] as? [String: Any])?["content"] as? String, !text.isEmpty {
            send(.text(text))
        }
    }

    override func connectionError(_ error: Error) -> String {
        String(localized: "Ollama çalışmıyor. Ollama uygulamasını aç ya da terminalde ollama serve çalıştır.")
    }
}

/// Service addresses; DEBUG probes can point them at a local mock server.
enum Endpoint {
    static func base(_ name: String, _ real: String) -> String {
        #if DEBUG
        if let mock = ProcessInfo.processInfo.environment["CENTIK_MOCK_\(name)"] { return mock }
        #endif
        return real
    }
    static var anthropic: String { base("ANTHROPIC", "https://api.anthropic.com") }
    static var gemini: String { base("GEMINI", "https://generativelanguage.googleapis.com/v1beta") }
    static var ollama: String { base("OLLAMA", "http://127.0.0.1:11434") }
}

struct ProviderError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func check(_ response: URLResponse, _ data: Data) throws {
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else {
        if status == 401 || status == 403 { throw ProviderError(String(localized: "Anahtar geçersiz ya da yetkisiz.")) }
        throw ProviderError(HTTPBackend.apiError(data) ?? String(localized: "Sunucu \(status) hatası döndürdü."))
    }
}
