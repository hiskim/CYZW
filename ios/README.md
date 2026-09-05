# iOS Shell Sources

Add `ios/EngineHost` and `ios/Shell` to an iOS 15.6+ application target named `GameShell`, and add `shared/design-tokens.css` to that target's Copy Bundle Resources phase while preserving the `shared` subdirectory. Add `ios/ProtocolTests` to the matching XCTest target.

The module name is intentionally explicit because this repository does not yet contain an Xcode project for the SwiftUI shell. `MainApp.swift` is the application entry point once these sources are added to that target.
