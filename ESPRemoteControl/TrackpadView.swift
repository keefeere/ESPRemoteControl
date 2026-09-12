import SwiftUI
import UIKit

enum TrackpadZoomShortcut: String, CaseIterable, Identifiable {
    case control
    case command

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .control: "Ctrl + / − (Windows/Linux)"
        case .command: "Command + / − (macOS)"
        }
    }

    func command(for step: Int) -> HIDCommand {
        let baseModifier: UInt8 = switch self {
        case .control: HID.modLeftCtrl
        case .command: HID.modLeftGUI
        }

        if step > 0 {
            return HIDCommand(
                modifiers: baseModifier | HID.modLeftShift,
                keycode: HID.keyEqual
            )
        }

        return HIDCommand(modifiers: baseModifier, keycode: HID.keyMinus)
    }
}

struct TrackpadView: UIViewRepresentable {
    var onMove: (Int8, Int8) -> Void
    var onTap: (Int) -> Void
    var onScroll: (Int8, Int8) -> Void
    var onZoom: (Int) -> Void = { _ in }
    var onDragStart: () -> Void = {}
    var onDragEnd: () -> Void = {}

    func makeUIView(context: Context) -> TrackpadUIView {
        let view = TrackpadUIView()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: TrackpadUIView, context: Context) {
        view.onMove = onMove
        view.onTap = onTap
        view.onScroll = onScroll
        view.onZoom = onZoom
        view.onDragStart = onDragStart
        view.onDragEnd = onDragEnd
    }
}

final class TrackpadUIView: UIView, UIGestureRecognizerDelegate {
    var onMove: ((Int8, Int8) -> Void)?
    var onTap: ((Int) -> Void)?
    var onScroll: ((Int8, Int8) -> Void)?
    var onZoom: ((Int) -> Void)?
    var onDragStart: (() -> Void)?
    var onDragEnd: (() -> Void)?

    private let movementSensitivity: CGFloat = 1.55
    private let scrollSensitivity: CGFloat = 0.40
    private let edgeScrollSensitivity: CGFloat = 0.40
    private let pinchActivationThreshold: CGFloat = 0.14
    private let pinchStepThreshold: CGFloat = 0.12
    private var lastOneFingerLocation = CGPoint.zero
    private var lastTwoFingerLocation = CGPoint.zero
    private var isDragging = false
    private var isPinching = false
    private var isEdgeScrolling = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        accessibilityLabel = "Remote trackpad"
        setupGestures()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.numberOfTouchesRequired = 1
        tap.delegate = self
        addGestureRecognizer(tap)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.delegate = self
        addGestureRecognizer(twoFingerTap)

        let threeFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleThreeFingerTap(_:)))
        threeFingerTap.numberOfTouchesRequired = 3
        threeFingerTap.delegate = self
        addGestureRecognizer(threeFingerTap)

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        scroll.delegate = self
        addGestureRecognizer(scroll)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        // One completed tap followed by a held second touch behaves like a
        // laptop trackpad: the second touch presses the left button and can drag.
        let tapAndDrag = UILongPressGestureRecognizer(target: self, action: #selector(handleTapAndDrag(_:)))
        tapAndDrag.numberOfTapsRequired = 1
        tapAndDrag.numberOfTouchesRequired = 1
        tapAndDrag.minimumPressDuration = 0.06
        tapAndDrag.allowableMovement = 56
        tapAndDrag.delegate = self
        addGestureRecognizer(tapAndDrag)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            let location = gesture.location(in: self)
            lastOneFingerLocation = location
            isEdgeScrolling = location.x >= bounds.maxX - rightEdgeScrollWidth
        case .changed:
            let location = gesture.location(in: self)
            if isDragging {
                isEdgeScrolling = false
                emitMovement(from: lastOneFingerLocation, to: location)
            } else if isEdgeScrolling {
                let dy = Int8(clamping: Int((lastOneFingerLocation.y - location.y) * edgeScrollSensitivity))
                if dy != 0 {
                    onScroll?(0, dy)
                }
            } else {
                emitMovement(from: lastOneFingerLocation, to: location)
            }
            lastOneFingerLocation = location
        case .ended, .cancelled, .failed:
            isEdgeScrolling = false
        default:
            break
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, !isDragging else { return }
        onTap?(1)
    }

    @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        onTap?(2)
    }

    @objc private func handleThreeFingerTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        onTap?(3)
    }

    @objc private func handleScroll(_ gesture: UIPanGestureRecognizer) {
        guard !isPinching else { return }

        switch gesture.state {
        case .began:
            lastTwoFingerLocation = gesture.location(in: self)
        case .changed:
            let location = gesture.location(in: self)
            let dx = Int8(clamping: Int((location.x - lastTwoFingerLocation.x) * scrollSensitivity))
            let dy = Int8(clamping: Int((lastTwoFingerLocation.y - location.y) * scrollSensitivity))
            if dx != 0 || dy != 0 {
                onScroll?(dx, dy)
            }
            lastTwoFingerLocation = location
        default:
            break
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            // Do not claim the two-finger gesture immediately. Small finger
            // separation changes are common during scroll and should stay scroll.
            isPinching = false
            gesture.scale = 1
        case .changed:
            let delta = gesture.scale - 1

            if !isPinching {
                guard abs(delta) >= pinchActivationThreshold else { return }
                isPinching = true
                onZoom?(delta > 0 ? 1 : -1)
                gesture.scale = 1
                return
            }

            if delta >= pinchStepThreshold {
                onZoom?(1)
                gesture.scale = 1
            } else if delta <= -pinchStepThreshold {
                onZoom?(-1)
                gesture.scale = 1
            }
        case .ended, .cancelled, .failed:
            isPinching = false
        default:
            break
        }
    }

    @objc private func handleTapAndDrag(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            isDragging = true
            isEdgeScrolling = false
            onDragStart?()
        case .ended, .cancelled, .failed:
            if isDragging {
                isDragging = false
                onDragEnd?()
            }
        default:
            break
        }
    }

    private var rightEdgeScrollWidth: CGFloat {
        max(28, min(36, bounds.width * 0.11))
    }

    private func emitMovement(from start: CGPoint, to end: CGPoint) {
        let dx = Int8(clamping: Int((end.x - start.x) * movementSensitivity))
        let dy = Int8(clamping: Int((end.y - start.y) * movementSensitivity))
        if dx != 0 || dy != 0 {
            onMove?(dx, dy)
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer.view === self && otherGestureRecognizer.view === self
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        bounds.contains(touch.location(in: self))
    }
}

private extension Int8 {
    init(clamping value: Int) {
        self = value > Int(Int8.max)
            ? Int8.max
            : value < Int(Int8.min)
                ? Int8.min
                : Int8(value)
    }
}
