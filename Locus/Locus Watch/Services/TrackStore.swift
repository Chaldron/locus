import CloudKit
import Foundation
import OSLog
import Observation

@Observable @MainActor final class TrackStore {
    var tracks: [Track] = []

    @ObservationIgnored private var uploadingTrackIDs: Set<String> = []

    @ObservationIgnored private let tracksDirectory = AppGroup.containerURL.appendingPathComponent("Tracks", isDirectory: true)

    @ObservationIgnored private let cloudDatabase = CKContainer(identifier: "iCloud.com.adityasm.locus.v2").publicCloudDatabase

    @ObservationIgnored private let logger = Logger(subsystem: AppGroup.logSubsystem, category: "TrackStore")

    private static let uploadedTrackIDsKey = "uploadedIDs"
    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    init() {
        try? FileManager.default.createDirectory(at: tracksDirectory, withIntermediateDirectories: true)
        logger.debug("Initialized in \(self.tracksDirectory.path, privacy: .private)")

        refresh()

        Task {
            let pendingTracks = self.tracks.filter { $0.uploadState == .pending }
            if pendingTracks.isEmpty {
                logger.debug("No pending tracks to upload on startup")
            } else {
                logger.debug("Uploading \(pendingTracks.count, privacy: .public) pending tracks on startup")
                for track in pendingTracks { await self.upload(trackID: track.id) }
            }
        }
    }

    func startingNewTrack(startTime: Date) -> (id: String, fileURL: URL) {
        let timestampFormatted = Self.filenameFormatter.string(from: startTime)
        let uniqueSuffix = String(UUID().uuidString.prefix(6)).uppercased()
        let trackID = "\(AppGroup.deviceID)-\(timestampFormatted)-\(uniqueSuffix)"

        logger.info("Generated track ID \(trackID, privacy: .public)")
        return (trackID, tracksDirectory.appendingPathComponent("\(trackID).gpx"))
    }

    func refresh() {
        let fileURLs = (try? FileManager.default.contentsOfDirectory(at: tracksDirectory, includingPropertiesForKeys: nil)) ?? []
        let trackFileURLs = fileURLs.filter { $0.pathExtension == "gpx" }
        let trackIDs = Set(trackFileURLs.map { Track.id(from: $0) })

        // Prune uploaded track IDs that no longer exist on the filesystem - for simplicity, we'll just leave them in the cloud instead of trying to delete them from here.
        var uploadedTrackIDs = loadUploadedTrackIDs()
        if !uploadedTrackIDs.isSubset(of: trackIDs) {
            let staleCount = uploadedTrackIDs.subtracting(trackIDs).count
            uploadedTrackIDs.formIntersection(trackIDs)
            saveUploadedTrackIDs(uploadedTrackIDs)
            logger.notice("Pruned \(staleCount, privacy: .public) stale uploaded track IDs that no longer have a corresponding local file")
        }

        self.tracks =
            trackFileURLs
            .compactMap { loadTrackFromFile(at: $0, uploadedIDs: uploadedTrackIDs) }
            .sorted(using: KeyPathComparator(\Track.startTime, order: .reverse))

        logger.info("Refreshed local track list, found \(self.tracks.count, privacy: .public) tracks")
    }

