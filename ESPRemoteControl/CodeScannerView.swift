import AVFoundation
import SwiftUI
import UIKit

struct CodeScannerButton: View {
    @Binding var text: String
    let isReady: Bool
    let onPrepare: () -> Void
    let onImmediateSend: (String) -> Void

    @AppStorage("scannerAutoSend") private var autoSend = false
    @AppStorage("scannerBatchMode") private var batchMode = false
    @State private var showsScanner = false
    @State private var alertMessage: String?
    @State private var batchStatus: String?

    var body: some View {
        Button {
            onPrepare()
            batchStatus = nil
            openScanner()
        } label: {
            Image(systemName: "qrcode.viewfinder")
                .frame(width: 34, height: 42)
        }
        .buttonStyle(.borderless)
        .padding(.top, 4)
        .accessibilityLabel("Сканувати QR, 2D або штрихкод")
        .help("QR, Data Matrix, Aztec, PDF417, EAN/UPC, Code 39/93/128 та ITF")
        .sheet(isPresented: $showsScanner) {
            NavigationStack {
                CodeScannerView(
                    continuous: batchMode,
                    onCode: handleCode,
                    onError: { message in
                        alertMessage = message
                        showsScanner = false
                    }
                )
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Сканер коду")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Закрити") { showsScanner = false }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Одразу надсилати", isOn: $autoSend)
                            .disabled(batchMode)
                        Toggle("Batch mode", isOn: $batchMode)

                        if let batchStatus {
                            Label(batchStatus, systemImage: "barcode.viewfinder")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(isReady ? Color.accentColor : Color.orange)
                        }

                        Text(scannerModeDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(.ultraThinMaterial)
                }
            }
        }
        .alert(
            "Сканер коду",
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var scannerModeDescription: String {
        if batchMode {
            return isReady
                ? "Batch mode не закриває камеру: кожен код одразу надсилається на комп’ютер, після нього — Enter. Повтор одного коду з того самого кадру приглушується."
                : "Batch mode потребує готового HID. Сканер залишиться відкритим, але код не буде відправлений, доки підключення не готове."
        }

        if autoSend {
            return isReady
                ? "Після сканування код одразу буде набраний на підключеному комп’ютері."
                : "HID не готовий: результат залишиться у полі «Ввід»."
        }

        return "Після сканування результат буде вставлено у поле «Ввід» без автоматичного надсилання."
    }

    private func openScanner() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showsScanner = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        showsScanner = true
                    } else {
                        alertMessage = "Доступ до камери не надано. Його можна увімкнути в Settings → Privacy & Security → Camera."
                    }
                }
            }
        case .denied, .restricted:
            alertMessage = "Доступ до камери вимкнений. Увімкни його в Settings → Privacy & Security → Camera."
        @unknown default:
            alertMessage = "Не вдалося визначити доступ до камери."
        }
    }

    private func handleCode(_ value: String) {
        text = value

        if batchMode {
            guard isReady else {
                batchStatus = "HID не готовий · код збережено у полі «Ввід»"
                return
            }

            // TextTypingPlanner maps the trailing newline to HID Enter, so the
            // whole barcode + submit action stays in the same ordered key queue.
            onImmediateSend(value + "\n")
            batchStatus = "Надіслано: \(value)"
            return
        }

        showsScanner = false

        guard autoSend else { return }
        guard isReady else {
            alertMessage = "Код збережено у полі «Ввід», але HID зараз не готовий до надсилання."
            return
        }
        onImmediateSend(value)
    }
}

struct CodeScannerView: UIViewControllerRepresentable {
    let continuous: Bool
    let onCode: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(continuous: continuous, onCode: onCode, onError: onError)
    }

    func makeUIViewController(context: Context) -> ScannerViewController {
        ScannerViewController(delegate: context.coordinator)
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {
        context.coordinator.continuous = continuous
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate, ScannerViewControllerDelegate {
        var continuous: Bool
        private let onCode: (String) -> Void
        private let onError: (String) -> Void
        private var acceptedCode = false
        private var lastValue: String?
        private var lastAcceptedAt: TimeInterval = 0

        init(
            continuous: Bool,
            onCode: @escaping (String) -> Void,
            onError: @escaping (String) -> Void
        ) {
            self.continuous = continuous
            self.onCode = onCode
            self.onError = onError
        }

        func scanner(_ scanner: ScannerViewController, didFail message: String) {
            onError(message)
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard let readable = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = readable.stringValue,
                  !value.isEmpty else { return }

            if continuous {
                let now = ProcessInfo.processInfo.systemUptime
                if value == lastValue, now - lastAcceptedAt < 0.75 {
                    return
                }
                lastValue = value
                lastAcceptedAt = now
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onCode(value)
                return
            }

            guard !acceptedCode else { return }
            acceptedCode = true
            output.setMetadataObjectsDelegate(nil, queue: nil)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onCode(value)
        }
    }
}

protocol ScannerViewControllerDelegate: AnyObject, AVCaptureMetadataOutputObjectsDelegate {
    func scanner(_ scanner: ScannerViewController, didFail message: String)
}

final class ScannerViewController: UIViewController {
    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "com.keefeere.ESPRemoteControl.codeScanner")
    private weak var scannerDelegate: ScannerViewControllerDelegate?
    private var previewLayer: AVCaptureVideoPreviewLayer?

    init(delegate: ScannerViewControllerDelegate) {
        scannerDelegate = delegate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureCaptureSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        captureQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func configureCaptureSession() {
        guard let camera = AVCaptureDevice.default(for: .video) else {
            scannerDelegate?.scanner(self, didFail: "Камеру не знайдено")
            return
        }

        configureCamera(camera)
        session.sessionPreset = .high

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(input) else {
                scannerDelegate?.scanner(self, didFail: "Не вдалося підключити камеру")
                return
            }
            session.addInput(input)
        } catch {
            scannerDelegate?.scanner(self, didFail: "Не вдалося відкрити камеру: \(error.localizedDescription)")
            return
        }

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            scannerDelegate?.scanner(self, didFail: "Сканер кодів недоступний")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(scannerDelegate, queue: .main)

        let wanted: [AVMetadataObject.ObjectType] = [
            .qr,
            .dataMatrix,
            .aztec,
            .pdf417,
            .ean8,
            .ean13,
            .upce,
            .code39,
            .code39Mod43,
            .code93,
            .code128,
            .interleaved2of5,
            .itf14
        ]
        output.metadataObjectTypes = wanted.filter { output.availableMetadataObjectTypes.contains($0) }
        guard !output.metadataObjectTypes.isEmpty else {
            scannerDelegate?.scanner(self, didFail: "Цей пристрій не підтримує barcode scanning")
            return
        }

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview

        let guide = UIView()
        guide.isUserInteractionEnabled = false
        guide.layer.borderWidth = 2
        guide.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
        guide.layer.cornerRadius = 18
        guide.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(guide)
        NSLayoutConstraint.activate([
            guide.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            guide.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            guide.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.82),
            guide.heightAnchor.constraint(equalTo: guide.widthAnchor, multiplier: 0.58)
        ])
    }

    private func configureCamera(_ camera: AVCaptureDevice) {
        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }

            if camera.isFocusModeSupported(.continuousAutoFocus) {
                camera.focusMode = .continuousAutoFocus
            }
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
        } catch {
            // Defaults still work; scanning should not fail just because an
            // optional camera tuning setting could not be changed.
        }
    }
}
