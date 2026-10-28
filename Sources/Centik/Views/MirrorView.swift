import AVFoundation
import SwiftUI

/// Front camera preview. The capture session runs only while the mirror is on screen.
final class MirrorCamera: ObservableObject {
    static let shared = MirrorCamera()

    enum State { case idle, running, denied, noCamera }

    @Published private(set) var state: State = .idle
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "centik.mirror")
    private var configured = false

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { granted ? self.run() : (self.state = .denied) }
            }
        default:
            state = .denied
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
        if state == .running { state = .idle }
    }

    private func run() {
        queue.async {
            if !self.configured {
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                        ?? AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: device),
                      self.session.canAddInput(input) else {
                    DispatchQueue.main.async { self.state = .noCamera }
                    return
                }
                self.session.beginConfiguration()
                self.session.sessionPreset = .high
                self.session.addInput(input)
                self.session.commitConfiguration()
                self.configured = true
            }
            self.session.startRunning()
            DispatchQueue.main.async { self.state = .running }
        }
    }
}

struct CameraPreview: NSViewRepresentable {
    var session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) {}

    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        private var observer: NSObjectProtocol?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            previewLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(previewLayer)
            // The preview's connection only exists once the session runs, which is usually after
            // the first layout, so mirroring is applied again when it starts.
            observer = NotificationCenter.default.addObserver(forName: AVCaptureSession.didStartRunningNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
                self?.applyMirroring()
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        override func layout() {
            super.layout()
            previewLayer.frame = bounds
            applyMirroring()
        }

        /// A mirror shows you flipped, as a real one would.
        private func applyMirroring() {
            guard let connection = previewLayer.connection else { return }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            } else {
                // Some cameras can't mirror in the connection; flip the layer instead.
                previewLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
            }
        }
    }
}

struct MirrorPanel: View {
    @ObservedObject private var camera = MirrorCamera.shared
    @ObservedObject private var model = IslandModel.shared

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                switch camera.state {
                case .running, .idle:
                    CameraPreview(session: camera.session)
                case .denied:
                    VStack(spacing: 8) {
                        EmptyState(symbol: "video.slash.fill", title: "Kamera izni yok",
                                   subtitle: "Ayna için Sistem Ayarları'nda Çentik'e kamera izni ver.", tint: .orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Sistem Ayarları'nı Aç") { Permissions.openSettings("Privacy_Camera") }.buttonStyle(.pill(.orange))
                    }
                case .noCamera:
                    EmptyState(symbol: "video.slash", title: "Kamera bulunamadı", subtitle: "Bu Mac'te kullanılabilir kamera yok.", tint: .gray)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.7))

            Button { withAnimation(Motion.content) { model.mirrorOn = false } } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.black.opacity(0.55)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 0.6))
            }
            .buttonStyle(PressScaleStyle())
            .padding(8)
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }
}
