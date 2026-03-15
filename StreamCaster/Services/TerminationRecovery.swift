// TerminationRecovery.swift
// StreamCaster
//
// Handles cleanup after the app is killed by iOS.
//
// WHY IS THIS NEEDED?
// Unlike Android, iOS can kill an app at ANY time without warning.
// When this happens during streaming:
//   - The RTMP connection just drops (no graceful shutdown)
//   - Local recording files may be incomplete (no moov atom)
//   - The user doesn't know their stream stopped
//
// On next launch, we need to:
//   1. Detect the unexpected termination
//   2. Show the user a message explaining what happened
//   3. Clean up any orphaned recording files
//   4. Start in idle state (NEVER auto-resume streaming)

import Foundation
import UIKit

/// TerminationRecovery detects when the app was killed mid-stream
/// and helps the user understand what happened on the next launch.
final class TerminationRecovery {

    // MARK: - UserDefaults Keys

    /// UserDefaults key to track if we were streaming when terminated.
    /// We set this to `true` when streaming starts and `false` when it
    /// stops cleanly. If it's still `true` on the next launch, we know
    /// the app was killed while streaming.
    private static let wasStreamingKey = "app.wasStreaming"

    // MARK: - Streaming State Markers

    /// Mark that streaming has started.
    /// Call this when the stream goes live so we can detect if the app
    /// is killed before the stream stops cleanly.
    static func markStreamingStarted() {
        UserDefaults.standard.set(true, forKey: wasStreamingKey)

        // Force the write to disk immediately. Normally UserDefaults
        // batches writes, but if the app is about to be killed, we
        // need this persisted RIGHT NOW.
        UserDefaults.standard.synchronize()
    }

    /// Mark that streaming has stopped cleanly.
    /// Call this when the user taps "Stop" or the stream ends normally.
    /// This clears the flag so the next launch won't think we crashed.
    static func markStreamingStopped() {
        UserDefaults.standard.set(false, forKey: wasStreamingKey)
        UserDefaults.standard.synchronize()
    }

    /// Check if the previous session ended unexpectedly.
    /// Returns `true` if the last launch was streaming when the app
    /// was killed (the flag was never cleared).
    static func didTerminateUnexpectedly() -> Bool {
        return UserDefaults.standard.bool(forKey: wasStreamingKey)
    }

    // MARK: - Orphaned Recordings

    /// File extensions we look for when searching for orphaned recordings.
    /// These are the formats that AVAssetWriter produces.
    private static let recordingExtensions: Set<String> = ["mov", "mp4", "tmp"]

    /// Find orphaned recording files in the app's Documents directory.
    ///
    /// "Orphaned" means files left behind from a previous session that
    /// wasn't finalized properly. These files are usually incomplete —
    /// they might be missing the "moov atom" (a table of contents that
    /// video players need to read the file).
    ///
    /// We look for .mov, .mp4, and .tmp files that were modified more
    /// than 5 minutes ago (to avoid catching an active recording).
    static func findOrphanedRecordings() -> [URL] {
        // Get the app's Documents directory. This is where we save
        // local recordings.
        guard let documentsDir = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            return []
        }

        // Try to list all files in the Documents directory.
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: documentsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else {
            return []
        }

        // The cutoff time: only consider files older than 5 minutes.
        // Files newer than this might belong to an active recording
        // session that just started.
        let cutoffDate = Date().addingTimeInterval(-5 * 60)

        // Filter to just recording files that are old enough to be orphaned.
        let orphaned = files.filter { url in
            // Check if the file extension matches our recording formats.
            let ext = url.pathExtension.lowercased()
            guard recordingExtensions.contains(ext) else { return false }

            // Check the modification date. If the file was modified
            // recently, it might still be in use.
            guard let resourceValues = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ),
            let modDate = resourceValues.contentModificationDate else {
                // If we can't read the date, assume it's orphaned.
                return true
            }

            // Only include files older than the cutoff.
            return modDate < cutoffDate
        }

        return orphaned
    }

    /// Delete orphaned recording files from disk.
    ///
    /// - Parameter urls: The file URLs to delete (from `findOrphanedRecordings`).
    ///
    /// We silently skip any files that can't be deleted — this shouldn't
    /// block the user from using the app.
    static func deleteOrphanedRecordings(_ urls: [URL]) {
        for url in urls {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                // Log the error but don't crash. The user can always
                // delete these files manually from the Files app.
                print("[TerminationRecovery] Failed to delete \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Full Recovery Check

    /// Perform a full recovery check on app launch.
    ///
    /// This is the main entry point — call it once in `StreamCasterApp`
    /// when the app starts. It:
    ///   1. Checks if we were streaming when the app was killed
    ///   2. Looks for orphaned recording files
    ///   3. Clears the "was streaming" flag so future launches are clean
    ///   4. Returns a result describing what happened
    static func performRecoveryCheck() -> RecoveryResult {
        // Step 1: Was the app killed while streaming?
        let wasStreaming = didTerminateUnexpectedly()

        // Step 2: Are there leftover recording files?
        let orphanedFiles = findOrphanedRecordings()

        // Step 3: Clear the flag. We've captured the info we need,
        // and we don't want this to trigger again on the next launch.
        markStreamingStopped()

        // Step 4: Package the results.
        return RecoveryResult(
            wasUnexpectedlyTerminated: wasStreaming,
            orphanedRecordings: orphanedFiles
        )
    }

    // MARK: - RecoveryResult

    /// The result of a recovery check, describing what happened
    /// during the previous app session.
    struct RecoveryResult {

        /// `true` if the app was killed by iOS while streaming.
        let wasUnexpectedlyTerminated: Bool

        /// Any recording files left behind from the previous session.
        let orphanedRecordings: [URL]

        /// `true` if we need to show the user a message about what happened.
        /// Either the app was terminated unexpectedly, or there are orphaned
        /// files to clean up (or both).
        var needsUserAttention: Bool {
            wasUnexpectedlyTerminated || !orphanedRecordings.isEmpty
        }
    }
}
