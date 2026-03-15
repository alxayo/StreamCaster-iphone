import SwiftUI
import AVFoundation

// MARK: - CameraPreviewView
// ──────────────────────────────────────────────────────────────────
// CameraPreviewView displays the live camera feed in the SwiftUI interface.
//
// HOW IT WORKS:
// SwiftUI can't directly display UIKit views, so we use UIViewRepresentable
// to wrap a UIKit view (MTHKView from HaishinKit) and embed it in SwiftUI.
//
// MTHKView is a Metal-based view that renders the camera preview
// with hardware acceleration — this is much faster than software rendering.
//
// The "Coordinator" pattern is used to manage the view's lifecycle:
//   - makeUIView:   Creates the preview view once
//   - updateUIView: Called when SwiftUI state changes
//   - Coordinator:  Handles cleanup and prevents memory leaks
//
// IMPORTANT: We must NOT hold strong references to the UIView across
// SwiftUI redraws, as this can cause memory leaks.
//
// FALLBACK:
// When HaishinKit is not available (e.g. running in the Simulator or
// before the SDK is integrated), we show a simple placeholder view
// with a camera icon. This keeps the UI buildable during development.
// ──────────────────────────────────────────────────────────────────

struct CameraPreviewView: UIViewRepresentable {

    // MARK: - Properties

    /// Whether the preview should be actively rendering.
    /// Set to `false` when PiP is active to save GPU resources.
    let isPaused: Bool

    /// The video gravity controls how the preview fills its bounds:
    ///   - `.resizeAspectFill` = fills the view, may crop edges (default)
    ///   - `.resizeAspect`     = fits entirely, may show letterbox bars
    let videoGravity: AVLayerVideoGravity

    // MARK: - Init

    /// Create a camera preview.
    ///
    /// - Parameters:
    ///   - isPaused: Pass `true` to pause rendering (saves GPU).
    ///   - videoGravity: How the video fills the view.
    init(
        isPaused: Bool = false,
        videoGravity: AVLayerVideoGravity = .resizeAspectFill
    ) {
        self.isPaused = isPaused
        self.videoGravity = videoGravity
    }

    // MARK: - UIViewRepresentable

    /// Called once when SwiftUI first needs this view.
    /// We create the underlying UIKit view here.
    func makeUIView(context: Context) -> UIView {
        // Create a plain container view. This is what SwiftUI manages.
        let container = UIView()
        container.backgroundColor = .black

        // Create the actual preview view (Metal-based or placeholder)
        let previewView = Self.createPreviewView()

        // Store a weak reference in the coordinator so we can update it later
        context.coordinator.previewView = previewView

        // Add the preview view inside the container
        container.addSubview(previewView)

        // Use Auto Layout to make the preview fill the container exactly.
        // `translatesAutoresizingMaskIntoConstraints = false` tells UIKit
        // we will define our own constraints instead of using the old
        // "springs and struts" system.
        previewView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: container.topAnchor),
            previewView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            previewView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        // Apply initial settings
        Self.applySettings(
            to: previewView,
            isPaused: isPaused,
            videoGravity: videoGravity
        )

        return container
    }

    /// Called every time SwiftUI state changes (e.g. `isPaused` toggles).
    /// We update the existing preview view to match the new state.
    func updateUIView(_ uiView: UIView, context: Context) {
        // Find the preview view via our weak coordinator reference
        guard let previewView = context.coordinator.previewView else { return }

        // Apply the latest settings to the preview
        Self.applySettings(
            to: previewView,
            isPaused: isPaused,
            videoGravity: videoGravity
        )
    }

    /// Called when SwiftUI removes this view from the hierarchy.
    /// We clean up to prevent retain cycles and free GPU resources.
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        // Remove all subviews so nothing retains the container
        uiView.subviews.forEach { $0.removeFromSuperview() }

        // Clear the coordinator's reference
        coordinator.previewView = nil
    }

    /// Creates the coordinator that lives as long as the view exists.
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Coordinator

    /// The Coordinator holds a weak reference to the preview view.
    /// This prevents retain cycles between SwiftUI and UIKit.
    class Coordinator {
        /// Weak reference to the preview view inside the container.
        /// Using `weak` means this won't keep the view alive if SwiftUI
        /// decides to tear it down.
        weak var previewView: UIView?
    }

    // MARK: - Private Helpers

    /// Create the right kind of preview view depending on whether
    /// HaishinKit is available.
    private static func createPreviewView() -> UIView {
        #if canImport(HaishinKit)
        return createHaishinKitPreview()
        #else
        return createPlaceholderPreview()
        #endif
    }

    /// Apply pause state and video gravity to the preview view.
    private static func applySettings(
        to previewView: UIView,
        isPaused: Bool,
        videoGravity: AVLayerVideoGravity
    ) {
        #if canImport(HaishinKit)
        applyHaishinKitSettings(
            to: previewView,
            isPaused: isPaused,
            videoGravity: videoGravity
        )
        #else
        // For the placeholder, pausing just hides/shows the icon
        previewView.alpha = isPaused ? 0.5 : 1.0
        #endif
    }
}

