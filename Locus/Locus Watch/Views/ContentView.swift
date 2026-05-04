import OSLog
import SwiftUI

private let logger = Logger(subsystem: AppGroup.logSubsystem, category: "ContentView")

struct ContentView: View {
    @Environment(Tracker.self) private var tracker
    @Environment(CameraMonitor.self) private var cameraMonitor

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)

            VStack(spacing: 4) {
                Text(tracker.pointCount == 1 ? "1 point" : "\(tracker.pointCount) points")
                    .font(.title3.monospacedDigit())
                    .opacity(tracker.state == .recording ? 1 : 0)

                VStack(spacing: 0) {
                    Text(formattedCoordinate(tracker.lastPoint?.latitude ?? 0))
                    Text(formattedCoordinate(tracker.lastPoint?.longitude ?? 0))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .opacity(tracker.lastPoint != nil ? 1 : 0)
            }

            Spacer(minLength: 0)

            actionButton
        }
        .padding(.horizontal)
        .task {
            await cameraMonitor.activate()
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    TracksView()
                } label: {
                    Image(systemName: "list.bullet")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gear")
                }
            }
        }
    }

    @ViewBuilder private var actionButton: some View {
        if tracker.isActive {
            Button(role: .destructive) {
                logger.info("Stop button pressed")
                tracker.stop()
            } label: {
                Text(tracker.state == .stopping ? "Stopping" : "Stop")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .tint(.red)
            .disabled(tracker.state == .stopping)
        } else {
            Button {
                logger.info("Start button pressed")
                Task {
                    do {
                        try await tracker.start()
                    } catch {
                        logger.error("Failed to start recording: \(error.localizedDescription, privacy: .public)")
                    }
                }
            } label: {
                Text(tracker.state == .starting ? "Starting" : (tracker.canStart ? "Start" : "Location off"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .tint(.green)
            .disabled(!tracker.canStart)
        }
    }

    private func formattedCoordinate(_ value: Double) -> String {
        String(format: "%+.5f", value)
    }
}
