import Foundation
import Combine

@MainActor
final class AccountLibraryViewModel: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var selectedIDs: Set<String> = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var remarks: [String: String]
    @Published private(set) var lastLoginTimestamps: [String: TimeInterval]
    @Published private(set) var groups: [AccountGroup]
    @Published private(set) var defaultGroupID: String?

    init() {
        remarks = UserDefaults.standard.dictionary(forKey: Self.remarksKey) as? [String: String] ?? [:]
        lastLoginTimestamps = Self.loadLastLoginTimestamps()
        groups = Self.loadGroups()
        defaultGroupID = UserDefaults.standard.string(forKey: Self.defaultGroupKey)
    }

    private static let remarksKey = "ios.shell.account-remarks"
    private static let lastLoginTimestampsKey = "ios.shell.account-last-login-timestamps"
    private static let groupAssignmentsKey = "ios.shell.account-groups"
    private static let groupNamesKey = "ios.shell.groups"
    private static let groupDefinitionsKey = "ios.shell.group-definitions"
    private static let defaultGroupKey = "ios.shell.default-group"

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

    var allGroup: AccountGroup { .all }

    var visibleGroups: [AccountGroup] {
        orderedGroups.filter { !$0.isHidden }
    }

    var hiddenGroups: [AccountGroup] {
        orderedGroups.filter(\.isHidden)
    }

    var groupNames: [String] {
        [Account.defaultGroupName] + orderedGroups.map(\.name)
    }

    var orderedGroups: [AccountGroup] {
        groups.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
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

    func lastLoginDate(for account: Account) -> Date? {
        lastLoginTimestamps[account.id].map(Date.init(timeIntervalSince1970:))
    }

    func recordLogin(for account: Account) {
        lastLoginTimestamps[account.id] = Date().timeIntervalSince1970
        UserDefaults.standard.set(lastLoginTimestamps, forKey: Self.lastLoginTimestampsKey)
    }

    func accounts(in group: AccountGroup) -> [Account] {
        group.id == AccountGroup.allID ? accounts : accounts.filter { $0.groupName == group.name }
    }

    func addGroup(named name: String, colorName: String = "blue", accountIDs: Set<String> = [], isDefault: Bool = false) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              trimmedName != Account.defaultGroupName,
              trimmedName != AccountGroup.all.name,
              !groups.contains(where: { $0.name == trimmedName }) else { return }
        let group = AccountGroup(name: trimmedName, colorName: colorName, sortOrder: (groups.map(\.sortOrder).max() ?? 0) + 1)
        groups.append(group)
        saveGroups()
        updateMembers(accountIDs, for: group)
        if isDefault { setDefaultGroup(group) }
    }

    func updateGroup(_ group: AccountGroup, name: String, colorName: String, accountIDs: Set<String>, isDefault: Bool) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              trimmedName != Account.defaultGroupName,
              trimmedName != AccountGroup.all.name,
              !groups.contains(where: { $0.name == trimmedName && $0.id != group.id }),
              let index = groups.firstIndex(where: { $0.id == group.id }) else { return }

        let oldName = groups[index].name
        groups[index].name = trimmedName
        groups[index].colorName = colorName
        if oldName != trimmedName {
            var assignments = groupAssignments
            for account in accounts where account.groupName == oldName {
                assignments[account.id] = trimmedName
            }
            groupAssignments = assignments
            for index in accounts.indices where accounts[index].groupName == oldName {
                accounts[index].groupName = trimmedName
            }
        }
        saveGroups()
        updateMembers(accountIDs, for: groups[index])
        if isDefault { setDefaultGroup(groups[index]) }
        else if defaultGroupID == group.id { defaultGroupID = nil; UserDefaults.standard.removeObject(forKey: Self.defaultGroupKey) }
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

    func setHidden(_ hidden: Bool, for group: AccountGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        if hidden && visibleGroups.count == 1 {
            errorMessage = "至少保留一个可见分组。"
            return
        }
        groups[index].isHidden = hidden
        saveGroups()
    }

    func moveGroups(from source: IndexSet, to destination: Int) {
        var ordered = orderedGroups.filter { !$0.isHidden }
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, group) in ordered.enumerated() {
            guard let groupIndex = groups.firstIndex(where: { $0.id == group.id }) else { continue }
            groups[groupIndex].sortOrder = index + 1
        }
        saveGroups()
    }

    func deleteGroup(_ group: AccountGroup, deletingMembers: Bool) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == group.id }) else { return }
        let members = accounts(in: group)
        if deletingMembers {
            do {
                for account in members {
                    try LegacyBinAccountStore.deleteAccount(named: account.fileName)
                }
                accounts.removeAll { account in members.contains(where: { $0.id == account.id }) }
                selectedIDs.subtract(Set(members.map(\.id)))
                for account in members { remarks.removeValue(forKey: account.id) }
                UserDefaults.standard.set(remarks, forKey: Self.remarksKey)
                var assignments = groupAssignments
                for account in members { assignments.removeValue(forKey: account.id) }
                groupAssignments = assignments
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        } else {
            var assignments = groupAssignments
            for account in members { assignments.removeValue(forKey: account.id) }
            groupAssignments = assignments
            for index in accounts.indices where accounts[index].groupName == group.name {
                accounts[index].groupName = Account.defaultGroupName
            }
        }
        groups.remove(at: groupIndex)
        if defaultGroupID == group.id {
            defaultGroupID = nil
            UserDefaults.standard.removeObject(forKey: Self.defaultGroupKey)
        }
        saveGroups()
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
                let account = try LegacyBinAccountStore.importAccount(from: url)
                if let defaultGroup = groups.first(where: { $0.id == defaultGroupID }) {
                    var assignments = groupAssignments
                    assignments[account.id] = defaultGroup.name
                    groupAssignments = assignments
                }
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
        lastLoginTimestamps.removeValue(forKey: id)
        UserDefaults.standard.set(lastLoginTimestamps, forKey: Self.lastLoginTimestampsKey)
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

    private func updateMembers(_ accountIDs: Set<String>, for group: AccountGroup) {
        var assignments = groupAssignments
        for account in accounts where account.groupName == group.name && !accountIDs.contains(account.id) {
            assignments.removeValue(forKey: account.id)
        }
        for accountID in accountIDs { assignments[accountID] = group.name }
        groupAssignments = assignments
        for index in accounts.indices {
            if accountIDs.contains(accounts[index].id) { accounts[index].groupName = group.name }
            else if accounts[index].groupName == group.name { accounts[index].groupName = Account.defaultGroupName }
        }
    }

    private func setDefaultGroup(_ group: AccountGroup) {
        defaultGroupID = group.id
        UserDefaults.standard.set(group.id, forKey: Self.defaultGroupKey)
    }

    private func saveGroups() {
        if let data = try? JSONEncoder().encode(groups) {
            UserDefaults.standard.set(data, forKey: Self.groupDefinitionsKey)
        }
    }

    private static func loadGroups() -> [AccountGroup] {
        if let data = UserDefaults.standard.data(forKey: groupDefinitionsKey),
           let groups = try? JSONDecoder().decode([AccountGroup].self, from: data) {
            return groups
        }
        let legacyNames = UserDefaults.standard.stringArray(forKey: groupNamesKey) ?? []
        return legacyNames.enumerated().map { index, name in
            AccountGroup(name: name, sortOrder: index + 1)
        }
    }

    private static func loadLastLoginTimestamps() -> [String: TimeInterval] {
        let storedValues = UserDefaults.standard.dictionary(forKey: lastLoginTimestampsKey) ?? [:]
        return storedValues.reduce(into: [:]) { timestamps, entry in
            guard let timestamp = (entry.value as? NSNumber)?.doubleValue else { return }
            timestamps[entry.key] = timestamp
        }
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
