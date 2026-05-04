# Locus Agent Guide

## Purpose

Locus is an Apple Watch GPS logger for geotagging photos taken with a separate camera. The watch app records sampled locations into a GPX file, keeps that file valid while recording, stores it locally in an App Group container, and uploads the finished file to the app's CloudKit public database. This repo also contains a command-line export script that downloads those CloudKit GPX assets back to disk. The watch app and exporter are developed for and used by the solo developer for their own purposes; do not over-generalize to many "users", and asking for input or action from the developer (e.g. for modifying CloudKit settings or blowing away the existing database) is okay.

Treat the current source as the source of truth. `AGENTS.md` is the maintained project context document, and `TODO.md` contains tasks yet to be finished.

## Repo Layout

- `TODO.md`: pending tasks yet to be completed
- `Locus/Locus.xcodeproj`: Xcode project. The target source folders use Xcode filesystem-synchronized groups, so adding or renaming source files under them usually does not require manual project file edits.
- `Locus/Locus Watch`: watch app source.
- `Resources/Logo.svg`: standalone logo artwork.
- `Scripts/generate_app_icons.swift`: renders `Resources/Logo.svg` into the watchOS asset catalog during builds.
- `Scripts/locus-exporter-cli.js`: Linux-friendly CLI exporter for downloading all public CloudKit GPX assets into a local folder.

## Targets

- `Locus`: watch app container target created by the Xcode watchOS template, bundle id `com.adityasm.locus`.
- `Locus Watch`: standalone watchOS app, bundle id `com.adityasm.locus.watch`, deployment target `watchOS 26.4`.
- Shared Xcode schemes:
  - `Development` is the normal development scheme with `Run = Debug`
  - `Personal`
    - builds the same watch app/container pair as `Locus Watch`
    - uses `Release` for the Run action and disables automatic debugger attach so personal on-watch installs behave closer to a normal standalone launch while still using development signing and the CloudKit development environment

There are no test targets in the project right now.

## Watch App Summary

The watch app is intentionally small and stateful:

- `Locus/Locus Watch/Locus.swift`: creates `TrackStore`, `Tracker`, and `CameraMonitor`, injects them into SwiftUI environment, shows a `NavigationStack`, and handles SwiftUI Bluetooth background tasks.
- `Locus/Locus Watch/Models.swift`: defines `Point` and `Track`.
- `Locus/Locus Watch/Services/AppGroup.swift`: centralizes app group id `group.com.adityasm.locus`, the persistent short device id, and the shared fractional ISO 8601 formatter.
- `Locus/Locus Watch/Services/CameraMonitor.swift`: scan-only BLE proof of concept for camera detection. It uses `CBCentralManager` state restoration plus local notifications, watches for the hard-coded Ricoh GR IIIx and Panasonic Lumix G9 advertised service UUIDs, and records debug state in App Group defaults for the settings screen.
- `Locus/Locus Watch/Services/Settings.swift`: static App Group-backed interval setting. Options are `5, 10, 30, 60, 120, 300, 600, 900, 1200, 1800, 3600` seconds; default is `30`.
- `Locus/Locus Watch/Services/Tracker.swift`: requests when-in-use location permission, starts `CLBackgroundActivitySession`, consumes `CLLocationUpdate.liveUpdates()`, drops stale startup fixes, samples by elapsed interval, appends points to the active GPX file, and uploads the finished track when recording stops.
- `Locus/Locus Watch/Services/GPXFile.swift`: incremental GPX writer that rewrites the closing footer on every append so the file stays valid throughout recording and stores timezone metadata in the GPX header.
- `Locus/Locus Watch/Services/TrackStore.swift`: local file inventory plus CloudKit sync service, including startup retries for pending uploads and delete-all cleanup for this watch's CloudKit records.

### Watch Data Flow

1. `ContentView` calls `tracker.start()`.
2. `Tracker` reserves an id and file URL via `TrackStore.startingNewTrack(startTime:)`.
3. `GPXFile` creates `<AppGroup container>/Tracks/<device-id>-<timestamp>-<suffix>.gpx`.
4. `Tracker` listens to `CLLocationUpdate.liveUpdates()`.
5. Each accepted sample becomes a `Point` and is appended to the GPX file.
6. After a fixed number of accepted points, `Tracker` rolls over to a new GPX file without stopping the live location stream and queues the completed segment for upload.
7. On stop or cancellation, `Tracker.finish()` invalidates the background session, refreshes the local store, and queues a CloudKit upload.

### Storage and Sync

- Local files are the source of truth.
- GPX filenames include the watch's short device id, a UTC compact timestamp, and a short unique suffix, like `<DEVICEID>-yyyyMMdd-HHmmss-ABC123.gpx`.
- Each watch persists its own short device id in the App Group container.
- The device id is baked into the track id at creation time, so local filenames, CloudKit record names, and export filenames are all inherently scoped to the originating watch.
- `TrackStore` parses each local GPX file to recover:
  - `startTime` from `<metadata><time>`
  - `pointCount` by counting `<trkpt `
- Cloud sync state is stored as a JSON-encoded `Set<String>` in App Group `UserDefaults` under `uploadedIDs`.
- Uploads use a long-lived `CKModifyRecordsOperation` into the CloudKit public database for container `iCloud.com.adityasm.locus.v2`.
- CloudKit record type is `Track` with fields:
  - `startTime`
  - `filename`
  - `file` (`CKAsset`)
