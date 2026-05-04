import OSLog
import SwiftUI

private let logger = Logger(subsystem: AppGroup.logSubsystem, category: "App")

@main struct LocusApp: App {
    @Environment(\.scenePhase) private var scenePhase

    @State private var trackStore: TrackStore
    @State private var tracker: Tracker
    @State private var cameraMonitor: CameraMonitor

    init() {
        logger.debug("\(#function)")

        let trackStore = TrackStore()
        let tracker = Tracker(trackStore: trackStore)
        let cameraMonitor = CameraMonitor()

        _trackStore = State(initialValue: trackStore)
        _tracker = State(initialValue: tracker)
        _cameraMonitor = State(initialValue: cameraMonitor)
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ContentView()
            }
            .environment(trackStore)
            .environment(tracker)
            .environment(cameraMonitor)
            .onAppear {
                cameraMonitor.updateScenePhase(scenePhase)
            }
            .onChange(of: scenePhase) { _, newScenePhase in
                cameraMonitor.updateScenePhase(newScenePhase)
            }
        }
        .backgroundTask(.bluetoothAlert) {
            await cameraMonitor.handleBluetoothAlertWake()
        }
    }
}
