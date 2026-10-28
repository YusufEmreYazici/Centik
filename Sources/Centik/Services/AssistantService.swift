import Foundation

struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant }

    var id = UUID()
    let role: Role
    var text: String
    var date = Date()
    var isError = false
}

/// The assistant tab's conversation. Answers come from whichever provider the person connected
/// (see AIProvider): a signed-in command-line tool, their own API key, or a local Ollama.
///
/// Every provider is chat-only. The command-line tools run in an empty folder with their file
/// and shell tools off, and each message carries a short line with the date, time and weather
/// so everyday questions can be answered without tools.
final class AssistantService: ObservableObject {
    static let shared = AssistantService()

    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isRunning = false
    @Published var draft = ""
    /// The provider answering right now; `auto` resolves to the first one that is ready.
    @Published private(set) var active: AIProvider?
    /// Whether a local Ollama answered the last check.
    @Published private(set) var ollamaRunning = false

    private var sessionID: String?
    private var sessionProvider: AIProvider?
    private var backend: ChatBackend?

    private var directory: URL { AgentService.shared.directory.appendingPathComponent("assistant", isDirectory: true) }
    private var historyFile: URL { directory.appendingPathComponent("chat.json") }

    private static let systemPrompt = """
    You are a helpful assistant chatting inside Çentik, a small panel in the MacBook notch. You can't \
    run commands or read files, so never write tool calls or code meant to fetch something. Answer \
    from your own knowledge and the context line at the start of each message; when a question needs \
    live data you don't have, say so in one sentence. Keep answers short and scannable: a few sentences \
    or a short list. Reply in the language the user writes in.
    """

    /// Longest answer kept before the run is stopped, so a runaway answer can't fill the panel.
    private static let answerLimit = 12_000

    private init() {
        load()
        DispatchQueue.global(qos: .utility).async {
            _ = ShellEnvironment.path   // warm the PATH lookup off the main thread
            DispatchQueue.main.async { self.active = self.resolve() }
        }
        refreshOllama()
    }

    // MARK: Providers

    var chosen: AIProvider { AIProvider(rawValue: Pref.string(Pref.aiProvider)) ?? .auto }

    /// Name for the tab and the chat header.
    var name: String { (active ?? chosen).assistantName }

    func status(_ provider: AIProvider) -> ProviderStatus {
        let home = NSHomeDirectory()
        func short(_ url: URL) -> String { url.path.replacingOccurrences(of: home, with: "~") }
        switch provider {
        case .auto:
            guard let resolved = resolve() else { return ProviderStatus(ready: false, text: "Hazır bir sağlayıcı yok. Aşağıdan birini bağla.") }
            return ProviderStatus(ready: true, text: "Şu an \(resolved.title) kullanılıyor.")
        case .claudeCode:
            guard let url = ClaudeCodeBackend.executable else { return ProviderStatus(ready: false, text: "Claude Code kurulu değil.") }
            return ProviderStatus(ready: true, text: "Bulundu: \(short(url))")
        case .geminiCLI:
            guard let url = GeminiCLIBackend.executable else { return ProviderStatus(ready: false, text: "Gemini CLI kurulu değil.") }
            guard GeminiCLIBackend.signedIn else {
                return ProviderStatus(ready: false, text: "Bulundu ama giriş yapılmamış. Terminalde gemini yazıp Google ile giriş yap.")
            }
            return ProviderStatus(ready: true, text: "Bulundu ve giriş yapılmış: \(short(url))")
        case .anthropicAPI, .geminiAPI:
            let saved = provider.keyAccount.flatMap(Keychain.get) != nil
            return ProviderStatus(ready: saved, text: saved ? "Anahtar Anahtar Zinciri'nde kayıtlı." : "Anahtar girilmedi.")
        case .ollama:
            return ProviderStatus(ready: ollamaRunning, text: ollamaRunning ? "Çalışıyor." : "Çalışmıyor ya da kurulu değil.")
        }
    }

    /// The provider that will answer: the chosen one, or for `auto` the first that is ready.
    func resolve() -> AIProvider? {
        if chosen != .auto { return chosen }
        return AIProvider.concrete.first { status($0).ready }
    }

    func providerChanged() {
        active = resolve()
        objectWillChange.send()
    }

    func refreshOllama() {
        Task {
            let running = (try? await OllamaBackend.models()) != nil
            await MainActor.run {
                self.ollamaRunning = running
                self.active = self.resolve()
            }
        }
    }

