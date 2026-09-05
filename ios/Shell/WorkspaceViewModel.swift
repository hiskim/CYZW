import Foundation
import Observation

struct WorkspaceItem: Identifiable {
    let id: UUID
    let account: Account
    let host: EngineHost
    var latestSnapshot: Snapshot?
}

@MainActor
@Observable
final class WorkspaceViewModel {
    private(set) var items: [WorkspaceItem] = []
    var selectedID: UUID?
    private(set) var revision = 0

    func start(accounts: [Account]) async {
        for account in accounts where !items.contains(where: { $0.account.id == account.id }) {
            let host = MockEngineHost()
            let item = WorkspaceItem(id: host.id, account: account, host: host, latestSnapshot: nil)
            EngineHostRegistry.shared.register(host)
            items.append(item)

            do {
                try await host.start(config: EngineConfig(
                    bundleIdentifier: "com.xyzw.game",
                    initialTarget: .scene("launcher"),
                    authenticationToken: account.id.uuidString
                ))
                selectedID = host.id
            } catch {
                EngineHostRegistry.shared.unregister(id: host.id)
                items.removeAll { $0.id == host.id }
            }
            revision += 1
        }
    }

    func pause(id: UUID) async {
        await item(id: id)?.host.pause()
        revision += 1
    }

    func resume(id: UUID) async {
        await item(id: id)?.host.resume()
        revision += 1
    }

    func captureSnapshot(id: UUID) async {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        do {
            items[index].latestSnapshot = try await items[index].host.snapshot()
        } catch {
            revision += 1
            return
        }
        revision += 1
    }

    func close(id: UUID) async {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        await items[index].host.close()
        EngineHostRegistry.shared.unregister(id: id)
        items.remove(at: index)
        if selectedID == id {
            selectedID = items.first?.id
        }
        revision += 1
    }

    func host(for id: UUID) -> EngineHost? {
        item(id: id)?.host
    }

    private func item(id: UUID) -> WorkspaceItem? {
        items.first { $0.id == id }
    }
}
