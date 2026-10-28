import AppKit
import SwiftUI

struct AssistantSettings: View {
    @ObservedObject private var service = AssistantService.shared
    @AppStorage(Pref.aiProvider) private var providerRaw = "auto"

    private var chosen: AIProvider { AIProvider(rawValue: providerRaw) ?? .auto }

    var body: some View {
        Section {
            Picker("Sohbet sekmesini yanıtlayan", selection: $providerRaw) {
                ForEach(AIProvider.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .onChange(of: providerRaw) { _, _ in service.providerChanged() }
            let status = service.status(chosen)
            Label(status.text, systemImage: status.ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(status.ready ? .green : .orange)
                .font(.callout)
        } header: {
            Text("Sağlayıcı")
        } footer: {
            Text("Herkes kendi hesabını kullanır; Çentik kimseye ücret ödemez ya da veri toplamaz. Sohbet yalnızca konuşmadır: dosyalarına erişilmez, komut çalıştırılmaz. Her mesajla yalnızca saat, tarih ve seçtiğin şehrin havası gider.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section("Kurulu araçlar · anahtar gerekmez") {
            ProviderRow(provider: .claudeCode)
            ProviderRow(provider: .geminiCLI)
        }
        Section("API anahtarı") {
            ProviderRow(provider: .anthropicAPI)
            ProviderRow(provider: .geminiAPI)
        }
        Section {
            ProviderRow(provider: .ollama)
        } header: {
            Text("Bu Mac'te")
        } footer: {
            Text("API anahtarları macOS Anahtar Zinciri'nde saklanır, yalnızca ilgili servise gönderilir.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// One provider: its state, how to connect it, its model and a connection test.
struct ProviderRow: View {
    let provider: AIProvider
    @ObservedObject private var service = AssistantService.shared
    @AppStorage private var model: String
    @State private var models: [ModelOption] = []
    @State private var loadError: String?
    @State private var keyDraft = ""
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?
    @State private var refresh = 0

    init(provider: AIProvider) {
        self.provider = provider
        _model = AppStorage(wrappedValue: "", provider.modelPref)
    }

    private var status: ProviderStatus {
        _ = refresh
        return service.status(provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AgentAvatar(source: provider.avatar, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(provider.title).fontWeight(.semibold)
                        Text(status.ready ? "Hazır" : "Bağlı değil").font(.caption.weight(.semibold))
                            .foregroundStyle(status.ready ? .green : .secondary)
                        if service.active == provider {
                            Text("Kullanılıyor").font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                        }
                    }
                    Text(provider.summary).font(.caption).foregroundStyle(.secondary)
                    Text(status.text).font(.caption).foregroundStyle(status.ready ? Color.secondary : Color.orange)
                        .textSelection(.enabled)
                }
                Spacer()
                if let url = provider.helpURL, !status.ready || provider.keyAccount != nil {
                    Button(provider.keyAccount != nil ? "Anahtar al" : "Nasıl kurulur") { NSWorkspace.shared.open(url) }
                }
            }

            if let account = provider.keyAccount { keyField(account) }
            if provider == .geminiCLI, GeminiCLIBackend.executable != nil, !GeminiCLIBackend.signedIn {
                HStack {
                    Text("gemini").font(.system(.caption, design: .monospaced))
                    Text("komutunu terminalde bir kez çalıştırıp Google ile giriş yap.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Kontrol et") { refresh += 1; service.providerChanged() }
                }
            }
            if provider == .ollama && !status.ready {
                HStack {
                    Spacer()
                    Button("Yeniden kontrol et") { service.refreshOllama() }
                }
            }

            if status.ready {
                HStack(spacing: 8) {
                    Picker("Model", selection: $model) {
                        if !models.contains(where: { $0.id == "" }) { Text(defaultName).tag("") }
                        ForEach(models) { Text($0.name).tag($0.id) }
                        if !model.isEmpty && !models.contains(where: { $0.id == model }) { Text(model).tag(model) }
                    }
                    .frame(maxWidth: 340)
                    Spacer()
                    if testing { ProgressView().controlSize(.small) }
                    Button("Bağlantıyı test et") { runTest() }.disabled(testing)
                }
                if let loadError { Text(loadError).font(.caption).foregroundStyle(.orange) }
                if let testResult {
                    Label(testResult.text, systemImage: testResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.caption).foregroundStyle(testResult.ok ? .green : .red).lineLimit(3)
                }
            }
        }
        .padding(.vertical, 4)
        .task(id: "\(status.ready)\(refresh)") { await loadModels() }
    }

    private var defaultName: String {
        switch provider {
        case .anthropicAPI: return "Önerilen (\(AnthropicBackend.defaultModel))"
        case .geminiAPI: return "Önerilen (\(GeminiAPIBackend.preferred(models) ?? "Flash"))"
        case .ollama: return models.first.map { "İlk model (\($0.id))" } ?? "Kurulu model yok"
        default: return "Varsayılan"
        }
    }

    @ViewBuilder
    private func keyField(_ account: String) -> some View {
        let saved = Keychain.get(account) != nil
        HStack(spacing: 8) {
            SecureField(saved ? "Kayıtlı anahtarı değiştirmek için yenisini yapıştır" : "API anahtarını yapıştır", text: $keyDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveKey)
            Button("Kaydet", action: saveKey).disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            if saved {
                Button("Sil", role: .destructive) {
                    Keychain.set(nil, for: account)
                    testResult = nil
                    models = []
                    refresh += 1
                    service.providerChanged()
                }
            }
        }
    }

    private func saveKey() {
        guard let account = provider.keyAccount else { return }
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Keychain.set(key, for: account)
        // The key was most likely copied to be pasted here; don't keep it in the clipboard history.
        let clipboard = ClipboardService.shared
        clipboard.items.filter { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) == key }.forEach(clipboard.remove)
        keyDraft = ""
        testResult = nil
        refresh += 1
        service.providerChanged()
    }

    private func loadModels() async {
        guard service.status(provider).ready else { models = []; return }
        do {
            let list = try await service.models(for: provider)
            models = list
            loadError = nil
        } catch {
            models = []
            loadError = "Model listesi alınamadı: \(error.localizedDescription)"
        }
    }

    private func runTest() {
        testing = true
        testResult = nil
        service.test(provider) { ok, text in
            testing = false
            testResult = (ok, text)
        }
    }
}
