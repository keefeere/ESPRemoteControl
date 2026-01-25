//
//  KeyCaptureTextField.swift
//  ESPRemoteControl
//
//  Created by Ruben Kostandyan on 14/12/2025.
//

import SwiftUI
import UIKit

/// Custom UITextField that can detect backspace even when empty
final class BackspaceDetectingTextField: UITextField {
    var onDeleteBackward: (() -> Void)?
    
    override func deleteBackward() {
        let wasEmpty = text?.isEmpty ?? true
        super.deleteBackward()
        // If field was empty, still notify about backspace
        if wasEmpty {
            onDeleteBackward?()
        }
    }
}

/// A SwiftUI wrapper around UITextField that:
/// - becomes first responder on launch (native keyboard immediately)
/// - allows natural typing, paste, etc.
/// - reports text changes to parent for processing
/// - displays masked bullets for privacy
struct KeyCaptureTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var wantsFirstResponder: Bool
    
    var onTextChange: (String, String) -> Void  // (oldText, newText)
    var onReturn: () -> Void
    var onBackspaceWhenEmpty: () -> Void  // Called when backspace pressed on empty field

    func makeUIView(context: Context) -> BackspaceDetectingTextField {
        let tf = BackspaceDetectingTextField(frame: .zero)
        tf.delegate = context.coordinator

        tf.borderStyle = .none
        tf.font = UIFont.monospacedSystemFont(ofSize: 20, weight: .semibold)
        tf.textColor = .label
        tf.tintColor = .clear  // Hide cursor for cleaner look with bullets
        
        // Prevent text field from expanding based on content
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Allow any keyboard - user can switch to emoji, numbers, symbols, etc.
        tf.keyboardType = .default
        tf.autocorrectionType = .no
        tf.spellCheckingType = .no
        tf.smartQuotesType = .no
        tf.smartDashesType = .no
        tf.smartInsertDeleteType = .no
        tf.textContentType = .none
        tf.autocapitalizationType = .sentences
        tf.returnKeyType = .send
        
        // Handle backspace when empty
        tf.onDeleteBackward = { [context] in
            context.coordinator.handleBackspaceWhenEmpty()
        }

        // Add target for text changes
        tf.addTarget(context.coordinator, action: #selector(Coordinator.textFieldDidChange(_:)), for: .editingChanged)

        return tf
    }

    func updateUIView(_ uiView: BackspaceDetectingTextField, context: Context) {
        // Display bullets instead of actual text for privacy
        let bulletDisplay = text.isEmpty ? "" : String(repeating: "•", count: text.count)
        if uiView.text != bulletDisplay {
            uiView.text = bulletDisplay
        }
        
        // Sync coordinator's internal text with binding
        context.coordinator.syncInternalText(text)

        if wantsFirstResponder, !uiView.isFirstResponder {
            DispatchQueue.main.async {
                _ = uiView.becomeFirstResponder()
            }
        } else if !wantsFirstResponder, uiView.isFirstResponder {
            DispatchQueue.main.async {
                _ = uiView.resignFirstResponder()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: KeyCaptureTextField
        private var internalText: String = ""

        init(parent: KeyCaptureTextField) {
            self.parent = parent
            self.internalText = parent.text
        }
        
        func syncInternalText(_ text: String) {
            internalText = text
        }
        
        func handleBackspaceWhenEmpty() {
            parent.onBackspaceWhenEmpty()
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onReturn()
            return false
        }

        func textField(_ textField: UITextField,
                       shouldChangeCharactersIn range: NSRange,
                       replacementString string: String) -> Bool {
            // Calculate what the new text would be
            let currentText = internalText
            guard let textRange = Range(range, in: currentText) else {
                return false
            }
            
            let newText = currentText.replacingCharacters(in: textRange, with: string)
            let oldText = internalText
            internalText = newText
            
            // Report the change
            parent.onTextChange(oldText, newText)
            
            // Update the binding
            DispatchQueue.main.async {
                self.parent.text = newText
            }
            
            // We handle the display ourselves (bullets), so return false
            // Update the bullet display to match the actual text length
            let bulletDisplay = newText.isEmpty ? "" : String(repeating: "•", count: newText.count)
            textField.text = bulletDisplay
            
            return false
        }
        
        @objc func textFieldDidChange(_ textField: UITextField) {
            // This catches any changes we might have missed (paste via menu, etc.)
            // Sync internal state if needed
        }
    }
}
