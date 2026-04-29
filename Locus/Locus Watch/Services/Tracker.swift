import CoreLocation
import Foundation
import OSLog
import Observation

enum RecordingState {
    case idle, starting, recording, stopping
}

@Observable @MainActor final class Tracker: NSObject, CLLocationManagerDelegate {
    private static let startupFreshnessGrace: TimeInterval = 2
    private static let maximumPointsPerTrack = 12

    var state: RecordingState = .idle

    @ObservationIgnored private let trackStore: TrackStore

    var activeTrackID: String?
    var pointCount = 0
    var lastPoint: Point?
    @ObservationIgnored private var gpxFile: GPXFile?
    @ObservationIgnored private var recordingStartedAt: Date?
    @ObservationIgnored private var lastPointAcceptedAt: Date?

    var locationAuthorization: CLAuthorizationStatus = .notDetermined
    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private var locationUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundActivitySession: CLBackgroundActivitySession?
    @ObservationIgnored private var authorizationContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?

    @ObservationIgnored private let logger = Logger(subsystem: AppGroup.logSubsystem, category: "Tracker")

    init(trackStore: TrackStore) {
        self.trackStore = trackStore
        super.init()

        locationManager.delegate = self
        locationAuthorization = locationManager.authorizationStatus
        logger.debug("Initialized with location authorization [\(self.locationAuthorization.displayText, privacy: .public)]")
    }

    var canStart: Bool { state == .idle && locationAuthorization != .denied && locationAuthorization != .restricted }
    var isActive: Bool { state == .recording || state == .stopping }

    func start() async throws {
        guard canStart else {
            logger.notice(
                "Start ignored because state=\(self.state.displayText, privacy: .public) authorization=\(self.locationAuthorization.displayText, privacy: .public)"
            )
            return
        }

        state = .starting
        let resolvedAuthorization = await requestPermissionIfNeeded()
        locationAuthorization = resolvedAuthorization

        guard resolvedAuthorization == .authorizedWhenInUse || resolvedAuthorization == .authorizedAlways else {
            state = .idle
            logger.notice("Start aborted because authorization requested resolved to \(resolvedAuthorization.displayText, privacy: .public)")
            return
        }

        do {
            let startTime = Date.now
            let trackID = try startNewTrack(startTime: startTime)
            logger.notice("Starting recording for track \(trackID, privacy: .public) on \(Int(Settings.interval), privacy: .public)s interval")

            backgroundActivitySession = CLBackgroundActivitySession()

            state = .recording

            locationUpdatesTask = Task { @MainActor [self] in
                logger.debug("Listening for location updates on track \(trackID, privacy: .public)")

                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if Task.isCancelled {
                            logger.debug("Location update task canceled on track \(trackID, privacy: .public)")
                            break
                        }
                        if update.authorizationDenied {
                            logger.notice("Location updates reported authorization denied on track \(trackID, privacy: .public)")
                            break
                        }

                        guard let location = update.location else { continue }
                        self.onLocationUpdate(location)
                    }
                } catch {
                    logger.error("Location update stream failed on track \(trackID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }

                self.finish()
            }
        } catch {
            state = .idle
            throw error
        }
    }

    private func startNewTrack(startTime: Date) throws -> String {
        let (newTrackID, newFileURL) = trackStore.startingNewTrack(startTime: startTime)
        let newGPXFile = try GPXFile(startTime: startTime, fileURL: newFileURL)

        activeTrackID = newTrackID
        pointCount = 0
        lastPoint = nil
        recordingStartedAt = startTime
        lastPointAcceptedAt = nil
        gpxFile = newGPXFile

        return newTrackID
    }

    private func requestPermissionIfNeeded() async -> CLAuthorizationStatus {
        let status = locationManager.authorizationStatus

        guard status == .notDetermined else {
            logger.debug("Not requesting permissions, current authorization is already [\(status.displayText, privacy: .public)]")
            return status
        }

        logger.info("Requesting location permissions")
        locationManager.requestWhenInUseAuthorization()
        return await withCheckedContinuation { continuation in authorizationContinuation = continuation }
    }

    func stop() {
        guard state == .recording else {
            logger.debug("Stop ignored because state=\(self.state.displayText, privacy: .public)")
            return
        }

        logger.info("Stopping active recording")

        state = .stopping
        locationUpdatesTask?.cancel()
    }

