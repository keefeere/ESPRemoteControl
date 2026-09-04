import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let textView = UITextView()
    private let statusLabel = UILabel()
    private let sendButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)

    private var fallbackAttributedText: [String] = []
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
        subtitleLabel.text = "Текст буде збережено для ESP Remote. Відкрий застосунок — він використає вибраний Bluetooth-вихід."
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

        statusLabel.text = "Завантаження…"
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 2

        var sendConfiguration = UIButton.Configuration.filled()
        sendConfiguration.title = "Зберегти для ESP Remote"
        sendConfiguration.image = UIImage(systemName: "paperplane.fill")
        sendConfiguration.imagePadding = 8
        sendButton.configuration = sendConfiguration
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendButton.isEnabled = false

        closeButton.setTitle("Закрити", for: .normal)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let buttonRow = UIStackView(arrangedSubviews: [closeButton, sendButton])
        buttonRow.axis = .horizontal
        buttonRow.alignment = .center
        buttonRow.distribution = .fillEqually
        buttonRow.spacing = 12

        let stack = UIStackView(arrangedSubviews: [
            titleLabel,
            subtitleLabel,
            textView,
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

    private func updateReadyState() {
        let hasText = !textView.text.isEmpty
        sendButton.isEnabled = hasText && !isSending
        if !isSending {
            statusLabel.text = hasText
                ? "Готово. За потреби відредагуйте текст перед передаванням."
                : "У спільному елементі немає тексту або URL."
        }
    }

    @objc private func sendTapped() {
        let text = textView.text ?? ""
        guard !text.isEmpty, text.count <= 2_000 else {
            statusLabel.text = text.isEmpty
                ? "Введіть текст для передавання."
                : "Скоротіть текст до 2000 символів."
            return
        }
        guard ShareTextInbox.enqueue(text) else {
            finishWithError("Не вдалося зберегти текст")
            return
        }

        view.endEditing(true)
        isSending = true
        sendButton.isEnabled = false
        closeButton.isEnabled = false
        statusLabel.text = "Текст збережено. Відкрий ESP Remote для надсилання."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private func finishWithError(_ message: String) {
        isSending = false
        sendButton.isEnabled = true
        closeButton.isEnabled = true
        var configuration = sendButton.configuration
        configuration?.title = "Повторити"
        sendButton.configuration = configuration
        statusLabel.text = "\(message). Текст не втрачено; можна повторити."
    }

    @objc private func closeTapped() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

extension ShareViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        updateReadyState()
    }
}
