import Foundation

// MARK: - AbrLadder

/// AbrLadder defines the quality steps that the ABR system can use.
///
/// WHAT IS AN ABR LADDER?
/// Think of it as a staircase of quality levels. When network conditions
/// are good, we use a high step (great quality). When the network gets
/// slow, we step down to lower quality to avoid buffering/stuttering.
///
/// The ladder is device-specific — older devices have fewer steps
/// because they can't handle the higher quality levels.
///
/// STEP-DOWN ORDER (prefer least-disruptive changes first):
/// 1. First, reduce BITRATE only (no encoder restart needed — instant!)
/// 2. If bitrate reduction isn't enough, reduce RESOLUTION
/// 3. As last resort, reduce FRAME RATE
struct AbrLadder {

    // MARK: - Step

    /// A single quality step in the ladder.
    /// Each step is a combination of resolution, frame rate, and bitrate.
    /// Example: 1280×720 @ 30fps at 2500 kbps.
    struct Step: Equatable {
        /// The video resolution for this step (e.g., 1280×720).
        let resolution: Resolution

        /// Frames per second for this step (e.g., 30).
        let fps: Int

        /// Video bitrate in kilobits per second (e.g., 2500).
        let bitrateKbps: Int

        /// Human-readable description, handy for logging.
        /// Example output: "1280x720@30fps 2500kbps"
        var description: String {
            "\(resolution.description)@\(fps)fps \(bitrateKbps)kbps"
        }
    }

    // MARK: - Properties

    /// All available steps, ordered from highest to lowest quality.
    /// Index 0 is the best quality; the last index is the worst.
    let steps: [Step]

    /// The index of the step we're currently using.
    /// Starts at 0 (best quality) and increases as we step down.
    private(set) var currentIndex: Int = 0

    // MARK: - Computed Properties

    /// The quality step we're currently on.
    var currentStep: Step { steps[currentIndex] }

    /// Can we step down to an even lower quality?
    /// Returns `false` when we're already at the bottom of the ladder.
    var canStepDown: Bool { currentIndex < steps.count - 1 }

    /// Can we step up to a higher quality?
    /// Returns `false` when we're already at the top of the ladder.
    var canStepUp: Bool { currentIndex > 0 }

    // MARK: - Mutations

    /// Move one step down the ladder (lower quality).
    /// Returns the new step, or `nil` if we're already at the bottom.
    mutating func stepDown() -> Step? {
        guard canStepDown else { return nil }
        currentIndex += 1
        return steps[currentIndex]
    }

    /// Move one step up the ladder (higher quality).
    /// Returns the new step, or `nil` if we're already at the top.
    mutating func stepUp() -> Step? {
        guard canStepUp else { return nil }
        currentIndex -= 1
        return steps[currentIndex]
    }

    /// Jump back to the top of the ladder (best quality).
    /// Called when starting a new streaming session.
    mutating func reset() {
        currentIndex = 0
    }

    // MARK: - Ladder Builder

    /// Standard streaming resolutions from highest to lowest.
    /// These are the candidate step-down resolutions the ABR system considers.
    /// Bitrates are NOT stored here — they come from `recommendedBitrate(for:codec:)`
    /// so each codec gets its own optimized target.
    private static let resolutionPresets: [Resolution] = [
        Resolution(width: 1920, height: 1080),  // 1080p Full HD
        Resolution(width: 1280, height: 720),   // 720p  HD
        Resolution(width: 960,  height: 540),   // 540p  qHD
        Resolution(width: 854,  height: 480),   // 480p  SD
    ]

    /// The lowest bitrate (in kbps) we'll include in the ladder.
    /// Anything below this produces unwatchable video.
    private static let minimumBitrateKbps = 200

    /// Returns the recommended bitrate (kbps) for a given resolution and codec.
    ///
    /// WHY DIFFERENT CODECS NEED DIFFERENT BITRATES:
    /// Modern codecs compress video more efficiently. At the same bitrate,
    /// H.265 looks ~40% better than H.264, and AV1 looks ~50% better.
    /// Flipping that around: to achieve the *same* visual quality,
    ///   • H.265 needs ~35% LESS bitrate than H.264
    ///   • AV1  needs ~45% LESS bitrate than H.264
    /// This means we can save significant bandwidth on newer codecs
    /// without any visible quality loss for the viewer.
    ///
    /// HOW IT WORKS:
    /// We calculate the total pixel count (width × height) and pick the
    /// matching bitrate tier. This handles non-standard resolutions gracefully
    /// — e.g., 1600×900 falls in the "≥ 1280×720" bucket.
    ///
    /// These values match the Android app's AbrLadder.kt to keep
    /// cross-platform behavior consistent.
    ///
    /// - Parameters:
    ///   - resolution: The video resolution to get a bitrate for.
    ///   - codec: The video codec being used (affects efficiency).
    /// - Returns: Recommended bitrate in kilobits per second.
    private static func recommendedBitrate(for resolution: Resolution, codec: VideoCodec) -> Int {
        let pixels = resolution.width * resolution.height

        switch codec {
        case .h264:
            // H.264 baseline bitrates (universal compatibility).
            // These are the highest because H.264 is the least efficient codec.
            if pixels >= 1920 * 1080 { return 4500 }  // 1080p
            if pixels >= 1280 * 720  { return 2500 }  // 720p
            if pixels >= 960 * 540   { return 1500 }  // 540p
            if pixels >= 854 * 480   { return 1000 }  // 480p
            return 500                                  // 360p and below

        case .h265:
            // H.265 (HEVC) needs ~35% less bitrate for equivalent quality.
            // Example: 1080p drops from 4500 kbps (H.264) to 3000 kbps.
            if pixels >= 1920 * 1080 { return 3000 }
            if pixels >= 1280 * 720  { return 1700 }
            if pixels >= 960 * 540   { return 1000 }
            if pixels >= 854 * 480   { return 800 }
            return 350

        case .av1:
            // AV1 needs ~45% less bitrate for equivalent quality.
            // Example: 1080p drops from 4500 kbps (H.264) to 2500 kbps.
            // Note: AV1 encoding requires A17 Pro chip (iPhone 15 Pro+).
            if pixels >= 1920 * 1080 { return 2500 }
            if pixels >= 1280 * 720  { return 1400 }
            if pixels >= 960 * 540   { return 850 }
            if pixels >= 854 * 480   { return 650 }
            return 275
        }
    }

