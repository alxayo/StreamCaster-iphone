// OrientationManager.swift
// StreamCaster
//
// A simple helper that locks and unlocks screen rotation.
//
// **Why we need this:**
// During streaming, we lock the orientation so the video doesn't rotate
// mid-stream (which would require restarting the encoder and cause a
// brief interruption). The orientation is locked when streaming starts
// and unlocked when streaming stops.
//
// **How it works:**
// 1. The user picks their preferred orientation (landscape or portrait)
//    in Settings before starting a stream.
// 2. When the stream starts, we read that preference and tell AppDelegate
//    to lock to that orientation.
// 3. The lock stays in place for the ENTIRE stream — including reconnects.
// 4. When the stream fully stops (idle), we unlock so the user can
//    rotate freely again.

import UIKit

/// OrientationManager controls which screen orientations are allowed.
///
/// Usage:
/// ```swift
/// // When stream starts — lock to user's preferred orientation:
/// OrientationManager.lockToPreferredOrientation(settings: mySettingsRepo)
///
/// // When stream stops — unlock so user can rotate freely:
/// OrientationManager.unlock()
/// ```
enum OrientationManager {

    // MARK: - Public API

    /// Lock the screen to the user's preferred orientation.
    ///
    /// Reads the preferred orientation from SettingsRepository and tells
    /// AppDelegate to restrict rotation to that orientation.
    ///
    /// - Parameter settings: The settings repository that stores the
    ///   user's preferred orientation choice.
    static func lockToPreferredOrientation(settings: SettingsRepository) {
        // Read the user's preferred orientation from settings.
        // The value is an Int where:
        //   0 = portrait
        //   1 = landscape (default)
        let preferredOrientation = settings.getPreferredOrientation()

        // Convert the Int preference into a UIInterfaceOrientationMask
        // that iOS understands.
        let mask = orientationMask(from: preferredOrientation)

        // Tell AppDelegate to lock to this orientation.
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else {
            // If we can't find AppDelegate, there's nothing we can do.
            // This should never happen in a real app.
            return
        }

        appDelegate.lockOrientation(mask)
    }

    /// Unlock the screen so the user can rotate freely.
    ///
    /// Call this when the stream fully stops and returns to idle.
    static func unlock() {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else {
            return
        }

        appDelegate.unlockOrientation()
    }

    // MARK: - Helpers

    /// Convert the Int-based orientation preference from settings into
    /// a `UIInterfaceOrientationMask`.
    ///
    /// - Parameter preference: 0 = portrait, 1 = landscape.
    /// - Returns: The matching `UIInterfaceOrientationMask`.
    private static func orientationMask(
        from preference: Int
    ) -> UIInterfaceOrientationMask {
        switch preference {
        case 0:
            // Portrait: allow both portrait-up and portrait-upside-down.
            return .portrait
        case 1:
            // Landscape: allow both landscape-left and landscape-right.
            return .landscape
        default:
            // If we get an unexpected value, default to landscape
            // since most streaming is done in landscape mode.
            return .landscape
        }
    }
}
