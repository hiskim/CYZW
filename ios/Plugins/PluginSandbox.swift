import Foundation

@MainActor
final class PluginSandbox {
    let pluginID: String

    private let plugin: any PluginProtocol
    private let targetHostID: UUID
    private let permissions: Set<PluginPermission>

    init(
        plugin: any PluginProtocol,
        targetHostID: UUID,
        permissions: Set<PluginPermission>
    ) {
        self.plugin = plugin
        pluginID = plugin.id
        self.targetHostID = targetHostID
        self.permissions = permissions
    }

    func load() async throws {
        try await plugin.onLoad(
            context: PluginContext(
                pluginID: pluginID,
                targetHostID: targetHostID,
                grantedPermissions: permissions
            )
        )
    }

    func deliver(_ event: EngineEvent, from hostID: UUID) async {
        guard permissions.contains(.events), hostID == targetHostID else { return }
        await plugin.onEvent(event, hostID: hostID)
    }

    /// L1 remains the only layer that invokes EngineHost.inject(resource:).
    func approves(resource: ResourceRef, for hostID: UUID) async -> Bool {
        guard permissions.contains(.resourceInjection), hostID == targetHostID else { return false }
        return await plugin.onResourceInject(resource, hostID: hostID)
    }

    func uiInjection() -> PluginUIInjection? {
        guard permissions.contains(.uiInjection) else { return nil }
        return plugin.onUIInject()
    }
}
