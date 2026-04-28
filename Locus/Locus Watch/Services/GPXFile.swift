import Foundation
import OSLog

final class GPXFile {
    private static let gpxFooter = "</trkseg></trk></gpx>\n"

    let fileURL: URL
    private let fileHandle: FileHandle

    private let logger = Logger(subsystem: AppGroup.logSubsystem, category: "GPXFile")

    init(startTime: Date, fileURL: URL) throws {
        let startTimeFormatted = ISO8601DateFormatter.fractional.string(from: startTime)
        let timeZone = TimeZone.autoupdatingCurrent
        let fileXML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <gpx version="1.1" creator="Locus" xmlns="http://www.topografix.com/GPX/1/1" xmlns:locus="https://adityasm.com/locus/gpx/1">
            <metadata>
            <time>\(startTimeFormatted)</time>
            <extensions>
            <locus:timezone identifier="\(timeZone.identifier)" offset="\(Self.timeZoneOffsetString(for: timeZone, at: startTime))" />
            </extensions>
            </metadata>
            <trk><name>\(startTimeFormatted)</name><trkseg>
            """ + Self.gpxFooter

        try fileXML.write(to: fileURL, atomically: true, encoding: .utf8)

        self.fileURL = fileURL
        self.fileHandle = try FileHandle(forWritingTo: fileURL)
        logger.notice("Created GPX file \(fileURL, privacy: .public)")
    }

    func append(_ point: Point) throws {
        let footerLength = UInt64(Self.gpxFooter.utf8.count)
        let fileEnd = try fileHandle.seekToEnd()
        try fileHandle.seek(toOffset: fileEnd - footerLength)

        var trackPointXML = "<trkpt lat=\"\(point.latitude)\" lon=\"\(point.longitude)\">"
        if let elevation = point.elevation { trackPointXML += "<ele>\(elevation)</ele>" }
        trackPointXML += "<time>\(ISO8601DateFormatter.fractional.string(from: point.timestamp))</time>"
        if let horizontalAccuracy = point.horizontalAccuracy { trackPointXML += "<hdop>\(horizontalAccuracy)</hdop>" }
        trackPointXML += "</trkpt>\n" + Self.gpxFooter

        try fileHandle.write(contentsOf: Data(trackPointXML.utf8))
        try fileHandle.synchronize()
    }

    deinit {
        try? fileHandle.close()
        logger.debug("Closed GPX file \(self.fileURL, privacy: .public)")
    }

    private static func timeZoneOffsetString(for timeZone: TimeZone, at date: Date) -> String {
        let totalMinutes = timeZone.secondsFromGMT(for: date) / 60
        let sign = totalMinutes >= 0 ? "+" : "-"
        let absoluteMinutes = abs(totalMinutes)
        return String(format: "%@%02d:%02d", sign, absoluteMinutes / 60, absoluteMinutes % 60)
    }
}
