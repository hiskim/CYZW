import Foundation
import Combine

@MainActor
final class AccountLibraryViewModel: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var selectedIDs: Set<String> = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var remarks: [String: String]
    @Published private(set) var customGroupNames: [String]

    init() {
        remarks = UserDefaults.standard.dictionary(forKey: Self.remarksKey) as? [String: String] ?? [:]
        customGroupNames = UserDefaults.standard.stringArray(forKey: Self.groupNamesKey) ?? []
    }

    private static let remarksKey = "ios.shell.account-remarks"
    private static let groupAssignmentsKey = "ios.shell.account-groups"
    private static let groupNamesKey = "ios.shell.groups"

    private var groupAssignments: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.groupAssignmentsKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.groupAssignmentsKey) }
    }

    var selectedAccounts: [Account] {
        accounts.filter { selectedIDs.contains($0.id) }
    }

    var allSelected: Bool {
        !accounts.isEmpty && accounts.allSatisfy { selectedIDs.contains($0.id) }
    }

    var groupNames: [String] {
        var names = Set(customGroupNames)
        names.insert(Account.defaultGroupName)
        names.formUnion(accounts.map(\.groupName))
        return names.sorted { lhs, rhs in
            if lhs == Account.defaultGroupName { return true }
            if rhs == Account.defaultGroupName { return false }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    func remark(for account: Account) -> String {
        remarks[account.id] ?? ""
    }

    func updateRemark(_ value: String, for account: Account) {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedValue.isEmpty {
            remarks.removeValue(forKey: account.id)
        } else {
            remarks[account.id] = trimmedValue
        }
        UserDefaults.standard.set(remarks, forKey: Self.remarksKey)
    }

    func addGroup(named name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              trimmedName != Account.defaultGroupName,
              !customGroupNames.contains(trimmedName) else { return }
        customGroupNames.append(trimmedName)
        customGroupNames.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        UserDefaults.standard.set(customGroupNames, forKey: Self.groupNamesKey)
    }

    func updateGroup(_ value: String, for account: Account) {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = trimmedValue.isEmpty ? Account.defaultGroupName : trimmedValue
        var assignments = groupAssignments
        assignments[account.id] = group
        groupAssignments = assignments
        addGroup(named: group)

        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index].groupName = group
    }

    func refresh() {
        do {
            let assignments = groupAssignments
            accounts = try LegacyBinAccountStore.loadAccounts().map { account in
                var account = account
                account.groupName = assignments[account.id] ?? Account.defaultGroupName
                return account
            }
            selectedIDs.formIntersection(Set(accounts.map(\.id)))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importFiles(from urls: [URL]) {
        do {
            for url in urls {
                _ = try LegacyBinAccountStore.importAccount(from: url)
            }
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(id: String) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        do {
            try LegacyBinAccountStore.deleteAccount(named: account.fileName)
            accounts.removeAll { $0.id == id }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        selectedIDs.remove(id)

        remarks.removeValue(forKey: id)
        UserDefaults.standard.set(remarks, forKey: Self.remarksKey)
        var assignments = groupAssignments
        assignments.removeValue(forKey: id)
        groupAssignments = assignments
    }

    func toggleSelection(id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    func toggleSelectAll() {
        selectedIDs = allSelected ? [] : Set(accounts.map(\.id))
    }
}

private enum LegacyBinAccountStore {
    enum StoreError: LocalizedError {
        case invalidFileType
        case unreadableFile
        case documentsUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidFileType:
                return "只能导入 .bin 账号文件。"
            case .unreadableFile:
                return "无法读取所选的 .bin 文件。"
            case .documentsUnavailable:
                return "无法访问应用文档目录。"
            }
        }
    }

    static func loadAccounts() throws -> [Account] {
        let directory = try binDirectory()
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        return urls
            .filter { $0.pathExtension.lowercased() == "bin" }
            .sorted { lhs, rhs in
                let leftDate = (try? lhs.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
                let rightDate = (try? rhs.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
                if leftDate != rightDate { return leftDate > rightDate }
                return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
            }
            .map { url in
                let values = try? url.resourceValues(forKeys: keys)
                return Account(
                    fileName: url.lastPathComponent,
                    importedAt: values?.creationDate ?? values?.contentModificationDate ?? .distantPast
                )
            }
    }

    static func importAccount(from source: URL) throws -> Account {
        guard source.pathExtension.lowercased() == "bin" else {
            throw StoreError.invalidFileType
        }

        let accessed = source.startAccessingSecurityScopedResource()
        defer {
            if accessed { source.stopAccessingSecurityScopedResource() }
        }

        guard let data = try? Data(contentsOf: source), !data.isEmpty else {
            throw StoreError.unreadableFile
        }

        let directory = try binDirectory()
        let destination = availableURL(in: directory, preferredName: safeBinName(source.lastPathComponent))
        try data.write(to: destination, options: .atomic)
        return Account(fileName: destination.lastPathComponent)
    }

    static func deleteAccount(named name: String) throws {
        let safeName = safeBinName(name)
        guard safeName == name else { throw StoreError.invalidFileType }
        try FileManager.default.removeItem(at: try binDirectory().appendingPathComponent(safeName))
    }

    private static func binDirectory() throws -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw StoreError.documentsUnavailable
        }
        let directory = documents.appendingPathComponent("ios2/bins", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func safeBinName(_ rawName: String) -> String {
        let candidate = (rawName as NSString).lastPathComponent
        let withExtension = (candidate as NSString).pathExtension.lowercased() == "bin" ? candidate : "\(candidate).bin"
        let invalid = CharacterSet(charactersIn: "/\\").union(.controlCharacters)
        let sanitized = withExtension.unicodeScalars.map { invalid.contains($0) ? "_" : String($0) }.joined()
        return (sanitized.isEmpty || sanitized == "." || sanitized == "..") ? "account.bin" : sanitized
    }

    private static func availableURL(in directory: URL, preferredName: String) -> URL {
        let initial = directory.appendingPathComponent(preferredName)
        guard FileManager.default.fileExists(atPath: initial.path) else { return initial }
        let base = (preferredName as NSString).deletingPathExtension
        return directory.appendingPathComponent("\(base)-\(UUID().uuidString.prefix(8)).bin")
    }
}
