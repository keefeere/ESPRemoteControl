import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let textView = UITextView()
    private let outputControl = UISegmentedControl(items: ["ESP32", "Bluetooth"])
    private let layoutControl = UISegmentedControl(items: ["EN", "UA"])
    private let statusLabel = UILabel()
    private let shortcutButton = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)

    private var selectedShortcut = ShareExtensionPreferences.layoutShortcut
    private var fallbackAttributedText: [String] = []
    private var transmitter: ShareTextTransmitter?
    private var isSending = false

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        loadSharedContent()
    }

    private func configureUI() {
        view.backgroundColor = .systemGroupedBackground
        let titleLabel = UILabel()
        titleLabel.text = "ESP Remote Control"
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true

        let subtitleLabel = UILabel()
        subtitleLabel.text = "Надіслати текст або посилання через ESP32 чи напряму Bluetooth"
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 0

        textView.font = .preferredFont(forTextStyle: .body)
        textView.backgroundColor = .secondarySystemGroupedBackground
        textView.layer.cornerRadius = 12
        textView.layer.cornerCurve = .continuous
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        textView.delegate = self
        textView.accessibilityLabel = "Текст для надсилання"

        outputControl.selectedSegmentIndex = ShareExtensionPreferences.outputRoute == .directBluetooth ? 1 : 0
        outputControl.accessibilityLabel = "Вихід для тексту"
        outputControl.addTarget(self, action: #selector(outputChanged), for: .valueChanged)

        layoutControl.selectedSegmentIndex = ShareExtensionPreferences.targetLayout == .ukrainianEnhanced ? 1 : 0
        layoutControl.accessibilityLabel = "Поточна розкладка комп’ютера"

        let layoutLabel = UILabel()
        layoutLabel.text = "Поточна розкладка на комп’ютері"
        layoutLabel.font = .preferredFont(forTextStyle: .subheadline)

        statusLabel.text = "Завантаження…"
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 2

        var sendConfiguration = UIButton.Configuration.filled()
        sendConfiguration.title = "Надіслати"
        sendConfiguration.image = UIImage(systemName: "paperplane.fill")
        sendConfiguration.imagePadding = 8
        sendButton.configuration = sendConfiguration
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendButton.isEnabled = false

        closeButton.setTitle("Закрити", for: .normal)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let layoutRow = UIStackView(arrangedSubviews: [layoutLabel, layoutControl])
        layoutRow.axis = .horizontal
        layoutRow.alignment = .center
        layoutRow.spacing = 12
        layoutLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        layoutControl.setContentHuggingPriority(.required, for: .horizontal)

        let outputLabel = UILabel()
        outputLabel.text = "Вихід"
        outputLabel.font = .preferredFont(forTextStyle: .subheadline)

        let outputRow = UIStackView(arrangedSubviews: [outputLabel, outputControl])
        outputRow.axis = .horizontal
        outputRow.alignment = .center
        outputRow.spacing = 12
        outputLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        outputControl.setContentHuggingPriority(.required, for: .horizontal)

        let shortcutLabel = UILabel()
        shortcutLabel.text = "Перемикання розкладки"
        shortcutLabel.font = .preferredFont(forTextStyle: .subheadline)
        configureShortcutMenu()

        let shortcutRow = UIStackView(arrangedSubviews: [shortcutLabel, shortcutButton])
        shortcutRow.axis = .horizontal
        shortcutRow.alignment = .center
        shortcutRow.spacing = 12
        shortcutLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        shortcutButton.setContentHuggingPriority(.required, for: .horizontal)

        let buttonRow = UIStackView(arrangedSubviews: [closeButton, sendButton])
        buttonRow.axis = .horizontal
        buttonRow.alignment = .center
        buttonRow.distribution = .fillEqually
        buttonRow.spacing = 12

        let stack = UIStackView(arrangedSubviews: [
            titleLabel,
            subtitleLabel,
            outputRow,
            textView,
            layoutRow,
            shortcutRow,
            statusLabel,
            buttonRow
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = UIScrollView()
        scrollView.keyboardDismissMode = .interactive
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -14),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32),
            textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            sendButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            closeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }

    private func loadSharedContent() {
        let extensionItems = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let providers = extensionItems.flatMap { $0.attachments ?? [] }
        fallbackAttributedText = extensionItems.compactMap { $0.attributedContentText?.string }

        loadProviderText(providers, index: 0, collected: [])
    }

    private func loadProviderText(
        _ providers: [NSItemProvider],
        index: Int,
        collected: [String]
    ) {
        guard index < providers.count else {
            let unique = collected.reduce(into: [String]()) { values, value in
                guard !value.isEmpty, !values.contains(value) else { return }
                values.append(value)
            }
            textView.text = (unique.isEmpty ? fallbackAttributedText : unique).joined(separator: "\n")
            updateReadyState()
            return
        }

        let provider = providers[index]
        let typeIdentifier: String?
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            typeIdentifier = UTType.url.identifier
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            typeIdentifier = UTType.plainText.identifier
        } else if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
            typeIdentifier = UTType.text.identifier
        } else {
            typeIdentifier = nil
        }

        guard let typeIdentifier else {
            loadProviderText(providers, index: index + 1, collected: collected)
            return
        }

        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] item, _ in
            let value = Self.stringValue(from: item)
            DispatchQueue.main.async {
                var updated = collected
                if let value, !value.isEmpty {
                    updated.append(value)
                }
                self?.loadProviderText(providers, index: index + 1, collected: updated)
            }
        }
    }

    nonisolated private static func stringValue(from item: NSSecureCoding?) -> String? {
        switch item {
        case let url as NSURL:
            url.absoluteString
        case let string as NSString:
            string as String
        case let data as NSData:
            String(data: data as Data, encoding: .utf8)
        default:
            nil
        }
    }

    private func configureShortcutMenu() {
        var configuration = UIButton.Configuration.bordered()
        configuration.title = selectedShortcut.displayName
        shortcutButton.configuration = configuration
        shortcutButton.showsMenuAsPrimaryAction = true
        shortcutButton.menu = UIMenu(children: HostLayoutShortcut.allCases.map { shortcut in
            UIAction(
                title: shortcut.displayName,
                state: shortcut == selectedShortcut ? .on : .off
            ) { [weak self] _ in
                self?.selectedShortcut = shortcut
                self?.configureShortcutMenu()
            }
        })
    }

    private func updateReadyState() {
        let hasText = !textView.text.isEmpty
        sendButton.isEnabled = hasText && !isSending
        if !isSending {
            statusLabel.text = hasText
                ? "Готово. За потреби відредагуйте текст перед надсиланням."
                : "У спільному елементі немає тексту або URL."
        }
    }

    @objc private func sendTapped() {
        let text = textView.text ?? ""
        guard !text.isEmpty, text.count <= 2_000 else {
            statusLabel.text = text.isEmpty
                ? "Введіть текст для надсилання."
                : "Скоротіть текст до 2000 символів."
            return
        }

        view.endEditing(true)
        isSending = true
        sendButton.isEnabled = false
        outputControl.isEnabled = false
        layoutControl.isEnabled = false
        shortcutButton.isEnabled = false
        closeButton.isEnabled = false

        let startingLayout: KeyboardLayout = layoutControl.selectedSegmentIndex == 1
            ? .ukrainianEnhanced
            : .englishUS
        let plan = TextTypingPlanner.makePlan(
            for: text,
            startingLayout: startingLayout,
            layoutShortcut: selectedShortcut
        )

        guard !plan.taps.isEmpty else {
            finishWithError("Для цього тексту немає підтримуваних HID-клавіш.")
            return
        }

        if ShareExtensionPreferences.outputRoute == .directBluetooth, plan.taps.count > 600 {
            finishWithError("Для прямого Bluetooth надішліть до 600 клавіш за раз.")
            return
        }

        let transmitter: ShareTextTransmitter = ShareExtensionPreferences.outputRoute == .directBluetooth
            ? ShareDirectHIDTransmitter()
            : ShareBLETransmitter()
        self.transmitter = transmitter
        transmitter.onStatusChange = { [weak self] status in
            self?.statusLabel.text = status
        }
        transmitter.send(plan.taps) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                ShareExtensionPreferences.targetLayout = plan.finalLayout
                ShareExtensionPreferences.layoutShortcut = selectedShortcut
                let routeName = ShareExtensionPreferences.outputRoute == .directBluetooth
                    ? "напряму Bluetooth"
                    : "через ESP32"
                statusLabel.text = plan.unsupportedCharacters.isEmpty
                    ? "Надіслано \(routeName)"
                    : "Надіслано \(routeName); пропущено: \(String(plan.unsupportedCharacters.prefix(6)))"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    self?.extensionContext?.completeRequest(returningItems: nil)
                }
            case .failure(let error):
                finishWithError(error.localizedDescription)
            }
        }
    }

    private func finishWithError(_ message: String) {
        isSending = false
        outputControl.isEnabled = true
        layoutControl.isEnabled = true
        shortcutButton.isEnabled = true
        closeButton.isEnabled = true
        sendButton.isEnabled = true
        var configuration = sendButton.configuration
        configuration?.title = "Повторити"
        sendButton.configuration = configuration

        statusLabel.text = "\(message). Текст не втрачено; можна повторити."
    }

    @objc private func closeTapped() {
        transmitter?.cancel()
        extensionContext?.completeRequest(returningItems: nil)
    }

    @objc private func outputChanged() {
        ShareExtensionPreferences.outputRoute = outputControl.selectedSegmentIndex == 1
            ? .directBluetooth
            : .espBridge
        statusLabel.text = ShareExtensionPreferences.outputRoute == .directBluetooth
            ? "Прямий Bluetooth: дочекайтеся підключення клавіатури на комп’ютері."
            : "ESP32: буде знайдено найближчий міст."
    }
}

extension ShareViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        updateReadyState()
    }
}
