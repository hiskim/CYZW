import Foundation

@MainActor
final class LoggerPlugin: PluginProtocol {
    let id = "com.xyzw.logger"

    func onLoad(context: PluginContext) async throws {
        MacLog.info("[LoggerPlugin] loaded for host %@", context.targetHostID.uuidString)
    }

    func onEvent(_ event: EngineEvent, hostID: UUID) async {
        // 每个事件一条，量不小：归到 debug，平时不进控制台。
        MacLog.debug("[LoggerPlugin] host=%@ event=%@", hostID.uuidString, String(describing: event))
    }
}
