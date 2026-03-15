# StreamCaster — iOS RTMP Streaming Application Specification

**Version:** 2.1 (Post-Adversarial Review)  
**Date:** March 15, 2026  
**Status:** Draft  
**Bundle ID:** `com.port80.app`  
**App Name:** StreamCaster

---

## 1. Overview

**StreamCaster** is a free, open-source native iOS application that captures video and/or audio from the device camera and microphone and streams it in real-time to a user-configured RTMP/RTMPS ingestion endpoint.

Distributed via Apple App Store, TestFlight, and sideloading (IPA via AltStore / notarized direct distribution under EU DMA).

### 1.1 Product Scope

- Native iOS app to live-stream camera and/or microphone to a single RTMP/RTMPS ingestion endpoint.
- Optional concurrent local MP4 recording.
- Basic streaming HUD (bitrate, fps, resolution, duration, connection state).
- Multiple saved endpoint profiles with Keychain-backed credential storage.
- Adaptive bitrate with device-capability-aware quality ladder.
- Best-effort background continuity: audio-only via background audio mode; video may continue temporarily via PiP while iOS permits camera capture, otherwise the session must degrade to audio-only or stop.

### 1.2 Non-Goals

The following are explicitly out of scope for the current version:

- Multi-destination streaming.
- Overlay rendering beyond a no-op architectural hook.
- H.265 encoding (deferred).
- SRT protocol (deferred).
- Stream scheduling.
- Analytics or tracking SDKs.
- Ads or in-app purchases.
- iPad or Mac Catalyst optimized UI.

---

## 2. Technology Stack

| Component | Choice | Rationale |
|---|---|---|
| **Language** | **Swift 5.10+** | Native, performant, null-safe via optionals, dominant iOS language. HaishinKit is Swift-native. |
| **Streaming Library** | **HaishinKit.swift v2.0.x** (BSD 3-Clause) | Most actively maintained open-source iOS RTMP library. Supports RTMP, RTMPS, SRT. Provides AVFoundation camera integration, adaptive bitrate, H.264/H.265/AAC hardware encoding via VideoToolbox. |
| **Camera Framework** | **HaishinKit `RTMPStream`** (AVFoundation internally) | HaishinKit's stream class is the sole camera owner via `attachCamera()` / `attachAudio()`. It manages `AVCaptureSession` internally. No separate CaptureSession layering. See §5.3. |
| **Build System** | **Xcode 16.x + Swift Package Manager (SPM)** | Standard toolchain. No CocoaPods or Carthage dependency. |
| **Min Deployment Target** | **iOS 15.0** | Required for `AVPictureInPictureController.ContentSource` (sample-buffer PiP), `async/await`, structured concurrency, modern SwiftUI. Covers ~98% of active iOS devices. |
| **Target SDK** | **iOS 18 (latest)** | Access to latest platform APIs and App Store submission compliance. |
| **Architecture** | **MVVM** with `ObservableObject` + Combine + async/await | Clean separation, lifecycle-aware, testable. Native Swift concurrency. |
| **DI** | **Protocol-based + Factory pattern** | Swift's protocol-oriented design makes lightweight DI natural without a framework. No Swinject or similar needed. |
| **UI** | **SwiftUI** + UIKit interop | Modern declarative UI. Camera preview uses `UIViewRepresentable` wrapping HaishinKit's `MTHKView` (Metal-based preview). |
| **Persistence** | **UserDefaults** | For storing non-sensitive settings (default camera, resolution, etc.). |
| **Credential Storage** | **Keychain Services** (Secure Enclave-backed) | For stream keys, passwords. Hardware-backed on all supported devices (iPhone 5s+). Items stored with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — not backed up, not transferred to new devices. |
| **Background Streaming** | **PiP (Picture-in-Picture)** + `UIBackgroundModes: audio` | PiP keeps video preview alive while app is backgrounded. Audio background mode keeps `AVCaptureSession` audio and RTMP connection alive. See §7.1. |
| **Crash Reporting** | **KSCrash** (MIT license) | Open-source, privacy-respecting. Supports custom HTTP transport to self-hosted endpoint. No third-party cloud dependencies. Closest iOS equivalent of ACRA. |

### 2.1 Why HaishinKit over Alternatives

| Library | Min iOS | RTMPS | Active | Verdict |
|---|---|---|---|---|
| **HaishinKit.swift** | 13.0 | Yes | Yes (March 2026) | **Selected** — most feature-complete, actively maintained, Swift-native, BSD license |
| LFLiveKit | 9.0 | Partial | No (EOL ~2020) | Rejected — dead project, Objective-C, limited features |
| VideoCore | 8.0 | No | No (EOL) | Rejected — dead project, no RTMPS |
| Larix SDK (iOS) | 14.0 | Yes | Yes | Rejected — proprietary license, not open-source |
| Mux Spaces SDK | 15.0 | N/A | Yes | Rejected — cloud-coupled to Mux platform |

---

## 3. Supported Platforms and Operating Assumptions

| Dimension | Assumption |
|---|---|
| **Min Deployment** | iOS 15.0. Required for sample-buffer PiP, async/await, modern SwiftUI, and `ProcessInfo.ThermalState` notification API. |
| **Target SDK** | iOS 18 (latest). Required for App Store submission in 2026. |
| **Device class** | iPhones only. iPad and Mac Catalyst are not guaranteed to work and are not tested against. |
| **Device tiers** | **Tier 1 (constrained):** A10/A11 chipsets (iPhone 7/8 class), ≤ 2 GB RAM. **Tier 2 (mid-range):** A12–A14 (iPhone XS through 12 class), 3–4 GB RAM. **Tier 3 (modern):** A15+ (iPhone 13+), 4+ GB RAM. Feature availability (60 fps, local recording) is gated by tier. See §4.2 VS-02, §8.3, §MC-05. |
| **Camera/encoder** | Hardware H.264 (Baseline/Main) + AAC-LC via VideoToolbox expected. H.265 deferred. All supported iPhones have hardware H.264. |
| **Network** | Hostile networks assumed. RTMPS is mandatory whenever a stream key, password, token, or any other secret is present. Plain RTMP is permitted only for anonymous endpoints that do not require credentials or bearer material (see §9). |
| **Background model** | iOS suspends apps aggressively. Background video is a best-effort behavior only: PiP may temporarily preserve camera capture, but the app must be prepared to lose the camera at any time and degrade to audio-only or stop. Audio-only streaming may continue via `UIBackgroundModes: audio` while the audio session remains active. |
| **Thermal** | iOS may throttle CPU/GPU under thermal pressure. `ProcessInfo.ThermalState` provides system-level thermal status. The app must respond to thermal escalation progressively. |

---

## 4. Functional Requirements

### 4.1 Media Capture

| ID | Requirement | Priority |
|---|---|---|
| MC-01 | Stream **video only**, **audio only**, or **both** — user selects before or during stream. Mid-session video→audio downgrade is permitted; audio→video upgrade requires disconnecting and reconnecting the RTMP session with the new track configuration (not a mid-session track addition), because not all RTMP servers accept a new video metadata/header packet mid-stream. If reconnection fails, remain in audio-only mode and surface the error. | Must |
| MC-02 | Default to **back camera**. User can switch to front camera before or during stream. | Must |
| MC-03 | Live camera preview displayed before and during streaming. Preview must restore after app comes back from background if PiP was dismissed. | Must |
| MC-04 | Orientation (portrait / landscape) selected by user before stream start; locked for the duration of the active session; unlocked only when idle. The lock must be applied before the first frame renders using `supportedInterfaceOrientations` on the root view controller. When a stream is active, the lock is enforced unconditionally to prevent orientation change during streaming. | Must |
| MC-05 | **Local recording** — optional toggle to save a local MP4 copy simultaneously. User selects destination: **Photos Library** (via `PHPhotoLibrary`) or **app's Documents directory** (accessible via Files app). Enabling the toggle must immediately prompt for the chosen destination if Photos Library permissions haven't been granted. **Launch gate:** this feature may ship only if the selected media pipeline proves that a single encoded sample-buffer stream can be safely fanned out into both the RTMP muxer and `AVAssetWriter` with monotonic timestamps, bounded memory ownership, and no second hardware encoder instance. If that feasibility gate fails for the chosen library stack, local recording is deferred from launch rather than opening a second encoder. If storage permission is denied or unavailable, recording must fail fast with a user prompt; streaming must not be blocked. **On Tier 1 devices (`physicalMemory < 3 GB`), display a warning that local recording may cause the app to be terminated by iOS due to memory pressure.** Register a `DispatchSource.makeMemoryPressureSource(.warning)` observer; on `.warning` or `.critical` memory pressure, **stop local recording AND aggressively degrade stream bitrate/resolution** to minimize memory buffering footprint. Notify the user of the degradation. See §3 device tiers. | Should |

### 4.2 Video Settings

