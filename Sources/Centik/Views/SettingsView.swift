import ServiceManagement
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, interaction, appearance, activities, tools, assistant, agents, permissions, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "Genel"
        case .interaction: return "Etkileşim"
        case .appearance: return "Görünüm"
        case .activities: return "Canlı Etkinlikler"
        case .tools: return "Araçlar"
        case .assistant: return "Yapay Zekâ"
        case .agents: return "Kodlama Ajanları"
        case .permissions: return "İzinler"
        case .about: return "Hakkında"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Başlangıç, ekran ve kısayol"
        case .interaction: return "Sekmeler, açılma, kapanma ve dokunsal geri bildirim"
        case .appearance: return "Tema, vurgu rengi, efektler ve boyutlar"
        case .activities: return "Çentikte beliren müzik, ses, pil ve ağ bildirimleri"
        case .tools: return "Pano, takvim, raf ve uyanık tut"
        case .assistant: return "Sohbet sekmesi için Claude, Gemini ya da Ollama bağlantısı"
        case .agents: return "Claude Code ve Codex uyarıları"
        case .permissions: return "Çentik'in kullandığı izinlerin durumu"
        case .about: return "Sürüm ve kısayollar"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .interaction: return "cursorarrow.motionlines"
        case .appearance: return "paintpalette.fill"
        case .activities: return "sparkles"
        case .tools: return "wrench.and.screwdriver.fill"
        case .assistant: return "sparkles"
        case .agents: return "terminal.fill"
        case .permissions: return "lock.shield.fill"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .interaction: return .blue
        case .appearance: return .purple
        case .activities: return .pink
        case .tools: return .orange
        case .assistant: return Color(red: 0.55, green: 0.42, blue: 0.95)
        case .agents: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .permissions: return .green
        case .about: return .indigo
        }
    }
}

/// Lets other parts of the app open Settings on a given page.
final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    @Published var page: SettingsPage? = .general
}

struct SettingsView: View {
    @ObservedObject private var router = SettingsRouter.shared

    private var page: SettingsPage? { router.page }

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $router.page) { p in
                HStack(spacing: 9) {
                    SettingsIcon(symbol: p.symbol, tint: p.tint, size: 22)
                    Text(p.title)
                }
                .padding(.vertical, 2)
                .tag(p)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 220)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let page {
                        PageHeader(page: page)
                        Form { content(page) }
                            .formStyle(.grouped)
                            .scrollDisabled(true)
                    }
                }
            }
            .id(page)
        }
        .frame(width: 760, height: 600)
    }

    @ViewBuilder
    private func content(_ page: SettingsPage) -> some View {
        switch page {
        case .general: GeneralSettings()
        case .interaction: InteractionSettings()
        case .appearance: AppearanceSettings()
        case .activities: ActivitySettings()
        case .tools: ToolSettings()
        case .assistant: AssistantSettings()
        case .agents: AgentSettings()
        case .permissions: PermissionSettings()
        case .about: AboutSettings()
        }
    }
}

struct SettingsIcon: View {
    var symbol: String
    var tint: Color
    var size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(tint.gradient))
    }
}

struct PageHeader: View {
    var page: SettingsPage

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: page.symbol, tint: page.tint, size: 40)
                .shadow(color: page.tint.opacity(0.35), radius: 6, y: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(page.title).font(.title2.weight(.bold))
                Text(page.subtitle).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
    }
}

