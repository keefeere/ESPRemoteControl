import SwiftUI

@main
struct PressActionsTestApp: App {
    var body: some Scene {
        WindowGroup { PressActionsTestView() }
    }
}

private struct PressActionsTestView: View {
    @State private var languageTaps = 0
    @State private var languageHolds = 0
    @State private var orientationTaps = 0
    @State private var orientationHolds = 0
    @State private var controlsEnabled = true

    var body: some View {
        VStack(spacing: 32) {
            HStack(spacing: 32) {
                Button { languageTaps += 1 } label: {
                    Text(languageTaps.isMultiple(of: 2) ? "UA/EN" : "EN/UA")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .frame(width: 60, height: 36)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(ShortAndLongPressButtonStyle(
                    longPressLabel: "Layout only", onLongPress: { languageHolds += 1 }
                ))
                .accessibilityLabel("Language")
                .accessibilityIdentifier("languageButton")

                Button { orientationTaps += 1 } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.landscape")
                        Image(systemName: orientationTaps.isMultiple(of: 2) ? "lock.open" : "lock.fill")
                    }
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.16))
                    .clipShape(Capsule())
                }
                .buttonStyle(ShortAndLongPressButtonStyle(
                    longPressLabel: "Landscape", onLongPress: { orientationHolds += 1 }
                ))
                .accessibilityLabel("Orientation")
                .accessibilityIdentifier("orientationButton")
            }
            .disabled(!controlsEnabled)

            Text("\(languageTaps):\(languageHolds)").accessibilityIdentifier("languageCounts")
            Text("\(orientationTaps):\(orientationHolds)").accessibilityIdentifier("orientationCounts")
            Button("Disable controls") { controlsEnabled = false }
                .accessibilityIdentifier("disableControls")
            Text(controlsEnabled ? "enabled" : "disabled").accessibilityIdentifier("enabledState")
        }
        .padding(24)
    }
}
