import Foundation

@MainActor
final class EngineHostRegistry {
    static let shared = EngineHostRegistry()

    private var hosts: [UUID: EngineHost] = [:]

    private init() {}

    func register(_ host: EngineHost) {
        hosts[host.id] = host
    }

    func unregister(id: UUID) {
        hosts.removeValue(forKey: id)
    }

    func host(for id: UUID) -> EngineHost? {
        hosts[id]
    }

    func allHosts() -> [EngineHost] {
        Array(hosts.values)
    }

    func removeAll() {
        hosts.removeAll()
    }
}
