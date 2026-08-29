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

@MainActor
enum AppOrientationLock {
    static func setLandscapeLocked(_ isLocked: Bool) {
        let orientations: UIInterfaceOrientationMask = isLocked ? .landscape : .all
        AppDelegate.supportedOrientations = orientations

        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else {
            return
        }

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
