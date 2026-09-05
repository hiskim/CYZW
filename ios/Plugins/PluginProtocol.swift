import Foundation
import SwiftUI

enum PluginPermission: Hashable, Sendable {
    case events
    case resourceInjection
    case uiInjection
}

struct PluginContext: Sendable {
    let pluginID: String
    let targetHostID: UUID
    let grantedPermissions: Set<PluginPermission>
}

struct PluginUIInjection {
    let placement: String
    let content: () -> AnyView
}

@MainActor
protocol PluginProtocol: AnyObject {
    var id: String { get }

    func onLoad(context: PluginContext) async throws
    func onEvent(_ event: EngineEvent, hostID: UUID) async
    func onResourceInject(_ resource: ResourceRef, hostID: UUID) async -> Bool
    func onUIInject() -> PluginUIInjection?
}

extension PluginProtocol {
    func onResourceInject(_ resource: ResourceRef, hostID: UUID) async -> Bool { true }
    func onUIInject() -> PluginUIInjection? { nil }
}
