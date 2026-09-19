import AVFoundation
import SwiftUI
import UIKit

enum CodeScannerMode: String, CaseIterable, Identifiable {
    case qr2D
    case barcode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .qr2D: "QR / 2D"
        case .barcode: localized("Штрихкод")
        }
    }

    var metadataTypes: [AVMetadataObject.ObjectType] {
        switch self {
        case .qr2D:
            [.qr, .dataMatrix, .aztec, .pdf417]
        case .barcode:
            [
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
        }
    }

    var guideWidthMultiplier: CGFloat {
        switch self {
        case .qr2D: 0.72
        case .barcode: 0.86
        }
    }

    var guideAspectRatio: CGFloat {
        switch self {
        case .qr2D: 1.0
        case .barcode: 0.48
        }
    }
}

struct CodeScannerButton: View {
    @Binding var text: String
    let isReady: Bool
    let onPrepare: () -> Void
    let onImmediateSend: (String) -> Void

    @AppStorage("scannerAutoSend") private var autoSend = false
    @AppStorage("scannerBatchMode") private var batchMode = false
    @AppStorage("scannerMode") private var scannerModeRawValue = CodeScannerMode.qr2D.rawValue
    @State private var showsScanner = false
    @State private var alertMessage: String?
    @State private var batchStatus: String?

    private var scannerMode: CodeScannerMode {
        CodeScannerMode(rawValue: scannerModeRawValue) ?? .qr2D
    }

