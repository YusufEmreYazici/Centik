import AppKit
import UniformTypeIdentifiers

enum ClipKind: String, CaseIterable, Identifiable {
    case text, link, code, color, image, file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: return "Metin"
        case .link: return "Bağlantı"
        case .code: return "Kod"
        case .color: return "Renk"
        case .image: return "Görsel"
        case .file: return "Dosya"
        }
    }

    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .color: return "paintpalette.fill"
        case .image: return "photo.fill"
        case .file: return "doc.fill"
        }
    }

    /// Works out what a copied string is.
    static func classify(_ text: String) -> ClipKind {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.contains(where: \.isWhitespace), let url = URL(string: t), let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto", "ftp"].contains(scheme) {
            return .link
        }
        if ClipItem.parseColor(t) != nil { return .color }
        let codeMarkers = ["{", "}", "=>", "->", "func ", "import ", "const ", "let ", "var ", "def ", "class ",
                           "</", "();", "#include", "SELECT ", "return "]
        let markers = codeMarkers.filter { t.contains($0) }.count
        if markers >= 2 || (markers == 1 && t.contains("\n")) { return .code }
        return .text
    }
}

struct ClipSource: Equatable {
    let name: String
    let bundleID: String?

    var icon: NSImage? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

struct ClipItem: Identifiable, Equatable {
    let id: UUID
    let kind: ClipKind
    let text: String?
    let rtf: Data?
    let image: Data?
    let thumbnail: NSImage?
    let pixelSize: CGSize?
    let files: [URL]
    let source: ClipSource?
    var date: Date
    var pinned: Bool

    init(id: UUID = UUID(), kind: ClipKind, text: String? = nil, rtf: Data? = nil, image: Data? = nil,
         thumbnail: NSImage? = nil, pixelSize: CGSize? = nil, files: [URL] = [], source: ClipSource?,
         date: Date = Date(), pinned: Bool = false) {
        self.id = id
        self.kind = kind
        self.text = text
        self.rtf = rtf
        self.image = image
        self.thumbnail = thumbnail
        self.pixelSize = pixelSize
        self.files = files
        self.source = source
        self.date = date
        self.pinned = pinned
    }

    static func == (a: ClipItem, b: ClipItem) -> Bool {
        a.id == b.id && a.pinned == b.pinned && a.date == b.date
    }