    func upload(trackID: String) async {
        guard let track = tracks.first(where: { $0.id == trackID }) else {
            logger.notice("Skipping upload, no local track found with id \(trackID, privacy: .public)")
            return
        }

        guard FileManager.default.fileExists(atPath: track.fileURL.path) else {
            logger.notice("Skipping upload, local file for track \(trackID, privacy: .public) no longer exists")
            refresh()
            return
        }

        guard !uploadingTrackIDs.contains(trackID) else {
            logger.debug("Skipping upload, local file for track \(trackID, privacy: .public) is already uploading")
            return
        }

        uploadingTrackIDs.insert(trackID)
        refresh()

        defer {
            uploadingTrackIDs.remove(trackID)
            refresh()
        }

        logger.notice("Uploading track \(trackID, privacy: .public)")
        let record = CKRecord(recordType: "Track", recordID: CKRecord.ID(recordName: trackID))
        record["startTime"] = track.startTime as NSDate
        record["filename"] = "\(trackID).gpx" as NSString
        record["file"] = CKAsset(fileURL: track.fileURL)

        // Long-lived operation survives watch app suspension during background uploads
        let operation = CKModifyRecordsOperation(recordsToSave: [record])
        operation.savePolicy = .allKeys
        let operationConfiguration = CKOperation.Configuration()
        operationConfiguration.isLongLived = true
        operationConfiguration.qualityOfService = .utility
        operation.configuration = operationConfiguration

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                operation.modifyRecordsResultBlock = { @Sendable result in
                    switch result {
                    case .success: continuation.resume()
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
                cloudDatabase.add(operation)
            }

            if FileManager.default.fileExists(atPath: track.fileURL.path) {
                var uploadedIDs = loadUploadedTrackIDs()
                uploadedIDs.insert(trackID)
                saveUploadedTrackIDs(uploadedIDs)
            } else {
                logger.notice(
                    "Upload completed for track \(trackID, privacy: .public) after its local file was removed; deleting the remote copy to keep local storage authoritative"
                )
                await deleteRemoteRecord(named: trackID)
            }
            logger.info("Uploaded track \(trackID, privacy: .public) successfully")
        } catch {
            logger.error("Upload failed for track \(trackID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func delete(_ track: Track) async {
        logger.notice("Deleting track \(track.id, privacy: .public)")

        deleteLocalFile(for: track)

        // Local storage stays authoritative, so clear the uploaded marker before remote cleanup.
        var uploadedIDs = loadUploadedTrackIDs()
        uploadedIDs.remove(track.id)
        saveUploadedTrackIDs(uploadedIDs)

        await deleteRemoteRecord(named: track.id)
        refresh()
    }

    func deleteAll() async {
        refresh()
        let tracksToDelete = tracks
        logger.notice("Deleting all local and remote tracks with device ID \(AppGroup.deviceID, privacy: .public)")

        for track in tracksToDelete { deleteLocalFile(for: track) }

        saveUploadedTrackIDs([])

        let remoteRecordNames = await fetchRemoteRecordNames()
        logger.debug("Attempting to remove \(remoteRecordNames.count, privacy: .public) remote records")

        for recordName in remoteRecordNames { await deleteRemoteRecord(named: recordName) }

        refresh()
    }

    private func loadTrackFromFile(at url: URL, uploadedIDs: Set<String>) -> Track? {
        guard let fileData = try? Data(contentsOf: url), let fileContent = String(data: fileData, encoding: .utf8) else {
            logger.error("Failed to read GPX file at \(url, privacy: .public)")
            return nil
        }

        let trackID = Track.id(from: url)

        guard let startTimeISO = extractStartTime(fromGPX: fileContent) else {
            logger.error("Unable to extract time from GPX file at \(url, privacy: .public)")
            return nil
        }
        guard let startTime = ISO8601DateFormatter.fractional.date(from: startTimeISO) else {
            logger.error("Invalid time \(startTimeISO, privacy: .public) from GPX file at \(url.lastPathComponent, privacy: .public)")
            return nil
        }

        var pointCount = 0
        var searchStartIndex = fileContent.startIndex
        while let trackPointRange = fileContent.range(of: "<trkpt ", range: searchStartIndex..<fileContent.endIndex) {
            pointCount += 1
            searchStartIndex = trackPointRange.upperBound
        }

        let uploadState: Track.UploadState
        if uploadingTrackIDs.contains(trackID) {
            uploadState = .uploading
        } else if uploadedIDs.contains(trackID) {
            uploadState = .uploaded
        } else {
            uploadState = .pending
        }

        logger.debug(
            "Loaded track \(trackID, privacy: .public) with \(pointCount, privacy: .public) points (\(String(describing: uploadState), privacy: .public))"
        )

        return Track(id: trackID, startTime: startTime, fileURL: url, pointCount: pointCount, uploadState: uploadState)
    }

    private func loadUploadedTrackIDs() -> Set<String> {
        guard let uploadedTrackIDsJSON = AppGroup.defaults.data(forKey: Self.uploadedTrackIDsKey) else {
            return []
        }

        do {
            return try JSONDecoder().decode(Set<String>.self, from: uploadedTrackIDsJSON)
        } catch {
            logger.error("Failed to get uploaded track IDs: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func saveUploadedTrackIDs(_ uploadedTrackIDs: Set<String>) {
        do {
            let uploadedTrackIDsJSON = try JSONEncoder().encode(uploadedTrackIDs)
            AppGroup.defaults.set(uploadedTrackIDsJSON, forKey: Self.uploadedTrackIDsKey)
            logger.debug("Saved \(uploadedTrackIDs.count, privacy: .public) uploaded track IDs")
        } catch {
            logger.error("Failed to save uploaded track IDs: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deleteLocalFile(for track: Track) {
        do {
            try FileManager.default.removeItem(at: track.fileURL)
            logger.debug("Removed local GPX file for \(track.id, privacy: .public)")
        } catch {
            logger.error("Failed to remove local GPX file for \(track.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deleteRemoteRecord(named recordName: String) async {
        do {
            _ = try await cloudDatabase.deleteRecord(withID: CKRecord.ID(recordName: recordName))
            logger.debug("Deleted iCloud record for \(recordName, privacy: .public)")
        } catch {
            if let ckError = error as? CKError, ckError.code == .unknownItem {
                logger.debug("iCloud record \(recordName, privacy: .public) was already absent")
                return
            }
            logger.error("Failed to delete iCloud record for \(recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func fetchRemoteRecordNames() async -> Set<String> {
        var recordNames: Set<String> = []
        var queryCursor: CKQueryOperation.Cursor?

        do {
            repeat {
                let queryPage: (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)], queryCursor: CKQueryOperation.Cursor?)

                if let queryCursor {
                    queryPage = try await cloudDatabase.records(continuingMatchFrom: queryCursor, desiredKeys: [], resultsLimit: 200)
                } else {
                    queryPage = try await cloudDatabase.records(
                        matching: CKQuery(recordType: "Track", predicate: NSPredicate(value: true)), desiredKeys: [], resultsLimit: 200)
                }

                for (recordID, recordResult) in queryPage.matchResults {
                    switch recordResult {
                    case .success:
                        if recordID.recordName.hasPrefix("\(AppGroup.deviceID)-") {
                            recordNames.insert(recordID.recordName)
                        }
                    case .failure(let error):
                        logger.error("Failed to inspect iCloud record \(recordID.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }

                queryCursor = queryPage.queryCursor
            } while queryCursor != nil
        } catch {
            logger.error("Failed to enumerate iCloud records for watch \(AppGroup.deviceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        return recordNames
    }

    private func extractStartTime(fromGPX content: String) -> String? {
        guard let metadataStart = content.range(of: "<metadata"), let metadataOpenEnd = content.range(of: ">", range: metadataStart.lowerBound..<content.endIndex),
            let metadataEnd = content.range(of: "</metadata>", range: metadataOpenEnd.upperBound..<content.endIndex),
            let timeStart = content.range(of: "<time>", range: metadataOpenEnd.upperBound..<metadataEnd.lowerBound),
            let timeEnd = content.range(of: "</time>", range: timeStart.upperBound..<metadataEnd.lowerBound)
        else { return nil }

        return String(content[timeStart.upperBound..<timeEnd.lowerBound])
    }
}