/// A setting row with a title, an optional explanation under it and the control on the right.
struct SettingRow<Control: View>: View {
    var title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        LabeledContent {
            control.accessibilityLabel(title)
        } label: {
            Text(title)
            if let detail { Text(detail) }
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @AppStorage(Pref.hideInFullscreen) private var hideInFullscreen = true
    @AppStorage(Pref.display) private var display = "builtin"
    @AppStorage(Pref.showMenuBarIcon) private var showMenuBarIcon = true
    @AppStorage(Pref.hotKeyEnabled) private var hotKeyEnabled = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var confirmReset = false

    var body: some View {
        Section("Başlangıç") {
            SettingRow(title: "Oturum açınca başlat", detail: loginError ?? "Mac açıldığında Çentik kendiliğinden çalışır.") {
                Toggle("", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin)).labelsHidden()
            }
            SettingRow(title: "Menü çubuğu simgesi", detail: "Kapatırsan ayarlara adadaki dişliden ya da ⌃⌥N ile ulaşırsın.") {
                Toggle("", isOn: $showMenuBarIcon).labelsHidden()
            }
        }
        Section("Ekran") {
            Picker("Adanın göründüğü ekran", selection: $display) {
                Text("MacBook ekranı (çentikli)").tag("builtin")
                Text("Etkin ekran").tag("main")
            }
            SettingRow(title: "Tam ekranda gizle", detail: "Video ya da oyun tam ekrandayken ada çekilir.") {
                Toggle("", isOn: $hideInFullscreen).labelsHidden()
            }
        }
        Section("Kısayol") {
            SettingRow(title: "⌃⌥N ile aç / kapat", detail: "Her uygulamadan çalışır, Erişilebilirlik izni gerektirmez.") {
                Toggle("", isOn: $hotKeyEnabled).labelsHidden()
            }
        }
        Section {
            Button("Tüm ayarları varsayılana döndür…", role: .destructive) { confirmReset = true }
                .confirmationDialog("Tüm ayarlar varsayılana dönsün mü?", isPresented: $confirmReset) {
                    Button("Varsayılana Döndür", role: .destructive) { resetAll() }
                } message: {
                    Text("Raf, pano ve sabitlenen öğeler korunur.")
                }
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Ayarlanamadı: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if on && SMAppService.mainApp.status == .requiresApproval {
            loginError = "Sistem Ayarları → Genel → Giriş Öğeleri'nden onay ver."
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private func resetAll() {
        let keep: Set<String> = [Pref.shelfPaths, Pref.lastTrack]
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where !keep.contains(key) && Pref.allKeys.contains(key) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

// MARK: - Interaction

struct InteractionSettings: View {
    @AppStorage(Pref.expandOnHover) private var expandOnHover = true
    @AppStorage(Pref.hoverDelay) private var hoverDelay = 0.2
    @AppStorage(Pref.collapseDelay) private var collapseDelay = 0.3
    @AppStorage(Pref.haptics) private var haptics = true
    @AppStorage(Pref.hoverGrow) private var hoverGrow = true
    @AppStorage(Pref.openTab) private var openTab = "last"

    var body: some View {
        Section("Açılma") {
            SettingRow(title: "Üzerine gelince aç", detail: "Kapalıyken adaya tıklayarak açarsın.") {
                Toggle("", isOn: $expandOnHover).labelsHidden()
            }
            SettingRow(title: "Açılma gecikmesi", detail: "İmleç bu kadar beklerse açılır; kazara açılmayı önler.") {
                DelaySlider(value: $hoverDelay, range: 0...1)
            }
            .disabled(!expandOnHover)
            Picker("Açılınca gösterilecek sekme", selection: $openTab) {
                Text("En son açık olan").tag("last")
                ForEach(IslandModel.shared.visibleTabs) { Text($0.title).tag($0.rawValue) }
            }
        }
        Section("Kapanma") {
            SettingRow(title: "Kapanma gecikmesi", detail: "İmleç adadan çıktıktan sonra bu kadar bekler.") {
                DelaySlider(value: $collapseDelay, range: 0...2)
            }
        }
        Section {
            TabSettings()
        } header: {
            Text("Sekmeler")
        } footer: {
            Text("Kapattığın sekmeler çentikte görünmez; sırayı oklarla değiştir. En az bir sekme açık kalır.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Geri bildirim") {
            SettingRow(title: "Dokunsal titreşim", detail: "Force Touch trackpad'de adanın üzerine gelince hafif tık.") {
                Toggle("", isOn: $haptics).labelsHidden()
            }
            SettingRow(title: "Üzerine gelince büyüme", detail: nil) {
                Toggle("", isOn: $hoverGrow).labelsHidden()
            }
        }
    }
}

struct DelaySlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: $value, in: range, step: 0.05).frame(width: 160)
            Text(String(format: "%.2f sn", value)).monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
        }
    }
}

// MARK: - Appearance

struct AppearanceSettings: View {
    @AppStorage(Pref.theme) private var theme = "night"
    @AppStorage(Pref.accentMode) private var accentMode = "artwork"
    @AppStorage(Pref.accentHex) private var accentHex = "#A97CFF"
    @AppStorage(Pref.animationsEnabled) private var animations = true
    @AppStorage(Pref.animationStyle) private var animationStyle = "fluid"
    @AppStorage(Pref.animationSpeed) private var animationSpeed = 1.0
    @AppStorage(Pref.islandExtraWidth) private var extraWidth = 0.0
    @AppStorage(Pref.hudBarWidth) private var hudBarWidth = 34.0

    private let swatches = ["#A97CFF", "#5E9BFF", "#3DDC97", "#FFB340", "#FF5E7A", "#FFFFFF"]

    var body: some View {
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                ForEach(ThemeKind.allCases) { kind in
                    ThemeCard(kind: kind, selected: theme == kind.rawValue, accent: accent)
                        .onTapGesture { withAnimation(.snappy) { theme = kind.rawValue } }
                }
            }
            .padding(.vertical, 4)
            Text((ThemeKind(rawValue: theme) ?? .night).subtitle).font(.callout).foregroundStyle(.secondary)
        } header: {
            Text("Tema")
        }
        Section("Vurgu rengi") {
            Picker("Kaynak", selection: $accentMode) {
                Text("Çalan şarkının kapağı").tag("artwork")
                Text("Kendi rengim").tag("custom")
            }
            .pickerStyle(.segmented)
            SettingRow(title: "Renk", detail: accentMode == "artwork" ? "Müzik çalmıyorken bu renk kullanılır." : nil) {
                HStack(spacing: 8) {
                    ForEach(swatches, id: \.self) { hex in
                        Circle().fill(Color(hex: hex) ?? .purple)
                            .frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(accentHex == hex ? 0.9 : 0.15),
                                                           lineWidth: accentHex == hex ? 2 : 0.5).padding(-2))
                            .onTapGesture { accentHex = hex }
                    }
                    ColorPicker("", selection: Binding(get: { Color(hex: accentHex) ?? .purple }, set: { accentHex = $0.hex }),
                                supportsOpacity: false)
                        .labelsHidden()
                }
            }
        }
        Section("Efektler") {
            SettingRow(title: "Animasyonlar", detail: "Kapatınca ada anında açılıp kapanır; en az işlemci kullanır.") {
                Toggle("", isOn: $animations).labelsHidden()
            }
            Picker("Hareket", selection: $animationStyle) {
                ForEach(AnimationStyle.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .disabled(!animations)
            SettingRow(title: "Hız", detail: nil) {
                HStack(spacing: 8) {
                    Slider(value: $animationSpeed, in: 0.6...1.6, step: 0.1).frame(width: 160)
                    Text(String(format: "%.1f×", animationSpeed)).monospacedDigit().foregroundStyle(.secondary).frame(width: 36)
                }
            }
            .disabled(!animations)
        }
        Section("Boyutlar") {
            SettingRow(title: "Kanat genişliği", detail: "Müzik ve göstergelerin çentiğin yanında kapladığı yer.") {
                HStack(spacing: 8) {
                    Slider(value: $extraWidth, in: 0...80, step: 4).frame(width: 160)
                    Text("+\(Int(extraWidth)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 44)
                }
            }
            SettingRow(title: "Ses/parlaklık çizgisi", detail: nil) {
                HStack(spacing: 8) {
                    Slider(value: $hudBarWidth, in: 24...60, step: 2).frame(width: 160)
                    Text("\(Int(hudBarWidth)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 44)
                }
            }
        }
    }

    private var accent: Color { Color(hex: accentHex) ?? .purple }
}

/// Small live preview of a theme: a mini island with a track and a bar.
struct ThemeCard: View {
    var kind: ThemeKind
    var selected: Bool
    var accent: Color

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(
                    LinearGradient(colors: [Color(white: 0.35), Color(white: 0.2)], startPoint: .top, endPoint: .bottom))
                let shape = NotchShape(topRadius: 5, bottomRadius: 12)
                ZStack(alignment: .top) {
                    IslandBackground(theme: kind, presentation: .expanded, accent: accent, notchHeight: 10)
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 4).fill(accent.gradient).frame(width: 18, height: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Capsule().fill(.white.opacity(0.85)).frame(width: 32, height: 4)
                            Capsule().fill(.white.opacity(0.35)).frame(width: 22, height: 3)
                            Capsule().fill(accent).frame(width: 36, height: 2.5)
                        }
                    }
                    .padding(.top, 16)
                }
                .frame(width: 86, height: 48)
                .clipShape(shape)
                .overlay { if kind == .neon { NeonRim(shape: shape, accent: accent, hiddenTop: 10) } }
                .shadow(color: .black.opacity(kind == .minimal ? 0 : 0.5), radius: 5, y: 3)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(height: 62)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
            Text(kind.title).font(.caption.weight(selected ? .semibold : .regular))
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Activities

struct ActivitySettings: View {
    @AppStorage(Pref.liveActivity) private var liveActivity = "music"
    @AppStorage(Pref.wingLeft) private var wingLeft = "cpu"
    @AppStorage(Pref.wingRight) private var wingRight = "memory"
    @AppStorage(Pref.musicEnabled) private var music = true
    @AppStorage(Pref.trackPreview) private var trackPreview = true
    @AppStorage(Pref.volumeHUD) private var volumeHUD = true
    @AppStorage(Pref.brightnessHUD) private var brightnessHUD = true
    @AppStorage(Pref.hudStyle) private var hudStyle = "bar"
    @AppStorage(Pref.hudDuration) private var hudDuration = 1.6
    @AppStorage(Pref.batteryAlerts) private var battery = true
    @AppStorage(Pref.lowBatteryThreshold) private var lowThreshold = 20.0
    @AppStorage(Pref.networkAlerts) private var network = true
    @AppStorage(Pref.unlockSound) private var unlockSound = false
    @AppStorage(Pref.unlockSoundName) private var unlockSoundName = "Glass"
    @AppStorage(Pref.unlockIcon) private var unlockIcon = true
    @AppStorage(Pref.meetingAlerts) private var meetings = true
    @AppStorage(Pref.meetingLead) private var meetingLead = 10.0
    @AppStorage(Pref.captureScreenshots) private var screenshots = true
    @AppStorage(Pref.captureDownloads) private var downloads = true

    private let sounds = ["Glass", "Hero", "Ping", "Pop", "Purr", "Submarine", "Tink", "Blow", "Bottle", "Frog", "Morse"]

    var body: some View {
        Section("Çentiğin yanında") {
            Picker("Göster", selection: $liveActivity) {
                Text("Yalnızca müzik").tag("music")
                Text("Müzik; çalmıyorsa sistem").tag("musicThenSystem")
                Text("Her zaman sistem").tag("system")
                Text("Hiçbiri").tag("off")
            }
            if liveActivity == "musicThenSystem" || liveActivity == "system" {
                Picker("Sol kanat", selection: $wingLeft) {
                    ForEach(Metric.allCases) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) }
                }
                Picker("Sağ kanat", selection: $wingRight) {
                    ForEach(Metric.allCases) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) }
                }
            }
        }
        Section("Toplantılar") {
            SettingRow(title: "Toplantı geri sayımı", detail: "Takvimdeki etkinlik yaklaşınca çentikte geri sayım ve Zoom/Meet/Teams için Katıl düğmesi.") {
                Toggle("", isOn: $meetings).labelsHidden()
            }
            SettingRow(title: "Ne kadar önce", detail: nil) {
                HStack(spacing: 8) {
                    Slider(value: $meetingLead, in: 1...30, step: 1).frame(width: 160)
                    Text("\(Int(meetingLead)) dk").monospacedDigit().foregroundStyle(.secondary).frame(width: 44)
                }
            }
            .disabled(!meetings)
        }
        Section("Dosyalar") {
            SettingRow(title: "Ekran görüntüleri", detail: "Yeni ekran görüntüsü ve kaydı gösterir; tıkla rafa ekle, sürükle paylaş.") {
                Toggle("", isOn: $screenshots).labelsHidden()
            }
            SettingRow(title: "Biten indirmeler", detail: "İndirilenler klasörüne yeni dosya inince gösterir.") {
                Toggle("", isOn: $downloads).labelsHidden()
            }
        }
        Section("Müzik") {
            SettingRow(title: "Spotify ve Apple Music", detail: "Çalan şarkıyı gösterir ve kontrol eder.") {
                Toggle("", isOn: $music).labelsHidden()
            }
            SettingRow(title: "Şarkı değişince önizleme", detail: nil) {
                Toggle("", isOn: $trackPreview).labelsHidden()
            }
            .disabled(!music)
        }
        Section("Ses ve parlaklık") {
            SettingRow(title: "Ses değişince göster", detail: nil) { Toggle("", isOn: $volumeHUD).labelsHidden() }
            SettingRow(title: "Parlaklık değişince göster", detail: "Otomatik parlaklığın küçük adımları gösterilmez.") {
                Toggle("", isOn: $brightnessHUD).labelsHidden()
            }
            Picker("Gösterim", selection: $hudStyle) {
                Text("Çizgi").tag("bar")
                Text("Yüzde").tag("percent")
            }
            .pickerStyle(.segmented)
            SettingRow(title: "Ekranda kalma", detail: nil) {
                HStack(spacing: 8) {
                    Slider(value: $hudDuration, in: 0.8...4, step: 0.2).frame(width: 160)
                    Text(String(format: "%.1f sn", hudDuration)).monospacedDigit().foregroundStyle(.secondary).frame(width: 44)
                }
            }
        }
        Section("Pil ve ağ") {
            SettingRow(title: "Şarj takılınca / çıkınca", detail: nil) { Toggle("", isOn: $battery).labelsHidden() }
            SettingRow(title: "Düşük pil uyarısı", detail: "Şarjda değilken bu seviyeye inince bir kez uyarır.") {
                HStack(spacing: 8) {
                    Slider(value: $lowThreshold, in: 5...50, step: 5).frame(width: 160)
                    Text("%\(Int(lowThreshold))").monospacedDigit().foregroundStyle(.secondary).frame(width: 36)
                }
            }
            .disabled(!battery)
            SettingRow(title: "İnternet ve Wi-Fi değişiklikleri", detail: "Kısa kopmalar gösterilmez.") {
                Toggle("", isOn: $network).labelsHidden()
            }
        }
        Section("Kilit açma") {
            SettingRow(title: "Kilit simgesi", detail: nil) { Toggle("", isOn: $unlockIcon).labelsHidden() }
            SettingRow(title: "Ses çal", detail: nil) { Toggle("", isOn: $unlockSound).labelsHidden() }
            HStack {
                Picker("Ses", selection: $unlockSoundName) {
                    ForEach(sounds, id: \.self) { Text($0).tag($0) }
                }
                Button { NSSound(named: unlockSoundName)?.play() } label: { Image(systemName: "play.fill") }
            }
            .disabled(!unlockSound)
        }
    }
}

