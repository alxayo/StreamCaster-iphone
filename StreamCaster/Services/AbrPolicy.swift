import Foundation
import Combine

// MARK: - AbrPolicy

/// AbrPolicy decides WHEN to change quality based on network conditions.
///
/// HOW IT WORKS:
/// 1. Monitors the actual streaming bitrate vs. the configured bitrate.
/// 2. If actual bitrate is significantly below target for several seconds,
///    the network is congested → step down the quality ladder.
/// 3. If actual bitrate sustains at target for a longer period,
///    the network has improved → try stepping up the quality ladder.
/// 4. Also watches for encoder backpressure (fps drops below 80% of target
///    for 5+ consecutive seconds) → the device can't keep up.
///
/// The policy makes DECISIONS. The EncoderController EXECUTES them.
///
/// IMPORTANT THRESHOLDS:
/// - Congestion:    actual bitrate < 75% of target for 3 seconds → step down
/// - Backpressure:  actual fps < 80% of target fps for 5 seconds → step down
/// - Recovery:      both bitrate AND fps ≥ 90% of target for 10 seconds → step up
final class AbrPolicy: ObservableObject {

    // MARK: - Published State

    /// Whether ABR is currently enabled.
    /// When `false`, `evaluateStats` does nothing (quality stays fixed).
    @Published var isEnabled: Bool

    // MARK: - Quality Ladder

    /// The quality ladder for this session. Contains all the steps
    /// we can move between (from best quality to worst).
    private var ladder: AbrLadder

    // MARK: - Encoder Controller

    /// Reference to the encoder controller that executes quality changes.
    /// The policy decides what to change; the controller does the work.
    private let encoderController: EncoderController

    // MARK: - Backpressure Detection

    /// How many seconds in a row the fps has been below the threshold.
    /// When this reaches `backpressureDurationSeconds`, we step down.
    private var consecutiveLowFpsSeconds: Int = 0

    /// What fraction of the target fps counts as "too low."
    /// 0.8 means: if target is 30 fps and actual is below 24 fps → problem.
    private let backpressureThreshold: Float = 0.8

    /// How many consecutive low-fps seconds before we react.
    /// We wait 5 seconds to avoid reacting to brief hiccups.
    private let backpressureDurationSeconds: Int = 5

    // MARK: - Congestion Detection

    /// How many seconds in a row the bitrate has been below the threshold.
    /// When this reaches `congestionDurationSeconds`, we step down.
    private var consecutiveLowBitrateSeconds: Int = 0

    /// What fraction of the target bitrate counts as "congested."
    /// 0.75 means: if target is 2500 kbps and actual is below 1875 kbps → problem.
    private let congestionThreshold: Float = 0.75

    /// How many consecutive congested seconds before we react.
    /// 3 seconds is fast enough to respond but slow enough to ignore blips.
    private let congestionDurationSeconds: Int = 3

    // MARK: - Recovery Detection

    /// How many seconds in a row both bitrate and fps have been "good."
    /// When this reaches `recoveryDurationSeconds`, we try stepping up.
    private var consecutiveGoodSeconds: Int = 0

    /// What fraction of the target counts as "good enough" for recovery.
    /// 0.9 means both bitrate and fps must be at least 90% of their targets.
    private let recoveryThreshold: Float = 0.9

    /// How many consecutive good seconds before we try stepping up.
    /// 10 seconds ensures the network is genuinely better, not just a spike.
    private let recoveryDurationSeconds: Int = 10

    // MARK: - Init

    /// Create a new ABR policy.
    ///
    /// - Parameters:
    ///   - encoderController: The actor that executes encoder changes.
    ///   - startingConfig: The user's chosen stream settings.
    ///   - deviceTier: 1 = old/slow, 2 = mid-range, 3 = flagship.
    init(
        encoderController: EncoderController,
        startingConfig: StreamConfig,
        deviceTier: Int
    ) {
        self.encoderController = encoderController
        self.isEnabled = startingConfig.abrEnabled
        self.ladder = AbrLadder.buildLadder(
            startingConfig: startingConfig,
            deviceTier: deviceTier
        )
    }

    // MARK: - Stats Evaluation (called every 1 second)

