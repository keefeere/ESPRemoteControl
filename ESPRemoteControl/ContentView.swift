//
//  ContentView.swift
//  ESPRemoteControl
//
//  Created by Ruben Kostandyan on 14/12/2025.
//

import SwiftUI

/// BLE + typing UI + mouse trackpad glued together.
struct ContentView: View {
    @StateObject private var ble = BLEKeyboardBridge()

    // The actual text content (used for diffing)
    @State private var inputText: String = ""

    // Auto-focus the field on launch.
    @State private var wantsFocus: Bool = true

    @State private var pageSelection: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            // Header (fixed at top)
            headerView

            // Paged content area
            TabView(selection: $pageSelection) {
                keyboardAndMousePage
                    .tag(0)

                controlPadPage
                    .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
        }
        .onChange(of: pageSelection) { _, newValue in
            // Close keyboard on page 2; re-open on page 1.
            wantsFocus = (newValue == 0)
        }
        .onAppear {
            ble.start()
        }
    }

    private var headerView: some View {
        VStack(spacing: 6) {
            Text("Wireless Input Bridge")
                .font(.headline)

            Text(ble.statusText)
                .font(.subheadline)
                .foregroundStyle(ble.isReady ? .green : .secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var keyboardAndMousePage: some View {
        VStack(spacing: 20) {
            // Keyboard input section
            VStack(alignment: .leading, spacing: 8) {
                Text("Keyboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                KeyCaptureTextField(
                    text: $inputText,
                    wantsFirstResponder: $wantsFocus,
                    onTextChange: handleTextChange,
                    onReturn: handleReturnKey,
                    onBackspaceWhenEmpty: handleBackspaceWhenEmpty
                )
                .frame(height: 52)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(.separator), lineWidth: 0.5)
                )
            }
            .padding(.horizontal)

            // Mouse trackpad section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Trackpad")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Tap to click • Two-finger tap for right-click")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 4)

                TrackpadView(
                    onMove: { dx, dy in
                        ble.sendMouseMove(dx: dx, dy: dy)
                    },
                    onTap: { fingerCount in
                        if fingerCount == 1 {
                            ble.sendMouseClick(button: 1) // Left click
                        } else if fingerCount >= 2 {
                            ble.sendMouseClick(button: 2) // Right click
                        }
                    },
                    onScroll: { dx, dy in
                        ble.sendMouseScroll(dx: dx, dy: dy)
                    },
                    onDragStart: {
                        ble.sendMouseButtonDown(button: 1) // Left mouse button down
                    },
                    onDragEnd: {
                        ble.sendMouseButtonUp(button: 1) // Left mouse button up
                    }
                )
                .frame(height: 220)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(.separator), lineWidth: 0.5)
                )
            }
            .padding(.horizontal)

            // Mouse buttons
            HStack(spacing: 16) {
                PressableKeyButton(
                    title: "Left Click",
                    minHeight: 48,
                    onPress: { ble.sendMouseButtonDown(button: 1) },
                    onRelease: { ble.sendMouseButtonUp(button: 1) }
                )
                .frame(maxWidth: .infinity)

                PressableKeyButton(
                    title: "Right Click",
                    minHeight: 48,
                    onPress: { ble.sendMouseButtonDown(button: 2) },
                    onRelease: { ble.sendMouseButtonUp(button: 2) }
                )
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal)

            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    private var controlPadPage: some View {
        ScrollView {
            ControlPadPage(ble: ble)
                .padding(.top, 12)
                .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    private func handleReturnKey() {
        ble.sendKeyTap(modifiers: 0x00, hidKeycode: HID.keyEnter)
        // Don't clear the field - let user continue typing or clear manually
        // Clearing would trigger the diff logic and send unwanted backspaces
    }

    private func handleBackspaceWhenEmpty() {
        // Send backspace even when field is empty (useful for deleting on remote)
        ble.sendKeyTap(modifiers: 0x00, hidKeycode: HID.keyBackspace)
    }

    /// Process text changes by computing the diff and sending appropriate HID commands.
    private func handleTextChange(oldText: String, newText: String) {
        // Handle newlines (shouldn't normally happen in single-line field, but just in case)
        if newText.contains("\n") || newText.contains("\r") {
            handleReturnKey()
            return
        }
        
        // Find common prefix length
        let commonPrefixLength = zip(oldText, newText).prefix(while: { $0 == $1 }).count
        
        // Characters deleted from old text (after common prefix)
        let deletedCount = oldText.count - commonPrefixLength
        
        // Characters inserted in new text (after common prefix)
        let insertedChars = newText.dropFirst(commonPrefixLength)
        
        var taps: [(modifiers: UInt8, keycode: UInt8)] = []
        taps.reserveCapacity(deletedCount + insertedChars.count)

        // Backspaces for deleted characters
        if deletedCount > 0 {
            for _ in 0..<deletedCount {
                taps.append((modifiers: 0x00, keycode: HID.keyBackspace))
            }
        }

        // Key taps for inserted characters
        for ch in insertedChars {
            if let cmd = HID.mapCharacterToHID(ch) {
                taps.append((modifiers: cmd.modifiers, keycode: cmd.keycode))
            }
            // Characters without HID mapping (emoji, non-latin, etc.) are silently skipped
        }

        if !taps.isEmpty {
            ble.sendKeyTaps(taps)
        }
    }
}

// MARK: - Trackpad View

/// A touch-sensitive area that simulates a trackpad for mouse control.
struct TrackpadView: UIViewRepresentable {
    var onMove: (Int8, Int8) -> Void
    var onTap: (Int) -> Void
    var onScroll: (Int8, Int8) -> Void
    var onDragStart: () -> Void = {}
    var onDragEnd: () -> Void = {}

    func makeUIView(context: Context) -> TrackpadUIView {
        let view = TrackpadUIView()
        view.onMove = onMove
        view.onTap = onTap
        view.onScroll = onScroll
        view.onDragStart = onDragStart
        view.onDragEnd = onDragEnd
        return view
    }

    func updateUIView(_ uiView: TrackpadUIView, context: Context) {
        uiView.onMove = onMove
        uiView.onTap = onTap
        uiView.onScroll = onScroll
        uiView.onDragStart = onDragStart
        uiView.onDragEnd = onDragEnd
    }
}

final class TrackpadUIView: UIView, UIGestureRecognizerDelegate {
    var onMove: ((Int8, Int8) -> Void)?
    var onTap: ((Int) -> Void)?
    var onScroll: ((Int8, Int8) -> Void)?
    var onDragStart: (() -> Void)?
    var onDragEnd: (() -> Void)?

    // Sensitivity multiplier for mouse movement
    private let sensitivity: CGFloat = 1.5
    // Scroll sensitivity (lower = more sensitive)
    private let scrollSensitivity: CGFloat = 0.3

    private var panGesture: UIPanGestureRecognizer!
    private var tapGesture: UITapGestureRecognizer!
    private var twoFingerTapGesture: UITapGestureRecognizer!
    private var twoFingerPanGesture: UIPanGestureRecognizer!
    private var longPressGesture: UILongPressGestureRecognizer!

    private var lastPanLocation: CGPoint = .zero
    private var isDragging: Bool = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        setupGestures()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupGestures() {
        // Long press for drag initiation (must be added first so it can be required to fail by tap)
        longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        longPressGesture.minimumPressDuration = 0.25
        longPressGesture.delegate = self
        addGestureRecognizer(longPressGesture)

        // Single finger pan for mouse movement
        panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        panGesture.maximumNumberOfTouches = 1
        panGesture.delegate = self
        panGesture.require(toFail: longPressGesture) // Don't start pan if long press might happen
        addGestureRecognizer(panGesture)

        // Single tap for left click
        tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tapGesture.numberOfTapsRequired = 1
        tapGesture.numberOfTouchesRequired = 1
        tapGesture.delegate = self
        addGestureRecognizer(tapGesture)

        // Two finger tap for right click
        twoFingerTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap))
        twoFingerTapGesture.numberOfTapsRequired = 1
        twoFingerTapGesture.numberOfTouchesRequired = 2
        twoFingerTapGesture.delegate = self
        addGestureRecognizer(twoFingerTapGesture)

        // Two finger pan for scrolling
        twoFingerPanGesture = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan))
        twoFingerPanGesture.minimumNumberOfTouches = 2
        twoFingerPanGesture.maximumNumberOfTouches = 2
        twoFingerPanGesture.delegate = self
        addGestureRecognizer(twoFingerPanGesture)
    }

    // MARK: - Gesture Handlers

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            lastPanLocation = gesture.location(in: self)
        case .changed:
            let location = gesture.location(in: self)
            let deltaX = location.x - lastPanLocation.x
            let deltaY = location.y - lastPanLocation.y

            let clampedX = Int8(clamping: Int(deltaX * sensitivity))
            let clampedY = Int8(clamping: Int(deltaY * sensitivity))

            if clampedX != 0 || clampedY != 0 {
                onMove?(clampedX, clampedY)
            }
            lastPanLocation = location
        default:
            break
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        if gesture.state == .ended {
            onTap?(1)
        }
    }

    @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        if gesture.state == .ended {
            onTap?(2)
        }
    }

    @objc private func handleTwoFingerPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            lastPanLocation = gesture.location(in: self)
        case .changed:
            let location = gesture.location(in: self)
            let deltaX = location.x - lastPanLocation.x
            let deltaY = location.y - lastPanLocation.y

            let scrollX = Int8(clamping: Int(deltaX * scrollSensitivity))
            let scrollY = Int8(clamping: Int(-deltaY * scrollSensitivity)) // Invert for natural scrolling

            if scrollX != 0 || scrollY != 0 {
                onScroll?(scrollX, scrollY)
            }
            lastPanLocation = location
        default:
            break
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            isDragging = true
            lastPanLocation = gesture.location(in: self)
            onDragStart?()
        case .changed:
            let location = gesture.location(in: self)
            let deltaX = location.x - lastPanLocation.x
            let deltaY = location.y - lastPanLocation.y

            let clampedX = Int8(clamping: Int(deltaX * sensitivity))
            let clampedY = Int8(clamping: Int(deltaY * sensitivity))

            if clampedX != 0 || clampedY != 0 {
                onMove?(clampedX, clampedY)
            }
            lastPanLocation = location
        case .ended, .cancelled:
            if isDragging {
                onDragEnd?()
                isDragging = false
            }
        default:
            break
        }
    }

    // MARK: - UIGestureRecognizerDelegate

    // This is key: our gestures should be required to fail before parent gestures (like TabView's scroll) can begin
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // If the other recognizer is not one of ours, require our gesture to fail first
        if otherGestureRecognizer.view !== self {
            return true
        }
        return false
    }

    // Allow our tap gestures to work alongside pan (so you can tap without waiting for pan to fail)
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Allow simultaneous recognition only between our own gestures
        return otherGestureRecognizer.view === self
    }

    // Ensure our gestures always begin when touch is in our bounds
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        return bounds.contains(touch.location(in: self))
    }
}

// Helper for clamping Int to Int8 range
private extension Int8 {
    init(clamping value: Int) {
        if value > Int(Int8.max) {
            self = Int8.max
        } else if value < Int(Int8.min) {
            self = Int8.min
        } else {
            self = Int8(value)
        }
    }
}

#Preview {
    ContentView()
}
