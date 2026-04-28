import Foundation

enum Settings {
    static let intervalKey = "interval"
    static let intervalDefault: TimeInterval = 30
    static let intervalOptions: [TimeInterval] = [5, 10, 30, 60, 2 * 60, 5 * 60, 10 * 60, 15 * 60, 20 * 60, 30 * 60, 60 * 60]

    static var interval: TimeInterval {
        let storedInterval = AppGroup.defaults.object(forKey: intervalKey) as? TimeInterval
        return storedInterval ?? intervalDefault
    }
}