| ID | Requirement | Default | Priority |
|---|---|---|---|
| VS-01 | **Resolution** selectable from device-supported list, filtered by `AVCaptureDevice.formats` and `VTSessionCopySupportedPropertyDictionary` for encoder compatibility. | **720p (1280×720)** | Must |
| VS-02 | **Frame rate** selectable: 24, 25, 30, 60 fps — shown only if the device camera+encoder support it (checked via `AVFrameRateRange`). **60 fps must be hidden on Tier 1 devices (A10/A11)** regardless of hardware capability, because sustained 60 fps encoding causes thermal oscillation within minutes on these chipsets. See §3 device tiers. | **30 fps** | Must |
| VS-03 | **Video codec**: H.264 (Baseline/Main profile). H.265 deferred. | H.264 | Must |
| VS-04 | **Video bitrate** selectable or auto. Range: 500 kbps – 8 Mbps, capped to encoder capability. | **2.5 Mbps** (for 720p30) | Must |
| VS-05 | **Keyframe interval** configurable (1–5 seconds). | **2 seconds** | Should |

### 4.3 Audio Settings

| ID | Requirement | Default | Priority |
|---|---|---|---|
| AS-01 | **Audio codec**: AAC-LC. | AAC-LC | Must |
| AS-02 | **Sample rate**: 44100 Hz or 48000 Hz. | **44100 Hz** | Must |
| AS-03 | **Audio bitrate**: 64 / 96 / 128 / 192 kbps. | **128 kbps** | Must |
| AS-04 | **Channels**: Mono / Stereo. | **Stereo** | Should |
| AS-05 | **Mute toggle** during active stream (stops sending audio data). | — | Must |

### 4.4 RTMP Endpoint Configuration

| ID | Requirement | Priority |
|---|---|---|
| EP-01 | User can enter an **RTMP URL** (e.g., `rtmp://ingest.example.com/live`). | Must |
| EP-02 | Support **RTMPS** (RTMP over TLS/SSL) endpoints. | Must |
| EP-03 | Optional **stream key** field (appended to URL or sent separately, per convention). | Must |
| EP-04 | Optional **username / password** authentication fields. | Must |
| EP-05 | **Save as default** — persists the last-used endpoint + key so the user doesn't re-enter it. Credentials stored only via Keychain Services. | Must |
| EP-06 | Multiple saved endpoint profiles (name + URL + key + auth). | Should |
| EP-07 | **Connection test** button — validates transport reachability and publish preconditions before going live. A handshake-only probe must be labeled as a transport probe and must not imply that a long-running publish has been validated. Any authenticated publish probe must obey the same transport security rules as live streaming (see §9.2). | Should |

### 4.5 Adaptive Bitrate (ABR)

| ID | Requirement | Priority |
|---|---|---|
| AB-01 | Toggle to **enable/disable** adaptive bitrate. | Must |
| AB-02 | When enabled, dynamically lower video bitrate and/or resolution within a device-capability-aware ABR ladder on network congestion. | Must |
| AB-03 | Automatically recover bitrate when bandwidth improves. | Must |
| AB-04 | Display current effective bitrate on the streaming HUD. | Should |

### 4.6 Streaming Lifecycle

| ID | Requirement | Priority |
|---|---|---|
| SL-01 | **Start / Stop** stream via prominent button. | Must |
| SL-02 | **Auto-reconnect** on network drop — configurable retry count (default: unlimited) and interval using exponential backoff with jitter (3 s, 6 s, 12 s, …, cap 60 s). Reconnect attempts must be driven by `NWPathMonitor` path status updates (`path.status == .satisfied`) in addition to the backoff timer; timer-based retries continue while network is available. | Must |
| SL-03 | **Background streaming** — audio-only background streaming is best-effort via `UIBackgroundModes: audio` while the `AVAudioSession` remains active. Background video is best-effort via PiP only and must never be represented as guaranteed camera continuity. When PiP is dismissed by the user while the app is in the background, or if camera sample delivery stalls, the camera is treated as interrupted by iOS; the stream switches to audio-only (or stops if video-only mode). On return to foreground, camera re-acquires and video resumes only if the device and OS still permit capture. See §7.1. | Must |
| SL-04 | **Lock Screen / Control Center controls** via `MPRemoteCommandCenter`. `MPNowPlayingInfoCenter` displays stream status (live duration, bitrate). **`pauseCommand` must map to mute-audio, not stop-stream**, to prevent accidental broadcast termination from AirPod removal, Bluetooth button press, Siri "pause" commands, or CarPlay events. **`stopCommand`** maps to stop-stream and must cancel any in-flight reconnect and leave the stream fully stopped. `togglePlayPauseCommand` maps to mute/unmute with debouncing (500 ms). | Must |
| SL-05 | Graceful shutdown on low battery (configurable threshold, default 5%). Auto-stop and finalize local recording at critical (≤ 2%). | Should |
| SL-06 | **Background camera interruption handling** — when iOS interrupts `AVCaptureSession` in the background (PiP dismissed or another app takes camera), cleanly stop the video track, keep the audio-only RTMP session alive (or stop gracefully if video-only mode). On return to foreground, re-acquire camera, re-init video encoder, and send an IDR frame to resume video. | Must |
| SL-07 | **Thermal throttling response** — register for `ProcessInfo.thermalStateDidChangeNotification`. On `.fair`: show HUD warning. On `.serious`: step down the ABR ladder (e.g., 720p→480p, 30→15 fps), performing a controlled encoder restart if resolution/fps change requires it. On `.critical`: stop stream and recording gracefully and show the user the reason. Enforce a minimum 60-second cooldown between thermal-triggered step changes to avoid rapid oscillation. **Quality restoration uses progressive backoff:** first restoration attempt after 60 s, second after 120 s, third+ after 300 s. If a restored configuration triggers another thermal event within the backoff window, **do not restore to that configuration again for the remainder of the session** — this prevents oscillation loops (e.g., 60 fps → thermal serious → 15 fps → cool → 60 fps → thermal serious). | Must |
| SL-08 | **Audio session interruption handling** — on incoming call or audio session interruption (`.began`), mute the microphone and show a muted indicator. Register for `AVAudioSession.interruptionNotification`. **Causal chain:** an audio interruption deactivates the audio session, which causes iOS to dismiss PiP (if active), which triggers `AVCaptureSession.wasInterruptedNotification` and camera loss. The engine must recognize this as a single compound event and enter a `suspended` sub-state — do not attempt RTMP reconnection during this window. On interruption `.ended` with `shouldResume`: (1) reactivate `AVAudioSession`, (2) re-start PiP if the app is still backgrounded, (3) re-acquire camera. **Privacy-first recovery rule:** audio must remain muted after interruption recovery until the user explicitly unmutes, even if the stream was unmuted before the interruption. If the stream mode is **audio-only**, an audio interruption must stop the stream (there is nothing left to send). If the stream mode is **video+audio**, mute audio and continue video. See SL-06 for the camera recovery path. | Must |

### 4.7 Overlay Architecture (Future)

| ID | Requirement | Priority |
|---|---|---|
| OV-01 | Architecture supports an **overlay pipeline** (text, timestamps, watermarks) that can be rendered onto the video frame before encoding. | Must (arch) |
| OV-02 | Actual overlay rendering implementation. | Deferred |

> **Implementation note:** HaishinKit supports custom video effects via its `VideoEffect` protocol (CIFilter-based pipeline). The architecture will include a pluggable `OverlayManager` protocol with a no-op default implementation. Future overlays will implement this protocol and render via Core Image filters or Metal shaders.

---

## 5. Non-Functional Requirements

| ID | Requirement | Target |
|---|---|---|
| NF-01 | **Startup to preview** in < 2 seconds on mid-range devices (iPhone 11 class). | Must |
| NF-02 | **Streaming latency** (glass-to-glass) ≤ 3 seconds over stable LTE. Surface as a debug metric if exceeded. | Should |
| NF-03 | **Battery drain** ≤ 15% per hour of streaming at 720p30. **Benchmarks required for two profiles:** (1) Foreground Active (screen on), (2) Background/PiP (screen off). Profile (2) must not exceed 10% per hour on Tier 2+ devices. Older devices (iPhone 7/8 class, iOS 15) are not bound by this target; measured drain on older hardware must be documented in the test report. | Should |
| NF-04 | **Crash-free rate** ≥ 99.5%. | Must |
| NF-05 | **App size** < 15 MB (before App Store thinning / App Slicing). | Should |
| NF-06 | No third-party analytics or tracking SDKs. | Must |
| NF-07 | All sensitive data (stream keys, passwords) must be stored encrypted via Keychain Services with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. The app must never fall back to plaintext storage (e.g., UserDefaults, plist files). | Must |
| NF-08 | **No custom TLS bypass.** RTMPS connections must use the system default TLS configuration via `URLSession` / `Network.framework`. No custom `SecTrustEvaluate` overrides or `NSAllowsArbitraryLoads` exceptions. Users with self-signed certs must install them via iOS Settings → General → Profile **and enable full trust in Settings → General → About → Certificate Trust Settings** (both steps required). See §9.2. | Must |
| NF-09 | **Thermal awareness.** Register for `ProcessInfo.thermalStateDidChangeNotification`. Progressively degrade stream quality to prevent device overheating and frame drops. See SL-07. | Must |

