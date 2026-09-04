//
//  ESPRemoteControlApp.swift
//  ESPRemoteControl
//
//  Created by Ruben Kostandyan on 14/12/2025.
//

import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var supportedOrientations: UIInterfaceOrientationMask = .all

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.supportedOrientations
    }
}

enum KeyboardOrientationLock: String {
    case unlocked, portrait, portraitUpsideDown, landscapeLeft, landscapeRight, landscape

    var isLocked: Bool { self != .unlocked }
    var isPortrait: Bool { self == .portrait || self == .portraitUpsideDown }

    var orientations: UIInterfaceOrientationMask {
        switch self {
        case .unlocked: return .all
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .landscape: return .landscape
        }
    }
}

@MainActor
enum AppOrientationLock {
    private static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }

    static var current: KeyboardOrientationLock {
        // Use the displayed orientation, including when the phone is face up.
        switch activeScene?.interfaceOrientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return .portrait
        }
    }

    static func apply(_ lock: KeyboardOrientationLock) {
        let orientations = lock.orientations
        AppDelegate.supportedOrientations = orientations

        guard let windowScene = activeScene else { return }

        windowScene.keyWindow?
            .rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()

        windowScene.requestGeometryUpdate(
            .iOS(interfaceOrientations: orientations)
        ) { error in
            print("Unable to update interface orientation: \(error.localizedDescription)")
        }
    }
}

@main
struct ESPRemoteControlApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
