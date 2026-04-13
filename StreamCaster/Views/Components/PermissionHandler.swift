// PermissionHandler.swift
// StreamCaster
//
// Handles runtime permission requests for Camera, Microphone, and Photos Library.
// iOS requires explicit user consent before accessing sensitive hardware/data.

import SwiftUI
import AVFoundation
import Photos

// MARK: - Permission Manager

/// PermissionManager keeps track of whether the user has granted access
/// to the camera, microphone, and photos library. SwiftUI views can
/// observe this object and react whenever a permission status changes.
@MainActor
class PermissionManager: ObservableObject {

    // MARK: Permission Status Enum

    /// Represents the three possible states for any single permission.
    enum PermissionStatus {
        case notDetermined  // User hasn't been asked yet
        case granted        // User said yes
        case denied         // User said no (or revoked later in Settings)
    }

    // MARK: Published Properties

    /// These @Published properties automatically notify SwiftUI views
    /// whenever their values change, causing the UI to update.
    @Published var cameraStatus: PermissionStatus = .notDetermined
    @Published var microphoneStatus: PermissionStatus = .notDetermined
    @Published var photosStatus: PermissionStatus = .notDetermined

    // MARK: Initializer

    /// When the manager is created, immediately check what permissions
    /// the user has already granted (or denied) in previous launches.
    init() {
        checkAllPermissions()
    }

    // MARK: Check All Permissions

    /// Refreshes every permission status by asking the system for the
    /// current authorization state. This does NOT trigger any prompts —
    /// it only reads the existing value.
    func checkAllPermissions() {
        checkCameraPermission()
        checkMicrophonePermission()
        checkPhotosPermission()
    }

    // MARK: Camera

    /// Reads the current camera authorization status from AVFoundation.
    private func checkCameraPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        cameraStatus = mapAVStatus(status)
    }

    /// Asks the user for camera access. The system shows a dialog the
    /// first time; after that the choice is remembered in Settings.
    func requestCameraAccess() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            // UI updates must happen on the main thread.
            DispatchQueue.main.async {
                self?.cameraStatus = granted ? .granted : .denied
            }
        }
    }

    // MARK: Microphone

    /// Reads the current microphone authorization status.
    private func checkMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        microphoneStatus = mapAVStatus(status)
    }

    /// Asks the user for microphone access.
    func requestMicrophoneAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                self?.microphoneStatus = granted ? .granted : .denied
            }
        }
    }

    // MARK: Photos Library

    /// Reads the current Photos library authorization status.
    /// We use `.addOnly` because the app only needs to save photos/videos,
    /// not read the entire library.
    private func checkPhotosPermission() {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        photosStatus = mapPHStatus(status)
    }

    /// Asks the user for Photos library write access.
    func requestPhotosAccess() {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            DispatchQueue.main.async {
                self?.photosStatus = self?.mapPHStatus(status) ?? .denied
            }
        }
    }

    // MARK: Open Settings

    /// Opens the iOS Settings page for this app so the user can change
    /// permissions they previously denied.
    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: Helpers

    /// Converts an AVFoundation authorization status into our simple enum.
    private func mapAVStatus(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }

    /// Converts a Photos framework authorization status into our simple enum.
    private func mapPHStatus(_ status: PHAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized, .limited:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }
}

// MARK: - Permission Request View

/// A full-screen view that lists each permission the app needs,
/// explains WHY it is needed, and lets the user grant access.
/// If a permission was denied, the user is guided to the Settings app.
///
/// Once the required permissions (camera + microphone) are granted,
/// the view automatically notifies its parent via `onAllRequired` so
/// the app can transition to the main streaming screen.
struct PermissionRequestView: View {

    /// The shared permission manager that tracks authorization states.
    @StateObject private var permissionManager = PermissionManager()

    /// Controls whether we show an alert telling the user to open Settings.
    @State private var showDeniedAlert = false

    /// Stores a human-readable name for the permission that was denied,
    /// so the alert message can say e.g. "Camera access was denied."
    @State private var deniedPermissionName = ""

    /// Callback invoked when the required permissions (camera + mic) are
    /// granted. The parent view uses this to transition to StreamView.
    var onAllRequired: (() -> Void)?

    /// Whether the two must-have permissions are both granted.
    /// Photos is optional (only needed for saving recordings).
    private var requiredPermissionsGranted: Bool {
        permissionManager.cameraStatus == .granted
            && permissionManager.microphoneStatus == .granted
    }