// MARK: - Tools

struct ToolSettings: View {
    @AppStorage(Pref.clipboardEnabled) private var clipboard = true
    @AppStorage(Pref.calendarEnabled) private var calendar = true
    @ObservedObject private var clips = ClipboardService.shared
    @ObservedObject private var shelf = ShelfStore.shared
    @ObservedObject private var awake = KeepAwake.shared

    var body: some View {
        Section("Pano") {
            SettingRow(title: "Pano geçmişi", detail: "Metin, bağlantı, renk, görsel ve dosyalar. Yalnızca bellekte; şifreler kaydedilmez.") {
                Toggle("", isOn: $clipboard).labelsHidden()
            }
            LabeledContent("\(clips.items.count) öğe, \(clips.items.filter(\.pinned).count) sabit") {
                Button("Geçmişi temizle") { clips.clear() }.disabled(clips.items.allSatisfy(\.pinned))
            }
        }
        Section("Takvim") {
            SettingRow(title: "Ana sekmede bugünün etkinlikleri", detail: nil) { Toggle("", isOn: $calendar).labelsHidden() }
        }
        Section {
            WeatherCityPicker()
        } header: {
            Text("Hava durumu")
        } footer: {
            Text("Open-Meteo kullanılır; hesap ya da konum izni gerekmez, yalnızca seçtiğin şehrin koordinatları gönderilir.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Raf") {
            LabeledContent(shelf.urls.isEmpty ? "Raf boş" : "Rafta \(shelf.urls.count) öğe") {
                Button("Rafı boşalt") { shelf.clear() }.disabled(shelf.urls.isEmpty)
            }
        }
        Section("Uyanık tut") {
            SettingRow(title: "Mac'i ve ekranı uyanık tut",
                       detail: awake.until.map { "\($0.formatted(date: .omitted, time: .shortened))'e kadar açık" } ?? "Ana sekmedeki kısayoldan da açılır; sağ tıkla süre seç.") {
                Toggle("", isOn: Binding(get: { awake.isOn }, set: { $0 ? awake.start() : awake.stop() })).labelsHidden()
            }
        }
    }
}

// MARK: - Agents

struct AgentSettings: View {
    @AppStorage(Pref.agentAlerts) private var alerts = true
    @AppStorage(Pref.agentSound) private var sound = true
    @State private var claudeInstalled = HookInstaller.claudeInstalled
    @State private var codexInstalled = HookInstaller.codexInstalled
    @State private var message: String?

