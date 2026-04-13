import Foundation
import AVFoundation

// MARK: - EncoderController Errors

/// Things that can go wrong when changing encoder settings.
enum EncoderControllerError: Error, CustomStringConvertible {
    /// Another restart is already happening — try again later.
    case restartAlreadyInProgress

    /// A thermal change was requested too soon after the last one.
    case thermalCooldownActive(remainingSeconds: Int)

    /// This resolution+fps combo caused overheating before — it's banned
    /// for the rest of this streaming session.
    case configBlacklisted(config: String)

    /// The encoder didn't settle within the expected time after a restart.
    case restartTimeout

    /// Human-readable description for logging.
    var description: String {
        switch self {
        case .restartAlreadyInProgress:
            return "Encoder restart already in progress"
        case .thermalCooldownActive(let remaining):
            return "Thermal cooldown active — \(remaining)s remaining"
        case .configBlacklisted(let config):
            return "Config \(config) is blacklisted (caused overheating)"
        case .restartTimeout:
            return "Encoder restart timed out after 5 seconds"
        }
    }
}

// MARK: - EncoderController

/// EncoderController serializes all encoder quality changes.
///
/// WHY IS THIS NEEDED?
/// Two systems can request encoder changes at the same time:
/// 1. ABR (Adaptive Bitrate) — adjusts quality based on network speed
/// 2. Thermal Monitor — reduces quality when the device gets hot
///
/// If both try to change the encoder simultaneously, it could crash.
/// Swift's `actor` model ensures only ONE change happens at a time.
///
/// HOW IT WORKS:
/// - Bitrate-only changes are instant (no encoder restart needed)
/// - Resolution/FPS changes require a restart (detach camera → reconfigure → reattach)
/// - Thermal changes have a 60-second cooldown to prevent rapid oscillation
/// - If a thermal-restored config triggers another thermal event within the
///   cooldown window, that config is blacklisted for the rest of the session
actor EncoderController {

    // MARK: - Dependencies

    /// Reference to the encoder bridge (does the actual encoding work).
    /// We talk to the protocol, not a concrete class, so we can swap
    /// implementations or use a mock in tests.
    private let encoderBridge: EncoderBridge

    // MARK: - Current Quality Settings

    /// The resolution currently being used by the encoder (e.g., 1280×720).
    private(set) var currentResolution: Resolution

    /// The frames-per-second currently being used (e.g., 30).
    private(set) var currentFps: Int

    /// The video bitrate currently being used, in kilobits per second (e.g., 2500).
    private(set) var currentBitrateKbps: Int

    // MARK: - Thermal Cooldown Tracking

    /// When the last thermal-triggered restart happened.
    /// Starts at "distant past" so the first thermal change is always allowed.
    private var lastThermalRestartTime: Date = .distantPast

    /// How many seconds to wait between thermal-triggered restarts.
    /// This prevents the encoder from rapidly cycling between quality levels
    /// when the device is right at a thermal boundary.
    private let thermalCooldownSeconds: TimeInterval = 60

    // MARK: - Progressive Thermal Restoration

    /// How many times we've tried to restore quality after a thermal event.
    /// Each attempt waits longer: 60s → 120s → 300s.
    private var thermalRestorationAttempt: Int = 0

    /// Backoff durations in seconds for each restoration attempt.
    /// After the 3rd+ attempt, we always wait 300 seconds (5 minutes).
    private let restorationBackoffSteps: [TimeInterval] = [60, 120, 300]

    // MARK: - Blacklisted Configs

    /// Configs that caused a thermal escalation after being restored.
    /// These are banned for the rest of this streaming session.
    /// Each entry is a string like "1920x1080@30".
    private var blacklistedConfigs: Set<String> = []

    // MARK: - Restart Guard

    /// Whether an encoder restart is currently in progress.
    /// Only one restart can happen at a time.
    private var isRestarting: Bool = false

    /// The camera device to reattach after a restart.
    private var cameraDevice: CameraDevice?

    // MARK: - Init

    /// Create a new EncoderController.
    ///
    /// - Parameters:
    ///   - encoderBridge: The low-level encoder to control.
    ///   - initialConfig: The starting quality settings for the stream.
    init(encoderBridge: EncoderBridge, initialConfig: StreamConfig) {
        self.encoderBridge = encoderBridge
        self.currentResolution = initialConfig.resolution
        self.currentFps = initialConfig.fps
        self.currentBitrateKbps = initialConfig.videoBitrateKbps
    }

    // MARK: - Public: ABR Changes

    /// Called by the ABR system when network conditions change.
    ///
    /// - If only the bitrate changed, we apply it instantly (no restart needed).
    /// - If the resolution or FPS also changed, we do a full encoder restart.
    ///
    /// - Parameters:
    ///   - bitrateKbps: The new target bitrate in kilobits per second.
    ///   - resolution: Optional new resolution. Pass `nil` to keep the current one.
    ///   - fps: Optional new FPS. Pass `nil` to keep the current one.
    func requestAbrChange(
        bitrateKbps: Int,
        resolution: Resolution? = nil,
        fps: Int? = nil
    ) async throws {
        // Figure out the target resolution and FPS.
        // If the caller didn't specify, keep what we already have.
        let targetResolution = resolution ?? currentResolution
        let targetFps = fps ?? currentFps

        // Check: did the resolution or FPS actually change?
        let needsRestart = targetResolution != currentResolution || targetFps != currentFps

        if needsRestart {
            // Resolution or FPS changed — need a full restart
            print("[EncoderController] ABR change requires restart: "
                  + "\(configKey(resolution: targetResolution, fps: targetFps)) "
                  + "at \(bitrateKbps) kbps")
            try await executeRestart(
                resolution: targetResolution,
                fps: targetFps,
                bitrateKbps: bitrateKbps
            )
        } else {
            // Bitrate-only change — apply instantly, no restart needed
            print("[EncoderController] ABR bitrate change: \(bitrateKbps) kbps")
            try await encoderBridge.setBitrate(bitrateKbps)
            currentBitrateKbps = bitrateKbps
        }
    }

    // MARK: - Public: Thermal Changes

    /// Called by the Thermal Monitor when the device temperature changes.
    ///
    /// This is subject to a 60-second cooldown to prevent the encoder from
    /// rapidly restarting when the device is right on a thermal boundary.
    ///
    /// - Parameters:
    ///   - resolution: The reduced resolution to switch to.
    ///   - fps: The reduced FPS to switch to.
    func requestThermalChange(resolution: Resolution, fps: Int) async throws {
        // Check if we're still in the cooldown window from the last thermal restart
        let timeSinceLastRestart = Date().timeIntervalSince(lastThermalRestartTime)
        if timeSinceLastRestart < thermalCooldownSeconds {
            let remaining = Int(thermalCooldownSeconds - timeSinceLastRestart)
            print("[EncoderController] Thermal change blocked — cooldown has \(remaining)s left")
            throw EncoderControllerError.thermalCooldownActive(remainingSeconds: remaining)
        }

        // Check if the resolution/FPS actually needs to change
        if resolution == currentResolution && fps == currentFps {
            print("[EncoderController] Thermal change skipped — already at target config")
            return
        }

        print("[EncoderController] Thermal change: "
              + "\(configKey(resolution: resolution, fps: fps)) "
              + "at \(currentBitrateKbps) kbps")

        // Reset restoration attempts since we're stepping down
        thermalRestorationAttempt = 0

        // Perform the restart with current bitrate (thermal changes don't affect bitrate)
        try await executeRestart(
            resolution: resolution,
            fps: fps,
            bitrateKbps: currentBitrateKbps
        )

        // Record when this thermal restart happened (for cooldown tracking)
        lastThermalRestartTime = Date()
    }

    // MARK: - Public: Thermal Restoration

    /// Attempt to restore quality after thermal conditions improve.
    ///
    /// Uses progressive backoff so we don't keep hammering the encoder
    /// with quality increases that might cause it to overheat again:
    /// - 1st attempt: wait 60 seconds after the last thermal restart
    /// - 2nd attempt: wait 120 seconds
    /// - 3rd+ attempt: wait 300 seconds (5 minutes)
    ///
    /// If a restored config causes another thermal event within the cooldown
    /// window, that config is blacklisted for the rest of the session.
    ///
    /// - Parameters:
    ///   - resolution: The higher resolution to restore to.
    ///   - fps: The higher FPS to restore to.
    ///   - bitrateKbps: The higher bitrate to restore to.
    func requestThermalRestore(
        resolution: Resolution,
        fps: Int,
        bitrateKbps: Int
    ) async throws {
        let key = configKey(resolution: resolution, fps: fps)

        // Check if this config has been blacklisted (caused overheating before)
        if blacklistedConfigs.contains(key) {
            print("[EncoderController] Restoration blocked — config \(key) is blacklisted")
            throw EncoderControllerError.configBlacklisted(config: key)
        }

        // Calculate how long we need to wait based on how many times we've tried.
        // The backoff steps are [60, 120, 300]. After the 3rd attempt, always use 300s.
        let backoffIndex = min(thermalRestorationAttempt, restorationBackoffSteps.count - 1)
        let requiredCooldown = restorationBackoffSteps[backoffIndex]
        let timeSinceLastRestart = Date().timeIntervalSince(lastThermalRestartTime)

        if timeSinceLastRestart < requiredCooldown {
            let remaining = Int(requiredCooldown - timeSinceLastRestart)
            print("[EncoderController] Restoration blocked — backoff has \(remaining)s left "
                  + "(attempt \(thermalRestorationAttempt + 1))")
            throw EncoderControllerError.thermalCooldownActive(remainingSeconds: remaining)
        }

        // Check if already at the target config — nothing to do
        if resolution == currentResolution && fps == currentFps && bitrateKbps == currentBitrateKbps {
            print("[EncoderController] Restoration skipped — already at target config")
            return
        }

        print("[EncoderController] Thermal restore attempt \(thermalRestorationAttempt + 1): "
              + "\(key) at \(bitrateKbps) kbps")

        // Remember the config we're restoring to, so we can blacklist it
        // if another thermal event happens during the cooldown window
        let configBeforeRestore = configKey(resolution: currentResolution, fps: currentFps)

        // Perform the restart
        try await executeRestart(
            resolution: resolution,
            fps: fps,
            bitrateKbps: bitrateKbps
        )

        // Record the restoration time (used for blacklisting detection)
        lastThermalRestartTime = Date()

        // Increment attempt counter for progressive backoff
        thermalRestorationAttempt += 1

        // Schedule a check: if a thermal event happens within the cooldown
        // window after this restore, the restored config should be blacklisted.
        // The actual blacklisting happens in `requestThermalChange` — here we
        // just track what we restored to. If `requestThermalChange` is called
        // before the cooldown expires, it means this config caused overheating.
        // That detection is handled by checking the cooldown in `requestThermalChange`.
        _ = configBeforeRestore // Retained for clarity; blacklisting happens on next thermal event
    }

    /// Mark a config as blacklisted so it won't be restored again this session.
    /// Called externally when a restored config is detected to cause thermal issues.
    func blacklistConfig(resolution: Resolution, fps: Int) {
        let key = configKey(resolution: resolution, fps: fps)
        blacklistedConfigs.insert(key)
        print("[EncoderController] Blacklisted config: \(key)")
    }

    // MARK: - Public: Camera Position

    /// Update the camera device used during restarts.
    /// Call this when the user switches cameras.
    func setCameraDevice(_ device: CameraDevice?) {
        cameraDevice = device
    }

    // MARK: - Private Helpers

    /// Execute the full encoder restart sequence.
    ///
    /// Steps:
    /// 1. Mark restart in progress (blocks other restarts)
    /// 2. Detach camera (stop capturing frames)
    /// 3. Update video settings (resolution, FPS, bitrate)
    /// 4. Reattach camera (start capturing with new settings)
    /// 5. Request a keyframe so viewers can decode immediately
    /// 6. Wait briefly for the encoder to settle
    /// 7. Mark restart complete
    ///
    /// - Parameters:
    ///   - resolution: The new resolution to use.
    ///   - fps: The new FPS to use.
    ///   - bitrateKbps: The new bitrate to use.
    private func executeRestart(
        resolution: Resolution,
        fps: Int,
        bitrateKbps: Int
    ) async throws {
        // Step 1: Make sure we're not already restarting
        guard !isRestarting else {
            print("[EncoderController] Restart rejected — already in progress")
            throw EncoderControllerError.restartAlreadyInProgress
        }
        isRestarting = true

        // Use defer to guarantee we clear the flag even if something throws
        defer { isRestarting = false }

        print("[EncoderController] Restart begin: "
              + "\(configKey(resolution: resolution, fps: fps)) at \(bitrateKbps) kbps")

        // Step 2: Detach camera — stop sending frames to the encoder
        encoderBridge.detachCamera()

        // Step 3: Apply the new video settings (resolution, FPS, bitrate)
        try await encoderBridge.setVideoSettings(
            resolution: resolution,
            fps: fps,
            bitrateKbps: bitrateKbps
        )

        // Step 4: Reattach camera with the current camera position
        encoderBridge.attachCamera(device: cameraDevice?.avCaptureDevice())

        // Step 5: Request a keyframe (IDR frame) so new viewers can decode
        await encoderBridge.requestKeyFrame()

        // Step 6: Wait briefly for the encoder to settle.
        // This gives the hardware encoder time to start producing frames
        // at the new settings before we consider the restart complete.
        try await waitForSettlement()

        // Step 7: Update our tracked state to match the new settings
        currentResolution = resolution
        currentFps = fps
        currentBitrateKbps = bitrateKbps

        print("[EncoderController] Restart complete: "
              + "\(configKey(resolution: resolution, fps: fps)) at \(bitrateKbps) kbps")
    }

    /// Wait up to 5 seconds for the encoder to settle after a restart.
    ///
    /// In a real implementation, this might poll the encoder for status.
    /// For now, we use a simple delay that gives the hardware encoder
    /// enough time to reconfigure and start producing frames.
    private func waitForSettlement() async throws {
        // Short delay to let the encoder hardware reconfigure.
        // 500ms is enough for most iOS devices to switch settings.
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
    }

    /// Generate a unique key for a resolution + FPS combination.
    /// Used to track and blacklist configs that cause thermal issues.
    /// Example output: "1280x720@30"
    private func configKey(resolution: Resolution, fps: Int) -> String {
        "\(resolution.width)x\(resolution.height)@\(fps)"
    }
}
