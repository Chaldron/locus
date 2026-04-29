import OSLog
import SwiftUI

private let logger = Logger(subsystem: AppGroup.logSubsystem, category: "TracksView")

struct TracksView: View {
    @Environment(TrackStore.self) private var store
    @Environment(Tracker.self) private var tracker

    @State private var pendingRetryTrack: Track?
    @State private var pendingDeleteTrack: Track?

    var body: some View {
        Group {
            if store.tracks.isEmpty {
                ContentUnavailableView("No tracks saved yet", systemImage: "mappin.slash")
            } else {
                List {
                    ForEach(store.tracks) { track in
                        let isActiveTrack = tracker.activeTrackID == track.id
                        TrackRow(
                            track: track,
                            isActiveTrack: isActiveTrack,
                            onDeleteRequest: { pendingDeleteTrack = track },
                            onRetryUploadRequest: { pendingRetryTrack = track }
                        )
                    }
                }
            }
        }
        .navigationTitle("Tracks")
        .onAppear {
            logger.debug("Tracks view appeared; refreshing local tracks")
            store.refresh()
        }
        .confirmationDialog(
            "Retry upload?",
            isPresented: isShowingRetryUploadConfirmation,
            presenting: pendingRetryTrack
        ) { track in
            Button("Retry Upload") {
                logger.info("Retry upload confirmed for track \(track.id, privacy: .public)")
                pendingRetryTrack = nil
                Task { await store.upload(trackID: track.id) }
            }

            Button("Cancel", role: .cancel) {
                logger.debug("Retry upload canceled for track \(track.id, privacy: .public)")
                pendingRetryTrack = nil
            }
        } message: { track in
            Text("Try uploading the track from \(track.startTime.formatted(date: .abbreviated, time: .shortened)) to iCloud again?")
        }
        .confirmationDialog(
            "Delete track?",
            isPresented: isShowingDeleteConfirmation,
            presenting: pendingDeleteTrack
        ) { track in
            Button("Delete", role: .destructive) {
                logger.info("Delete confirmed for track \(track.id, privacy: .public)")
                pendingDeleteTrack = nil
                Task { await store.delete(track) }
            }

            Button("Cancel", role: .cancel) {
                logger.debug("Delete canceled for track \(track.id, privacy: .public)")
                pendingDeleteTrack = nil
            }
        } message: { track in
            Text("Delete the track from \(track.startTime.formatted(date: .abbreviated, time: .shortened))?")
        }
    }

    private var isShowingRetryUploadConfirmation: Binding<Bool> {
        Binding(
            get: { pendingRetryTrack != nil },
            set: { isShowing in
                if !isShowing {
                    pendingRetryTrack = nil
                }
            }
        )
    }

    private var isShowingDeleteConfirmation: Binding<Bool> {
        Binding(
            get: { pendingDeleteTrack != nil },
            set: { isShowing in
                if !isShowing {
                    pendingDeleteTrack = nil
                }
            }
        )
    }
}

private struct TrackRow: View {
    let track: Track
    let isActiveTrack: Bool

    let onDeleteRequest: () -> Void
    let onRetryUploadRequest: () -> Void

    var body: some View {
        rowContent
            .swipeActions {
                if !isActiveTrack {
                    Button(role: .destructive) {
                        onDeleteRequest()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }

                if track.uploadState == .pending && !isActiveTrack {
                    Button {
                        onRetryUploadRequest()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise.icloud")
                    }
                    .tint(.blue)
                }
            }
    }

    @ViewBuilder private var badge: some View {
        switch track.uploadState {
        case .pending: Image(systemName: "icloud.slash").foregroundStyle(.orange)
        case .uploading: Image(systemName: "icloud.and.arrow.up").foregroundStyle(.blue)
        case .uploaded: Image(systemName: "icloud.fill").foregroundStyle(.secondary)
        }
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track.startTime.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
            HStack {
                Text(track.pointCount == 1 ? "1 point" : "\(track.pointCount) points")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                badge
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isActiveTrack ? 0.45 : 1)
        .contentShape(Rectangle())
    }
}