    /// One-line label for lists.
    var title: String {
        switch kind {
        case .image:
            if let s = pixelSize { return "Görsel · \(Int(s.width))×\(Int(s.height))" }
            return "Görsel"
        case .file:
            guard let first = files.first else { return "Dosya" }
            return files.count == 1 ? first.lastPathComponent : "\(first.lastPathComponent) +\(files.count - 1)"
        default:
            return (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ⏎ ")
        }
    }

    var color: NSColor? { kind == .color ? text.flatMap(Self.parseColor) : nil }

    var byteCount: Int {
        image?.count ?? text?.utf8.count ?? 0
    }

    /// Whether two captures are the same thing copied again.
    func sameContent(as other: ClipItem) -> Bool {
        guard kind == other.kind else { return false }
        switch kind {
        case .image: return image?.count == other.image?.count && image == other.image
        case .file: return files == other.files
        default: return text == other.text
        }
    }

    /// Accepts #RGB, #RRGGBB, #RRGGBBAA and rgb()/rgba() strings.
    static func parseColor(_ s: String) -> NSColor? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.hasPrefix("#") {
            var hex = String(t.dropFirst())
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6 || hex.count == 8, let v = UInt64(hex, radix: 16) else { return nil }
            let hasAlpha = hex.count == 8
            let r = Double((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
            let g = Double((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
            let b = Double((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
            let a = hasAlpha ? Double(v & 0xFF) / 255 : 1
            return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        }
        if t.hasPrefix("rgb"), let open = t.firstIndex(of: "("), let close = t.lastIndex(of: ")") {
            let parts = t[t.index(after: open)..<close].split(separator: ",").compactMap {
                Double($0.trimmingCharacters(in: .whitespaces))
            }
            guard parts.count >= 3, parts.prefix(3).allSatisfy({ (0...255).contains($0) }) else { return nil }
            return NSColor(srgbRed: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255,
                           alpha: parts.count > 3 ? min(1, parts[3]) : 1)
        }
        return nil
    }
}

/// Clipboard history for text, links, code, colours, images and files.
///
/// History lives in memory. Only items the user pins are written to disk (so they survive a
/// restart). Anything marked concealed or transient, which password managers use, is skipped.
final class ClipboardService: ObservableObject {
    static let shared = ClipboardService()

    @Published private(set) var items: [ClipItem] = []

    private var lastCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    private static let maxItems = 60
    private static let maxImages = 15
    private static let maxImageBytes = 25_000_000
    private static let skippedTypes: Set<NSPasteboard.PasteboardType> = [
        .init("org.nspasteboard.ConcealedType"),
        .init("org.nspasteboard.TransientType"),
        .init("org.nspasteboard.AutoGeneratedType"),
        .init("com.agilebits.onepassword"),
    ]

    private var pinnedDirectory: URL {
        AgentService.shared.directory.appendingPathComponent("Pinned", isDirectory: true)
    }

    func start() {
        loadPinned()
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in self?.poll() }
    }

    var counts: [ClipKind: Int] {
        Dictionary(grouping: items, by: \.kind).mapValues(\.count)
    }

    // MARK: Capture

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastCount else { return }
        lastCount = pb.changeCount
        guard Pref.bool(Pref.clipboardEnabled), let types = pb.types,
              Self.skippedTypes.isDisjoint(with: types) else { return }
        guard let item = Self.capture(pb) else { return }
        insert(item)
    }

    private static func capture(_ pb: NSPasteboard) -> ClipItem? {
        let app = NSWorkspace.shared.frontmostApplication
        let source = app.map { ClipSource(name: $0.localizedName ?? "Uygulama", bundleID: $0.bundleIdentifier) }

        // Files first: copying a file in Finder also puts its icon on the pasteboard as an image.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return ClipItem(kind: .file, files: urls, source: source)
        }
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff), data.count <= maxImageBytes {
            return imageItem(data, source: source)
        }
        if let raw = pb.string(forType: .string) {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 100_000 else { return nil }
            return ClipItem(kind: ClipKind.classify(text), text: text, rtf: pb.data(forType: .rtf), source: source)
        }
        return nil
    }

    static func imageItem(_ data: Data, source: ClipSource?) -> ClipItem? {
        guard let image = NSImage(data: data), let rep = image.representations.first else { return nil }
        let pixels = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        return ClipItem(kind: .image, image: data, thumbnail: thumbnail(of: image, side: 240),
                        pixelSize: pixels, source: source)
    }

    private static func thumbnail(of image: NSImage, side: CGFloat) -> NSImage {
        let size = image.size
        let scale = min(1, side / max(size.width, size.height, 1))
        let target = NSSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        return NSImage(size: target, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
    }

    private func insert(_ item: ClipItem) {
        var item = item
        if let existing = items.firstIndex(where: { $0.sameContent(as: item) }) {
            item.pinned = items[existing].pinned
            items.remove(at: existing)
        }
        items.insert(item, at: 0)
        trim()
    }

    private func trim() {
        // Pinned items are never dropped; images are capped separately because they are large.
        var images = 0
        items = items.filter { item in
            guard !item.pinned, item.kind == .image else { return true }
            images += 1
            return images <= Self.maxImages
        }
        while items.count > Self.maxItems, let last = items.lastIndex(where: { !$0.pinned }) {
            items.remove(at: last)
        }
    }

    // MARK: Actions

    /// Puts the item back on the clipboard with its original types; `plain` drops formatting.
    func copy(_ item: ClipItem, plain: Bool = false) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .image:
            if let data = item.image, let image = NSImage(data: data) {
                pb.writeObjects([image])
            }
        case .file:
            pb.writeObjects(item.files as [NSURL])
        default:
            if !plain, let rtf = item.rtf { pb.setData(rtf, forType: .rtf) }
            pb.setString(item.text ?? "", forType: .string)
        }
        lastCount = pb.changeCount
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            var moved = items.remove(at: index)
            moved.date = Date()
            items.insert(moved, at: 0)
        }
    }

    func togglePin(_ item: ClipItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].pinned.toggle()
        savePinned()
    }

    func remove(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
        if item.pinned { savePinned() }
    }

    /// Clears everything except pinned items.
    func clear() { items.removeAll { !$0.pinned } }

