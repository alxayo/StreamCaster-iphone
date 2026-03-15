// StreamCasterApp.swift
// StreamCaster
//
// The main entry point of the StreamCaster app.
// SwiftUI uses the @main attribute to know where the app starts.

import SwiftUI

/// This is the starting point of the app.
/// The @main attribute tells Swift "run this first."
/// We use @UIApplicationDelegateAdaptor to connect our AppDelegate
/// so we can still use UIKit lifecycle events (like orientation control).
@main
struct StreamCasterApp: App {

    // Connect the UIKit AppDelegate so we get lifecycle callbacks
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // WindowGroup is the main window of the app.
        // Everything the user sees starts here.
        WindowGroup {
            // TODO: Replace this placeholder with the real streaming UI
            Text("StreamCaster")
                .font(.largeTitle)
                .fontWeight(.bold)
        }
    }
}