    var body: some View {
        Button {
            onPrepare()
            batchStatus = nil
            openScanner()
        } label: {
            Image(systemName: scannerMode == .barcode ? "barcode.viewfinder" : "qrcode.viewfinder")
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Відкрити сканер · \(scannerMode.title)")
        .help("Сканер · \(scannerMode.title)")
        .sheet(isPresented: $showsScanner) {
            NavigationStack {
                CodeScannerView(
                    mode: scannerMode,
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
                        Picker("Режим", selection: $scannerModeRawValue) {
                            ForEach(CodeScannerMode.allCases) { mode in
                                Text(mode.title).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)

                        Toggle("Одразу надсилати", isOn: $autoSend)
                            .disabled(batchMode)
                        Toggle("Batch mode", isOn: $batchMode)

                        if let batchStatus {
                            Label(batchStatus, systemImage: scannerMode == .barcode ? "barcode.viewfinder" : "qrcode.viewfinder")
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
        let modeText = localized(scannerMode == .barcode
            ? "Штрихкод: EAN/UPC, Code 39/93/128, Interleaved 2 of 5 та ITF-14."
            : "QR / 2D: QR, Data Matrix, Aztec та PDF417.")

        if batchMode {
            return modeText + localized(" Batch mode не закриває камеру: кожен код одразу надсилається на комп’ютер, після нього — Enter. Повтор одного коду з того самого кадру приглушується.")
        }

        if autoSend {
            return modeText + (isReady
                ? localized(" Після сканування код одразу буде набраний на підключеному комп’ютері.")
                : localized(" HID не готовий: результат залишиться у полі «Ввід»."))
        }

        return modeText + localized(" Після сканування результат буде вставлено у поле «Ввід» без автоматичного надсилання.")
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
                        alertMessage = localized("Доступ до камери не надано. Його можна увімкнути в Settings → Privacy & Security → Camera.")
                    }
                }
            }
        case .denied, .restricted:
            alertMessage = localized("Доступ до камери вимкнений. Увімкни його в Settings → Privacy & Security → Camera.")
        @unknown default:
            alertMessage = localized("Не вдалося визначити доступ до камери.")
        }
    }

    private func handleCode(_ value: String) {
        text = value

        if batchMode {
            guard isReady else {
                batchStatus = localized("HID не готовий · код збережено у полі «Ввід»")
                return
            }

            // TextTypingPlanner maps the trailing newline to HID Enter, so the
            // whole code + submit action stays in the same ordered key queue.
            onImmediateSend(value + "\n")
            batchStatus = localizedFormat("Надіслано: %@", value)
            return
        }

        showsScanner = false

        guard autoSend else { return }
        guard isReady else {
            alertMessage = localized("Код збережено у полі «Ввід», але HID зараз не готовий до надсилання.")
            return
        }
        onImmediateSend(value)
    }
}

struct CodeScannerView: UIViewControllerRepresentable {
    let mode: CodeScannerMode
    let continuous: Bool
    let onCode: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(mode: mode, continuous: continuous, onCode: onCode, onError: onError)
    }

    func makeUIViewController(context: Context) -> ScannerViewController {
        ScannerViewController(delegate: context.coordinator, mode: mode)
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {
        context.coordinator.update(mode: mode, continuous: continuous)
        uiViewController.setMode(mode)
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate, ScannerViewControllerDelegate {
        private var mode: CodeScannerMode
        private(set) var continuous: Bool
        private let onCode: (String) -> Void
        private let onError: (String) -> Void
        private var acceptedCode = false
        private var lastValue: String?
        private var lastAcceptedAt: TimeInterval = 0

        init(
            mode: CodeScannerMode,
            continuous: Bool,
            onCode: @escaping (String) -> Void,
            onError: @escaping (String) -> Void
        ) {
            self.mode = mode
            self.continuous = continuous
            self.onCode = onCode
            self.onError = onError
        }

        func update(mode: CodeScannerMode, continuous: Bool) {
            if self.mode != mode {
                self.mode = mode
                acceptedCode = false
                lastValue = nil
                lastAcceptedAt = 0
            }
            self.continuous = continuous
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
    private var metadataOutput: AVCaptureMetadataOutput?
    private var scanGuide: UIView?
    private var guideWidthConstraint: NSLayoutConstraint?
    private var guideHeightConstraint: NSLayoutConstraint?
    private var mode: CodeScannerMode

    init(delegate: ScannerViewControllerDelegate, mode: CodeScannerMode) {
        scannerDelegate = delegate
        self.mode = mode
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

    func setMode(_ mode: CodeScannerMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        applyMode()
    }

    private func configureCaptureSession() {
        guard let camera = AVCaptureDevice.default(for: .video) else {
            scannerDelegate?.scanner(self, didFail: localized("Камеру не знайдено"))
            return
        }

        configureCamera(camera)
        session.sessionPreset = .high

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(input) else {
                scannerDelegate?.scanner(self, didFail: localized("Не вдалося підключити камеру"))
                return
            }
            session.addInput(input)
        } catch {
            scannerDelegate?.scanner(self, didFail: localizedFormat("Не вдалося відкрити камеру: %@", error.localizedDescription))
            return
        }

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            scannerDelegate?.scanner(self, didFail: localized("Сканер кодів недоступний"))
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(scannerDelegate, queue: .main)
        metadataOutput = output

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
        scanGuide = guide
        NSLayoutConstraint.activate([
            guide.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            guide.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        applyMode()
    }

    private func applyMode() {
        guard let output = metadataOutput, let guide = scanGuide else { return }

        let wanted = mode.metadataTypes.filter { output.availableMetadataObjectTypes.contains($0) }
        guard !wanted.isEmpty else {
            scannerDelegate?.scanner(self, didFail: localizedFormat("Режим «%@» не підтримується цим пристроєм", mode.title))
            return
        }
        output.metadataObjectTypes = wanted

        guideWidthConstraint?.isActive = false
        guideHeightConstraint?.isActive = false

        let width = guide.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: mode.guideWidthMultiplier)
        let height = guide.heightAnchor.constraint(equalTo: guide.widthAnchor, multiplier: mode.guideAspectRatio)
        guideWidthConstraint = width
        guideHeightConstraint = height
        NSLayoutConstraint.activate([width, height])
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
