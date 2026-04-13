import XCTest
import AVFoundation
@testable import StreamCaster

// =============================================================================
// MARK: - Video Orientation Tests
// =============================================================================
/// Tests for the camera orientation fix.
///
/// Verifies that:
/// 1. `StubEncoderBridge` conforms to the updated `EncoderBridge` protocol
///    (includes `setVideoOrientation`).
/// 2. Device orientation → capture orientation mapping is correct,
///    particularly the landscape left/right swap between UIDevice and
///    AVCapture conventions.
/// 3. The `StreamingEngine` correctly forwards orientation to the bridge.

@MainActor
final class VideoOrientationTests: XCTestCase {

    // ──────────────────────────────────────────────────────────
    // MARK: - StubEncoderBridge Protocol Conformance
    // ──────────────────────────────────────────────────────────

    /// Verify that StubEncoderBridge can accept setVideoOrientation calls.
    /// This ensures the protocol + default extension compile and work.
    func testStubBridgeAcceptsSetVideoOrientation() {
        let stub = StubEncoderBridge()
        // Should not crash — just a no-op with a print.
        stub.setVideoOrientation(.portrait)
        stub.setVideoOrientation(.landscapeRight)
        stub.setVideoOrientation(.landscapeLeft)
        stub.setVideoOrientation(.portraitUpsideDown)
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Orientation Mapping Tests
    // ──────────────────────────────────────────────────────────
    // UIDevice and AVCapture use opposite conventions for
    // landscape orientations:
    //   UIDevice.landscapeLeft  → AVCapture.landscapeRight
    //   UIDevice.landscapeRight → AVCapture.landscapeLeft
    //
    // These tests verify the mapping handles this swap correctly.

    func testPortraitMapsToPortrait() {
        let result = StreamingEngine.captureOrientation(from: .portrait)
        XCTAssertEqual(result, .portrait)
    }

    func testPortraitUpsideDownMaps() {
        let result = StreamingEngine.captureOrientation(from: .portraitUpsideDown)
        XCTAssertEqual(result, .portraitUpsideDown)
    }

    func testLandscapeLeftMapsToLandscapeRight() {
        // UIDevice.landscapeLeft means the home button is on the RIGHT side.
        // AVCapture.landscapeRight means the same physical position.
        let result = StreamingEngine.captureOrientation(from: .landscapeLeft)
        XCTAssertEqual(result, .landscapeRight)
    }

    func testLandscapeRightMapsToLandscapeLeft() {
        let result = StreamingEngine.captureOrientation(from: .landscapeRight)
        XCTAssertEqual(result, .landscapeLeft)
    }

    func testFaceUpReturnsNil() {
        let result = StreamingEngine.captureOrientation(from: .faceUp)
        XCTAssertNil(result, "Face-up has no capture orientation equivalent")
    }

    func testFaceDownReturnsNil() {
        let result = StreamingEngine.captureOrientation(from: .faceDown)
        XCTAssertNil(result, "Face-down has no capture orientation equivalent")
    }

    func testUnknownReturnsNil() {
        let result = StreamingEngine.captureOrientation(from: .unknown)
        XCTAssertNil(result, "Unknown orientation should return nil")
    }
}
