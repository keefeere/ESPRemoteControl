import SwiftUI
import UIKit

/// UIKit delivers a short release to the button. A recognized hold cancels
/// that touch sequence, so releasing a long press cannot also trigger a tap.
struct ShortAndLongPressButtonStyle: PrimitiveButtonStyle {
    let longPressLabel: String
    let onLongPress: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        PressActionButtonBody(
            label: configuration.label,
            longPressLabel: longPressLabel,
            onTap: configuration.trigger,
            onLongPress: onLongPress
        )
    }
}

private struct PressActionButtonBody<Label: View>: View {
    let label: Label
    let longPressLabel: String
    let onTap: () -> Void
    let onLongPress: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isPressed = false

    var body: some View {
        label
            .opacity(isEnabled ? (isPressed ? 0.65 : 1) : 0.4)
            .overlay {
                PressActionSurface(
                    isEnabled: isEnabled,
                    onTap: onTap,
                    onLongPress: onLongPress,
                    onPressingChanged: { isPressed = $0 }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                if isEnabled { onTap() }
            }
            .accessibilityAction(named: Text(longPressLabel)) {
                if isEnabled { onLongPress() }
            }
    }
}

private struct PressActionSurface: UIViewRepresentable {
    let isEnabled: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void
    let onPressingChanged: (Bool) -> Void

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.isExclusiveTouch = false
        button.isAccessibilityElement = false
        button.isEnabled = isEnabled
        button.addTarget(context.coordinator, action: #selector(Coordinator.touchDown), for: .touchDown)
        button.addTarget(context.coordinator, action: #selector(Coordinator.touchUpInside), for: .touchUpInside)
        button.addTarget(context.coordinator, action: #selector(Coordinator.touchCancelled),
                         for: [.touchCancel, .touchUpOutside, .touchDragExit])
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.longPress(_:)))
        hold.minimumPressDuration = 0.5
        hold.allowableMovement = 10
        hold.cancelsTouchesInView = true
        hold.delaysTouchesBegan = false
        button.addGestureRecognizer(hold)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.parent = self
        button.isEnabled = isEnabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject {
        var parent: PressActionSurface
        private var didLongPress = false

        init(parent: PressActionSurface) { self.parent = parent }

        @objc func touchDown() {
            didLongPress = false
            parent.onPressingChanged(true)
        }

        @objc func touchUpInside() {
            parent.onPressingChanged(false)
            guard parent.isEnabled, !didLongPress else { return }
            parent.onTap()
        }

        @objc func touchCancelled() {
            parent.onPressingChanged(false)
        }

        @objc func longPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, parent.isEnabled else { return }
            didLongPress = true
            parent.onPressingChanged(false)
            parent.onLongPress()
        }
    }
}