    func open(_ item: ClipItem) {
        switch item.kind {
        case .link: if let url = item.text.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
        case .file: item.files.first.map { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
        default: break
        }
    }

    /// Writes an image item to Downloads as PNG and shows it in Finder.
    @discardableResult
    func saveImage(_ item: ClipItem, to folder: URL? = nil, reveal: Bool = true) -> URL? {
        guard let data = item.image, let image = NSImage(data: data), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let dir = folder ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let stamp = item.date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().second())
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        let url = dir.appendingPathComponent("Pano \(stamp).png")
        guard (try? png.write(to: url)) != nil else { return nil }
        if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        return url
    }

    /// Hands the item to the file shelf: files as they are, images and text as new files.
    func addToShelf(_ item: ClipItem) {
        let dir = AgentService.shared.directory.appendingPathComponent("Clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        switch item.kind {
        case .file:
            ShelfStore.shared.add(item.files)
        case .image:
            if let url = saveImage(item, to: dir, reveal: false) { ShelfStore.shared.add([url]) }
        default:
            let name = String((item.text ?? "Metin").prefix(28)).replacingOccurrences(of: "/", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let url = dir.appendingPathComponent("\(name.isEmpty ? "Metin" : name).txt")
            if (try? (item.text ?? "").write(to: url, atomically: true, encoding: .utf8)) != nil {
                ShelfStore.shared.add([url])
            }
        }
        IslandModel.shared.tab = .shelf
    }

    /// Item for dragging out of the history into another app.
    func itemProvider(_ item: ClipItem) -> NSItemProvider {
        switch item.kind {
        case .file:
            return item.files.first.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider()
        case .image:
            if let data = item.image, let image = NSImage(data: data) { return NSItemProvider(object: image) }
            return NSItemProvider()
        case .link:
            if let url = item.text.flatMap(URL.init(string:)) { return NSItemProvider(object: url as NSURL) }
            return NSItemProvider(object: (item.text ?? "") as NSString)
        default:
            return NSItemProvider(object: (item.text ?? "") as NSString)
        }
    }

    // MARK: Pinned persistence

    private struct StoredPin: Codable {
        let id: UUID
        let kind: String
        let text: String?
        let files: [String]
        let sourceName: String?
        let sourceBundle: String?
        let date: Date
    }

    private func savePinned() {
        try? FileManager.default.createDirectory(at: pinnedDirectory, withIntermediateDirectories: true)
        let pinned = items.filter(\.pinned)
        let stored = pinned.map {
            StoredPin(id: $0.id, kind: $0.kind.rawValue, text: $0.text, files: $0.files.map(\.path),
                      sourceName: $0.source?.name, sourceBundle: $0.source?.bundleID, date: $0.date)
        }
        for item in pinned where item.kind == .image {
            let url = pinnedDirectory.appendingPathComponent("\(item.id.uuidString).img")
            if !FileManager.default.fileExists(atPath: url.path) { try? item.image?.write(to: url) }
        }
        // Drop image files that are no longer pinned.
        let keep = Set(pinned.map { "\($0.id.uuidString).img" })
        for name in (try? FileManager.default.contentsOfDirectory(atPath: pinnedDirectory.path)) ?? []
        where name.hasSuffix(".img") && !keep.contains(name) {
            try? FileManager.default.removeItem(at: pinnedDirectory.appendingPathComponent(name))
        }
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: pinnedDirectory.appendingPathComponent("pinned.json"), options: .atomic)
        }
    }

    private func loadPinned() {
        guard let data = try? Data(contentsOf: pinnedDirectory.appendingPathComponent("pinned.json")),
              let stored = try? JSONDecoder().decode([StoredPin].self, from: data) else { return }
        items = stored.compactMap { pin in
            guard let kind = ClipKind(rawValue: pin.kind) else { return nil }
            let source = pin.sourceName.map { ClipSource(name: $0, bundleID: pin.sourceBundle) }
            if kind == .image {
                guard let data = try? Data(contentsOf: pinnedDirectory.appendingPathComponent("\(pin.id.uuidString).img")),
                      let item = Self.imageItem(data, source: source) else { return nil }
                return ClipItem(id: pin.id, kind: .image, image: item.image, thumbnail: item.thumbnail,
                                pixelSize: item.pixelSize, source: source, date: pin.date, pinned: true)
            }
            return ClipItem(id: pin.id, kind: kind, text: pin.text, files: pin.files.map { URL(fileURLWithPath: $0) },
                            source: source, date: pin.date, pinned: true)
        }
    }
}

#if DEBUG
extension ClipboardService {
    func loadPreview(_ preview: [ClipItem]) { items = preview }
}
#endif
