// ConnectionTesterTests.swift
// StreamCasterTests
//
// Tests for ConnectionTester URL parsing logic.
// Verifies that RTMP, RTMPS, and SRT URLs are correctly
// parsed into host, port, and TLS settings.

import XCTest
@testable import StreamCaster

final class ConnectionTesterTests: XCTestCase {

    // MARK: - RTMP URLs

    func testParseRtmpUrlBasic() {
        let result = ConnectionTester.parseUrl("rtmp://live.twitch.tv/app")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.host, "live.twitch.tv")
        XCTAssertEqual(result?.port, 1935)
        XCTAssertEqual(result?.isSecure, false)
    }

    func testParseRtmpUrlCustomPort() {
        let result = ConnectionTester.parseUrl("rtmp://myserver:1936/live")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.host, "myserver")
        XCTAssertEqual(result?.port, 1936)
        XCTAssertEqual(result?.isSecure, false)
    }

    // MARK: - RTMPS URLs

    func testParseRtmpsUrl() {
        let result = ConnectionTester.parseUrl("rtmps://a.rtmp.youtube.com/live2")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.host, "a.rtmp.youtube.com")
        XCTAssertEqual(result?.port, 443)
        XCTAssertEqual(result?.isSecure, true)
    }

    func testParseRtmpsUrlCustomPort() {
        let result = ConnectionTester.parseUrl("rtmps://secure.server.com:8443/app")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.host, "secure.server.com")
        XCTAssertEqual(result?.port, 8443)
        XCTAssertEqual(result?.isSecure, true)
    }

    // MARK: - SRT URLs

    func testParseSrtUrlWithPort() {
        let result = ConnectionTester.parseUrl("srt://ingest.server.com:9000")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.host, "ingest.server.com")
        XCTAssertEqual(result?.port, 9000)
        XCTAssertEqual(result?.isSecure, false)
    }

    func testParseSrtUrlDefaultPort() {
        let result = ConnectionTester.parseUrl("srt://myserver")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.host, "myserver")
        XCTAssertEqual(result?.port, 9998)
        XCTAssertEqual(result?.isSecure, false)
    }

    func testParseSrtUrlWithPath() {
        let result = ConnectionTester.parseUrl("srt://server.example.com:4900?streamid=test")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.host, "server.example.com")
        XCTAssertEqual(result?.port, 4900)
        XCTAssertEqual(result?.isSecure, false)
    }

    // MARK: - Invalid URLs

    func testParseInvalidScheme() {
        XCTAssertNil(ConnectionTester.parseUrl("http://example.com"))
    }

    func testParseEmptyString() {
        XCTAssertNil(ConnectionTester.parseUrl(""))
    }

    func testParseGibberish() {
        XCTAssertNil(ConnectionTester.parseUrl("not a url"))
    }

    func testParseMissingHost() {
        XCTAssertNil(ConnectionTester.parseUrl("rtmp://"))
    }
}
