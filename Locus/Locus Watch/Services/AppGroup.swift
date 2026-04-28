import Foundation

enum AppGroup {
    static let logSubsystem = Bundle.main.bundleIdentifier ?? "com.adityasm.locus.watch"

    static let identifier = "group.com.adityasm.locus"
    static let defaults = UserDefaults(suiteName: identifier)!
    static let containerURL: URL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)!
    private static let deviceIdentifierKey = "deviceIdentifier"

    static let deviceID: String = {
        if let storedID = defaults.string(forKey: deviceIdentifierKey), !storedID.isEmpty {
            return storedID
        }

        let generatedID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).uppercased()
        defaults.set(generatedID, forKey: deviceIdentifierKey)
        return generatedID
    }()
}

extension ISO8601DateFormatter {
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
