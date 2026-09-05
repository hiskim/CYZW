import Foundation

struct WebKitSandboxPolicy: Equatable, Sendable {
    var allowsCrossOriginFetch: Bool
    var allowsStorage: Bool
    var allowsCookies: Bool
    var allowedPostMessageTargets: Set<String>
    var allowedNetworkHosts: Set<String>

    init(
        allowsCrossOriginFetch: Bool = false,
        allowsStorage: Bool = false,
        allowsCookies: Bool = false,
        allowedPostMessageTargets: Set<String> = ["engineHost"],
        allowedNetworkHosts: Set<String> = []
    ) {
        self.allowsCrossOriginFetch = allowsCrossOriginFetch
        self.allowsStorage = allowsStorage
        self.allowsCookies = allowsCookies
        self.allowedPostMessageTargets = allowedPostMessageTargets
        self.allowedNetworkHosts = allowedNetworkHosts
    }

    static let `default` = WebKitSandboxPolicy()

    func allowsNavigation(to url: URL, initialURL: URL?) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        guard scheme == "https" || scheme == "http" || scheme == "about" else { return false }
        guard let host = url.host?.lowercased() else { return scheme == "about" }

        return host == initialURL?.host?.lowercased()
            || allowedNetworkHosts.contains(host)
    }
}
