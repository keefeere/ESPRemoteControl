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
    private let scrollSensitivity: CGFloat = 0.34
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

        // One recognizer owns all 1/2/3-finger taps. Native UITapGestureRecognizer
        // instances with different touch counts can race as fingers land/lift at
        // slightly different times; that is what made 3-finger taps leak into a
        // right click. This recognizer waits for the complete touch sequence and
        // reports the maximum number of simultaneous fingers exactly once.
        let tap = FingerCountTapGestureRecognizer(target: self, action: #selector(handleFingerCountTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)

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

    @objc private func handleFingerCountTap(_ gesture: FingerCountTapGestureRecognizer) {
        guard gesture.state == .ended,
              !isPinching,
              !isDragging,
              (1...3).contains(gesture.recognizedFingerCount) else { return }
        onTap?(gesture.recognizedFingerCount)
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
        guard gestureRecognizer.view === self, otherGestureRecognizer.view === self else { return false }

        // The discrete tap recognizer stays passive until all fingers are up and
        // fails as soon as movement exceeds tap tolerance. Pan/scroll/pinch must
        // therefore be allowed to proceed independently while it is still possible.
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        bounds.contains(touch.location(in: self))
    }
}

private final class FingerCountTapGestureRecognizer: UIGestureRecognizer {
    private let maximumTapDuration: TimeInterval = 0.35
    private let maximumMovement: CGFloat = 10

    private var beganAt: TimeInterval = 0
    private var maximumConcurrentTouches = 0
    private var initialLocations: [ObjectIdentifier: CGPoint] = [:]

    private(set) var recognizedFingerCount = 0

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)

        if beganAt == 0 {
            beganAt = ProcessInfo.processInfo.systemUptime
        }

        for touch in touches {
            initialLocations[ObjectIdentifier(touch)] = touch.location(in: view)
        }

        maximumConcurrentTouches = max(maximumConcurrentTouches, activeTouchCount(in: event))
        if maximumConcurrentTouches > 3 {
            state = .failed
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard state == .possible else { return }

        for touch in touches {
            guard let origin = initialLocations[ObjectIdentifier(touch)] else { continue }
            let location = touch.location(in: view)
            if hypot(location.x - origin.x, location.y - origin.y) > maximumMovement {
                state = .failed
                return
            }
        }

        maximumConcurrentTouches = max(maximumConcurrentTouches, activeTouchCount(in: event))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard state == .possible else { return }

        maximumConcurrentTouches = max(maximumConcurrentTouches, activeTouchCount(in: event))
        guard activeTouchCount(in: event) == 0 else { return }

        let duration = ProcessInfo.processInfo.systemUptime - beganAt
        guard duration <= maximumTapDuration,
              (1...3).contains(maximumConcurrentTouches) else {
            state = .failed
            return
        }

        recognizedFingerCount = maximumConcurrentTouches
        state = .recognized
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        state = .cancelled
    }

    override func reset() {
        super.reset()
        beganAt = 0
        maximumConcurrentTouches = 0
        initialLocations.removeAll(keepingCapacity: true)
        recognizedFingerCount = 0
    }

    private func activeTouchCount(in event: UIEvent) -> Int {
        event.allTouches?.reduce(into: 0) { count, touch in
            switch touch.phase {
            case .began, .moved, .stationary:
                count += 1
            default:
                break
            }
        } ?? 0
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
