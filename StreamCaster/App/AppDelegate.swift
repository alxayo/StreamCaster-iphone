// AppDelegate.swift
// StreamCaster
//
// Handles UIKit app lifecycle events that SwiftUI doesn't cover directly,
// such as controlling which screen orientations are allowed.

import UIKit

/// AppDelegate gives us access to UIKit lifecycle hooks.
/// We need this mainly to control screen orientation at runtime
/// (e.g., locking to landscape while streaming).
class AppDelegate: NSObject, UIApplicationDelegate {

    // MARK: - Orientation Lock

    /// Controls which orientations the app currently supports.
    /// When set to `.all`, the device rotates freely.
    /// When set to `.landscape` or `.portrait`, rotation is locked.
    ///
    /// iOS asks us for this value every time the device rotates,
    /// so changing it immediately affects rotation behavior.
    private(set) var orientationLock: UIInterfaceOrientationMask = .all

    /// Lock the screen to a specific orientation.
    ///
    /// Call this when a stream starts so the video doesn't rotate
    /// mid-stream (rotating would require restarting the encoder
    /// and would cause a brief interruption).
    ///
    /// - Parameter mask: The allowed orientations (e.g., `.landscape`
    ///   or `.portrait`). Pass `.all` to allow free rotation.
    func lockOrientation(_ mask: UIInterfaceOrientationMask) {
        orientationLock = mask

        // Tell iOS that supported orientations have changed.
        // Without this call, iOS won't check again until the next
        // physical rotation event — so the lock might not take
        // effect immediately.
        if #available(iOS 16.0, *) {
            // iOS 16+ uses the new geometry-request API on the window scene.
            guard let windowScene = UIApplication.shared
                .connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
            else { return }

            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))

            // Also tell the root view controller to re-query its
            // supported orientations.
            windowScene.windows.first?.rootViewController?
                .setNeedsUpdateOfSupportedInterfaceOrientations()
        } else {
            // On older iOS versions, calling setValue on the device
            // triggers a re-evaluation of supported orientations.
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    /// Unlock the screen so the user can rotate freely again.
    ///
    /// Call this when the stream fully stops (returns to idle).
    func unlockOrientation() {
        lockOrientation(.all)
    }

    // MARK: - App Lifecycle

    /// Called once when the app finishes launching.
    /// Use this for one-time setup like configuring crash reporters,
    /// initializing services, or setting default preferences.
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Initialize the KSCrash crash reporter so we capture any crashes
        // that happen during the session. This must be called early — before
        // other code runs — so we don't miss crashes during startup.
        CrashReportConfigurator.configure()

        // Initialize the dependency container. Accessing `.shared` triggers
        // its lazy setup, which creates all the app's shared services
        // (streaming engine, profile repository, settings, etc.).
        _ = DependencyContainer.shared

        return true
    }

    /// Called by the system to ask which orientations are allowed.
    /// We return whatever `orientationLock` is currently set to,
    /// so other parts of the app can change it dynamically.
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        return orientationLock
    }
}