---

## 6. Architecture

### 6.1 High-Level Diagram

```
┌─────────────────────────────────────────────────────────┐
│                        UI Layer                         │
│  ┌──────────┐  ┌──────────┐  ┌───────────────────────┐  │
│  │ Preview  │  │ Controls │  │ Settings Screens      │  │
│  │ (SwiftUI)│  │ (SwiftUI)│  │ (SwiftUI + Navigation)│  │
│  └────┬─────┘  └────┬─────┘  └──────────┬────────────┘  │
│       │              │                   │               │
│  ┌────▼──────────────▼───────────────────▼────────────┐  │
│  │              ViewModels (MVVM)                     │  │
│  │  StreamViewModel · SettingsViewModel               │  │
│  │  (@ObservableObject + @Published / Combine)        │  │
│  └────────────────────┬──────────────────────────────┘  │
│                       │  references engine               │
├───────────────────────┼──────────────────────────────────┤
│                 Domain / Service Layer                   │
│  ┌────────────────────▼──────────────────────────────┐  │
│  │       StreamingEngine (Singleton)                  │  │
│  │       ← authoritative source of stream state →    │  │
│  │  ┌──────────────┐  ┌────────────┐ ┌───────────┐  │  │
│  │  │ RTMPStream   │  │ AudioSess  │ │OverlayMgr │  │  │
│  │  │ + RTMPConn   │  │ Manager    │ │ (No-op)   │  │  │
│  │  │ (AVFoundation│  │ (Mic)      │ │           │  │  │
│  │  │  internally) │  │            │ │           │  │  │
│  │  └──────┬───────┘  └─────┬──────┘ └─────┬─────┘  │  │
│  │         │                │               │         │  │
│  │  ┌──────▼────────────────▼───────────────▼──────┐  │  │
│  │  │         HaishinKit Streaming Engine           │  │  │
│  │  │  ┌──────────┐ ┌──────────┐ ┌─────────────┐   │  │  │
│  │  │  │VideoTool │ │AudioTool │ │ RTMP/S Conn │   │  │  │
│  │  │  │box H.264 │ │box AAC   │ │             │   │  │  │
│  │  │  └──────────┘ └──────────┘ └─────────────┘   │  │  │
│  │  │  ┌──────────────┐ ┌───────────────────────┐   │  │  │
│  │  │  │Adaptive Rate │ │ AVAssetWriter (opt MP4)│   │  │  │
│  │  │  └──────────────┘ └───────────────────────┘   │  │  │
│  │  └──────────────────────────────────────────────┘  │  │
│  │  ┌───────────────┐  ┌────────────────────────┐    │  │
│  │  │ PiPManager    │  │ NowPlayingController   │    │  │
│  │  │ (Sample-buffer│  │ (MPRemoteCommand +     │    │  │
│  │  │  PiP)         │  │  MPNowPlayingInfo)     │    │  │
│  │  └───────────────┘  └────────────────────────┘    │  │
│  └───────────────────────────────────────────────────┘  │
├──────────────────────────────────────────────────────────┤
│                    Data Layer                            │
│  ┌────────────────┐  ┌──────────────────────────────┐   │
│  │ SettingsRepo   │  │ EndpointProfileRepo           │   │
│  │ (UserDefaults) │  │ (Keychain Services)           │   │
│  └────────────────┘  └──────────────────────────────┘   │
└──────────────────────────────────────────────────────────┘
```

### 6.2 Key Components

| Component | Responsibility |
|---|---|
| `StreamViewModel` | References `StreamingEngine`. Reads authoritative streaming state as a published `StreamSessionSnapshot`, not a single flattened enum. The snapshot contains orthogonal domains: `TransportState` (`idle`, `connecting`, `live`, `reconnecting`, `stopping`, `stopped`), `MediaState` (`videoActive`, `audioActive`, `audioMuted`, `interruptionOrigin`), `BackgroundState` (`foreground`, `pipStarting`, `pipActive`, `backgroundAudioOnly`, `suspended`), and `RecordingState` (`off`, `starting`, `recording`, `finalizing`, `failed`). `StopReason` remains explicit: `.userRequest`, `.errorEncoder`, `.errorAuth`, `.errorCamera`, `.errorAudio`, `.errorNetwork`, `.errorStorage`, `.thermalCritical`, `.batteryCritical`, `.pipDismissedVideoOnly`, `.osTerminated`, `.unknown`. Exposes preview surface, stream stats, and control actions. All start/stop/mute commands are idempotent. The `StreamingEngine` must never hold strong references to observers. All Combine subscriptions from `StreamViewModel` must be stored in `var cancellables: Set<AnyCancellable>` and cancelled in `deinit`. The engine exposes state only via `@Published` snapshot properties (pull model) and must never call back into ViewModels directly (push model). |
| `SettingsViewModel` | Reads/writes user preferences. Queries device for supported resolutions, frame rates, and codec profiles via `DeviceCapabilityQuery`. |
| `StreamingEngine` | Singleton (application-scoped). Owns the HaishinKit `RTMPConnection` + `RTMPStream` instances. Is the **single source of truth** for stream lifecycle. All mutable lifecycle state must be confined to a single internal coordinator (`StreamingSessionCoordinator`) implemented as a Swift `actor` with a monotonic session token. The coordinator serializes user commands, reconnect intents, interruption events, PiP events, and thermal/battery stops. The engine publishes immutable `StreamSessionSnapshot` values to the UI on `@MainActor`; `@MainActor` is an emission boundary only, not the mutation authority. |
| `DeviceCapabilityQuery` | Queries `AVCaptureDevice.DiscoverySession` and `AVCaptureDevice.formats` for available cameras, resolutions, frame rates, and codec profiles. Does NOT own the camera or open a capture session. |
| `AudioSessionManager` | Configures `AVAudioSession`. Manages category, mode, interruption handling, and route changes. |
| `PiPManager` | Manages `AVPictureInPictureController` with `AVSampleBufferDisplayLayer`. Activates PiP on app backgrounding, deactivates on foregrounding. Monitors PiP lifecycle events. |
| `NowPlayingController` | Configures `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` for lock screen / Control Center controls. |
| `OverlayManager` | Protocol with `func processFrame(_ image: CIImage) -> CIImage`. Default no-op. Future overlays plug in here via HaishinKit's `VideoEffect`. |
| `SettingsRepository` | Persists non-sensitive settings via UserDefaults. |
| `EndpointProfileRepository` | CRUD for saved RTMP endpoint profiles. Credentials stored via Keychain Services with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. |
| `ConnectionManager` | Handles RTMP connect/disconnect, auto-reconnect logic with exponential backoff + jitter, and connection health monitoring via `NWPathMonitor`. Cancels retries on explicit user stop. It must not mutate user-visible state directly; instead it submits intents to `StreamingSessionCoordinator`, which performs the state transition and validates the active session token atomically before each connect/reconnect attempt. Stopping the stream must **first** transition the session into a stopping state and cancel the `NWPathMonitor`/reconnect timers, **then** send the RTMP disconnect. The disconnect action must enforce a hard timeout (e.g., 2 seconds) where it closes the file descriptor if the socket semantic close blocks; the UI must show "Disconnecting..." during this phase. |

### 6.3 Camera Strategy — HaishinKit as Sole Camera Owner

> **Design decision:** HaishinKit provides optimized camera management via `RTMPStream.attachCamera()` and `RTMPStream.attachAudio()` which tightly couple AVFoundation capture with hardware encoding and RTMP muxing. Creating a separate `AVCaptureSession` would risk session contention.
>
> **Therefore, the app uses HaishinKit's `RTMPStream` exclusively for camera ownership.**
> - No separate `AVCaptureSession`.
> - `DeviceCapabilityQuery` only reads `AVCaptureDevice.formats` and `AVCaptureDevice.DiscoverySession`; it never opens/activates the camera.

```
┌───────────────────────────────────┐
│   HaishinKit Stream Classes       │
│   (sole camera owner)             │
├───────────────────────────────────┤
│   RTMPStream.attachCamera(device) │
│   RTMPStream.attachAudio(device)  │
│   MTHKView (Metal preview)        │
└───────────────────────────────────┘
```

Camera switching and preview attachment are delegated directly to `RTMPStream.attachCamera(devicePosition:)` and the `MTHKView` SwiftUI wrapper.

---

## 7. Lifecycle and State Management

### 7.1 Background Streaming via PiP + Audio Mode

iOS does not support indefinite camera access in the background the way Android's foreground service does. StreamCaster uses a two-pronged approach:

