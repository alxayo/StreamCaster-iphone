// swift-tools-version: 5.9

// Package.swift
// StreamCaster
//
// Declares the external libraries (SPM dependencies) this project uses.
// Swift Package Manager (SPM) reads this file to know what to download.

import PackageDescription

let package = Package(
    // The name of our package / project
    name: "StreamCaster",

    // Minimum platform versions required
    platforms: [
        .iOS(.v15)
    ],

    // The libraries our app depends on.
    // SPM will download these from GitHub automatically.
    dependencies: [
        // HaishinKit: Handles RTMP streaming (encoding video/audio and
        // sending it to a streaming server like YouTube, Twitch, etc.)
        .package(
            url: "https://github.com/shogo4405/HaishinKit.swift.git",
            from: "2.0.0"
        ),

        // KSCrash: Catches and reports crashes so we can fix bugs
        // that happen on users' devices.
        .package(
            url: "https://github.com/kstenerud/KSCrash.git",
            from: "2.0.0"
        ),
    ],

    // Targets define the modules in our project and which
    // dependencies each module uses.
    targets: [
        .executableTarget(
            name: "StreamCaster",
            dependencies: [
                // Use the HaishinKit library in our main target
                .product(name: "HaishinKit", package: "HaishinKit.swift"),
                // RTMP protocol stack used by the encoder bridge
                .product(name: "RTMPHaishinKit", package: "HaishinKit.swift"),
                // Use KSCrash recording module for crash reporting
                .product(name: "Recording", package: "KSCrash"),
            ],
            path: "."
        ),
    ]
)
