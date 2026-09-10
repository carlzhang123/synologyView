import Foundation

struct FileOperationSettingsStore {
    private let defaults = UserDefaults.standard
    private let lastMoveDestinationPathKey = "synology.lastMoveDestinationPath"

    func loadLastMoveDestinationPath() -> String {
        defaults.string(forKey: lastMoveDestinationPathKey) ?? ""
    }

    func saveLastMoveDestinationPath(_ path: String) {
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(normalizedPath, forKey: lastMoveDestinationPathKey)
    }
}

struct UploadProgressStore {
    private let defaults = UserDefaults.standard
    private let key = "synology.uploadProgressItems"

    func load() -> [UploadProgressItem] {
        guard let data = defaults.data(forKey: key) else { return [] }
        guard let items = try? JSONDecoder().decode([UploadProgressItem].self, from: data) else {
            return []
        }

        let retainedItems = items.filter { $0.status != .finished }
        if retainedItems.count != items.count {
            save(retainedItems)
        }
        return retainedItems
    }

    func save(_ items: [UploadProgressItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: key)
    }
}
