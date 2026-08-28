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

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: textContainerInset.left + self.textContainer.lineFragmentPadding
            ),
            placeholderLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -(textContainerInset.right + self.textContainer.lineFragmentPadding)
            ),
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: textContainerInset.top)
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

    func updatePlaceholder() {
        placeholderLabel.isHidden = !text.isEmpty
    }
}

/// A fixed-height, multiline composer backed by UIKit so marked text, paste,
/// prediction and non-Latin keyboards behave like a native iOS text editor.
struct KeyCaptureTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var wantsFirstResponder: Bool

    var isSecure: Bool
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

        let accessory = UIToolbar()
        accessory.sizeToFit()
        accessory.items = [
            UIBarButtonItem(
                barButtonSystemItem: .flexibleSpace,
                target: nil,
                action: nil
            ),
            UIBarButtonItem(
                title: "Сховати",
                style: .done,
                target: context.coordinator,
                action: #selector(Coordinator.dismissKeyboard)
            )
        ]
        textView.inputAccessoryView = accessory
        textView.onDeleteBackwardWhenEmpty = {
            context.coordinator.parent.onBackspaceWhenEmpty()
        }
        return textView
    }

    func updateUIView(_ textView: BackspaceDetectingTextView, context: Context) {
        context.coordinator.parent = self
        if textView.isSecureTextEntry != isSecure {
            textView.isSecureTextEntry = isSecure
        }

        if textView.text != text {
            textView.text = text
            context.coordinator.lastCommittedText = text
            textView.updatePlaceholder()
        }

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

        @objc func dismissKeyboard() {
            parent.wantsFirstResponder = false
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
