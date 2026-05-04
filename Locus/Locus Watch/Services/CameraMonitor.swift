import CoreBluetooth
import Foundation
import Observation
import OSLog
import SwiftUI
import UserNotifications

@Observable @MainActor final class CameraMonitor: NSObject {
    private enum KnownCamera: String, CaseIterable {
        case ricohGRIIIx
        case lumixG9

        var displayName: String {
            switch self {
            case .ricohGRIIIx:
                return "Ricoh GR IIIx"
            case .lumixG9:
                return "Panasonic Lumix G9"
            }
        }

        var advertisedServiceUUID: CBUUID {
            switch self {
            case .ricohGRIIIx:
                return CBUUID(string: "9A5ED1C5-74CC-4C50-B5B6-66A48E7CCFF1")
            case .lumixG9:
                return CBUUID(string: "054AC620-3214-11E6-AC0D-0002A5D5C51B")
            }
        }

        var notificationIdentifierPrefix: String {
            "camera-monitor-\(rawValue)"
        }

        var lastNotificationAtKey: String {
            "cameraMonitor.lastNotificationAt.\(rawValue)"
        }
    }

    private enum DefaultsKey {
        static let isArmed = "cameraMonitor.isArmed"
        static let lastDetectedCameraName = "cameraMonitor.lastDetectedCameraName"
        static let lastDetectedAt = "cameraMonitor.lastDetectedAt"
        static let lastDetectedPeripheralIdentifier = "cameraMonitor.lastDetectedPeripheralIdentifier"
        static let lastDetectedRSSI = "cameraMonitor.lastDetectedRSSI"
        static let discoveryCount = "cameraMonitor.discoveryCount"
        static let lastRestoreAt = "cameraMonitor.lastRestoreAt"
        static let restoreCount = "cameraMonitor.restoreCount"
        static let lastBackgroundWakeAt = "cameraMonitor.lastBackgroundWakeAt"
        static let backgroundWakeCount = "cameraMonitor.backgroundWakeCount"
        static let lastNotificationAt = "cameraMonitor.lastNotificationAt"
        static let lastNotificationIdentifier = "cameraMonitor.lastNotificationIdentifier"
        static let notificationCount = "cameraMonitor.notificationCount"
        static let lastEventDescription = "cameraMonitor.lastEventDescription"
        static let lastErrorDescription = "cameraMonitor.lastErrorDescription"
    }

    private static let notificationCooldown: TimeInterval = 30
    private static let centralRestoreIdentifier = "CameraMonitorCentral"

    var bluetoothState: CBManagerState = .unknown
    var notificationAuthorization: UNAuthorizationStatus = .notDetermined
    var scenePhase: ScenePhase = .inactive
    var isArmed: Bool
    var isScanning = false
    var lastDetectedCameraName: String?
    var lastDetectedAt: Date?
    var lastDetectedPeripheralIdentifier: String?
    var lastDetectedRSSI: Int?
    var discoveryCount: Int
    var lastRestoreAt: Date?
    var restoreCount: Int
    var lastBackgroundWakeAt: Date?
    var backgroundWakeCount: Int
    var lastNotificationAt: Date?
    var lastNotificationIdentifier: String?
    var notificationCount: Int
    var lastEventDescription: String?
    var lastErrorDescription: String?

    var bluetoothStateText: String { bluetoothState.displayText }
    var notificationAuthorizationText: String { notificationAuthorization.displayText }
    var scenePhaseText: String { scenePhase.displayText }

    @ObservationIgnored private let notificationCenter = UNUserNotificationCenter.current()
    @ObservationIgnored private var centralManager: CBCentralManager!
    @ObservationIgnored private let logger = Logger(subsystem: AppGroup.logSubsystem, category: "CameraMonitor")

