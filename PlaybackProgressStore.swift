import Foundation

struct PlaybackProgressStore {
    private let defaults = UserDefaults.standard
    private let keyPrefix = "synology.playbackProgress."
    private let durationKeyPrefix = "synology.playbackDuration."

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

    func duration(for path: String) -> TimeInterval {
        let duration = defaults.double(forKey: durationKey(for: path))
        guard duration.isFinite, duration > 0 else {
            return 0
        }

        return duration
    }

    func saveDuration(_ duration: TimeInterval, for path: String) {
        guard duration.isFinite, duration > 0 else {
            return
        }

        let currentDuration = self.duration(for: path)
        guard currentDuration <= 0 || duration > currentDuration else {
            return
        }

        defaults.set(duration, forKey: durationKey(for: path))
    }

    private func key(for path: String) -> String {
        keyPrefix + path
    }

    private func durationKey(for path: String) -> String {
        durationKeyPrefix + path
    }
}
