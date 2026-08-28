import SwiftUI
import UIKit

struct TrackpadView: UIViewRepresentable {
    var onMove: (Int8, Int8) -> Void
    var onTap: (Int) -> Void
    var onScroll: (Int8, Int8) -> Void
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
        view.onDragStart = onDragStart
        view.onDragEnd = onDragEnd
    }
}

final class TrackpadUIView: UIView, UIGestureRecognizerDelegate {
    var onMove: ((Int8, Int8) -> Void)?
    var onTap: ((Int) -> Void)?
    var onScroll: ((Int8, Int8) -> Void)?
    var onDragStart: (() -> Void)?
    var onDragEnd: (() -> Void)?

    private let movementSensitivity: CGFloat = 1.55
    private let scrollSensitivity: CGFloat = 0.34
    private var lastOneFingerLocation = CGPoint.zero
    private var lastTwoFingerLocation = CGPoint.zero
    private var isDragging = false

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

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        scroll.delegate = self
        addGestureRecognizer(scroll)

        // Long-press holds the left mouse button. Movement continues through
        // the normal one-finger pan recognizer, so the cursor reacts instantly.
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.28
        longPress.allowableMovement = 32
        longPress.delegate = self
        addGestureRecognizer(longPress)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            lastOneFingerLocation = gesture.location(in: self)
        case .changed:
            let location = gesture.location(in: self)
            emitMovement(from: lastOneFingerLocation, to: location)
            lastOneFingerLocation = location
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

    @objc private func handleScroll(_ gesture: UIPanGestureRecognizer) {
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

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            isDragging = true
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