    override init() {
        isArmed = AppGroup.defaults.bool(forKey: DefaultsKey.isArmed)
        lastDetectedCameraName = AppGroup.defaults.string(forKey: DefaultsKey.lastDetectedCameraName)
        lastDetectedAt = AppGroup.defaults.object(forKey: DefaultsKey.lastDetectedAt) as? Date
        lastDetectedPeripheralIdentifier = AppGroup.defaults.string(forKey: DefaultsKey.lastDetectedPeripheralIdentifier)
        if AppGroup.defaults.object(forKey: DefaultsKey.lastDetectedRSSI) != nil {
            lastDetectedRSSI = AppGroup.defaults.integer(forKey: DefaultsKey.lastDetectedRSSI)
        } else {
            lastDetectedRSSI = nil
        }
        discoveryCount = AppGroup.defaults.integer(forKey: DefaultsKey.discoveryCount)
        lastRestoreAt = AppGroup.defaults.object(forKey: DefaultsKey.lastRestoreAt) as? Date
        restoreCount = AppGroup.defaults.integer(forKey: DefaultsKey.restoreCount)
        lastBackgroundWakeAt = AppGroup.defaults.object(forKey: DefaultsKey.lastBackgroundWakeAt) as? Date
        backgroundWakeCount = AppGroup.defaults.integer(forKey: DefaultsKey.backgroundWakeCount)
        lastNotificationAt = AppGroup.defaults.object(forKey: DefaultsKey.lastNotificationAt) as? Date
        lastNotificationIdentifier = AppGroup.defaults.string(forKey: DefaultsKey.lastNotificationIdentifier)
        notificationCount = AppGroup.defaults.integer(forKey: DefaultsKey.notificationCount)
        lastEventDescription = AppGroup.defaults.string(forKey: DefaultsKey.lastEventDescription)
        lastErrorDescription = AppGroup.defaults.string(forKey: DefaultsKey.lastErrorDescription)

        super.init()

        notificationCenter.delegate = self
        centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.centralRestoreIdentifier]
        )

        Task {
            await refreshNotificationAuthorization()
        }
    }

    func activate() async {
        if !isArmed {
            isArmed = true
            AppGroup.defaults.set(true, forKey: DefaultsKey.isArmed)
            logger.notice("Camera monitor armed")
        }

        do {
            let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound])
            logger.info("Notification authorization request resolved to \(granted, privacy: .public)")
        } catch {
            logger.error("Notification authorization request failed: \(error.localizedDescription, privacy: .public)")
            setLastErrorDescription("Notifications failed: \(error.localizedDescription)")
        }

        await refreshNotificationAuthorization()
        rearmScanningFromForeground()
    }

    func updateScenePhase(_ newPhase: ScenePhase) {
        guard scenePhase != newPhase else { return }

        scenePhase = newPhase
        logger.info("Scene phase changed to \(newPhase.displayText, privacy: .public)")
    }

    func sendTestNotification() async {
        let timestamp = Date.now

        await scheduleNotification(
            identifier: "camera-monitor-test-\(timestamp.timeIntervalSince1970)",
            title: "Locus camera alerts",
            body: "Test notification from the watch app.",
            scheduledAt: timestamp
        )
    }

    func handleBluetoothAlertWake() async {
        let wakeTime = Date.now

        lastBackgroundWakeAt = wakeTime
        backgroundWakeCount += 1
        AppGroup.defaults.set(wakeTime, forKey: DefaultsKey.lastBackgroundWakeAt)
        AppGroup.defaults.set(backgroundWakeCount, forKey: DefaultsKey.backgroundWakeCount)

        setLastEventDescription("Background Bluetooth wake at \(wakeTime.formatted(date: .omitted, time: .standard))")
        refreshScanning()
    }

    func resetDiagnostics() {
        lastDetectedCameraName = nil
        lastDetectedAt = nil
        lastDetectedPeripheralIdentifier = nil
        lastDetectedRSSI = nil
        discoveryCount = 0
        lastRestoreAt = nil
        restoreCount = 0
        lastBackgroundWakeAt = nil
        backgroundWakeCount = 0
        lastNotificationAt = nil
        lastNotificationIdentifier = nil
        notificationCount = 0
        lastEventDescription = nil
        lastErrorDescription = nil

        AppGroup.defaults.removeObject(forKey: DefaultsKey.lastDetectedCameraName)
        AppGroup.defaults.removeObject(forKey: DefaultsKey.lastDetectedAt)
        AppGroup.defaults.removeObject(forKey: DefaultsKey.lastDetectedPeripheralIdentifier)
        AppGroup.defaults.removeObject(forKey: DefaultsKey.lastDetectedRSSI)
        AppGroup.defaults.removeObject(forKey: DefaultsKey.discoveryCount)
        AppGroup.defaults.removeObject(forKey: DefaultsKey.lastRestoreAt)
        AppGroup.defaults.removeObject(forKey: DefaultsKey.restoreCount)
        AppGroup.defaults.removeObject(forKey: DefaultsKey.lastBackgroundWakeAt)
        AppGroup.defaults.removeObject(forKey: DefaultsKey.backgroundWakeCount)
        AppGroup.defaults.removeObject(forKey: DefaultsKey.lastNotificationAt)
        AppGroup.defaults.removeObject(forKey: DefaultsKey.lastNotificationIdentifier)
        AppGroup.defaults.removeObject(forKey: DefaultsKey.notificationCount)
        AppGroup.defaults.removeObject(forKey: DefaultsKey.lastEventDescription)
        AppGroup.defaults.removeObject(forKey: DefaultsKey.lastErrorDescription)

        for camera in KnownCamera.allCases {
            AppGroup.defaults.removeObject(forKey: camera.lastNotificationAtKey)
        }

        logger.info("Camera monitor diagnostics reset")
    }

    private func refreshScanning() {
        guard isArmed else {
            stopScanning()
            return
        }

        guard bluetoothState == .poweredOn else {
            isScanning = false
            return
        }

        guard !centralManager.isScanning else {
            isScanning = true
            return
        }

        centralManager.scanForPeripherals(withServices: KnownCamera.allCases.map(\.advertisedServiceUUID), options: nil)
        isScanning = true
        logger.notice("Started Bluetooth scan for camera advertisements")
        setLastEventDescription("Scanning for camera advertisements")
    }

    private func rearmScanningFromForeground() {
        guard isArmed else {
            stopScanning()
            return
        }

        guard bluetoothState == .poweredOn else {
            isScanning = false
            return
        }

        if centralManager.isScanning {
            centralManager.stopScan()
            logger.info("Stopped Bluetooth scan to re-arm from foreground")
        }

        isScanning = false

        centralManager.scanForPeripherals(withServices: KnownCamera.allCases.map(\.advertisedServiceUUID), options: nil)
        isScanning = true
        logger.notice("Re-armed Bluetooth scan for camera advertisements from foreground")
        setLastEventDescription("Re-armed scan from foreground")
    }

    private func stopScanning() {
        if centralManager.isScanning {
            centralManager.stopScan()
            logger.info("Stopped Bluetooth scan")
        }

        isScanning = false
    }

    private func handleDiscovery(
        peripheralIdentifier: UUID,
        peripheralName: String?,
        advertisementData: [String: Any],
        rssi: NSNumber
    ) async {
        guard let camera = resolveCamera(peripheralName: peripheralName, advertisementData: advertisementData) else {
            logger.debug("Ignoring Bluetooth discovery without a known camera service")
            return
        }

        let detectedAt = Date.now

        lastDetectedCameraName = camera.displayName
        lastDetectedAt = detectedAt
        lastDetectedPeripheralIdentifier = peripheralIdentifier.uuidString
        lastDetectedRSSI = rssi.intValue
        discoveryCount += 1
        AppGroup.defaults.set(camera.displayName, forKey: DefaultsKey.lastDetectedCameraName)
        AppGroup.defaults.set(detectedAt, forKey: DefaultsKey.lastDetectedAt)
        AppGroup.defaults.set(peripheralIdentifier.uuidString, forKey: DefaultsKey.lastDetectedPeripheralIdentifier)
        AppGroup.defaults.set(rssi.intValue, forKey: DefaultsKey.lastDetectedRSSI)
        AppGroup.defaults.set(discoveryCount, forKey: DefaultsKey.discoveryCount)

        let eventDescription = "Detected \(camera.displayName) at RSSI \(rssi.intValue)"
        logger.notice("\(eventDescription, privacy: .public)")
        setLastEventDescription(eventDescription)

        guard scenePhase != .active else {
            logger.debug("Suppressing camera notification while app is active")
            return
        }

        guard shouldSendNotification(for: camera, at: detectedAt) else {
            logger.debug("Skipping duplicate notification for \(camera.displayName, privacy: .public)")
            return
        }

        AppGroup.defaults.set(detectedAt, forKey: camera.lastNotificationAtKey)

        await scheduleNotification(
            identifier: "\(camera.notificationIdentifierPrefix)-\(detectedAt.timeIntervalSince1970)",
            title: "Camera detected",
            body: "\(camera.displayName) appeared nearby.",
            scheduledAt: detectedAt
        )
    }

    private func resolveCamera(
        peripheralName: String?,
        advertisementData: [String: Any]
    ) -> KnownCamera? {
        if let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            for camera in KnownCamera.allCases where serviceUUIDs.contains(camera.advertisedServiceUUID) {
                return camera
            }
        }

        guard let peripheralName else {
            return nil
        }

        if peripheralName.contains("GR_") {
            return .ricohGRIIIx
        }

        if peripheralName.contains("G9") {
            return .lumixG9
        }

        return nil
    }

    private func shouldSendNotification(for camera: KnownCamera, at timestamp: Date) -> Bool {
        guard let lastNotificationAt = AppGroup.defaults.object(forKey: camera.lastNotificationAtKey) as? Date else {
            return true
        }

        return timestamp.timeIntervalSince(lastNotificationAt) >= Self.notificationCooldown
    }

    private func scheduleNotification(
        identifier: String,
        title: String,
        body: String,
        scheduledAt: Date
    ) async {
        let settings = await notificationCenter.notificationSettings()

        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            logger.notice("Skipping notification because authorization is \(settings.authorizationStatus.displayText, privacy: .public)")
            notificationAuthorization = settings.authorizationStatus
            setLastErrorDescription("Notifications are \(settings.authorizationStatus.displayText.lowercased())")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        do {
            try await notificationCenter.add(request)
            lastNotificationAt = scheduledAt
            lastNotificationIdentifier = identifier
            notificationCount += 1
            AppGroup.defaults.set(scheduledAt, forKey: DefaultsKey.lastNotificationAt)
            AppGroup.defaults.set(identifier, forKey: DefaultsKey.lastNotificationIdentifier)
            AppGroup.defaults.set(notificationCount, forKey: DefaultsKey.notificationCount)
            setLastErrorDescription(nil)
        } catch {
            logger.error("Failed to schedule local notification: \(error.localizedDescription, privacy: .public)")
            setLastErrorDescription("Notification failed: \(error.localizedDescription)")
        }
    }

    private func refreshNotificationAuthorization() async {
        let settings = await notificationCenter.notificationSettings()
        notificationAuthorization = settings.authorizationStatus
    }

    private func setLastEventDescription(_ description: String) {
        lastEventDescription = description
        AppGroup.defaults.set(description, forKey: DefaultsKey.lastEventDescription)
    }

    private func setLastErrorDescription(_ description: String?) {
        lastErrorDescription = description
        AppGroup.defaults.set(description, forKey: DefaultsKey.lastErrorDescription)
    }
}

