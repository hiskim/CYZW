import Foundation

enum ResourceRef: Codable, Hashable, Sendable {
    case local(path: String)
    case remote(url: URL)
    case bundled(assetName: String)
}
