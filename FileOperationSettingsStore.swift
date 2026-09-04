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