    private func onLocationUpdate(_ location: CLLocation) {
        let horizontalAccuracy = location.horizontalAccuracy
        let interval = Settings.interval
        let receivedAt = Date.now

        if let recordingStartedAt, location.timestamp < recordingStartedAt.addingTimeInterval(-Self.startupFreshnessGrace) {
            logger.debug("Dropping stale location predating start by more than \(Int(Self.startupFreshnessGrace), privacy: .public)s")
            return
        }

        if let lastPointAcceptedAt, receivedAt.timeIntervalSince(lastPointAcceptedAt) < interval {
            return
        }

        lastPointAcceptedAt = receivedAt

        guard let gpxFile else {
            logger.error("Received a location sample without an active track")
            return
        }

        let point = Point(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            elevation: location.verticalAccuracy >= 0 ? location.altitude : nil,
            horizontalAccuracy: horizontalAccuracy >= 0 ? horizontalAccuracy : nil,
            timestamp: location.timestamp
        )

        do {
            try gpxFile.append(point)
            lastPoint = point
            pointCount += 1

            logger.debug(
                "Recorded point \(self.pointCount, privacy: .public) to \(gpxFile.fileURL.lastPathComponent, privacy: .public) with horizontal accuracy \(horizontalAccuracy, privacy: .public)m"
            )

            rollOverTrackIfNeeded()

        } catch {
            logger.error(
                "Failed to append point \(self.pointCount + 1, privacy: .public) to \(gpxFile.fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func queueUpload(for trackID: String) {
        logger.info("Queueing upload for completed track \(trackID, privacy: .public)")
        Task { await trackStore.upload(trackID: trackID) }
    }

    private func rollOverTrackIfNeeded() {
        guard pointCount >= Self.maximumPointsPerTrack else { return }
        guard let finishedTrackId = activeTrackID else {
            logger.error("Reached point rollover threshold without an active track")
            return
        }

        let finishedPointCount = pointCount
        let rolloverStartTime = Date.now

        do {
            let newTrackId = try startNewTrack(startTime: rolloverStartTime)
            logger.notice(
                "Rolled over recording from \(finishedTrackId, privacy: .public) to \(newTrackId, privacy: .public) after \(finishedPointCount, privacy: .public) points")

            trackStore.refresh()
            queueUpload(for: finishedTrackId)
        } catch {
            logger.error(
                "Failed to roll over track \(finishedTrackId, privacy: .public) after \(finishedPointCount, privacy: .public) points: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func finish() {
        let finishedTrackID = activeTrackID

        if let finishedTrackID {
            logger.notice("Finishing recording for track \(finishedTrackID, privacy: .public) after \(self.pointCount, privacy: .public) points")
        } else {
            logger.debug("Finished recording without an active track")
        }

        activeTrackID = nil
        pointCount = 0
        lastPoint = nil
        gpxFile = nil
        recordingStartedAt = nil
        lastPointAcceptedAt = nil

        locationUpdatesTask = nil
        backgroundActivitySession?.invalidate()
        backgroundActivitySession = nil

        state = .idle

        trackStore.refresh()

        if let finishedTrackID {
            queueUpload(for: finishedTrackID)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let authorization = manager.authorizationStatus
        Task { @MainActor in
            if authorization != self.locationAuthorization {
                logger.info(
                    "Location authorization changed from \(self.locationAuthorization.displayText, privacy: .public) to \(authorization.displayText, privacy: .public)"
                )
            }
            self.locationAuthorization = authorization
            if authorization != .notDetermined {
                if let continuation = self.authorizationContinuation {
                    self.authorizationContinuation = nil
                    continuation.resume(returning: authorization)
                }
            }
        }
    }
}

extension CLAuthorizationStatus {
    var displayText: String {
        switch self {
        case .notDetermined: "Not set"
        case .restricted: "Restricted"
        case .denied: "Denied"
        case .authorizedAlways: "Always"
        case .authorizedWhenInUse: "While in use"
        @unknown default: "Unknown"
        }
    }
}

extension RecordingState {
    var displayText: String {
        switch self {
        case .idle: "Idle"
        case .starting: "Starting"
        case .recording: "Recording"
        case .stopping: "Stopping"
        }
    }
}
