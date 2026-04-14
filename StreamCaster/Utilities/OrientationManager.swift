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
// 1. The user picks their preferred orientation (auto, landscape, or portrait)
//    in Settings before starting a stream.
// 2. When the stream starts, we read that preference and tell AppDelegate
//    to lock to that orientation. In Auto mode, we lock to the current
//    device orientation at stream-start time.
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
    /// Reads the preferred orientation mode from SettingsRepository and tells
    /// AppDelegate to restrict rotation to that orientation.
    ///
    /// - Parameter settings: The settings repository that stores the
    ///   user's preferred orientation choice.
    static func lockToPreferredOrientation(settings: SettingsRepository) {
        let mode = settings.getOrientationMode()
        let mask: UIInterfaceOrientationMask

        switch mode {
        case "portrait":
            mask = .portrait
        case "landscape":
            mask = .landscape
        default:
            // Auto mode: lock to the current device orientation at stream start.
            let current = UIDevice.current.orientation
            if current.isLandscape {
                mask = .landscape
            } else {
                mask = .portrait
            }
        }

        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else {
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

    /// Returns the orientation mask for idle/preview state based on user preference.
    /// In Auto mode, returns `.all`. Otherwise returns the locked orientation.
    static func idleMask(settings: SettingsRepository) -> UIInterfaceOrientationMask {
        let mode = settings.getOrientationMode()
        switch mode {
        case "portrait":  return .portrait
        case "landscape": return .landscape
        default:          return .allButUpsideDown
        }
    }
}