**PiP (Picture-in-Picture) for Video:**
- **PiP is a best-effort mechanism for temporary background video continuity, not a platform guarantee.** The product contract is: while the app is backgrounded, the session may keep sending video if PiP remains active and iOS continues delivering camera frames; otherwise it must degrade to audio-only or stop.
- **`UIApplication.didEnterBackgroundNotification` is the authoritative signal for committed background handling.** `scenePhase` must not be used for engine-level lifecycle decisions (it is unreliable on iOS 15–16: may not fire, may fire multiple times, or may stall at `.inactive` during Siri/notification center interactions). Use `scenePhase` only for SwiftUI view updates. `UIApplication.willResignActiveNotification` may be used only to mark a pending background transition and prepare PiP resources; it must not commit irreversible engine state changes until background entry is confirmed or a short timeout elapses.
- Wrap all background transition work (PiP activation, encoder reconfiguration, audio session changes) in `UIApplication.shared.beginBackgroundTask(expirationHandler:)`. The expiration handler **must forcefully close the network socket (TCP RST / close file descriptor) immediately** to ensure immediate return. Do not attempt a graceful RTMP handshake shutdown in the expiration handler, as network blocking here will cause a watchdog kill (`0x8badf00d`), corrupting any local recordings.
- Verify PiP activation via `AVPictureInPictureControllerDelegate.pictureInPictureControllerDidStartPictureInPicture` within 500 ms. If the delegate callback is not received, **or if video sample buffers stop arriving while backgrounded**, immediately transition to **audio-only mode** (Audio Background fallback) and log a `PiP activation failure` metric. Do not assume PiP will always sustain the camera; iOS may deprioritize capture in future versions.
- PiP may keep the `AVCaptureSession` alive and the camera accessible for some devices and OS versions, but the app must treat camera loss while PiP is visible as a normal operating condition rather than a contract violation.
- If the user dismisses PiP while backgrounded, iOS interrupts the capture session (see SL-06).
- **`MTHKView` rendering must be paused** (set `isPaused = true` or remove from the render tree) when PiP is active and the app is not in the foreground. Rendering both `MTHKView` and `AVSampleBufferDisplayLayer` simultaneously is GPU-wasteful and can push Tier 1/Tier 2 devices to `.serious` thermal state within minutes. **On Tier 1 devices (A10/A11), strict "Low Power Mode" is enforced:** disable `MTHKView` completely and unbind Metal context when PiP is active or thermal state is `.fair` or higher. Resume `MTHKView` rendering on foreground return **before** deactivating PiP, to avoid a black-frame flash.
- On `UIApplication.willEnterForegroundNotification` / foreground return, deactivate PiP and restore the full-screen preview.

**Audio Background Mode:**
- Declare `UIBackgroundModes: audio` in `Info.plist`.
- The `AVAudioSession` with `.playAndRecord` category keeps the app alive for audio capture even when PiP is not active.
- This enables audio-only streaming to survive backgrounding.

**Constraints:**
- PiP requires the app to have an active `AVAudioSession`. If the audio session is interrupted (e.g., incoming call), PiP may also be dismissed. **This is a causal chain, not two independent events** — see SL-08 for the full audio-interruption → PiP-dismissed → camera-interrupted recovery sequence.
- The app must not assume the camera is always available in the background. All camera access must be gated on `AVCaptureSession.isRunning`.
- If the user has disabled PiP in iOS Settings, the app falls back to audio-only background streaming.

### 7.2 App ↔ StreamingEngine Relationship

- `StreamViewModel` holds a reference to the `StreamingEngine` singleton.
- The engine exposes authoritative state via `@Published var sessionSnapshot: StreamSessionSnapshot` and `@Published var streamStats: StreamStats` (Combine publishers).
- On app foreground return after background streaming, the ViewModel reads current state and restores the preview surface.
- If the app is terminated by iOS while streaming, the stream stops (no surviving service on iOS). On next launch, the app starts in `idle` state with a notification informing the user the session ended.

### 7.3 App Termination Recovery

- If the app is terminated by iOS (memory pressure, user swipe-kill, watchdog), the stream stops immediately.
- On next launch, the app starts in `idle` state. No automatic stream resumption occurs.
- **Dead-man’s-switch notification:** On stream start, schedule a local notification via `UNUserNotificationCenter` (e.g., "StreamCaster session may have ended unexpectedly") to fire ~5 minutes after the last heartbeat timestamp. Update the notification’s fire date on each successful stats update (heartbeat). Cancel the notification on clean stream stop. This ensures the user is informed even if the app is terminated by jetsam while backgrounded (the app cannot schedule a notification retroactively after termination).
- If a local recording was in progress, `AVAssetWriter` finalization may not complete. **Orphaned file definition:** a `.mov` or `.mp4` file in the recording directory whose `AVAssetWriter` was not finalized (detectable by the absence of a complete moov atom, or by checking for a `.tmp`/`.inProgress` sentinel file written at recording start and deleted on finalization). On detection, show file size and last-modified date. Offer **"Delete"** (default) and **"Keep as-is"** (for users who want to attempt external recovery via `ffmpeg`). Do not offer in-app recovery — incomplete moov atoms are generally unrecoverable by standard iOS APIs, and the option creates a false expectation.
- State restoration for UI settings (selected camera, resolution, etc.) is handled via `@AppStorage` / `UserDefaults`. No stream state is persisted across app terminations.

### 7.4 Lock Screen / Control Center Controls

- Stream status displayed via `MPNowPlayingInfoCenter.default().nowPlayingInfo` — shows stream title ("StreamCaster Live"), elapsed duration, and connection state.
- **`pauseCommand` maps to mute/unmute audio** (not stop-stream), preventing accidental broadcast termination from AirPod removal, Bluetooth button press, Siri commands, or CarPlay. **`stopCommand`** maps to stop-stream.
- `togglePlayPauseCommand` maps to mute/unmute with 500 ms debouncing.
- A stop action must immediately cancel any pending reconnect attempts and transition to stopped state.

---

## 8. Media Pipeline Requirements

### 8.1 Encoder Initialization

- Before starting a stream, validate the chosen resolution and frame rate against `AVCaptureDevice.Format` properties (`formatDescription`, `videoSupportedFrameRateRanges`). If the device cannot support the requested configuration, fail fast with an actionable error message and suggest a supported configuration.
- **`AVCaptureDevice.formats` filtering alone is insufficient for encoder compatibility.** Camera sensor capability does not guarantee sustained encoder throughput (e.g., iPhone 8/A11 sensor supports 4K capture, but sustained 4K H.264 encoding via VideoToolbox causes immediate frame drops). Implement a pre-flight encoder validation: create a temporary `VTCompressionSession` with the desired resolution+fps+bitrate, encode ~10 test frames, and verify the actual output rate matches the configured rate. Cache results by device model identifier (`utsname.machine`) to avoid repeating. **This validation must run asynchronously** (e.g., when the user selects a resolution in Settings, or lazily during the preview phase) and must **never block the "Start Stream" action**. If validation is missing for the current setting, warn the user but allow streaming to proceed.
- Pre-flight validation is advisory only. It must not be described in UI or logs as proof of sustained real-world compatibility because it does not model long-running thermal load, PiP, local recording, or network contention.
- Pre-flight: configure `RTMPStream` with the chosen parameters and verify VideoToolbox encoder creation succeeds before connecting to the RTMP endpoint. HaishinKit reports encoder errors via its delegate.
- During streaming, monitor the actual encoded output frame rate. If measured output fps falls below 80% of configured fps for more than 5 consecutive seconds, treat this as a backpressure event and trigger the ABR step-down path.

### 8.2 ABR Ladder

- Define a per-device quality ladder based on camera and encoder capabilities, e.g.:
  - **1080p30 → 720p30 → 540p30 → 480p30** (resolution steps)
  - **30 fps → 24 fps → 15 fps** (frame rate steps)
  - Bitrate scales proportionally to resolution × fps.
- ABR first reduces bitrate only (via `RTMPStream.videoSettings.bitRate`). If insufficient, step down resolution/fps via controlled encoder restart.
- Prefer bitrate reduction before frame skipping.
- All quality-change requests from **both** the ABR system and the thermal throttling system (SL-07) must be serialized through a single `EncoderController` component using a Swift `actor` or `AsyncStream` with serial processing. This prevents concurrent encoder reconfiguration races.
- **The `EncoderController` must not only serialize requests but also await confirmation of each change before dequeuing the next.** HaishinKit dispatches encoder operations on its own internal serial queue; assigning `RTMPStream.videoSettings` returns before the encoder has actually reconfigured. Use HaishinKit’s delegate callbacks or poll `RTMPStream` properties to verify the encoder has settled at the new configuration. If confirmation does not arrive within 5 seconds, treat it as an encoder error (see §11 Encoder error handling).
- The 60-second thermal cooldown (SL-07) applies only to **thermal-triggered** resolution/fps changes that require an encoder restart. ABR **bitrate-only** reductions and recoveries do not require an encoder restart and bypass the cooldown entirely. ABR resolution/fps changes that do require an encoder restart are subject to the cooldown timer.

