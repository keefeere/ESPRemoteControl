# Background Mouse Jiggler feasibility

## Current behavior

The Mouse Jiggler intentionally runs only while the app is active. `ContentView`
turns it off when the scene enters the background, and the periodic task checks
for an active scene before every mouse movement.

## iOS 17–25

A reliable periodic background jiggler is not available through supported iOS
APIs:

- UIKit normally suspends an app shortly after it enters the background.
- A finite `beginBackgroundTask` assertion is for completing existing work; it
  is not an indefinite runtime entitlement.
- The declared `bluetooth-central` and `bluetooth-peripheral` modes allow iOS to
  wake the app for relevant Core Bluetooth delegate events. They do not keep a
  Swift concurrency timer running continuously.
- Background processing tasks are scheduled at the system's discretion and
  cannot provide the sub-minute, user-selected intervals required by the
  jiggler.
- Audio, location, or other unrelated background modes must not be used merely
  to keep the process alive.

Consequently, removing the foreground checks would make the feature appear to
work briefly and then stop as soon as iOS suspends the process. The current
foreground-only behavior is the honest and deterministic option.

## iOS 26 investigation path

Apple documents an iOS 26 Core Bluetooth path where an app with an instantiated
`CBManager` and an active Live Activity can retain foreground-style Bluetooth
privileges while in the background. This is not yet sufficient evidence that a
periodic HID notification remains reliable for the duration of a jiggler
session.

A future prototype should:

1. Present a genuine, user-visible Live Activity for an explicitly started
   jiggler session, including its interval and stop control.
2. Keep the existing foreground implementation as the fallback on iOS 17–25.
3. Measure timer execution and HID notification delivery with the screen locked,
   after several minutes, under Low Power Mode, and after memory pressure.
4. Test both direct HID peripheral mode and the ESP32 central connection.
5. Stop immediately when the user ends the Live Activity, the HID route is lost,
   or iOS expires the activity.
6. Avoid claiming background support until those device tests pass.

## References

- [Core Bluetooth](https://developer.apple.com/documentation/corebluetooth)
- [Core Bluetooth Background Processing for iOS Apps](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)
- [Extending your app's background execution time](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)
- [Configuring background execution modes](https://developer.apple.com/documentation/xcode/configuring-background-execution-modes)
