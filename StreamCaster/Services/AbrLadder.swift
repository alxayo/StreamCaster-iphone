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

    /// Standard streaming resolutions from highest to lowest,
    /// paired with their recommended bitrates (in kbps).
    /// These bitrate values produce good-looking video at each size.
    private static let resolutionPresets: [(resolution: Resolution, recommendedKbps: Int)] = [
        (Resolution(width: 1920, height: 1080), 4500),   // 1080p Full HD
        (Resolution(width: 1280, height: 720),  2500),   // 720p  HD
        (Resolution(width: 960,  height: 540),  1500),   // 540p  qHD
        (Resolution(width: 854,  height: 480),  1000),   // 480p  SD
    ]

    /// The lowest bitrate (in kbps) we'll include in the ladder.
    /// Anything below this produces unwatchable video.
    private static let minimumBitrateKbps = 200

    /// Build a quality ladder based on the user's starting config
    /// and the device's hardware tier.
    ///
    /// HOW IT WORKS:
    /// 1. Start from the user's chosen resolution and bitrate.
    /// 2. At that resolution, add sub-steps at 75% and 50% bitrate
    ///    (these are instant changes — no encoder restart needed).
    /// 3. Drop to the next lower resolution and repeat.
    /// 4. At the very bottom, add frame-rate reduction steps (last resort).
    ///
    /// On Tier 1 devices (older iPhones), we cap at 720p because
    /// their hardware can't sustain higher resolutions while streaming.
    ///
    /// - Parameters:
    ///   - startingConfig: The user's chosen stream settings.
    ///   - deviceTier: 1 = old/slow, 2 = mid-range, 3 = flagship.
    /// - Returns: A fully built `AbrLadder` ready to use.
    static func buildLadder(startingConfig: StreamConfig, deviceTier: Int) -> AbrLadder {
        var steps: [Step] = []

        // Figure out the maximum pixel count we'll allow.
        // On Tier 1 (old) devices, never go above 720p.
        let startingPixels = startingConfig.resolution.width * startingConfig.resolution.height
        let tier1MaxPixels = 1280 * 720  // 720p
        let maxPixels = (deviceTier <= 1) ? min(startingPixels, tier1MaxPixels) : startingPixels

        // Filter the preset list: only keep resolutions at or below our max.
        let availableResolutions = resolutionPresets.filter {
            $0.resolution.width * $0.resolution.height <= maxPixels
        }

        // Track the previous step's bitrate so each new step never
        // increases bandwidth. This ensures stepping down always
        // reduces (or maintains) the data we're sending.
        var previousBitrate = Int.max

        for (index, entry) in availableResolutions.enumerated() {
            // --- Determine the base bitrate for this resolution ---
            let baseBitrate: Int
            if index == 0 {
                // First (highest) resolution: use the user's chosen bitrate
                baseBitrate = min(startingConfig.videoBitrateKbps, previousBitrate)
            } else {
                // Lower resolutions: use the recommended bitrate, but
                // cap it so we never step UP in bandwidth
                baseBitrate = min(entry.recommendedKbps, previousBitrate)
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
                    resolution: entry.resolution,
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