### 8.3 Encoder Restart for Quality Changes

- Resolution or frame rate changes during a live stream require a controlled re-init sequence only when the current device tier has already demonstrated that the restart can complete inside the ingest-safe budget for that endpoint. Otherwise the engine must either perform a controlled reconnect with new metadata or defer the change and continue with bitrate-only adaptation.
  Controlled live re-init sequence:
  1. Detach camera from stream.
  2. Update stream video settings (resolution, fps, bitrate).
  3. Re-attach camera with new format.
  4. Force an IDR frame.
- **Device-tier-aware restart policy:** Tier 3 (A15+): live restart permitted only when validated to complete within 2 s. Tier 2 (A12–A14): prefer bitrate-only changes; use controlled reconnect for resolution/fps changes unless endpoint-specific testing proves a < 2 s live restart. Tier 1 (A10/A11): treat resolution/fps changes as reconnect-or-defer events; do not rely on a 4–6 s live encoder restart because most RTMP servers and CDN ingest points interpret a gap >2–3 seconds as a dead stream and close the connection.
- **On Tier 1 devices, prefer bitrate-only ABR changes** (which do not require encoder restart) over resolution/fps step-downs. Resolution changes on Tier 1 should be a last resort.

### 8.4 Frame Drop Policy

- Expose a `droppedFrameCount` metric (see §14).
- Prefer bitrate reduction over frame dropping.
- If backpressure forces drops, drop non-IDR frames before keyframes.

### 8.5 Latency

- Target glass-to-glass ≤ 3 seconds on stable LTE.
- Surface current measured latency as a debug metric if it exceeds target.

---

## 9. Security and Privacy Requirements

### 9.1 Credential Storage

- Stream keys and passwords must be stored using Keychain Services with:
  - `kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — not backed up to iCloud, not transferred to new devices.
  - `kSecAttrSynchronizable: false` — not synced via iCloud Keychain.
- The app must never fall back to plaintext storage (UserDefaults, plist files, files on disk) under any circumstance.
- The `StreamingEngine` must never receive stream keys or RTMP URLs with embedded credentials via any public API parameter. The engine receives only a non-sensitive profile ID (`String`); it retrieves credentials directly from `EndpointProfileRepository` at runtime. This prevents key exfiltration via debugging tools or crash report captures.
- **Active-session credential handling:** once a stream starts successfully, the engine may retain the minimum secret material needed for that active publish session in process memory only for the lifetime of that session so reconnects can proceed while the device is locked. It must not re-query Keychain while the device is locked. The in-memory copy must be zeroed and discarded immediately on final stop, app termination, or profile switch.
- **URL-embedded stream key extraction:** Many streaming platforms provide URLs in the format `rtmp://host/app/sk_live_secret` with the stream key embedded in the URL path. When the user enters or pastes an RTMP URL, the `EndpointProfileRepository` must parse the URL at input time: extract the path segment after the second component (the "app" name) as the stream key and store it separately in the Keychain. Display the sanitized base URL (`rtmp://host/app/`) back to the user for confirmation. Also detect and extract keys from query parameters (e.g., `?key=abc`). The sanitized base URL (without key) is the only form stored in the endpoint profile’s URL field.
- Input sanitization must use canonical URL parsing rather than regex alone: strip `userinfo`, percent-decode before scanning, reject malformed hosts, and normalize the stored base URL to host + application path only. Regex-based redaction remains a secondary safety net for logging and crash reporting, not the primary extraction mechanism.
- When the app is installed on a new device, Keychain items with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` are not transferred. The app must detect missing credentials and display a prompt informing the user that credentials must be re-entered.
- **Sideload security acknowledgment:** Sideloaded builds signed with a free Apple Developer account have the `get-task-allow` entitlement, which enables debugger attachment. Stream keys held in process memory are accessible via `lldb` on sideloaded builds. App Store builds use hardened runtime (default for distribution signing) and do not have this exposure. This trade-off must be documented in the app’s sideloading instructions.

### 9.2 Transport Security

- If a profile includes authentication (username/password), a stream key, a bearer token, or any other secret, the app must enforce RTMPS and **must hard-reject `rtmp://`** for that attempt.
- Plain `rtmp://` is permitted only for anonymous endpoints that do not require a stream key, password, bearer token, or credential-bearing query parameter.
- The connection test button must obey the same transport rules: it must not send credentials or secret-bearing publish attempts over plaintext RTMP under any circumstance.
- RTMPS must use iOS system TLS via `Network.framework` / `URLSession`. No custom `SecTrustEvaluate` overrides. No `NSAllowsArbitraryLoads` or `NSExceptionDomains` in `Info.plist` for RTMP endpoints. Users needing self-signed certs must install them via iOS Settings → General → Profile **and then enable full trust in Settings → General → About → Certificate Trust Settings** (two-step process required on iOS 15+). The app’s help screen and TLS error messages must document both steps. On TLS verification failure, surface an actionable error explaining the two-step cert trust process.

### 9.3 Logging and Crash Reports