- Deleting a track removes the local file, clears its uploaded marker, and attempts to delete the matching CloudKit record.
- `Delete all tracks` removes all local files, clears uploaded markers, then scans CloudKit for records whose record name matches the current watch's device id prefix and deletes those remote copies too.

### Watch UI

- `Locus/Locus Watch/Views/ContentView.swift`:
  - Start/Stop button
  - live point count while recording
  - last recorded latitude/longitude
  - toolbar navigation to tracks and settings
- `Locus/Locus Watch/Views/TracksView.swift`:
  - lists local GPX tracks
  - shows point count and start time
  - shows pending/uploading/uploaded iCloud badge
  - swipe left for delete and (for pending tracks) retry upload actions
- `Locus/Locus Watch/Views/SettingsView.swift`:
  - interval picker
  - current location authorization summary
  - camera alert debug/status section with manual re-arm and test-notification buttons

## CLI Export Tool

The exporter is a simple script for downloading every `Track` asset in the public CloudKit database to a local directory, overwriting any existing file with the same name.

- `Scripts/locus-exporter-cli.js`:
  - accepts all inputs on the command line
  - signs CloudKit server-to-server requests directly from a PEM private key using Node's crypto APIs
  - queries all public `Track` records with pagination
  - downloads each asset through its CloudKit `downloadURL`
  - writes through a `.<filename>.part` temp file before replacing the final file
  - assumes Node.js 18+ for the built-in `fetch` API

## Style Expectations

Keep this repo optimized for a solo developer reading it quickly and maintaining it over time.

- Prefer direct code over reusable-looking layers. Add a helper only when it removes real duplication or isolates an Apple/framework constraint.
- Use descriptive names for state and locals. If a variable represents a specific thing like a location task, GPX file, or export batch, name it that way.
- Separate distinct phases inside a function with blank lines: guards, setup, main work, cleanup, and state updates should not run together visually.
- Keep functions focused, but do not split tiny one-use helpers out just to look clean on paper.
- Avoid enterprise-style defensive code. Only sanitize, normalize, or heavily validate data when it crosses a real external boundary such as user input, CloudKit, or file contents.
- Prefer simple user-facing error text. Put detailed diagnostics in logs.
- Comments should be rare and explain non-obvious behavior or platform constraints, not restate the code.
- When this file drifts from the implementation, update it to match the code instead of preserving stale intent.

## Capabilities and Project Metadata

- Watch info plist: `Locus/Locus-Watch-Info.plist`
  - enables background location and Core Bluetooth via `UIBackgroundModes = location, bluetooth-central`
  - sets `NSBluetoothAlwaysUsageDescription` for camera detection alerts
- Watch entitlements: `Locus/Locus Watch/Locus.entitlements`
  - CloudKit container `iCloud.com.adityasm.locus.v2`
  - App Group `group.com.adityasm.locus`
- The watch project file sets `NSLocationWhenInUseUsageDescription` to explain GPX tracking for photo geotagging.
- App icons are generated from `Resources/Logo.svg` by the watch target build phase. The watch app uses a single 1024px asset in `AppIcon.appiconset`.
- The watch target intentionally keeps `ENABLE_USER_SCRIPT_SANDBOXING = NO` because the icon-generation build phase writes directly into the source asset catalog during the build. The project-level default can stay stock.

## Historical Notes

Important differences so future agents do not assume the original request is a perfect description of the shipped app:

- The original prompt sketches a status dot and page-style watch UI; the current watch app uses a `NavigationStack` with toolbar links and does not show the red/orange/green status dot.
- The original prompt mentions a settings help icon or sheet; the current settings screen shows plain authorization text plus a footer message instead.
- The repo now uses CloudKit public-database storage plus a standalone CLI exporter script instead of a macOS exporter app.
- The current code supports multiple watches sharing one iCloud account by baking a persistent short device id into track ids at creation time.
- `Settings` is currently a static enum backed by `UserDefaults`, not an observable service.

## Good Files to Start With

- Watch recording behavior: `Locus/Locus Watch/Services/Tracker.swift`
- Camera detection behavior: `Locus/Locus Watch/Services/CameraMonitor.swift`
- GPX file format and write strategy: `Locus/Locus Watch/Services/GPXFile.swift`
- Local file parsing and CloudKit upload: `Locus/Locus Watch/Services/TrackStore.swift`
- Watch UI: `Locus/Locus Watch/Views`
- CLI export flow: `Scripts/locus-exporter-cli.js`

## Bookkeeping

- Edit AGENTS.md if you think something is worth remembering for future agentic tasks. For example, guidance on coding style, more information about the target user demographic, etc.
- Edit TODO.md as needed, for example whenever you finish a task or think of a new one.

## Coding Style

- Add whitespace between logical blocks of code. For example, local and global variable declarations in a class should be separate by whitespace. If a function does multiple things in a sequence, split up those pieces with a whitespace. 
- Prefer descriptive variable and function names over shorter ones like `t` or `trk`, but avoid over-descriptive variable names as well.
- Avoid overengineering; this is a project for personal use maintained by a solo developer. For example, asking the developer to clear the iCloud state instead of implementing a migration is a good trade-off. Skipping enterprise-y features like excessive testing, input santization, hardening, and scaling is a good trade-off.
