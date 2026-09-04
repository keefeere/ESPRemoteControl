import SwiftUI
import UIKit

final class BackspaceDetectingTextView: UITextView {
    var onDeleteBackwardWhenEmpty: (() -> Void)?

    private let placeholderLabel: UILabel = {
        let label = UILabel()
        label.text = "Введіть або вставте текст…"
        label.font = UIFont.systemFont(ofSize: 17)
        label.textColor = .placeholderText
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let secureLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 17)
        label.textColor = .label
        label.numberOfLines = 0
        label.lineBreakMode = .byCharWrapping
        label.isHidden = true
        label.isAccessibilityElement = false
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private var masksText = false

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        addSubview(secureLabel)
        addSubview(placeholderLabel)
        let horizontalInset = textContainerInset.left + self.textContainer.lineFragmentPadding
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalInset),
            placeholderLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -(textContainerInset.right + self.textContainer.lineFragmentPadding)
            ),
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: textContainerInset.top),
            secureLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalInset),
            secureLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -(textContainerInset.right + self.textContainer.lineFragmentPadding)
            ),
            secureLabel.topAnchor.constraint(equalTo: topAnchor, constant: textContainerInset.top)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func deleteBackward() {
        let wasEmpty = text.isEmpty
        super.deleteBackward()
        if wasEmpty {
            onDeleteBackwardWhenEmpty?()
        }
    }

    func setSecureDisplay(_ isSecure: Bool) {
        masksText = isSecure
        updateTextPresentation()
    }

    func updatePlaceholder() {
        placeholderLabel.isHidden = !text.isEmpty
        updateTextPresentation()
    }

    private func updateTextPresentation() {
        textColor = masksText ? .clear : .label
        secureLabel.text = masksText ? String(repeating: "•", count: text.count) : nil
        secureLabel.isHidden = !masksText || text.isEmpty
        accessibilityValue = masksText && !text.isEmpty ? "Прихований текст" : nil
    }
}

/// A fixed-height, multiline composer backed by UIKit so marked text, paste,
/// prediction and non-Latin keyboards behave like a native iOS text editor.
struct KeyCaptureTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var wantsFirstResponder: Bool

    var isSecure: Bool
    var onBeginEditing: () -> Void
    var onTextChange: (String, String) -> Void
    var onReturn: () -> Void
    var onBackspaceWhenEmpty: () -> Void

    func makeUIView(context: Context) -> BackspaceDetectingTextView {
        let textView = BackspaceDetectingTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = UIFont.systemFont(ofSize: 17)
        textView.textColor = .label
        textView.tintColor = .systemBlue
        textView.keyboardType = .default
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.textContentType = .none
        textView.autocapitalizationType = .sentences
        textView.returnKeyType = .send
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = false
        textView.showsVerticalScrollIndicator = true
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.updatePlaceholder()

        textView.onDeleteBackwardWhenEmpty = {
            context.coordinator.parent.onBackspaceWhenEmpty()
        }
        return textView
    }

    func updateUIView(_ textView: BackspaceDetectingTextView, context: Context) {
        context.coordinator.parent = self
        if textView.text != text {
            textView.text = text
            context.coordinator.lastCommittedText = text
            textView.updatePlaceholder()
        }
        textView.setSecureDisplay(isSecure)

        if wantsFirstResponder, !textView.isFirstResponder {
            DispatchQueue.main.async {
                textView.becomeFirstResponder()
                context.coordinator.moveCaretToEnd(in: textView)
            }
        } else if !wantsFirstResponder, textView.isFirstResponder {
            DispatchQueue.main.async {
                textView.resignFirstResponder()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: KeyCaptureTextField
        var lastCommittedText: String
        private var isMovingSelection = false

        init(parent: KeyCaptureTextField) {
            self.parent = parent
            self.lastCommittedText = parent.text
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            guard replacement == "\n" else { return true }
            parent.onReturn()
            return false
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onBeginEditing()
            guard !parent.wantsFirstResponder else { return }
            DispatchQueue.main.async {
                self.parent.wantsFirstResponder = true
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            guard parent.wantsFirstResponder else { return }
            DispatchQueue.main.async {
                self.parent.wantsFirstResponder = false
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            (textView as? BackspaceDetectingTextView)?.updatePlaceholder()
            guard textView.markedTextRange == nil else { return }

            let newText = textView.text ?? ""
            let oldText = lastCommittedText
            guard newText != oldText else { return }

            lastCommittedText = newText
            parent.text = newText
            parent.onTextChange(oldText, newText)
            moveCaretToEnd(in: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard textView.markedTextRange == nil, !isMovingSelection else { return }
            moveCaretToEnd(in: textView)
        }

        func moveCaretToEnd(in textView: UITextView) {
            let end = textView.endOfDocument
            if let selectedRange = textView.selectedTextRange,
               textView.compare(selectedRange.end, to: end) == .orderedSame {
                return
            }
            isMovingSelection = true
            textView.selectedTextRange = textView.textRange(from: end, to: end)
            isMovingSelection = false
        }
    }
}

/// Installs a non-blocking tap recognizer on the surrounding SwiftUI host.
/// Touches inside the editor keep editing; every other tap dismisses it.
struct KeyboardDismissTapView: UIViewRepresentable {
    let onTapOutside: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onTapOutside = onTapOutside
        DispatchQueue.main.async {
            context.coordinator.installIfNeeded(from: view)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTapOutside: onTapOutside)
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTapOutside: () -> Void
        private weak var hostView: UIView?
        private var recognizer: UITapGestureRecognizer?

        init(onTapOutside: @escaping () -> Void) {
            self.onTapOutside = onTapOutside
        }

        func installIfNeeded(from view: UIView) {
            guard recognizer == nil, let host = view.superview else { return }
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(tapped))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            host.addGestureRecognizer(recognizer)
            hostView = host
            self.recognizer = recognizer
        }

        func uninstall() {
            if let recognizer {
                hostView?.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            hostView = nil
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            var touchedView: UIView? = touch.view
            while let view = touchedView {
                if view is UITextView { return false }
                touchedView = view.superview
            }
            return true
        }

        @objc private func tapped() {
            onTapOutside()
        }
    }
}
