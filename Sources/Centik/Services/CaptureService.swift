import AppKit
import QuickLookThumbnailing

struct CaptureEvent: Equatable {
    enum Kind { case screenshot, recording, download }

    let url: URL
    let kind: Kind
    let thumbnail: NSImage?

    static func == (a: CaptureEvent, b: CaptureEvent) -> Bool { a.url == b.url && a.kind == b.kind }

    var title: String {
        switch kind {
        case .screenshot: return String(localized: "Ekran görüntüsü alındı")
        case .recording: return String(localized: "Ekran kaydı hazır")
        case .download: return String(localized: "İndirme tamamlandı")
        }
    }

    var symbol: String {
        switch kind {
        case .screenshot: return "camera.viewfinder"
        case .recording: return "record.circle"
        case .download: return "arrow.down.circle.fill"
        }
    }
}

/// Watches the screenshot folder and Downloads, and reports new screenshots, screen recordings
/// and finished downloads. Folder events come from the kernel; nothing is polled.
final class CaptureService {
    static let shared = CaptureService()

    var onCapture: ((CaptureEvent) -> Void)?

    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private var known: [String: Set<String>] = [:]
    private var pending: [String: DispatchWorkItem] = [:]

    private static let partialExtensions: Set<String> = ["download", "crdownload", "part", "partial", "tmp", "opdownload"]
    private static let screenshotPrefixes = ["Ekran Resmi", "Ekran Kaydı", "Screenshot", "Screen Shot", "Screen Recording",
                                             "Bildschirmfoto", "Capture d", "Captura de pantalla"]

    var screenshotFolder: URL {
        let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        let path = custom.map { ($0 as NSString).expandingTildeInPath } ?? NSHomeDirectory() + "/Desktop"
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    /// Starts or stops each watcher to match the current settings.
    func apply() {
        update(screenshotFolder, on: Pref.bool(Pref.captureScreenshots), kind: "shots")
        update(downloadsFolder, on: Pref.bool(Pref.captureDownloads), kind: "downloads")
    }

    private var starting = Set<String>()

    private func update(_ folder: URL, on: Bool, kind key: String) {
        if !on {
            watchers[key]?.cancel()
            watchers[key] = nil
            return
        }
        guard watchers[key] == nil, !starting.contains(key) else { return }
        starting.insert(key)
        // Opening Desktop or Downloads can raise a privacy prompt that blocks the calling thread
        // until answered, so the folder is opened off the main thread.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fd = open(folder.path, O_EVTONLY)
            let names = fd >= 0 ? self?.names(in: folder) ?? [] : []
            DispatchQueue.main.async {
                guard let self else { return }
                self.starting.remove(key)
                guard fd >= 0 else { return }
                guard Pref.bool(key == "shots" ? Pref.captureScreenshots : Pref.captureDownloads) else {
                    close(fd)
                    return
                }
                self.known[key] = Set(names)
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
                source.setEventHandler { [weak self] in self?.folderChanged(folder, key: key) }
                source.setCancelHandler { close(fd) }
                source.resume()
                self.watchers[key] = source
            }
        }
    }

    private func names(in folder: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { !$0.hasPrefix(".") } ?? []
    }

    private func folderChanged(_ folder: URL, key: String) {
        // Several events arrive per save; look once things settle.
        pending[key]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan(folder, key: key) }
        pending[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func scan(_ folder: URL, key: String) {
        let now = Set(names(in: folder))
        let added = now.subtracting(known[key] ?? [])
        known[key] = now
        for name in added.sorted() {
            let url = folder.appendingPathComponent(name)
            if key == "shots" {
                guard let kind = Self.screenKind(url) else { continue }
                announce(url, kind: kind)
            } else {
                guard !Self.partialExtensions.contains(url.pathExtension.lowercased()) else { continue }
                waitUntilStable(url) { [weak self] in self?.announce(url, kind: .download) }
            }
        }
    }

    static func screenKind(_ url: URL) -> CaptureEvent.Kind? {
        let name = url.lastPathComponent
        guard screenshotPrefixes.contains(where: { name.hasPrefix($0) }) else { return nil }
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "tiff", "pdf": return .screenshot
        case "mov", "mp4": return .recording
        default: return nil
        }
    }

    /// Calls back once the file's size stops changing (browsers sometimes write the final name early).
    private func waitUntilStable(_ url: URL, lastSize: Int64 = -1, attempts: Int = 0, then done: @escaping () -> Void) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
        guard size >= 0, attempts < 30 else { return }
        if size == lastSize, size > 0 { return done() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.waitUntilStable(url, lastSize: size, attempts: attempts + 1, then: done)
        }
    }

    private func announce(_ url: URL, kind: CaptureEvent.Kind) {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 96, height: 96),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            let image = rep?.nsImage ?? NSWorkspace.shared.icon(forFile: url.path)
            DispatchQueue.main.async { self?.onCapture?(CaptureEvent(url: url, kind: kind, thumbnail: image)) }
        }
    }
}