    /// Evaluate the latest stream stats and decide whether to change quality.
    ///
    /// This method is called once per second by the streaming engine.
    /// It checks three things in order:
    /// 1. Backpressure — is the device struggling to encode fast enough?
    /// 2. Congestion — is the network too slow for our bitrate?
    /// 3. Recovery — has the network been good long enough to step up?
    ///
    /// - Parameters:
    ///   - stats: The latest stream statistics (actual fps, bitrate, etc.).
    ///   - targetFps: The fps we told the encoder to produce.
    ///   - targetBitrateKbps: The bitrate we told the encoder to produce.
    func evaluateStats(
        _ stats: StreamStats,
        targetFps: Int,
        targetBitrateKbps: Int
    ) async {
        // Do nothing if ABR is turned off
        guard isEnabled else { return }

        // Safety: avoid division by zero if targets aren't set yet
        guard targetFps > 0, targetBitrateKbps > 0 else { return }

        // --- 1. CHECK FOR ENCODER BACKPRESSURE ---
        // If the device can't keep up, fps drops. This means the CPU/GPU
        // is too busy encoding at the current settings.
        let fpsRatio = stats.fps / Float(targetFps)

        if fpsRatio < backpressureThreshold {
            // FPS is low — count this second
            consecutiveLowFpsSeconds += 1
            // Reset recovery counter (things are NOT good)
            consecutiveGoodSeconds = 0

            if consecutiveLowFpsSeconds >= backpressureDurationSeconds {
                // FPS has been low for too long — step down!
                print("[AbrPolicy] Backpressure detected: "
                      + "fps \(stats.fps) < \(Int(backpressureThreshold * Float(targetFps))) "
                      + "for \(backpressureDurationSeconds)s")
                await performStepDown()
                return
            }
        } else {
            // FPS is OK — reset the backpressure counter
            consecutiveLowFpsSeconds = 0
        }

        // --- 2. CHECK FOR NETWORK CONGESTION ---
        // If the network is too slow, the actual bitrate drops below
        // what we're trying to send. Packets pile up and get dropped.
        let bitrateRatio = Float(stats.videoBitrateKbps) / Float(targetBitrateKbps)

        if bitrateRatio < congestionThreshold {
            // Bitrate is low — count this second
            consecutiveLowBitrateSeconds += 1
            // Reset recovery counter (things are NOT good)
            consecutiveGoodSeconds = 0

            if consecutiveLowBitrateSeconds >= congestionDurationSeconds {
                // Network has been congested for too long — step down!
                print("[AbrPolicy] Congestion detected: "
                      + "bitrate \(stats.videoBitrateKbps) kbps "
                      + "< \(Int(congestionThreshold * Float(targetBitrateKbps))) kbps "
                      + "for \(congestionDurationSeconds)s")
                await performStepDown()
                return
            }
        } else {
            // Bitrate is OK — reset the congestion counter
            consecutiveLowBitrateSeconds = 0
        }

        // --- 3. CHECK FOR RECOVERY OPPORTUNITY ---
        // If both fps AND bitrate are at or near their targets,
        // the network/device has capacity. After 10 good seconds,
        // try stepping up to better quality.
        let bitrateOk = bitrateRatio >= recoveryThreshold
        let fpsOk = fpsRatio >= recoveryThreshold

        if bitrateOk && fpsOk {
            consecutiveGoodSeconds += 1

            if consecutiveGoodSeconds >= recoveryDurationSeconds && ladder.canStepUp {
                print("[AbrPolicy] Recovery: stable for \(recoveryDurationSeconds)s, stepping up")
                await performStepUp()
            }
        } else {
            // Not quite good enough — reset recovery counter
            consecutiveGoodSeconds = 0
        }
    }

    // MARK: - Public Actions

    /// Force an immediate step down. Called externally by the thermal
    /// monitoring system when the device is overheating.
    func forceStepDown() async {
        await performStepDown()
    }

    /// Reset the ladder for a new streaming session.
    /// Call this when the user starts a new stream with fresh settings.
    ///
    /// - Parameters:
    ///   - config: The new stream settings.
    ///   - deviceTier: 1 = old/slow, 2 = mid-range, 3 = flagship.
    func reset(config: StreamConfig, deviceTier: Int) {
        ladder = AbrLadder.buildLadder(
            startingConfig: config,
            deviceTier: deviceTier
        )
        isEnabled = config.abrEnabled
        resetCounters()
    }

    // MARK: - Private Helpers

    /// Step down to the next lower quality level and tell the encoder.
    private func performStepDown() async {
        guard let newStep = ladder.stepDown() else {
            print("[AbrPolicy] Already at lowest quality step — cannot step down")
            return
        }

        // Reset all counters so we don't immediately trigger another
        // step-down or a premature step-up after the change
        resetCounters()

        print("[AbrPolicy] Stepping down to: \(newStep.description)")
        await applyStep(newStep)
    }

    /// Step up to the next higher quality level and tell the encoder.
    private func performStepUp() async {
        guard let newStep = ladder.stepUp() else {
            print("[AbrPolicy] Already at highest quality step — cannot step up")
            return
        }

        // Reset all counters so we give the new quality level time
        // to prove itself before making another decision
        resetCounters()

        print("[AbrPolicy] Stepping up to: \(newStep.description)")
        await applyStep(newStep)
    }

    /// Send the new quality settings to the encoder controller.
    /// The controller figures out if a full restart is needed
    /// (resolution/fps change) or just a bitrate tweak.
    private func applyStep(_ step: AbrLadder.Step) async {
        do {
            try await encoderController.requestAbrChange(
                bitrateKbps: step.bitrateKbps,
                resolution: step.resolution,
                fps: step.fps
            )
        } catch {
            // Log the error but don't crash — the policy can try
            // again on the next evaluation cycle.
            print("[AbrPolicy] Failed to apply step \(step.description): \(error)")
        }
    }

    /// Reset all detection counters to zero.
    /// Called after every step change (up or down) to give the new
    /// quality level a clean slate for evaluation.
    private func resetCounters() {
        consecutiveLowFpsSeconds = 0
        consecutiveLowBitrateSeconds = 0
        consecutiveGoodSeconds = 0
    }
}