// MARK: - HaishinKit Preview (Real Camera)
// ──────────────────────────────────────────────────────────────────
// This section is only compiled when HaishinKit is available.
// It creates a Metal-based MTHKView that renders the live camera feed.
// ──────────────────────────────────────────────────────────────────

#if canImport(HaishinKit)
import HaishinKit

extension CameraPreviewView {

    /// Create a Metal-based preview view from HaishinKit.
    /// MTHKView uses Metal for GPU-accelerated camera rendering.
    fileprivate static func createHaishinKitPreview() -> MTHKView {
        let mthkView = MTHKView(frame: .zero)

        // Fill the view by default — edges may be cropped
        mthkView.videoGravity = .resizeAspectFill

        // Dark background so there's no flash of white before the camera starts
        mthkView.backgroundColor = .black

        // Enable user interaction so taps can pass through for focus/exposure
        mthkView.isUserInteractionEnabled = false

        return mthkView
    }

    /// Update the MTHKView's properties when SwiftUI state changes.
    fileprivate static func applyHaishinKitSettings(
        to previewView: UIView,
        isPaused: Bool,
        videoGravity: AVLayerVideoGravity
    ) {
        guard let mthkView = previewView as? MTHKView else { return }

        // Update the video gravity (aspect fill vs. aspect fit)
        mthkView.videoGravity = videoGravity

        #if os(iOS)
        // Pause or resume Metal rendering.
        // When paused, the view stops requesting GPU frames,
        // which saves battery when PiP is active.
        mthkView.isPaused = isPaused
        #endif
    }
}
#endif

// MARK: - Placeholder Preview (Simulator / No HaishinKit)
// ──────────────────────────────────────────────────────────────────
// When HaishinKit isn't available (e.g. on the Simulator), we show
// a dark view with a camera icon. This keeps the UI working during
// development without needing a real camera.
// ──────────────────────────────────────────────────────────────────

extension CameraPreviewView {

    /// Create a placeholder view with a camera icon for use
    /// when HaishinKit is not available (Simulator, early development).
    fileprivate static func createPlaceholderPreview() -> UIView {
        let view = UIView()
        view.backgroundColor = UIColor.black

        // Create a camera icon using SF Symbols
        let config = UIImage.SymbolConfiguration(
            pointSize: 48,
            weight: .light
        )
        let cameraImage = UIImage(
            systemName: "video.fill",
            withConfiguration: config
        )

        let imageView = UIImageView(image: cameraImage)
        imageView.tintColor = UIColor.white.withAlphaComponent(0.3)
        imageView.contentMode = .scaleAspectFit

        // Center the camera icon in the placeholder
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 64),
            imageView.heightAnchor.constraint(equalToConstant: 64),
        ])

        // Add a "Camera Preview" label below the icon
        let label = UILabel()
        label.text = "Camera Preview"
        label.textColor = UIColor.white.withAlphaComponent(0.3)
        label.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        label.textAlignment = .center

        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 12),
        ])

        return view
    }
}

// MARK: - SwiftUI Preview
// ──────────────────────────────────────────────────────────────────
// This preview lets you see the CameraPreviewView in Xcode's canvas
// without running the full app.
// ──────────────────────────────────────────────────────────────────

#Preview("Camera Preview") {
    CameraPreviewView()
        .ignoresSafeArea()
}

#Preview("Camera Preview - Paused") {
    CameraPreviewView(isPaused: true)
        .ignoresSafeArea()
}