extension CameraMonitor: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            bluetoothState = central.state
            logger.info("Bluetooth central state changed to \(central.state.displayText, privacy: .public)")

            if central.state == .poweredOn {
                refreshScanning()
            } else {
                isScanning = false
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        Task { @MainActor in
            let restoredAt = Date.now

            bluetoothState = central.state
            isArmed = true
            isScanning = central.isScanning
            lastRestoreAt = restoredAt
            restoreCount += 1

            AppGroup.defaults.set(true, forKey: DefaultsKey.isArmed)
            AppGroup.defaults.set(restoredAt, forKey: DefaultsKey.lastRestoreAt)
            AppGroup.defaults.set(restoreCount, forKey: DefaultsKey.restoreCount)

            if let restoredServices = dict[CBCentralManagerRestoredStateScanServicesKey] as? [CBUUID] {
                let serviceList = restoredServices.map(\.uuidString).joined(separator: ", ")
                logger.notice("Restored Bluetooth scan for services: \(serviceList, privacy: .public)")
            } else {
                logger.notice("Restored Bluetooth central without explicit scan services")
            }

            setLastEventDescription("Restored Bluetooth scan state")
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            await handleDiscovery(
                peripheralIdentifier: peripheral.identifier,
                peripheralName: peripheral.name,
                advertisementData: advertisementData,
                rssi: RSSI
            )
        }
    }
}

extension CameraMonitor: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

private extension CBManagerState {
    var displayText: String {
        switch self {
        case .unknown:
            return "Unknown"
        case .resetting:
            return "Resetting"
        case .unsupported:
            return "Unsupported"
        case .unauthorized:
            return "Unauthorized"
        case .poweredOff:
            return "Powered Off"
        case .poweredOn:
            return "Powered On"
        @unknown default:
            return "Unknown"
        }
    }
}

private extension UNAuthorizationStatus {
    var displayText: String {
        switch self {
        case .notDetermined:
            return "Not Determined"
        case .denied:
            return "Denied"
        case .authorized:
            return "Authorized"
        case .provisional:
            return "Provisional"
        case .ephemeral:
            return "Ephemeral"
        @unknown default:
            return "Unknown"
        }
    }
}

private extension ScenePhase {
    var displayText: String {
        switch self {
        case .active:
            return "Active"
        case .inactive:
            return "Inactive"
        case .background:
            return "Background"
        @unknown default:
            return "Unknown"
        }
    }
}