    func model(for provider: AIProvider) -> String { Pref.string(provider.modelPref) }

    /// Models to offer in Settings. API providers and Ollama are asked for their current list.
    func models(for provider: AIProvider) async throws -> [ModelOption] {
        switch provider {
        case .auto: return []
        case .claudeCode: return ClaudeCodeBackend.models
        case .geminiCLI: return GeminiCLIBackend.models
        case .anthropicAPI:
            guard let key = Keychain.get("anthropic") else { return [] }
            return try await AnthropicBackend.models(key: key)
        case .geminiAPI:
            guard let key = Keychain.get("gemini") else { return [] }
            return try await GeminiAPIBackend.models(key: key)
        case .ollama:
            return try await OllamaBackend.models()
        }
    }

    /// Fills in a sensible model the first time a provider is used without one chosen.
    private func defaultModel(for provider: AIProvider) async -> String {
        let saved = model(for: provider)
        if !saved.isEmpty { return saved }
        switch provider {
        case .anthropicAPI:
            let list = (try? await AnthropicBackend.models(key: Keychain.get("anthropic") ?? "")) ?? []
            return list.contains { $0.id == AnthropicBackend.defaultModel } || list.isEmpty ? AnthropicBackend.defaultModel : list[0].id
        case .geminiAPI:
            let list = (try? await GeminiAPIBackend.models(key: Keychain.get("gemini") ?? "")) ?? []
            return GeminiAPIBackend.preferred(list) ?? ""
        case .ollama:
            return (try? await OllamaBackend.models())?.first?.id ?? ""
        default:
            return ""
        }
    }

    // MARK: Conversation

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        guard let provider = resolve(), status(provider).ready else {
            draft = ""
            messages.append(ChatMessage(role: .user, text: text))
            messages.append(ChatMessage(role: .assistant, text: notReadyMessage(), isError: true))
            save()
            return
        }
        active = provider
        draft = ""
        let history = messages
        messages.append(ChatMessage(role: .user, text: text))
        messages.append(ChatMessage(role: .assistant, text: ""))
        isRunning = true

