import Foundation
import Observation

@MainActor
@Observable
final class AccountLibraryViewModel {
    private(set) var accounts: [Account]
    private(set) var selectedIDs: Set<UUID> = []

    init(accounts: [Account]? = nil) {
        self.accounts = accounts ?? Self.sampleAccounts
    }

    var selectedAccounts: [Account] {
        accounts.filter { selectedIDs.contains($0.id) }
    }

    var allSelected: Bool {
        !accounts.isEmpty && accounts.allSatisfy { selectedIDs.contains($0.id) }
    }

    func add(_ account: Account) {
        accounts.append(account)
    }

    func update(_ account: Account) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account
    }

    func delete(id: UUID) {
        accounts.removeAll { $0.id == id }
        selectedIDs.remove(id)
    }

    func toggleSelection(id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    func toggleSelectAll() {
        selectedIDs = allSelected ? [] : Set(accounts.map(\.id))
    }

    private static let sampleAccounts = [
        Account(nickname: "夜影孤鸿", gameName: "星海远征", groupName: "常用"),
        Account(nickname: "清风明月", gameName: "星海远征", groupName: "常用"),
        Account(nickname: "一剑霜寒", gameName: "星海远征", groupName: "主号"),
        Account(nickname: "搬砖小号01", gameName: "星海远征", groupName: "小号搬砖")
    ]
}
