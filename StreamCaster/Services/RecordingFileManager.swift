import Foundation

// MARK: - RecordingFileManager
// ──────────────────────────────────────────────────────────────────
// Manages local recording files (MP4) in the app's Documents directory.
//
// Recordings are saved with timestamped filenames like:
//   StreamCaster_2024-01-15_14-30-00.mp4
//
// This struct is intentionally stateless — every method is `static`
// so you can call them from anywhere without needing an instance.
//
// Responsibilities:
//   • Generate unique, human-readable filenames with timestamps
//   • Create the Recordings subdirectory if it doesn't exist
//   • Check available disk space before starting a recording
//   • List all saved recordings
//   • Delete individual recordings or clear all of them
// ──────────────────────────────────────────────────────────────────

struct RecordingFileManager {

    // MARK: - Constants

    /// Minimum free disk space required to start a recording (in megabytes).
    /// 100 MB is a conservative safety margin — a 1080p stream at 4 Mbps
    /// uses roughly 30 MB per minute, so 100 MB gives about 3 minutes of
    /// buffer. We check this *before* starting to avoid running out mid-stream.
    static let defaultMinimumFreeMB = 100

    // MARK: - Directories

    /// The directory where all recordings are saved.
    ///
    /// We use a "Recordings" subdirectory inside the app's Documents folder
    /// rather than dumping files directly into Documents. This keeps things
    /// organized and makes it easy for users to find recordings in the
    /// Files app (Files → StreamCaster → Recordings).
    ///
    /// The directory is created automatically if it doesn't exist yet.
    static var recordingsDirectory: URL {
        let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!

        let recordingsURL = documentsURL.appendingPathComponent(
            "Recordings",
            isDirectory: true
        )

        // Create the directory if it doesn't exist.
        // `withIntermediateDirectories: true` means "don't fail if it already
        // exists" — it's safe to call this every time.
        if !FileManager.default.fileExists(atPath: recordingsURL.path) {
            try? FileManager.default.createDirectory(
                at: recordingsURL,
                withIntermediateDirectories: true
            )
        }

        return recordingsURL
    }

    // MARK: - Filename Generation

    /// Generate a unique file URL for a new recording.
    ///
    /// The filename includes the current date and time so users can easily
    /// identify when each recording was made:
    ///   `StreamCaster_2024-01-15_14-30-00.mp4`
    ///
    /// - Returns: A file URL inside the `recordingsDirectory` that does not
    ///   yet exist on disk.
    static func generateFilename() -> URL {
        // Create a date formatter that produces filesystem-safe strings.
        // We use underscores and hyphens instead of spaces and colons
        // because some file systems don't handle those well.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let timestamp = formatter.string(from: Date())
        let filename = "StreamCaster_\(timestamp).mp4"

        return recordingsDirectory.appendingPathComponent(filename)
    }

    // MARK: - Disk Space

    /// Check whether there is enough free disk space to safely start recording.
    ///
    /// iOS provides the `volumeAvailableCapacityForImportantUsageKey` attribute,
    /// which returns the space available for "important" files. This is a
    /// better estimate than raw free space because iOS can reclaim purgeable
    /// storage (caches, old photos) to make room.
    ///
    /// - Parameter minimumMB: The minimum free space required in megabytes.
    ///   Defaults to 100 MB.
    /// - Returns: `true` if there is at least `minimumMB` of free space,
    ///   `false` otherwise.
    static func hasEnoughDiskSpace(minimumMB: Int = defaultMinimumFreeMB) -> Bool {
        do {
            // Get the URL for the app's home directory — the volume it
            // lives on is where recordings will be written.
            let homeURL = URL(fileURLWithPath: NSHomeDirectory())

            // Ask the file system how much space is available for
            // "important" usage. This is the recommended key for
            // checking space before creating user-visible files.
            let values = try homeURL.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            )

            // The value is in bytes. Convert our minimum to bytes for comparison.
            let minimumBytes = Int64(minimumMB) * 1_000_000
            if let availableBytes = values.volumeAvailableCapacityForImportantUsage {
                return availableBytes >= minimumBytes
            }

            // If the key isn't available (shouldn't happen on iOS), be
            // optimistic and allow the recording.
            return true
        } catch {
            // If we can't query disk space, allow the recording and let
            // AVAssetWriter report an error if it actually runs out.
            print("[RecordingFileManager] Could not check disk space: \(error)")
            return true
        }
    }

    // MARK: - Listing Recordings

    /// List all saved recordings sorted by creation date (newest first).
    ///
    /// - Returns: An array of file URLs pointing to `.mp4` files in the
    ///   recordings directory. Returns an empty array if the directory
    ///   doesn't exist or can't be read.
    static func listRecordings() -> [URL] {
        let fileManager = FileManager.default
        let directory = recordingsDirectory

        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        // Filter to only .mp4 files and sort newest first.
        return contents
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return lhsDate > rhsDate
            }
    }

    // MARK: - Deleting Recordings

    /// Delete a single recording file.
    ///
    /// - Parameter url: The file URL of the recording to delete.
    /// - Returns: `true` if the file was successfully deleted, `false` otherwise.
    @discardableResult
    static func deleteRecording(at url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            print("[RecordingFileManager] Deleted recording: \(url.lastPathComponent)")
            return true
        } catch {
            print("[RecordingFileManager] Failed to delete \(url.lastPathComponent): \(error)")
            return false
        }
    }

    /// Delete ALL recordings in the recordings directory.
    ///
    /// Use with caution — this cannot be undone!
    ///
    /// - Returns: The number of files that were successfully deleted.
    @discardableResult
    static func deleteAllRecordings() -> Int {
        let recordings = listRecordings()
        var deletedCount = 0
        for url in recordings {
            if deleteRecording(at: url) {
                deletedCount += 1
            }
        }
        print("[RecordingFileManager] Deleted \(deletedCount) of \(recordings.count) recordings.")
        return deletedCount
    }
}
