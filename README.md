# TransitHub – iOS App

SwiftUI app for multi-provider public transit. Add any GTFS-compatible agency, browse routes and schedules, see stops on a map, and get real-time vehicle positions and service alerts where supported.

## Features

| Tab | Description |
|-----|-------------|
| **Lignes** | Routes grouped by type (Metro, Bus, Rail, …). Filter by provider. Tap a route for its stop sequence and service alerts. |
| **Carte** | MapKit map showing nearby stops. Tap any stop for its full schedule. |
| **Nearby** | 20 nearest stops sorted by walking distance, with next departures. |
| **Favoris** | Saved stops with quick access to schedules. Swipe to remove. Synced across devices via iCloud. |
| **Plan** | Direct trip planner — pick origin and destination, get departure options. |
| **Alertes** | Active service alerts across all configured providers. |

## Requirements

- Xcode 15+
- iOS 17+ deployment target
- Internet connection for first-time GTFS download

---

## Setup (Option A — XcodeGen, recommended)

```bash
# Install XcodeGen if needed
brew install xcodegen

# Generate the .xcodeproj
cd "path/to/TransitHub"
xcodegen

# Open in Xcode
open TransitHub.xcodeproj
```

Xcode will automatically resolve the ZIPFoundation Swift Package dependency.

---

## Setup (Option B — Manual Xcode project)

1. Open Xcode → **File > New > Project** → **iOS App**
2. Product Name: `TransitHub`, Interface: SwiftUI, Language: Swift
3. Choose a location outside of this folder, then **move all files** from `Sources/TransitHub/` into the new project, preserving the group structure.
4. Add the ZIPFoundation package:
   - **File > Add Package Dependencies…**
   - URL: `https://github.com/weichsel/ZIPFoundation.git`
   - Version: `0.9.19`
5. Add location permission in `Info.plist`:
   - Key: `NSLocationWhenInUseUsageDescription`
   - Value: `TransitHub uses your location to find nearby stops.`

---

## Adding a Transit Provider

On first launch the app shows an empty state. Tap **Ajouter un réseau** to search the [MobilityDatabase](https://database.mobilitydata.org/) catalogue and add any GTFS-compatible agency. Multiple providers can be active simultaneously.

Each provider gets its own SQLite database (`gtfs_{id}.sqlite`) and the app refreshes it automatically before its feed's expiry date.

Providers with a real-time API (e.g. STM) additionally need an API key configured in **Settings → Clé API**.

---

## Architecture

```
Sources/TransitHub/
├── Models/
│   ├── GTFSModels.swift          — Route, Stop, Trip, ScheduleEntry, ServiceCalendar
│   ├── GTFSRealtimeModels.swift  — VehiclePosition, RouteDelay, ServiceAlert
│   ├── TransitProvider.swift     — Provider descriptor (id, feed URL, brand color, …)
│   ├── MobilityDBModels.swift    — MobilityDatabase API response types
│   └── TripPlan.swift            — TripItinerary, PlanEndpoint
├── Services/
│   ├── GTFSDatabase.swift        — SQLite3 wrapper (schema + queries); one instance per call
│   ├── GTFSService.swift         — Download ZIP → stream-parse CSV → import to SQLite
│   ├── GTFSRealtimeService.swift — Protobuf GTFS-RT: vehicle positions, trip updates, alerts
│   ├── MobilityDatabaseService.swift — Searches the MobilityDatabase catalogue
│   ├── TripPlanner.swift         — Direct trip planning (no transfers)
│   ├── LocationService.swift     — CLLocationManager wrapper
│   ├── LiveActivityManager.swift — Live Activity / Dynamic Island updates
│   ├── NotificationManager.swift — Local push notifications
│   └── gtfs_realtime.pb.swift    — Generated protobuf bindings
├── Stores/
│   └── UserProvidersStore.swift  — Persists user-configured providers to Documents/
├── ViewModels/
│   └── AppViewModel.swift        — Central @MainActor store (routes, stops, realtime, favorites)
└── Views/
    ├── TransitHubApp.swift       — @main entry + loading / error screens
    ├── MainTabView.swift         — TabView shell + realtime refresh timer
    ├── RoutesView.swift          — Route list (grouped by type) + RouteDetailView
    ├── TransitMapView.swift      — MapKit map with stop annotations
    ├── NearbyView.swift          — Nearest-stops list
    ├── StopDetailView.swift      — Timetable (grouped by hour) + favourite toggle
    ├── FavoritesView.swift       — Persisted favourites with iCloud sync
    ├── PlanView.swift            — Trip planner UI
    ├── PlanStopPickerView.swift  — Stop picker for trip origin / destination
    ├── AlertsView.swift          — Service alert list
    ├── AddProviderView.swift     — MobilityDatabase search + provider onboarding
    ├── SettingsView.swift        — Per-provider GTFS info, force-update, API key
    └── NoProvidersView.swift     — Empty-state CTA
```

## Data flow

1. **Provider added** → `UserProvidersStore` persists it → `AppViewModel` triggers `GTFSService.downloadAndImport()`
2. **Import** — ZIP downloaded to a temp dir, extracted, CSV files streamed line-by-line into SQLite (batches of 50 000 rows inside transactions to limit memory use)
3. **Schedules** — queried on-demand by joining `stop_times → trips → routes` filtered by today's active service IDs (computed from `calendar` + `calendar_dates`)
4. **Real-time** — `GTFSRealtimeService` polls Protobuf endpoints every 30 s; vehicle positions, trip-update delays, and service alerts are merged across all providers and published to `AppViewModel`
5. **Favorites** — stored as `"providerId:stopId"` keys in both `UserDefaults` (local) and `NSUbiquitousKeyValueStore` (iCloud); merged on external change notification

## Notes

- `stop_times.txt` can contain several million rows (STM ~8 M, RTL ~830 K). The importer streams it with a 64 KB read buffer and commits in batches.
- The database is refreshed when today's date approaches the feed's last covered date (derived from the `calendar` end dates at import time), not on a fixed interval.
- GTFS-RT real-time requires an API key per provider. Register at the provider's developer portal (e.g. https://www.stm.info/en/about/developers for STM).
- The import pipeline is GTFS-column-order independent (uses header-based lookup), handles BOM, CRLF, quoted fields, subfolder-nested ZIPs, feeds with `calendar_dates`-only service, missing `direction_id`, and GTFS times past midnight (> 24:00:00).
