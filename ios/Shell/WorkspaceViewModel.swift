import Foundation
import Combine

struct WorkspaceItem: Identifiable {
    let id: UUID
    let account: Account
    let host: EngineHost
    var latestSnapshot: Snapshot?
}

@MainActor
final class WorkspaceViewModel: ObservableObject {
    static let maximumInstanceCount = 4

    #if os(macOS)
    private let instanceLimit: Int? = nil
    #else
    private let instanceLimit: Int? = maximumInstanceCount
    #endif

    @Published private(set) var items: [WorkspaceItem] = []
    @Published var selectedID: UUID?
    @Published private(set) var revision = 0

    func start(accounts: [Account]) async {
        let existingIDs = Set(items.map { $0.account.id })
        let candidates = accounts.filter { !existingIDs.contains($0.id) }
        let pendingAccounts: [Account]
        if let instanceLimit {
            pendingAccounts = Array(candidates.prefix(max(0, instanceLimit - items.count)))
        } else {
            pendingAccounts = candidates
        }
        // Publish all cards before awaiting authentication/startup. The
        // matrix should react to the click immediately, even when WebKit or
        // CDN preparation takes time.
        var pending: [(WorkspaceItem, MockEngineHost)] = []
        for account in pendingAccounts {
            let host = MockEngineHost()
            let item = WorkspaceItem(id: host.id, account: account, host: host, latestSnapshot: nil)
            EngineHostRegistry.shared.register(host)
            items.append(item)
            pending.append((item, host))
        }
        revision += 1

        for (item, host) in pending {

            do {
                try await host.start(config: EngineConfig(
                    bundleIdentifier: "com.xyzw.game",
                    initialTarget: .scene("launcher"),
                    // Legacy account identities are opaque .bin filenames, not UUIDs.
                    authenticationToken: item.account.id
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
        let host = items[index].host
        let accountID = items[index].account.id
        // Remove the card first so the matrix responds to the close button
        // immediately; host/WebKit cleanup can finish asynchronously.
        items.remove(at: index)
        EngineHostRegistry.shared.unregister(id: id)
#if os(macOS)
        // 群控退位：关掉的是主窗口就停止同步，同时摘掉它的接收标记。
        MacInputSyncController.shared.retire(accountID: accountID)
        // 真正释放 WebKit 实例：矩阵格子被复用/滚动时不能停，只有这里才算关实例。
        MacGameInstancePool.shared.destroy(accountID: accountID)
#endif
        if selectedID == id {
            selectedID = items.first?.id
        }
        revision += 1
        await host.close()
    }

    func host(for id: UUID) -> EngineHost? {
        item(id: id)?.host
    }

    private func item(id: UUID) -> WorkspaceItem? {
        items.first { $0.id == id }
    }
}
