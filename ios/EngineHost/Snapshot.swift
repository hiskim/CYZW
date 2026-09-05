import Foundation

struct Snapshot: Codable, Hashable, Sendable {
    enum RenderState: String, Codable, Sendable {
        case running
        case paused
        case loading
    }

    struct Camera: Codable, Hashable, Sendable {
        let x: Double
        let y: Double
        let z: Double
        let zoom: Double
    }

    struct ScrollPosition: Codable, Hashable, Sendable {
        let horizontal: Double
        let vertical: Double
    }

    let engineID: UUID
    let capturedAt: Date
    let renderState: RenderState
    let camera: Camera
    let scrollPosition: ScrollPosition
    let metadata: [String: String]
}
