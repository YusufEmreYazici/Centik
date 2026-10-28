import SwiftUI

struct AssistantTab: View {
    @ObservedObject private var claude = AssistantService.shared
    @ObservedObject private var model = IslandModel.shared
    @FocusState private var typing: Bool

    private var provider: AIProvider { claude.active ?? claude.chosen }
    private var tint: Color { AgentAvatar.style(provider.avatar).color }

    var body: some View {
        VStack(spacing: 7) {
            header
            if claude.active == nil && claude.messages.isEmpty {
                VStack(spacing: 8) {
                    EmptyState(symbol: "sparkles", title: "Bir yapay zekâ bağla",
                               subtitle: "Claude ya da Gemini hesabını, bir API anahtarını veya Ollama'yı bağla. Ücretsiz seçenekler de var.",
                               tint: tint)
                    Button { SettingsWindow.shared.show(page: .assistant) } label: { Label("Ayarlar'da bağla", systemImage: "link") }
                        .buttonStyle(.pill(tint))
                }
                .frame(maxHeight: .infinity)
            } else if claude.messages.isEmpty {
                suggestions
            } else {
                transcript
            }
            input
        }
        .onChange(of: typing) { _, on in model.keepOpen = on }
        .onDisappear { model.keepOpen = false }
    }

    private var header: some View {
        HStack(spacing: 8) {
            AgentAvatar(source: provider.avatar, size: 22)
            Text(claude.name).font(.system(size: 12.5, weight: .bold))
            if claude.isRunning {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Yanıtlıyor").font(.system(size: 10, weight: .medium)).foregroundStyle(tint)
                }
            } else {
                Chip(text: provider == .auto ? "Yalnızca sohbet" : provider.title, symbol: "lock.fill", tint: .white)
                    .help("Burada dosyalara erişilmez ve komut çalıştırılmaz. Sağlayıcıyı Ayarlar > Yapay Zekâ'dan değiştirebilirsin.")
            }
            Spacer()
            Button { claude.attachClipboard() } label: { Label("Panodan ekle", systemImage: "doc.on.clipboard") }
                .buttonStyle(.pill)
                .help("Son kopyaladığın metni sorunun önüne ekler")
            if !claude.messages.isEmpty {
                Button { claude.newChat() } label: { Label("Yeni", systemImage: "square.and.pencil") }
                    .buttonStyle(.pill(tint))
            }
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ne sormak istersin?").font(.system(size: 13, weight: .semibold))
            let ideas: [(String, String)] = [
                ("text.redaction", "Kopyaladığım metni kısaca özetle"),
                ("envelope", "Kopyaladığım e-postayı daha kibar yaz"),
                ("chevron.left.forwardslash.chevron.right", "Kopyaladığım kodu açıkla"),
                ("globe", "Kopyaladığım metni İngilizceye çevir"),
            ]
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(ideas, id: \.1) { symbol, text in
                    Button {
                        claude.draft = text
                        claude.attachClipboard()
                        typing = true
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                            Text(text).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 9)
                        .frame(height: 30)
                        .background(CardSurface(radius: 9))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScaleStyle(scale: 0.96))
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(claude.messages) { ChatBubble(message: $0, running: claude.isRunning && $0.id == claude.messages.last?.id, avatar: provider.avatar) }
                    Color.clear.frame(height: 1).id("bottom")
                }
            }
            .onChange(of: claude.messages.last?.text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .frame(maxHeight: .infinity)
    }

    private var input: some View {
        HStack(spacing: 8) {
            TextField("\(claude.name) ile konuş… (Enter ile gönder)", text: $claude.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...3)
                .focused($typing)
                .onSubmit { claude.send() }
            if claude.isRunning {
                Button { claude.stop() } label: {
                    Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 24, height: 24).background(Circle().fill(.red.opacity(0.8)))
                }
                .buttonStyle(PressScaleStyle())
                .help("Durdur")
            } else {
                Button { claude.send() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(claude.draft.isEmpty ? AnyShapeStyle(.white.opacity(0.25)) : AnyShapeStyle(tint.gradient)))
                }
                .buttonStyle(PressScaleStyle())
                .disabled(claude.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Gönder")
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .background(CardSurface(tint: typing ? tint : nil, radius: 14))
        .onTapGesture { typing = true }
    }
}

struct ChatBubble: View {
    var message: ChatMessage
    var running: Bool
    var avatar = "claude"
    private var tint: Color { AgentAvatar.style(avatar).color }
    @State private var hover = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            if message.role == .user { Spacer(minLength: 60) } else { AgentAvatar(source: avatar, size: 18) }
            VStack(alignment: .leading, spacing: 3) {
                if message.text.isEmpty && running {
                    TypingDots()
                } else {
                    Text(Self.render(message.text))
                        .font(.system(size: 11.5))
                        .foregroundStyle(message.isError ? .orange : .white.opacity(0.92))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        // Answers can echo pasted text, so only web links open; file:, smb: and
                        // app URL schemes hidden behind link text are ignored.
                        .environment(\.openURL, OpenURLAction { url in
                            ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
                        })
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(message.role == .user ? AnyShapeStyle(tint.opacity(0.32)) : AnyShapeStyle(Color.white.opacity(0.07)))
            )
            .overlay(alignment: .topTrailing) {
                if message.role == .assistant, hover, !message.text.isEmpty, !running {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(copied ? .green : .white)
                            .frame(width: 20, height: 20).background(Circle().fill(.black.opacity(0.6)))
                    }
                    .buttonStyle(PressScaleStyle())
                    .offset(x: 6, y: -6)
                }
            }
            if message.role == .assistant { Spacer(minLength: 30) }
        }
        .onHover { hover = $0 }
    }

    /// Inline Markdown (bold, italics, code, links) with line breaks kept.
    static func render(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

struct TypingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25)) { context in
            let step = Int(DemoClock.time(context.date) * 4) % 3
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(.white.opacity(i == step ? 0.9 : 0.3)).frame(width: 5, height: 5)
                }
            }
            .frame(height: 14)
        }
    }
}