        // A command-line session belongs to the tool that started it.
        if sessionProvider != provider {
            sessionID = nil
            sessionProvider = provider
        }
        let prompt = Self.context() + "\n\n" + text
        Task { @MainActor in
            let model = await defaultModel(for: provider)
            let request = ChatRequest(history: history, prompt: prompt, model: model, system: Self.systemPrompt, sessionID: sessionID)
            guard isRunning, let backend = makeBackend(provider) else {
                if isRunning { fail("\(provider.title) başlatılamadı.") }
                return
            }
            self.backend = backend
            backend.start(request) { [weak backend] event in
                guard let backend, self.backend === backend else { return }
                self.apply(event)
            }
        }
    }

    private var tests: [AIProvider: ChatBackend] = [:]

    /// Sends a tiny message through a provider and reports its reply or the error, for Settings.
    func test(_ provider: AIProvider, completion: @escaping (_ ok: Bool, _ text: String) -> Void) {
        Task { @MainActor in
            let model = await defaultModel(for: provider)
            guard let backend = makeBackend(provider) else { completion(false, status(provider).text); return }
            tests[provider] = backend
            var reply = ""
            let request = ChatRequest(history: [], prompt: "Yalnızca şunu yaz: Bağlantı tamam", model: model,
                                      system: Self.systemPrompt, sessionID: nil)
            backend.start(request) { event in
                switch event {
                case .text(let text): reply += text
                case .session: break
                case .failed(let message):
                    self.tests[provider] = nil
                    completion(false, message)
                case .finished:
                    self.tests[provider] = nil
                    let answer = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                    completion(!answer.isEmpty, answer.isEmpty ? "Yanıt boş geldi." : "\(model.isEmpty ? "" : model + ": ")\(answer.prefix(80))")
                }
            }
        }
    }

    private func notReadyMessage() -> String {
        if chosen == .auto { return "Henüz bir yapay zekâ bağlı değil. Ayarlar > Yapay Zekâ'dan Claude, Gemini ya da Ollama'yı bağla." }
        return "\(chosen.title) hazır değil: \(status(chosen).text) Ayarlar > Yapay Zekâ'dan kontrol edebilirsin."
    }

    private func makeBackend(_ provider: AIProvider) -> ChatBackend? {
        let base = AgentService.shared.directory
        switch provider {
        case .claudeCode:
            return ClaudeCodeBackend.executable.map { ClaudeCodeBackend(executable: $0, directory: directory) }
        case .geminiCLI:
            return GeminiCLIBackend.executable.map {
                GeminiCLIBackend(executable: $0, directory: base.appendingPathComponent("gemini", isDirectory: true))
            }
        case .anthropicAPI: return AnthropicBackend()
        case .geminiAPI: return GeminiAPIBackend()
        case .ollama: return OllamaBackend()
        case .auto: return nil
        }
    }

    private func apply(_ event: BackendEvent) {
        switch event {
        case .text(let text): appendToAnswer(text)
        case .session(let id): sessionID = id
        case .failed(let message): fail(message)
        case .finished: finish()
        }
    }

    func stop() {
        backend?.cancel()
    }

    func newChat() {
        backend?.cancel()
        backend = nil
        isRunning = false
        messages = []
        sessionID = nil
        save()
    }

    /// Puts copied text in front of the draft as context.
    func attachClipboard() {
        guard let text = ClipboardService.shared.items.first(where: { $0.text != nil })?.text else { return }
        draft = "\"\"\"\n\(text.prefix(6000))\n\"\"\"\n" + draft
    }

    /// The current date, time and weather, sent ahead of each message (but not shown in the chat),
    /// so "what's the weather" or "what day is it" can be answered without tools.
    private static func context() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "d MMMM yyyy EEEE, HH:mm"
        var parts = ["Şu an: \(f.string(from: Date())) (\(TimeZone.current.identifier))"]
        let weather = WeatherService.shared
        if let city = weather.city, let temp = weather.temperature {
            var line = "Hava (\(city)): \(Int(temp.rounded()))°C, \(WeatherService.describe(weather.code, isDay: weather.isDay).text)"
            if let feels = weather.feelsLike { line += ", hissedilen \(Int(feels.rounded()))°C" }
            if let high = weather.high, let low = weather.low { line += ", bugün en yüksek \(Int(high.rounded()))° en düşük \(Int(low.rounded()))°" }
            if let rain = weather.rainChance { line += ", yağış ihtimali %\(rain)" }
            parts.append(line)
        }
        return "[Bağlam: " + parts.joined(separator: ". ") + "]"
    }

    private func appendToAnswer(_ text: String) {
        guard isRunning, let last = messages.indices.last, messages[last].role == .assistant,
              !messages[last].isError else { return }
        messages[last].text += text
        let answer = messages[last].text
        if answer.contains("<invoke") || answer.contains("<function_calls") {
            // The model tried to call a tool it doesn't have; stop it before it loops.
            backend?.cancel()
            fail("Bunu araç kullanmadan yanıtlayamadı. Soruyu biraz farklı sormayı dene.")
        } else if answer.count > Self.answerLimit {
            backend?.cancel()
            messages[last].text += "\n\n…(yanıt kısaltıldı)"
            finish()
        }
    }

    private func finish() {
        isRunning = false
        backend = nil
        if let last = messages.indices.last, messages[last].role == .assistant, messages[last].text.isEmpty {
            messages[last].text = "Yanıt boş geldi."
            messages[last].isError = true
        }
        save()
    }

    private func fail(_ message: String) {
        isRunning = false
        backend = nil
        if let last = messages.indices.last, messages[last].role == .assistant {
            if message == "Durduruldu.", !messages[last].text.isEmpty {
                // Keep what already arrived.
            } else {
                messages[last].text = message
                messages[last].isError = true
            }
        } else {
            messages.append(ChatMessage(role: .assistant, text: message, isError: true))
        }
        save()
    }

    // MARK: Persistence

    private struct Stored: Codable {
        let sessionID: String?
        let provider: String?
        let messages: [ChatMessage]
    }

    private func save() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stored = Stored(sessionID: sessionID, provider: sessionProvider?.rawValue, messages: Array(messages.suffix(60)))
        if let data = try? JSONEncoder().encode(stored) { try? data.write(to: historyFile, options: .atomic) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: historyFile),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        sessionID = stored.sessionID
        sessionProvider = stored.provider.flatMap(AIProvider.init)
        messages = stored.messages
    }
}

#if DEBUG
extension AssistantService {
    func loadPreview(_ preview: [ChatMessage], running: Bool = false, provider: AIProvider? = nil) {
        messages = preview
        isRunning = running
        if let provider { active = provider }
    }
}
#endif
