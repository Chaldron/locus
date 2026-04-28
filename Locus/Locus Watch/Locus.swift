import OSLog
import SwiftUI

private let logger = Logger(subsystem: AppGroup.logSubsystem, category: "App")

@main struct LocusApp: App {
    @State private var trackStore: TrackStore
    @State private var tracker: Tracker

    init() {
        logger.debug("\(#function)")

        let trackStore = TrackStore()
        let tracker = Tracker(trackStore: trackStore)

        _trackStore = State(initialValue: trackStore)
        _tracker = State(initialValue: tracker)
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ContentView()
            }
            .environment(trackStore)
            .environment(tracker)
        }
    }
}