- The app must never log RTMP URLs containing stream keys, auth headers, passwords, or tokens in any log level.
- **Strict Type Safety for Secrets:** Define a wrapper type `struct Redacted<T>: CustomStringConvertible, CustomDebugStringConvertible` that wraps all sensitive strings (stream keys, passwords). Its `description` and `debugDescription` must return `"****"`. The raw value is accessible only via an explicit `.unmaskedValue` property, used *only* at the precise moment of injection into the URL/handshake. This prevents accidental exposure via `os.Logger` interpolation or string debugging.
- All sensitive fields must be masked in logs and metrics (e.g., `rtmp://host/app/****`).
- KSCrash crash reports must:
  - Exclude or redact RTMP URLs, stream keys, and auth fields from all report data.
  - Use a custom `KSCrashReportFilter` that applies URL-sanitization to all string-valued fields before any field is serialized: replace key path segments using the pattern `rtmp[s]?://([^/\s]+/[^/\s]+)/\S+` → `rtmp[s]://<host>/<app>/****`. **Also match query-parameter patterns** (e.g., `[?&](key|token|secret|sk)=[^&\s]+` → `$1=****`) and stream keys embedded in deeper path segments.
  - Apply the credential sanitizer not just to crash reports but to **all string serialization paths**: HaishinKit debug delegate output, `NWPathMonitor` descriptions, and `os.Logger` interpolations.
  - Include a unit test verifying that a synthetic crash report containing a known stream key string (in URL path, query parameter, and standalone field positions) produces zero occurrences of that string after the sanitization pass.
  - Send reports only to user-configured endpoints. Transport must enforce **HTTPS**. **Plain `http://` endpoints must be hard-rejected** — there is no legitimate use case for sending crash reports (which may contain memory dumps, stack traces with string literals, and post-sanitization artifacts) over plaintext HTTP. If local-network testing is required, restrict HTTP to RFC 1918 addresses only (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`).
### 9.3.5 App Switcher Privacy

- **Security Curtain:** When `sceneWillResignActive` fires, the app must immediately overlay a sensitive content protection view (blur effect or solid color logo view) covering the entire window. This prevents iOS from capturing a snapshot of the camera preview (potentially showing private surroundings) or visible stream keys in the App Switcher. Remove the curtain on `sceneDidBecomeActive`.

### 9.4 Permissions

| Permission | When Requested | Required For |
|---|---|---|
| Camera (`NSCameraUsageDescription`) | Stream start (video modes) | Video capture |
| Microphone (`NSMicrophoneUsageDescription`) | Stream start (audio modes) | Audio capture |
| Photo Library Add (`NSPhotoLibraryAddUsageDescription`) | First recording to Photos Library | Saving MP4 recordings |
| Local Network (`NSLocalNetworkUsageDescription`) | First RTMP connection to local network | Local RTMP server connectivity (iOS 14+). **Description text must be generic** (e.g., "StreamCaster needs local network access to connect to streaming servers on your network") — do not mention RTMP, stream keys, or broadcasting specifically. |

> **Note:** iOS does not require explicit notification permissions for background audio or PiP. Local notifications (for session-ended alerts) require `UNUserNotificationCenter.requestAuthorization()`.

### 9.5 Permissions Flow

```
App Launch
  │
  └─ User taps "Start Stream"
       │
       ├─ Video enabled? → Check Camera permission (AVCaptureDevice.requestAccess)
       │     └─ Denied? → Show rationale → Open Settings or disable video
       │
       ├─ Audio enabled? → Check Microphone permission (AVCaptureDevice.requestAccess)
       │     └─ Denied? → Show rationale → Open Settings or disable audio
       │
       └─ All required permissions granted → Configure AVAudioSession → Connect RTMP
```

### 9.6 Background Capture

- Camera access in the background is only possible while PiP is active. When PiP is dismissed, `AVCaptureSession` is interrupted.
- The microphone is accessible in the background via `UIBackgroundModes: audio`.
- iOS displays camera/microphone indicators automatically (green/orange dot in status bar).
- No audio or video capture may occur without proper `AVAudioSession` configuration and user permission.

---

## 10. Screen Map & UI

### 10.1 Screens

| Screen | Description |
|---|---|
| **Main / Stream** | Camera preview (full-screen), start/stop button, mute button, camera-switch button, stream status badge, recording indicator. Minimal HUD overlay showing: bitrate, FPS, duration, connection status. |
| **Endpoint Setup** | RTMP(S) URL field, stream key field, optional username/password, "Test Connection" button, "Save as Default" toggle, saved profiles list. |
| **Video/Audio Settings** | Resolution picker (filtered by device), frame rate picker, video bitrate slider, audio bitrate picker, mono/stereo toggle, ABR enable/disable, keyframe interval, local recording toggle + destination picker. |
| **General Settings** | Default camera (front/back), orientation mode (landscape default, explicit portrait toggle), auto-reconnect toggle + retry settings, battery threshold, media stream selection (video+audio / video-only / audio-only). |

### 10.2 Navigation

```
Main (Stream) ──┬── Endpoint Setup
                ├── Video/Audio Settings
                └── General Settings
```

Single-window SwiftUI app with `NavigationView` on all supported iOS versions (iOS 15–18). Although `NavigationView` is deprecated in iOS 16, it provides a single consistent navigation API across the deployment range. Using `NavigationStack` (iOS 16+) with an iOS 15 `NavigationView` fallback doubles the navigation testing surface for minimal gain and introduces behavioral divergence in programmatic navigation. **Do not use `NavigationStack`** unless the minimum deployment target is raised to iOS 16.

### 10.3 Stream Screen HUD Layout

Since landscape is the primary UX (see §19 Decision 9), the landscape layout is the normative reference. Portrait is a secondary option explicitly toggled by the user.

#### Landscape (Default)

```
┌──────────────────────────────────────────────────┐
│ ● LIVE  00:12:34   ⇕ 2.4 Mbps  30fps  720p   🔴 REC │  ← status bar
│                                          ┌────────┐ │
│                                          │[🔇 Mute]│ │
│         [Camera Preview]                │[⏺ START]│ │
│     (fills width, 16:9 aspect ratio)    │[🔄 Cam ]│ │
│                                          └────────┘ │
└──────────────────────────────────────────────────┘
```

Controls are at the right edge in landscape to remain within thumb reach. All UI elements must respect safe areas (`safeAreaInsets`) to avoid occlusion by the Dynamic Island, notch, or home indicator.

#### Portrait (User-Toggled)
```
┌──────────────────────────────────────┐
│ ● LIVE  00:12:34        🔴 REC      │  ← status bar
│                                      │
│                                      │
│         [Camera Preview]             │
│                                      │
│                                      │
│  ↕ 2.4 Mbps   30fps   720p          │  ← stats bar
├──────────────────────────────────────┤
│  [🔇 Mute]  [⏺ START]  [🔄 Cam]    │  ← controls
└──────────────────────────────────────┘
```

---

## 11. Reliability and Failure Handling

| Scenario | Behavior |
|---|---|
| **Network drop** | Pause send. Reconnect with exponential backoff + jitter (3 s, 6 s, 12 s, …, cap 60 s). Show "Reconnecting…" badge. Resume on success. NWPathMonitor drives immediate retry on `path.status == .satisfied`. |
| **RTMP auth failure** | Stop stream, show error with option to edit credentials. |
| **Encoder error** | Attempt one re-init. If it fails, stop stream and show explicit error identifying the failure cause. |
| **Camera unavailable** | Try alternate camera. If none available, offer audio-only mode. |
| **Camera interrupted (background/PiP dismissed)** | Cleanly stop video track. Keep audio-only RTMP session alive (or stop gracefully if video-only mode). On return to foreground: re-acquire camera, re-init video encoder, send IDR to resume video. |
| **Microphone interrupted mid-stream** | **Behavior depends on stream mode.** If **audio-only mode**: stop stream entirely and surface an error (there is nothing left to send; `StopReason.errorAudio`). If **video+audio mode**: mute the audio track and continue video streaming; show muted indicator. After interruption recovery, audio remains muted until the user explicitly unmutes. See SL-08 for recovery sequence. |
| **Thermal throttle** | On `.fair`: warn user via HUD badge. On `.serious`: step down ABR ladder with controlled encoder restart if needed (minimum 60 s between steps). On `.critical`: stop stream and recording gracefully, display reason to user. |
| **App terminated by iOS** | Stream stops. On next launch, display a local notification or in-app message indicating the session ended. No automatic stream resumption. |
| **Low battery** | Below configured threshold: show warning. Below critical (≤ 2%): auto-stop stream and finalize local recording. |
| **Prolonged session** | On older devices (identified by `ProcessInfo.processInfo.physicalMemory < 3 GB`), app monitors session duration. After a configurable default of 90 minutes, show a notification recommending stopping to prevent heat/battery risk. Suppressed if `UIDevice.current.batteryState == .charging`. |
| **Insufficient storage** | Stop recording, continue streaming, notify user. |
| **Audio session interruption / incoming call** | **Causal chain:** audio interruption → PiP dismissed → camera interrupted (see SL-08). In video+audio mode: mute audio, continue video. In audio-only mode: stop stream. Resume audio only on explicit user action (unmute button). |
| **Memory pressure** | Register `DispatchSource.makeMemoryPressureSource`. On `.warning` or `.critical`: stop local recording (but not streaming), notify user. See MC-05. |

---

## 12. Observability and Diagnostics

### 12.1 Metrics (non-PII)

The following metrics must be tracked internally for HUD display and debug diagnostics. They must not contain PII or credentials.

- Current and target bitrate (video/audio).
- Current fps and dropped frame count.
- Encoder init success/failure count.
- Reconnect attempt count and success/failure ratio.
- Thermal level transitions.
- Storage write errors.
- PiP activation success/failure events.
- Permission denial events.

### 12.2 HUD

The streaming HUD must display: live bitrate, fps, resolution, session duration, connection state (live/reconnecting/stopped), recording state (on/off), and a thermal warning badge when quality has been degraded.

### 12.3 Debug Logging

- Structured logging via `os.Logger` (Unified Logging) only in debug builds.
- All secrets must be redacted in every log level (debug and release). Use `os.Logger` privacy annotations: `.private` for sensitive values.
- **HaishinKit internal logging control:** HaishinKit uses `os.Logger` or `print()` internally for connection diagnostics and will log full RTMP URLs (including embedded stream keys) if not suppressed. Set HaishinKit’s logger configuration (`LBLogger.with(id:)`) to `.off` for release builds and `.error`-only for debug builds. This is a **build-time requirement**. Add an integration test that connects with a known stream key and verifies zero occurrences of the key in captured `os_log` output.
- Production logs must be minimal and rate-limited.

### 12.4 Health Checks

- The connection test feature should default to a lightweight transport probe (e.g., RTMP handshake only) and label the result accordingly.
- If the product later adds a true publish validation mode, it must be presented as a separate authenticated probe with the same transport-security rules as live streaming.
- Timeouts for connection test must be capped (default: 10 seconds).
- Test result must be surfaced to the user with actionable messaging (success, timeout, auth failure, TLS error).

---

## 13. Build & Project Structure

```
StreamCaster/
├── StreamCaster.xcodeproj/
│   ├── project.pbxproj
│   └── xcshareddata/
│       └── xcschemes/
│           ├── StreamCaster.xcscheme
│           └── StreamCaster-Sideload.xcscheme
├── StreamCaster/
│   ├── App/
│   │   ├── StreamCasterApp.swift                // @main App entry
│   │   └── AppDelegate.swift                    // UIKit lifecycle hooks
│   ├── Views/
│   │   ├── Stream/
│   │   │   ├── StreamView.swift
│   │   │   └── StreamHudView.swift
│   │   ├── Settings/
│   │   │   ├── EndpointSettingsView.swift
│   │   │   ├── VideoAudioSettingsView.swift
│   │   │   └── GeneralSettingsView.swift
│   │   └── Components/
│   │       ├── CameraPreviewView.swift          // UIViewRepresentable wrapper
│   │       ├── PermissionHandler.swift
│   │       └── TransportSecurityAlert.swift
│   ├── ViewModels/
│   │   ├── StreamViewModel.swift
│   │   └── SettingsViewModel.swift
│   ├── Services/
│   │   ├── StreamingEngine.swift                // Singleton: owns RTMPStream
│   │   ├── ConnectionManager.swift
│   │   ├── EncoderController.swift
│   │   ├── PiPManager.swift
│   │   ├── NowPlayingController.swift
│   │   ├── AbrPolicy.swift
│   │   └── AbrLadder.swift
│   ├── Camera/
│   │   └── DeviceCapabilityQuery.swift
│   ├── Audio/
│   │   └── AudioSessionManager.swift
│   ├── Thermal/
│   │   └── ThermalMonitor.swift
│   ├── Overlay/
│   │   ├── OverlayManager.swift                 // Protocol
│   │   └── NoOpOverlayManager.swift
│   ├── Data/
│   │   ├── SettingsRepository.swift
│   │   ├── EndpointProfileRepository.swift
│   │   ├── MetricsCollector.swift
│   │   └── Models/
│   │       ├── StreamSessionSnapshot.swift
│   │       ├── TransportState.swift
│   │       ├── StreamConfig.swift
│   │       ├── EndpointProfile.swift
│   │       ├── StreamStats.swift
│   │       └── StopReason.swift
│   ├── Crash/
│   │   ├── CrashReportConfigurator.swift
│   │   └── CredentialSanitizer.swift
│   ├── Utilities/
│   │   └── RedactingLogger.swift
│   ├── Resources/
│   │   ├── Info.plist
│   │   ├── Assets.xcassets/
│   │   └── StreamCaster.entitlements
│   └── SupportingFiles/
│       └── Localizable.strings
├── StreamCasterTests/                            // Unit tests
├── StreamCasterUITests/                          // UI tests
└── Package.swift                                 // SPM dependency declaration (or via Xcode)
```

---

## 14. Dependencies (Swift Package Manager)

```swift
// Package.swift or Xcode SPM integration
dependencies: [
    .package(url: "https://github.com/shogo4405/HaishinKit.swift.git", from: "2.0.0"),
    .package(url: "https://github.com/kstenerud/KSCrash.git", from: "2.0.0"),
]
```

| Library | Purpose | License |
|---|---|---|
| **HaishinKit.swift** | RTMP/RTMPS streaming, camera capture, encoding | BSD 3-Clause |
| **KSCrash** | Crash reporting with custom HTTP transport | MIT |

> **Note:** No additional camera, Keychain, or networking libraries are needed. iOS platform frameworks (`AVFoundation`, `Security`, `Network`, `MediaPlayer`, `Photos`) cover all requirements natively.

---

## 15. Testing Strategy

| Layer | Approach |
|---|---|
| **ViewModel** | XCTest + Combine testing (`expectation`, `sink`). Mock repositories and engine. |
| **Repository** | XCTest for UserDefaults and Keychain tests. |
| **ConnectionManager** | Unit test reconnection logic, backoff timing, jitter, NWPathMonitor integration. |
| **DeviceCapabilityQuery** | UI tests on real devices (oldest supported iPhone + latest). |
| **Streaming E2E** | Manual test matrix: 3 devices (iPhone 8 iOS 15, iPhone 12 iOS 17, iPhone 15 iOS 18) × (RTMP, RTMPS) × (video+audio, video-only, audio-only). |
| **Lifecycle** | UI tests for app backgrounding with PiP, foreground return, audio session interruption. |
| **UI** | SwiftUI preview tests + XCUITest for navigation, control states. |

---

## 16. Release & Signing

- **Debug builds:** Auto-signed with Xcode-managed development provisioning profile.
- **Release builds:** Signed with App Store distribution certificate and provisioning profile. Managed via Xcode or `fastlane`.
- **App Store:** `.ipa` via App Store Connect. App thinning (bitcode where supported, App Slicing for device-specific assets).
- **Sideload / AltStore:** Ad-hoc or Development signed `.ipa`. Re-signing instructions provided for AltStore users.
- **TestFlight:** Same App Store certificate, distributed via TestFlight for beta testing.

### 16.1 Build Configurations

| Configuration | App Store | TestFlight | Sideload | Notes |
|---|---|---|---|---|
| Debug | No | No | Yes (dev profile) | Development signing |
| Release | Yes | Yes | Yes (ad-hoc) | Distribution signing |

> **Note:** Unlike Android's `foss`/`gms` flavors, iOS does not have a Google Play Services dependency to exclude. Both distribution paths use the same codebase. Xcode schemes can differentiate build settings if needed (e.g., `StreamCaster` for App Store, `StreamCaster-Sideload` for ad-hoc distribution with different bundle ID suffix for side-by-side installs).

---

## 17. Phased Implementation Plan

### Phase 1 — Core Streaming (MVP)
- [ ] Project scaffolding (Xcode project, SPM, SwiftUI App, entitlements)
- [ ] Camera preview via HaishinKit `MTHKView` (back camera default)
- [ ] Basic RTMP streaming (video + audio) via HaishinKit
- [ ] Start / stop controls
- [ ] Single RTMP endpoint input (URL + stream key) with embedded-key extraction (§9.1)
- [ ] Background audio mode + PiP for best-effort background continuity, **including PiP lifecycle edge cases**: activation failure detection, dismissed-while-backgrounded handling (SL-06), `beginBackgroundTask` protection, `MTHKView` pause/resume, audio interruption → PiP → camera causal chain recovery (SL-08). **PiP is not shippable without its failure recovery paths, and the UI/help text must describe background video as best-effort rather than guaranteed.**
- [ ] Runtime permissions handling (Camera, Microphone)
- [ ] StreamingEngine singleton with coordinator-owned lifecycle state and published `StreamSessionSnapshot` updates on `@MainActor`
- [ ] Dead-man’s-switch local notification for background termination (§7.3)

### Phase 2 — Settings & Configuration
- [ ] Video settings screen (resolution, FPS, bitrate, keyframe interval — all filtered by AVCaptureDevice.formats)
- [ ] Audio settings screen (bitrate, sample rate, channels)
- [ ] Camera switching (front ↔ back)
- [ ] Stream mode selection (video+audio / video-only / audio-only)
- [ ] Orientation lock (portrait / landscape)
- [ ] Keychain credential storage
- [ ] Save default endpoint; endpoint profiles

### Phase 3 — Resilience & Polish
- [ ] RTMPS (TLS) support with transport security enforcement (§9.2)
- [ ] Username/password authentication (with RTMPS-only enforcement)
- [ ] Adaptive bitrate with device-capability ABR ladder
- [ ] Auto-reconnect with exponential backoff + jitter
- [ ] Connection test button / transport probe (obeys transport rules and labels handshake-only results correctly)
- [ ] Streaming HUD (bitrate, FPS, duration, status, thermal badge)
- [ ] Mute toggle
- [ ] Low battery handling
- [ ] Audio session interruption handling (SL-08)
- [ ] Thermal throttling response with cooldown (SL-07)

### Phase 4 — Local Recording & Extras
- [ ] Local MP4 recording (Photos Library or Documents directory) with memory pressure observer (MC-05), **only if the single-encoder feasibility gate passes; otherwise defer from launch**
- [ ] Lock Screen / Control Center controls (MPRemoteCommandCenter) with pause→mute mapping (SL-04)
- [ ] KSCrash crash reporting with credential redaction (expanded regex, HaishinKit log suppression)
- [ ] App termination recovery (orphaned recording cleanup with sentinel files, session-ended message)

### Phase 5 — Future (Deferred)
- [ ] Overlay pipeline implementation (text, timestamps, watermarks)
- [ ] H.265 streaming option
- [ ] Multi-destination streaming
- [ ] Stream scheduling
- [ ] SRT protocol option

---

## 18. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| HaishinKit API breaking changes | Build failure | Pin to specific version; monitor releases. |
| HaishinKit camera quirks on older iPhones | Black preview, crashes | Use `DeviceCapabilityQuery` to validate before selecting resolution/fps. Test on diversified device set. File upstream issues. |
| RTMPS certificate validation failures | Cannot connect to some endpoints | Strictly enforce system TLS. No custom `SecTrustEvaluate`. Users needing self-signed certs install them via iOS Settings → Profile. Document in help screen. |
| iOS kills app during background streaming | Stream drops | PiP + audio background mode provides best-effort background. If PiP dismissed, fall back to audio-only. Inform user about PiP requirement for background video. |
| App size exceeds 15 MB | User drop-off | HaishinKit is Swift-native with no large native binaries. Use App Slicing. |
| Thermal throttling causes frame drops | Stuttering stream | Monitor `ProcessInfo.ThermalState`. Progressive degradation with 60s cooldown. |
| PiP not available on all devices / user-disabled | No background video | Fall back to audio-only. Show one-time guidance to enable PiP in Settings. |
| Encoder does not support requested config | Silent failure on stream start | Pre-flight validate against `AVCaptureDevice.formats` before connecting. Fail fast with actionable suggestion. |
| Concurrent ABR + thermal encoder restart | Crash from encoder reconfiguration race | All quality-change requests serialized through `EncoderController` Swift `actor`. `EncoderController` must await confirmation from HaishinKit before dequeuing next request. See §8.2. |
| Stream key exfiltration via debug tools | Credentials visible in memory dump | Engine receives only profile ID; credentials fetched internally from `EndpointProfileRepository`. Sideload builds with `get-task-allow` are inherently debuggable — documented in sideloading instructions. See §9.1. |
| Stream key leakage via embedded URLs | Credentials in logs, crash reports, HaishinKit output | Parse and extract stream keys from user-pasted URLs at input time. Store only sanitized base URL in endpoint profile. See §9.1. |
| HaishinKit internal logging leaks credentials | Stream keys visible in `os_log` and `sysdiagnose` | Suppress HaishinKit logging in release builds (`LBLogger.with(id:)` → `.off`). See §12.3. |
| PiP activation failure (silent) | Background video streaming silently dies | Verify PiP activation via delegate within 500 ms; fall back to audio-only on failure. Begin activation in `.willResignActive` not `.background`. See §7.1. |
| Background transition interrupted by OS suspension | Inconsistent state in `StreamingEngine` | Wrap all background work in `beginBackgroundTask`. See §7.1. |
| Encoder restart exceeds RTMP timeout on older devices | RTMP server disconnects during quality change | Device-tier-aware restart timeouts; fall back to audio-only if timeout exceeded. See §8.3. |
| Thermal oscillation loop | Rapid quality cycling degrades stream | Progressive restoration backoff (60 s, 120 s, 300 s). Block configurations that re-trigger thermal events within the backoff window. See SL-07. |
| Keychain items lost on device transfer | Credentials silently lost on new device | Use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; prompt user to re-enter on new device. See §9.1. |
| App Store rejection for inadequate privacy descriptions | Distribution blocked | Provide thorough `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, `NSPhotoLibraryAddUsageDescription` in Info.plist. |
| EU DMA sideloading requires notarization | Cannot distribute outside App Store | Prepare notarization-ready build for EU alternative marketplace compliance (iOS 17.4+). |

---

## 19. Resolved Decisions

| # | Question | Decision |
|---|---|---|
| 1 | App name & bundle ID | **StreamCaster** / `com.port80.app` |
| 2 | Icon / branding | Minimal geometric: camera lens + broadcast signal arcs. Primary: #E53935 (red), Accent: #1E88E5 (blue), Dark surface: #121212. |
| 3 | Distribution | **All:** App Store (`.ipa`), TestFlight (beta), sideload (AltStore / direct IPA / EU DMA alternative marketplace). |
| 4 | Monetization | **Free.** No ads, no in-app purchases. |
| 5 | Crash reporting | **KSCrash** (open-source, MIT license). Reports via HTTP to self-hosted endpoint. No third-party tracking. Credential redaction required. |
| 6 | Min deployment target | **iOS 15.0**. Required for sample-buffer PiP, async/await, structured concurrency. Covers ~98% of active iOS devices. |
| 7 | Camera framework | **HaishinKit `RTMPStream` exclusively.** No separate `AVCaptureSession`. |
| 8 | Transport security default | **RTMPS enforced whenever auth, stream keys, or tokens are present.** Anonymous plaintext RTMP is allowed only for endpoints with no secrets. Self-signed certs require iOS two-step trust process (install profile + enable in Certificate Trust Settings). |
| 9 | Orientation support | **Landscape first.** UX relies on landscape as primary, providing an option for portrait that the user must explicitly toggle. |
| 10 | Session duration limit | **Recommendation-based.** On older devices, app monitors session duration and issues a notification recommending stopping, unless connected to power. |
| 11 | Background streaming | **Best-effort PiP for temporary background video continuity** + **audio background mode** for audio-only. PiP dismissed or camera starvation = camera interrupted, fall back to audio-only or stop. PiP lifecycle edge cases are Phase 1 scope. |
| 12 | Local recording destination | **Both Photos Library and Documents directory**, user selectable via toggle. |
| 13 | Navigation API | **`NavigationView`** on all iOS versions (15–18). `NavigationStack` deferred until min deployment is raised to iOS 16. |
| 14 | Lock screen play/pause behavior | **`pauseCommand` maps to mute-audio, not stop-stream.** `stopCommand` maps to stop-stream. After interruption recovery, audio remains muted until explicit user action. Prevents accidental broadcast termination from AirPod removal, Bluetooth, Siri, or CarPlay events. |
| 15 | Crash report transport | **HTTPS only.** Plain HTTP hard-rejected (RFC 1918 exception for local-network testing). |

---

## 20. Acceptance Criteria

The following criteria are testable conditions that must pass before the corresponding feature is considered complete.

| # | Criterion |
|---|---|
| AC-01 | When app enters background during an active video stream, the engine either (a) activates PiP and continues receiving camera frames, or (b) degrades to audio-only / stops within the defined fallback window without entering a stuck or falsely-"live" state. |
| AC-02 | Auto-reconnect fires correctly: NWPathMonitor `.satisfied` triggers immediate retry; backoff sequence follows 3, 6, 12, …, 60s cap with jitter. |
| AC-03 | Switching from 720p30 to 480p15 on `ProcessInfo.ThermalState.serious` does not crash. The engine either completes a validated ingest-safe live restart (Tier 3 only, ≤ 2 s) or uses the specified fallback path (bitrate-only adaptation, controlled reconnect, or audio-only fallback) without state desynchronization. |
| AC-04 | Credentials are stored in Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. No plaintext storage exists (UserDefaults, plist, files). |
| AC-05 | Lock Screen **stop** action (via `MPRemoteCommandCenter.stopCommand`) cancels in-flight reconnect and leaves stream stopped. Lock Screen **pause** action mutes audio without stopping the stream. |
| AC-06 | Connection test with auth, stream key, or token over `rtmp://` is hard-rejected before transmission. Anonymous `rtmp://` transport probes remain allowed and are labeled as transport-only validation. |
| AC-07 | KSCrash crash reports do not contain stream keys, passwords, or auth headers in any report field. |
| AC-08 | After PiP dismissal while backgrounded, returning to foreground re-acquires camera, restores preview, and reflects live stats within 2 seconds. |
| AC-09 | If iOS terminates the app during streaming, the next launch shows a session-ended message. No silent stream resumption occurs. |
| AC-10 | Local recording to Photos Library succeeds on first attempt after granting permission. If permission denied, recording fails fast; streaming is not blocked. |
| AC-11 | On incoming phone call, the app mutes the microphone, correlates the interruption/PiP/camera event chain as one compound suspension event, and displays a muted indicator. Audio resumes only on explicit user unmute. |
| AC-12 | Camera interruption in background (PiP dismissed) switches to audio-only. Returning to foreground re-acquires camera and resumes video with an IDR frame. |
| AC-13 | The StreamingEngine receives only a non-sensitive profile ID. No stream key or auth credential appears as a parameter in any public API surface or at any log level. |
| AC-14 | Keychain items use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. On a new device, missing credentials trigger a re-entry prompt rather than crashing. |
| AC-15 | KSCrash release-build crash report for an active stream contains zero occurrences of a synthetic stream key string across all report fields. |
| AC-16 | Simultaneous ABR step-down and `.serious` thermal event do not crash the encoder. `EncoderController` serializes both requests and stream resumes within 3 seconds. |
| AC-17 | A `.fair` thermal state shows a HUD warning. `.critical` thermal state triggers graceful stream stop with reason displayed. |
| AC-18 | Enabling local recording presents destination picker (Photos Library or Documents). Tapping Start without granting Photos permission (if selected) leaves recording blocked and streaming unaffected. |
| AC-19 | In landscape orientation with an active stream, a device rotation gesture does not restart the stream, alter the published session snapshot incorrectly, or cause a visible flash of portrait orientation. |
| AC-20 | PiP activation failure (simulated by disabling PiP in iOS Settings) results in automatic fallback to audio-only mode or clean stop within 500 ms, with a `PiP activation failure` metric logged and no stale "video live" state exposed to the UI. |
| AC-21 | All background transition work (PiP activation, encoder reconfiguration) is wrapped in `beginBackgroundTask`. The expiration handler force-closes network resources, abandons non-essential transition work, and leaves the session in a consistent stopped or audio-only state. |
| AC-22 | A user-pasted URL containing an embedded stream key (e.g., `rtmp://host/app/sk_live_secret`) is parsed at input time: the key is extracted and stored separately in Keychain; only the sanitized base URL is stored in the profile URL field. |
| AC-23 | HaishinKit internal logging is suppressed in release builds. An integration test connecting with a known stream key produces zero occurrences of that key in captured `os_log` output. |
| AC-24 | KSCrash crash report transport rejects plain `http://` endpoints (except RFC 1918 addresses). |
| AC-25 | On Tier 1 device (A10/A11), 60 fps is not shown in the frame rate picker. |
| AC-26 | On memory pressure `.warning` during simultaneous streaming + recording, local recording stops automatically; streaming continues. |
| AC-27 | Dead-man’s-switch local notification fires if the app is terminated by jetsam during an active stream. The notification is cancelled on clean stream stop. |
| AC-28 | Audio→video upgrade mid-session triggers an RTMP reconnect (not mid-session track addition). If reconnect fails, stream remains audio-only with error surfaced. |