    /// Build a quality ladder based on the user's starting config,
    /// the device's hardware tier, and the selected video codec.
    ///
    /// HOW IT WORKS:
    /// 1. Start from the user's chosen resolution and bitrate.
    /// 2. At that resolution, add sub-steps at 75% and 50% bitrate
    ///    (these are instant changes — no encoder restart needed).
    /// 3. Drop to the next lower resolution and repeat, using the
    ///    codec-specific recommended bitrate for each resolution.
    /// 4. At the very bottom, add frame-rate reduction steps (last resort).
    ///
    /// WHY CODEC MATTERS:
    /// Each codec has different compression efficiency. H.265 and AV1
    /// achieve the same visual quality at lower bitrates than H.264.
    /// By passing the codec, the ladder sets lower bitrate targets for
    /// more efficient codecs — saving bandwidth without losing quality.
    ///
    /// On Tier 1 devices (older iPhones), we cap at 720p because
    /// their hardware can't sustain higher resolutions while streaming.
    ///
    /// - Parameters:
    ///   - startingConfig: The user's chosen stream settings.
    ///   - deviceTier: 1 = old/slow, 2 = mid-range, 3 = flagship.
    ///   - codec: The video codec being used. Defaults to `.h264` for
    ///     backward compatibility with callers that don't specify a codec.
    /// - Returns: A fully built `AbrLadder` ready to use.
    static func buildLadder(
        startingConfig: StreamConfig,
        deviceTier: Int,
        codec: VideoCodec = .h264
    ) -> AbrLadder {
        var steps: [Step] = []

        // Figure out the maximum pixel count we'll allow.
        // On Tier 1 (old) devices, never go above 720p.
        let startingPixels = startingConfig.resolution.width * startingConfig.resolution.height
        let tier1MaxPixels = 1280 * 720  // 720p
        let maxPixels = (deviceTier <= 1) ? min(startingPixels, tier1MaxPixels) : startingPixels

        // Filter the preset list: only keep resolutions at or below our max.
        let availableResolutions = resolutionPresets.filter {
            $0.width * $0.height <= maxPixels
        }

        // Track the previous step's bitrate so each new step never
        // increases bandwidth. This ensures stepping down always
        // reduces (or maintains) the data we're sending.
        var previousBitrate = Int.max

        for (index, resolution) in availableResolutions.enumerated() {
            // --- Determine the base bitrate for this resolution ---
            // Use the codec-specific recommended bitrate so that more
            // efficient codecs (H.265, AV1) get lower targets automatically.
            let baseBitrate: Int
            if index == 0 {
                // First (highest) resolution: use the user's chosen bitrate
                baseBitrate = min(startingConfig.videoBitrateKbps, previousBitrate)
            } else {
                // Lower resolutions: use the codec-aware recommended bitrate,
                // but cap it so we never step UP in bandwidth
                let recommended = recommendedBitrate(for: resolution, codec: codec)
                baseBitrate = min(recommended, previousBitrate)
            }

            // --- Determine the frame rate ---
            // Keep the user's fps for the starting resolution.
            // For lower resolutions, cap at 30 fps (60fps at 480p is wasteful).
            let fps: Int
            if index == 0 {
                fps = startingConfig.fps
            } else {
                fps = min(startingConfig.fps, 30)
            }

            // --- Add bitrate sub-steps: 100%, 75%, 50% ---
            // These give us fine-grained control before dropping resolution.
            let percentages = [100, 75, 50]
            for percent in percentages {
                let bitrate = baseBitrate * percent / 100

                // Skip steps that produce unwatchably low bitrate
                guard bitrate >= minimumBitrateKbps else { continue }

                steps.append(Step(
                    resolution: resolution,
                    fps: fps,
                    bitrateKbps: bitrate
                ))
                previousBitrate = bitrate
            }
        }

        // --- Add frame-rate reduction steps (last resort) ---
        // These go at the very bottom of the ladder. Dropping FPS is
        // very noticeable to viewers, so we only do it when everything
        // else has been exhausted.
        if let lastStep = steps.last {
            let lowerFpsOptions = [24, 15].filter { $0 < lastStep.fps }
            for fps in lowerFpsOptions {
                steps.append(Step(
                    resolution: lastStep.resolution,
                    fps: fps,
                    bitrateKbps: lastStep.bitrateKbps
                ))
            }
        }

        // --- Safety net ---
        // If the ladder ended up empty (shouldn't happen, but just in case),
        // create a single step from the starting config.
        if steps.isEmpty {
            steps = [Step(
                resolution: startingConfig.resolution,
                fps: startingConfig.fps,
                bitrateKbps: startingConfig.videoBitrateKbps
            )]
        }

        return AbrLadder(steps: steps)
    }
}