    var body: some View {
        Section {
            SettingRow(title: "Uyarıları çentikte göster", detail: nil) { Toggle("", isOn: $alerts).labelsHidden() }
            SettingRow(title: "Uyarılarda ses çal", detail: nil) { Toggle("", isOn: $sound).labelsHidden() }
        } footer: {
            Text("Hook'lar yalnızca yerel bir dosyaya küçük bir olay satırı yazar; hiçbir şey internete gönderilmez. Değiştirilen dosyanın yanına .centik-backup yedeği bırakılır.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Bağlantılar") {
            hookRow(name: "Claude Code", source: "claude", installed: claudeInstalled, path: HookInstaller.claudeSettings.path,
                    detail: "Onay beklediğinde ve işi bitince", install: HookInstaller.installClaude, uninstall: HookInstaller.uninstallClaude)
            hookRow(name: "Codex", source: "codex", installed: codexInstalled, path: HookInstaller.codexConfig.path,
                    detail: "Her tur tamamlandığında", install: HookInstaller.installCodex, uninstall: HookInstaller.uninstallCodex)
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
        }
        Section("Başka araçlardan") {
            Text("\"\(AgentService.shared.hookScript.path)\" kaynak tür '{\"message\":\"…\"}'")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func hookRow(name: String, source: String, installed: Bool, path: String, detail: String,
                         install: @escaping () throws -> Void, uninstall: @escaping () throws -> Void) -> some View {
        HStack(spacing: 10) {
            AgentAvatar(source: source, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(name).fontWeight(.semibold)
                    Text(installed ? "Bağlı" : "Bağlı değil").font(.caption.weight(.semibold))
                        .foregroundStyle(installed ? .green : .secondary)
                }
                Text("\(detail) · \(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(installed ? "Kaldır" : "Bağla") {
                do {
                    try installed ? uninstall() : install()
                    message = nil
                } catch {
                    message = error.localizedDescription
                }
                claudeInstalled = HookInstaller.claudeInstalled
                codexInstalled = HookInstaller.codexInstalled
            }
        }
    }
}

// MARK: - Permissions

struct PermissionSettings: View {
    @State private var spotify = PermissionState.notAsked
    @State private var music = PermissionState.notAsked
    @State private var calendar = PermissionState.notAsked

    var body: some View {
        Section {
            permissionRow(title: "Spotify kontrolü", symbol: "music.note", state: spotify, pane: "Privacy_Automation") {
                Permissions.automation(PlayerApp.spotify.rawValue, ask: true) { spotify = $0 }
            }
            permissionRow(title: "Müzik kontrolü", symbol: "music.note.list", state: music, pane: "Privacy_Automation") {
                Permissions.automation(PlayerApp.music.rawValue, ask: true) { music = $0 }
            }
            permissionRow(title: "Takvim", symbol: "calendar", state: calendar, pane: "Privacy_Calendars") {
                CalendarService.shared.requestAccess()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { refresh() }
            }
        } footer: {
            Text("Çentik Erişilebilirlik, Ekran Kaydı ya da Tam Disk Erişimi istemez. Otomasyon izni, ilgili uygulama açıkken sorulabilir. Uygulama kalıcı bir imzayla imzalandığı için izinler güncellemelerden sonra da hatırlanır.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        Permissions.automation(PlayerApp.spotify.rawValue) { spotify = $0 }
        Permissions.automation(PlayerApp.music.rawValue) { music = $0 }
        calendar = Permissions.calendar
    }

    private func permissionRow(title: String, symbol: String, state: PermissionState, pane: String,
                               request: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            SettingsIcon(symbol: symbol, tint: .accentColor, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.semibold)
                HStack(spacing: 4) {
                    Circle().fill(color(state)).frame(width: 7, height: 7)
                    Text(state.label).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            switch state {
            case .granted, .unavailable:
                EmptyView()
            case .denied:
                Button("Sistem Ayarları'nı Aç") { Permissions.openSettings(pane) }
            case .notAsked:
                Button("İzin İste") { request() }
            case .appNotRunning:
                Text("Uygulama açılınca kontrol edilir").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func color(_ s: PermissionState) -> Color {
        switch s {
        case .granted: return .green
        case .denied: return .red
        case .notAsked: return .orange
        case .appNotRunning, .unavailable: return .gray
        }
    }
}

// MARK: - About

struct AboutSettings: View {
    var body: some View {
        Section {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Çentik").font(.title2.bold())
                    Text("Sürüm \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                        .foregroundStyle(.secondary)
                    Text("Tamamen ücretsiz; hesap, reklam ya da veri toplama yok.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        Section("Kısayollar") {
            LabeledContent("Çentiği aç / kapat", value: "⌃⌥N")
            LabeledContent("Rafa ekle", value: "Dosyayı çentiğe sürükle")
            LabeledContent("Panodan kopyala", value: "Çift tık")
            LabeledContent("Uyanık tut süresi", value: "Ana sekmede sağ tık")
        }
        Section {
            Button("Çentik'ten Çık", role: .destructive) { NSApp.terminate(nil) }
        }
    }
}

struct WeatherCityPicker: View {
    @AppStorage(Pref.weatherCity) private var city = ""
    @State private var query = ""
    @State private var results: [CityResult] = []
    @State private var searching = false
    @ObservedObject private var weather = WeatherService.shared

    var body: some View {
        if !city.isEmpty {
            LabeledContent {
                Button("Kaldır") { WeatherService.shared.select(nil) }
            } label: {
                Text(city)
                if let t = weather.temperature {
                    Text("\(Int(t.rounded()))° · \(weather.condition.text)")
                }
            }
        }
        HStack {
            TextField(city.isEmpty ? "Şehir ara (ör. İstanbul)" : "Başka şehir ara", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit(search)
            Button("Ara", action: search).disabled(query.trimmingCharacters(in: .whitespaces).count < 2)
            if searching { ProgressView().controlSize(.small) }
        }
        ForEach(results) { r in
            Button {
                WeatherService.shared.select(r)
                results = []
                query = ""
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.name).fontWeight(.medium)
                        if !r.subtitle.isEmpty { Text(r.subtitle).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func search() {
        searching = true
        WeatherService.search(query) { found in
            results = found
            searching = false
        }
    }
}

/// Turn tabs on or off and change their order.
struct TabSettings: View {
    @AppStorage(Pref.hiddenTabs) private var hiddenTabs = ""
    @AppStorage(Pref.tabOrder) private var tabOrder = ""

    private var hidden: Set<IslandTab> {
        Set(hiddenTabs.split(separator: ",").compactMap { IslandTab(rawValue: String($0)) })
    }

    private var ordered: [IslandTab] {
        let saved = tabOrder.split(separator: ",").compactMap { IslandTab(rawValue: String($0)) }
        return saved + IslandTab.allCases.filter { !saved.contains($0) }
    }

    var body: some View {
        let order = ordered
        let visibleCount = order.filter { !hidden.contains($0) }.count
        ForEach(Array(order.enumerated()), id: \.element) { index, tab in
            let on = !hidden.contains(tab)
            HStack(spacing: 10) {
                SettingsIcon(symbol: tab.symbol, tint: on ? .accentColor : .gray, size: 24)
                Text(tab.title).foregroundStyle(on ? .primary : .secondary)
                Spacer()
                Button { move(tab, by: -1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).disabled(index == 0)
                Button { move(tab, by: 1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless).disabled(index == order.count - 1)
                Toggle("", isOn: Binding(get: { on }, set: { setVisible(tab, $0) }))
                    .labelsHidden()
                    .disabled(on && visibleCount == 1)
                    .accessibilityLabel(tab.title)
            }
        }
        Button("Varsayılan sıra ve tüm sekmeler") {
            hiddenTabs = ""
            tabOrder = ""
        }
        .disabled(hiddenTabs.isEmpty && tabOrder.isEmpty)
    }

    private func setVisible(_ tab: IslandTab, _ on: Bool) {
        var set = hidden
        if on { set.remove(tab) } else { set.insert(tab) }
        hiddenTabs = IslandTab.allCases.filter(set.contains).map(\.rawValue).joined(separator: ",")
    }

    private func move(_ tab: IslandTab, by offset: Int) {
        var order = ordered
        guard let i = order.firstIndex(of: tab), order.indices.contains(i + offset) else { return }
        order.swapAt(i, i + offset)
        tabOrder = order.map(\.rawValue).joined(separator: ",")
    }
}
