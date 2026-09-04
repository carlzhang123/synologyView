import Foundation

struct PlaybackProgressStore {
    private let defaults = UserDefaults.standard
    private let keyPrefix = "synology.playbackProgress."

    func progress(for path: String) -> TimeInterval {
        defaults.double(forKey: key(for: path))
    }

    func save(_ progress: TimeInterval, for path: String) {
        guard progress.isFinite, progress >= 0 else {
            return
        }

        defaults.set(progress, forKey: key(for: path))
    }

    func clear(for path: String) {
        defaults.removeObject(forKey: key(for: path))
    }

    private func key(for path: String) -> String {
        keyPrefix + path
    }
}
