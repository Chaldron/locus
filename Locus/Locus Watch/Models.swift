import Foundation

struct Point: Hashable, Codable {
    let latitude: Double
    let longitude: Double
    let elevation: Double?
    let horizontalAccuracy: Double?
    let timestamp: Date
}

struct Track: Identifiable, Hashable {
    enum UploadState { case pending, uploading, uploaded }

    let id: String
    let startTime: Date
    let fileURL: URL
    let pointCount: Int
    let uploadState: UploadState

    static func id(from fileURL: URL) -> String { fileURL.deletingPathExtension().lastPathComponent }
}
