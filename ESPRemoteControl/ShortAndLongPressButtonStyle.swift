import SwiftUI

/// One gesture owns both actions, so completing a hold cannot also trigger a tap.
struct ShortAndLongPressButtonStyle: PrimitiveButtonStyle {
    let longPressLabel: String
    let onLongPress: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @GestureState private var isPressed = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (isPressed ? 0.65 : 1) : 0.4)
            .gesture(
                LongPressGesture(minimumDuration: 0.5, maximumDistance: 10)
                    .exclusively(before: TapGesture())
                    .updating($isPressed) { value, pressed, _ in
                        if case .first(let holding) = value { pressed = holding }
                    }
                    .onEnded { value in
                        guard isEnabled else { return }
                        switch value {
                        case .first(let completed):
                            if completed { onLongPress() }
                        case .second:
                            configuration.trigger()
                        }
                    }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                if isEnabled { configuration.trigger() }
            }
            .accessibilityAction(named: Text(longPressLabel)) {
                if isEnabled { onLongPress() }
            }
    }
}
