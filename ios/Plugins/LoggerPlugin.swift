import Foundation

@MainActor
final class LoggerPlugin: PluginProtocol {
    let id = "com.xyzw.logger"

    func onLoad(context: PluginContext) async throws {
        print("[LoggerPlugin] loaded for host \(context.targetHostID.uuidString)")
    }

    func onEvent(_ event: EngineEvent, hostID: UUID) async {
        print("[LoggerPlugin] host=\(hostID.uuidString) event=\(String(describing: event))")
    }
}
