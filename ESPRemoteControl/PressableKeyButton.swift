import SwiftUI
import UIKit

struct PressableKeyButton: UIViewRepresentable {
    let title: String
    var isActive: Bool = false
    var isProminent: Bool = false
    var isCompact: Bool = false
    var fontSize: CGFloat? = nil
    var minHeight: CGFloat = 44

    var onPress: () -> Void
    var onRelease: () -> Void

    func makeUIView(context: Context) -> KeyUIButton {
        let button = KeyUIButton(type: .custom)
        button.addTarget(context.coordinator, action: #selector(Coordinator.touchDown), for: .touchDown)
        button.addTarget(context.coordinator, action: #selector(Coordinator.touchUp), for: .touchUpInside)
        button.addTarget(context.coordinator, action: #selector(Coordinator.touchUp), for: .touchUpOutside)
        button.addTarget(context.coordinator, action: #selector(Coordinator.touchUp), for: .touchCancel)
        button.addTarget(context.coordinator, action: #selector(Coordinator.touchUp), for: .touchDragExit)

        button.baseTitle = title
        button.isActive = isActive
        button.isProminent = isProminent
        button.isCompact = isCompact
        button.fontSize = fontSize
        button.minHeight = minHeight
        button.applyConfiguration()

        return button
    }

    func updateUIView(_ uiView: KeyUIButton, context: Context) {
        uiView.baseTitle = title
        uiView.isActive = isActive
        uiView.isProminent = isProminent
        uiView.isCompact = isCompact
        uiView.fontSize = fontSize
        uiView.minHeight = minHeight
        uiView.applyConfiguration()
        context.coordinator.update(onPress: onPress, onRelease: onRelease)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPress: onPress, onRelease: onRelease)
    }

    final class Coordinator: NSObject {
        private var onPress: () -> Void
        private var onRelease: () -> Void
        private var isDown: Bool = false

        init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
            self.onPress = onPress
            self.onRelease = onRelease
        }

        func update(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
            self.onPress = onPress
            self.onRelease = onRelease
        }

        @objc func touchDown() {
            guard !isDown else { return }
            isDown = true
            onPress()
        }

        @objc func touchUp() {
            guard isDown else { return }
            isDown = false
            onRelease()
        }
    }
}

final class KeyUIButton: UIButton {
    var baseTitle: String = "" {
        didSet {
            if baseTitle != oldValue {
                applyConfiguration()
            }
        }
    }
    var isActive: Bool = false {
        didSet {
            if isActive != oldValue {
                applyConfiguration()
            }
        }
    }
    var isProminent: Bool = false {
        didSet {
            if isProminent != oldValue {
                applyConfiguration()
            }
        }
    }
    var isCompact: Bool = false {
        didSet {
            if isCompact != oldValue {
                applyConfiguration()
            }
        }
    }
    var fontSize: CGFloat? {
        didSet {
            if fontSize != oldValue {
                applyConfiguration()
            }
        }
    }
    var minHeight: CGFloat = 44 {
        didSet {
            if minHeight != oldValue {
                heightConstraint?.constant = minHeight
            }
        }
    }

    private var heightConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Separate keys must be able to receive simultaneous fingers for
        // hardware-like chords (for example Ctrl+Alt+Delete).
        isExclusiveTouch = false
        
        // Set static properties once
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        clipsToBounds = true
        
        // Create height constraint once
        heightConstraint = heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight)
        heightConstraint?.isActive = true

        configurationUpdateHandler = { [weak self] _ in
            self?.applyConfiguration()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyConfiguration() {
        var config = UIButton.Configuration.filled()
        config.cornerStyle = isCompact ? .small : .medium
        config.title = baseTitle
        config.contentInsets = isCompact
            ? NSDirectionalEdgeInsets(top: 2, leading: 3, bottom: 2, trailing: 3)
            : NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { [weak self] incoming in
            var outgoing = incoming
            outgoing.font = UIFont.monospacedSystemFont(
                ofSize: self?.fontSize ?? (self?.isCompact == true ? 10 : 16),
                weight: .semibold
            )
            return outgoing
        }

        let pressed = isHighlighted
        let active = isActive

        let bg: UIColor
        if isProminent {
            bg = pressed ? UIColor.systemRed.withAlphaComponent(0.75) : UIColor.systemRed
            config.baseForegroundColor = .white
        } else if active {
            bg = pressed ? UIColor.systemBlue.withAlphaComponent(0.65) : UIColor.systemBlue.withAlphaComponent(0.9)
            config.baseForegroundColor = .white
        } else {
            bg = pressed ? UIColor.secondarySystemFill : UIColor.tertiarySystemFill
            config.baseForegroundColor = .label
        }

        config.baseBackgroundColor = bg
        configuration = config
    }
}
