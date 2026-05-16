import SwiftUI
import AVFoundation

struct CameraPreviewView: UIViewControllerRepresentable {
    let useFrontCamera: Bool
    let captureNonce: Int
    let isPaused: Bool
    let onImage: (UIImage) -> Void
    let onReady: () -> Void

    func makeUIViewController(context: Context) -> CameraViewController {
        let vc = CameraViewController()
        vc.onImage = onImage
        vc.onReady = onReady
        return vc
    }

    func updateUIViewController(_ uiViewController: CameraViewController, context: Context) {
        uiViewController.setUseFrontCamera(useFrontCamera)
        uiViewController.setPaused(isPaused)
        if context.coordinator.lastCaptureNonce != captureNonce {
            context.coordinator.lastCaptureNonce = captureNonce
            uiViewController.capture()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var lastCaptureNonce: Int = 0
    }
}

final class CameraViewController: UIViewController {
    var onImage: ((UIImage) -> Void)?
    var onReady: (() -> Void)?

    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var currentPosition: AVCaptureDevice.Position = .back

    private var isConfigured = false
    private var isConfiguringSession = false
    private var isPaused = false
    private let sessionQueue = DispatchQueue(label: "PocketLLM.camera.session")

    private var inFlightCaptureDelegate: PhotoCaptureDelegate?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupPreviewLayer()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        requestAndStart()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    func setUseFrontCamera(_ useFront: Bool) {
        let target: AVCaptureDevice.Position = useFront ? .front : .back
        guard target != currentPosition else { return }
        currentPosition = target
        reconfigureIfNeeded()
    }

    func capture() {
        sessionQueue.async {
            guard self.isConfigured, !self.isPaused else { return }
            let settings = AVCapturePhotoSettings()

            let delegate = PhotoCaptureDelegate(
                onImage: { [weak self] image in
                    self?.onImage?(image)
                },
                onFinish: { [weak self] in
                    self?.inFlightCaptureDelegate = nil
                }
            )
            self.inFlightCaptureDelegate = delegate

            // Call capture on main to match MainActor default isolation.
            DispatchQueue.main.async {
                self.photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    private func requestAndStart() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            startIfNeeded()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    self.startIfNeeded()
                }
            }
        default:
            // No permission: keep black screen.
            break
        }
    }

    func setPaused(_ paused: Bool) {
        sessionQueue.async {
            self.isPaused = paused
            if paused {
                if self.session.isRunning {
                    self.session.stopRunning()
                }
            } else {
                self.startRunningIfPossible()
            }
        }
    }

    private func startIfNeeded() {
        sessionQueue.async {
            if !self.isConfigured {
                self.configureSession()
            }
            self.startRunningIfPossible()
        }
    }

    private func reconfigureIfNeeded() {
        sessionQueue.async {
            guard self.isConfigured else { return }
            let wasRunning = self.session.isRunning
            if wasRunning {
                self.session.stopRunning()
            }

            self.isConfiguringSession = true
            self.session.beginConfiguration()
            defer {
                self.session.commitConfiguration()
                self.isConfiguringSession = false
                if wasRunning {
                    self.startRunningIfPossible()
                }
            }

            // Remove existing video inputs
            for input in self.session.inputs {
                if let deviceInput = input as? AVCaptureDeviceInput,
                   deviceInput.device.hasMediaType(.video) {
                    self.session.removeInput(deviceInput)
                }
            }

            if let input = self.makeVideoInput(position: self.currentPosition), self.session.canAddInput(input) {
                self.session.addInput(input)
            }
        }
    }

    private func configureSession() {
        isConfiguringSession = true
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
            isConfiguringSession = false
        }

        session.sessionPreset = .photo

        guard let input = makeVideoInput(position: currentPosition), session.canAddInput(input) else {
            return
        }
        session.addInput(input)

        guard session.canAddOutput(photoOutput) else {
            return
        }
        session.addOutput(photoOutput)

        isConfigured = true
    }

    private func setupPreviewLayer() {
        guard previewLayer == nil else { return }
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
    }

    private func startRunningIfPossible() {
        guard isConfigured else { return }
        guard !isConfiguringSession else { return }
        guard !isPaused else { return }
        guard !session.isRunning else {
            DispatchQueue.main.async { self.onReady?() }
            return
        }
        session.startRunning()
        DispatchQueue.main.async { self.onReady?() }
    }

    private func makeVideoInput(position: AVCaptureDevice.Position) -> AVCaptureDeviceInput? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: position
        )
        guard let device = discovery.devices.first else { return nil }
        return try? AVCaptureDeviceInput(device: device)
    }
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let onImage: (UIImage) -> Void
    private let onFinish: () -> Void

    init(onImage: @escaping (UIImage) -> Void, onFinish: @escaping () -> Void) {
        self.onImage = onImage
        self.onFinish = onFinish
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        defer { onFinish() }
        guard error == nil, let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
            return
        }
        DispatchQueue.main.async {
            self.onImage(image)
        }
    }
}
