import CoreLocation
import OSLog
import SwiftUI

private let logger = Logger(subsystem: AppGroup.logSubsystem, category: "SettingsView")

struct SettingsView: View {
    @Environment(TrackStore.self) private var store
    @Environment(Tracker.self) private var tracker
    @Environment(CameraMonitor.self) private var cameraMonitor

    @AppStorage(Settings.intervalKey, store: AppGroup.defaults) private var interval: Double = Settings.intervalDefault

    @State private var isShowingDeleteAllConfirmation = false
    @State private var isDeletingAll = false

    var body: some View {
        Form {
            Section("Tracking") {
                Picker("Interval", selection: $interval) {
                    ForEach(Settings.intervalOptions, id: \.self) { seconds in
                        Text(intervalLabel(for: seconds)).tag(seconds)
                    }
                }
            }

            Section {
                LabeledContent("Access", value: tracker.locationAuthorization.displayText)
            } header: {
                Text("Location")
            } footer: {
                Text("You can change this in Settings > Privacy & Security > Location Services.")
            }

            Section {
                LabeledContent("App state", value: cameraMonitor.scenePhaseText)
                LabeledContent("Bluetooth", value: cameraMonitor.bluetoothStateText)
                LabeledContent("Notifications", value: cameraMonitor.notificationAuthorizationText)
                LabeledContent("Armed", value: cameraMonitor.isArmed ? "Yes" : "No")
                LabeledContent("Scanning", value: cameraMonitor.isScanning ? "Yes" : "No")
                LabeledContent("Discoveries", value: "\(cameraMonitor.discoveryCount)")
                LabeledContent("Restores", value: "\(cameraMonitor.restoreCount)")
                LabeledContent("Alert tasks", value: "\(cameraMonitor.backgroundWakeCount)")
                LabeledContent("Notifications sent", value: "\(cameraMonitor.notificationCount)")

                if let lastDetectedCameraName = cameraMonitor.lastDetectedCameraName,
                   let lastDetectedAt = cameraMonitor.lastDetectedAt {
                    LabeledContent("Last seen", value: "\(lastDetectedCameraName) at \(formattedTimestamp(lastDetectedAt))")
                }

                if let lastDetectedPeripheralIdentifier = cameraMonitor.lastDetectedPeripheralIdentifier {
                    LabeledContent("Last peripheral", value: abbreviatedIdentifier(lastDetectedPeripheralIdentifier))
                }

                if let lastDetectedRSSI = cameraMonitor.lastDetectedRSSI {
                    LabeledContent("Last RSSI", value: "\(lastDetectedRSSI) dBm")
                }

                if let lastRestoreAt = cameraMonitor.lastRestoreAt {
                    LabeledContent("Last restore", value: formattedTimestamp(lastRestoreAt))
                }

                if let lastBackgroundWakeAt = cameraMonitor.lastBackgroundWakeAt {
                    LabeledContent("Last wake", value: formattedTimestamp(lastBackgroundWakeAt))
                }

                if let lastNotificationAt = cameraMonitor.lastNotificationAt {
                    LabeledContent("Last notification", value: formattedTimestamp(lastNotificationAt))
                }

                Button("Arm camera alerts") {
                    Task {
                        await cameraMonitor.activate()
                    }
                }

                Button("Send test notification") {
                    Task {
                        await cameraMonitor.sendTestNotification()
                    }
                }

                Button("Reset diagnostics", role: .destructive) {
                    cameraMonitor.resetDiagnostics()
                }
            } header: {
                Text("Camera alerts")
            } footer: {
                Text(cameraAlertsFooter)
            }

            Section {
                Button(role: .destructive) {
                    logger.info("Delete all tracks button pressed")
                    isShowingDeleteAllConfirmation = true
                } label: {
                    Text(isDeletingAll ? "Deleting..." : "Delete all tracks")
                }
                .disabled(tracker.isActive || isDeletingAll)
            } header: {
                Text("Storage")
            } footer: {
                Text(storageFooter)
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            logger.debug("Settings view appeared")
        }
        .onChange(of: interval) { _, newInterval in
            logger.info("Sampling interval changed to \(Int(newInterval), privacy: .public)s")
        }
        .confirmationDialog("Delete all tracks?", isPresented: $isShowingDeleteAllConfirmation) {
            Button("Delete all", role: .destructive) {
                logger.info("Delete all confirmed")
                isDeletingAll = true
                Task { @MainActor in
                    await store.deleteAll()
                    isDeletingAll = false
                }
            }

            Button("Cancel", role: .cancel) {
                logger.debug("Delete all canceled")
            }
        } message: {
            Text("All track data from this watch will be deleted, including tracks stored in iCloud. This cannot be undone.")
        }
    }

    private func intervalLabel(for seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "\(Int(seconds))s"
        }

        let minutes = Int(seconds / 60)
        return "\(minutes)m"
    }

    private var storageFooter: String {
        if isDeletingAll {
            return ""
        } else if tracker.isActive {
            return "Stop recording before deleting tracks."
        } else {
            return "Deletes all tracks from this watch, including tracks in iCloud."
        }
    }

    private var cameraAlertsFooter: String {
        var lines = ["Launch Locus once, then power on a known camera to test background detection."]

        if let lastEventDescription = cameraMonitor.lastEventDescription {
            lines.append(lastEventDescription)
        }

        if let lastErrorDescription = cameraMonitor.lastErrorDescription {
            lines.append(lastErrorDescription)
        }

        return lines.joined(separator: "\n")
    }

    private func formattedTimestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    private func abbreviatedIdentifier(_ identifier: String) -> String {
        guard identifier.count > 8 else {
            return identifier
        }

        return String(identifier.prefix(8))
    }
}
