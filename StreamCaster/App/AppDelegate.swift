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
    /// Change this value at runtime to lock/unlock rotation.
    /// Default: allow all orientations.
    var orientationLock: UIInterfaceOrientationMask = .all

    // MARK: - App Lifecycle

    /// Called once when the app finishes launching.
    /// Use this for one-time setup like configuring crash reporters,
    /// initializing services, or setting default preferences.
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // TODO: Initialize crash reporting (KSCrash)
        // TODO: Set up dependency container
        // TODO: Configure default settings

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
