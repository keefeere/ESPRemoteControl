import SwiftUI
import UIKit

final class BackspaceDetectingTextField: UITextField {
    var onDeleteBackwardWhenEmpty: (() -> Void)?

    override func deleteBackward() {
        let wasEmpty = text?.isEmpty ?? true
        super.deleteBackward()
        if wasEmpty {
            onDeleteBackwardWhenEmpty?()
        }
    }
}

/// A real text field used as a remote typing composer. Unlike the original
/// masked implementation, its backing text always matches what UIKit sees,
/// which keeps non-Latin keyboards, marked text, paste and prediction sane.
struct KeyCaptureTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var wantsFirstResponder: Bool

    var isSecure: Bool
    var onTextChange: (String, String) -> Void
    var onReturn: () -> Void
    var onBackspaceWhenEmpty: () -> Void

    func makeUIView(context: Context) -> BackspaceDetectingTextField {
        let textField = BackspaceDetectingTextField(frame: .zero)
        textField.delegate = context.coordinator
        textField.borderStyle = .none
        textField.font = UIFont.systemFont(ofSize: 18)
        textField.textColor = .label
        textField.tintColor = .systemBlue
        textField.placeholder = "Введіть або вставте текст…"
        textField.keyboardType = .default
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.smartQuotesType = .no
        textField.smartDashesType = .no
        textField.smartInsertDeleteType = .no
        textField.textContentType = .none
        textField.autocapitalizationType = .sentences
        textField.returnKeyType = .send
        textField.clearButtonMode = .whileEditing

        textField.onDeleteBackwardWhenEmpty = {
            context.coordinator.parent.onBackspaceWhenEmpty()
        }
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textFieldDidChange(_:)),
            for: .editingChanged
        )
        return textField
    }

    func updateUIView(_ textField: BackspaceDetectingTextField, context: Context) {
        context.coordinator.parent = self
        if textField.isSecureTextEntry != isSecure {
            textField.isSecureTextEntry = isSecure
        }

        if textField.text != text {
            textField.text = text
            context.coordinator.lastCommittedText = text
        }

        if wantsFirstResponder, !textField.isFirstResponder {
            DispatchQueue.main.async {
                textField.becomeFirstResponder()
                context.coordinator.moveCaretToEnd(in: textField)
            }
        } else if !wantsFirstResponder, textField.isFirstResponder {
            DispatchQueue.main.async {
                textField.resignFirstResponder()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: KeyCaptureTextField
        var lastCommittedText: String
        private var isMovingSelection = false

        init(parent: KeyCaptureTextField) {
            self.parent = parent
            self.lastCommittedText = parent.text
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onReturn()
            return false
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            guard !parent.wantsFirstResponder else { return }
            DispatchQueue.main.async {
                self.parent.wantsFirstResponder = true
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            guard parent.wantsFirstResponder else { return }
            DispatchQueue.main.async {
                self.parent.wantsFirstResponder = false
            }
        }

        @objc func textFieldDidChange(_ textField: UITextField) {
            // Wait until an IME finishes composing before emitting HID taps.
            guard textField.markedTextRange == nil else { return }

            let newText = textField.text ?? ""
            let oldText = lastCommittedText
            guard newText != oldText else { return }

            lastCommittedText = newText
            parent.text = newText
            parent.onTextChange(oldText, newText)
            moveCaretToEnd(in: textField)
        }

        func textFieldDidChangeSelection(_ textField: UITextField) {
            guard textField.markedTextRange == nil, !isMovingSelection else { return }
            moveCaretToEnd(in: textField)
        }

        func moveCaretToEnd(in textField: UITextField) {
            let end = textField.endOfDocument
            if let selectedRange = textField.selectedTextRange,
               textField.compare(selectedRange.end, to: end) == .orderedSame {
                return
            }
            isMovingSelection = true
            textField.selectedTextRange = textField.textRange(from: end, to: end)
            isMovingSelection = false
        }
    }
}
