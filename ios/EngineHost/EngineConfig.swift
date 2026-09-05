import Foundation

enum EngineInitialTarget: Codable, Hashable, Sendable {
    case url(URL)
    case scene(String)
}

struct EngineConfig: Codable, Hashable, Sendable {
    let bundleIdentifier: String
    let initialTarget: EngineInitialTarget
    let resources: [ResourceRef]
    let authenticationToken: String

    init(
        bundleIdentifier: String,
        initialTarget: EngineInitialTarget,
        resources: [ResourceRef] = [],
        authenticationToken: String
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.initialTarget = initialTarget
        self.resources = resources
        self.authenticationToken = authenticationToken
    }

    static let preview = EngineConfig(
        bundleIdentifier: "com.xyzw.game",
        initialTarget: .scene("launcher"),
        authenticationToken: "preview-token"
    )
}