    var body: some View {
        NavigationView {
            List {
                // -- Explanatory header --
                Section {
                    Text("StreamCaster needs a few permissions to let you live-stream and save recordings.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                // -- Camera permission row --
                Section(header: Text("Camera")) {
                    PermissionRow(
                        icon: "camera.fill",
                        title: "Camera Access",
                        rationale: "Required to capture video for your live stream.",
                        status: permissionManager.cameraStatus,
                        onRequest: {
                            handleRequest(
                                currentStatus: permissionManager.cameraStatus,
                                permissionName: "Camera",
                                request: permissionManager.requestCameraAccess
                            )
                        }
                    )
                }

                // -- Microphone permission row --
                Section(header: Text("Microphone")) {
                    PermissionRow(
                        icon: "mic.fill",
                        title: "Microphone Access",
                        rationale: "Required to capture audio for your live stream.",
                        status: permissionManager.microphoneStatus,
                        onRequest: {
                            handleRequest(
                                currentStatus: permissionManager.microphoneStatus,
                                permissionName: "Microphone",
                                request: permissionManager.requestMicrophoneAccess
                            )
                        }
                    )
                }

                // -- Photos library permission row --
                Section(header: Text("Photos Library")) {
                    PermissionRow(
                        icon: "photo.fill",
                        title: "Photos Library Access",
                        rationale: "Allows saving stream recordings to your photo library.",
                        status: permissionManager.photosStatus,
                        onRequest: {
                            handleRequest(
                                currentStatus: permissionManager.photosStatus,
                                permissionName: "Photos Library",
                                request: permissionManager.requestPhotosAccess
                            )
                        }
                    )
                }

                // -- Continue button (appears when camera + mic are granted) --
                if requiredPermissionsGranted {
                    Section {
                        Button {
                            onAllRequired?()
                        } label: {
                            HStack {
                                Spacer()
                                Text("Continue to StreamCaster")
                                    .fontWeight(.semibold)
                                Image(systemName: "arrow.right.circle.fill")
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .listRowBackground(Color.clear)
                    } footer: {
                        Text("Photos Library access is optional — you can grant it later from Settings.")
                            .font(.caption2)
                    }
                }
            }
            .navigationTitle("Permissions")
            // Auto-navigate when the required permissions are granted.
            // Uses a short delay so the user sees the checkmark appear
            // before the screen transitions.
            .onChange(of: permissionManager.cameraStatus) { _ in
                autoNavigateIfReady()
            }
            .onChange(of: permissionManager.microphoneStatus) { _ in
                autoNavigateIfReady()
            }
            // Refresh statuses when the user returns from the Settings app.
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.willEnterForegroundNotification
                )
            ) { _ in
                permissionManager.checkAllPermissions()
            }
            // Alert shown when a permission has already been denied.
            .alert("Permission Denied", isPresented: $showDeniedAlert) {
                Button("Open Settings") {
                    permissionManager.openAppSettings()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("\(deniedPermissionName) access was denied. You can change this in the Settings app.")
            }
        }
    }

    // MARK: Request Helper

    /// Decides what to do when the user taps a permission button:
    /// - If not yet asked → request permission normally.
    /// - If already denied → show an alert pointing to Settings.
    /// - If already granted → do nothing (already good!).
    private func handleRequest(
        currentStatus: PermissionManager.PermissionStatus,
        permissionName: String,
        request: @escaping () -> Void
    ) {
        switch currentStatus {
        case .notDetermined:
            // First time — the system will show its own permission dialog.
            request()
        case .denied:
            // Already denied — we can't ask again; guide user to Settings.
            deniedPermissionName = permissionName
            showDeniedAlert = true
        case .granted:
            // Nothing to do; permission is already granted.
            break
        }
    }

    // MARK: Auto-Navigate

    /// Automatically transitions to StreamView after a short delay
    /// once both camera and microphone permissions are granted.
    /// The delay lets the user see the green checkmark animation.
    private func autoNavigateIfReady() {
        guard requiredPermissionsGranted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            onAllRequired?()
        }
    }
}

// MARK: - Permission Row (Reusable Sub-View)

/// A single row inside the permissions list. It shows an icon, a title,
/// a short explanation (rationale), the current status, and a button.
private struct PermissionRow: View {

    let icon: String
    let title: String
    let rationale: String
    let status: PermissionManager.PermissionStatus
    let onRequest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // -- Title and status icon --
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.headline)
                Spacer()
                statusIcon
            }

            // -- Why this permission is needed --
            Text(rationale)
                .font(.caption)
                .foregroundColor(.secondary)

            // -- Action button --
            if status != .granted {
                Button(action: onRequest) {
                    Text(buttonLabel)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(status == .denied ? .orange : .accentColor)
            }
        }
        .padding(.vertical, 4)
    }

    /// Shows a checkmark, an X, or a question mark depending on the status.
    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .denied:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
        case .notDetermined:
            Image(systemName: "questionmark.circle")
                .foregroundColor(.gray)
        }
    }

    /// The text shown on the action button.
    private var buttonLabel: String {
        switch status {
        case .notDetermined:
            return "Grant Access"
        case .denied:
            return "Open Settings"
        case .granted:
            return "" // Button is hidden when granted
        }
    }
}

// MARK: - Preview

#Preview {
    PermissionRequestView()
}
