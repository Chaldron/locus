import CoreLocation
import OSLog
import SwiftUI

private let logger = Logger(subsystem: AppGroup.logSubsystem, category: "SettingsView")

struct SettingsView: View {
    @Environment(TrackStore.self) private var store
    @Environment(Tracker.self) private var tracker

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
}
