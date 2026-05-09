# TransitHub – iOS App

SwiftUI app that displays STM (Société de transport de Montréal) transit data including metro lines, bus routes, schedules, and a real-time map.

## Features

| Tab | Description |
|-----|-------------|
| **Lignes** | All metro and bus routes. Tap a route to browse its stops. |
| **Carte** | MapKit map showing stops near you. Tap any stop for its full schedule. |
| **Nearby** | List of the 20 nearest stops sorted by walking distance. |
| **Favoris** | Saved stops with quick access to schedules. Swipe to remove. |

## Requirements

- Xcode 15+
- iOS 17+ deployment target
- Internet connection for first-time GTFS download (~50 MB)

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

## First Launch

On first run the app downloads and imports the STM GTFS static feed (~50 MB ZIP). This takes **1–3 minutes** depending on connection speed. The data is cached in SQLite and refreshes automatically every 7 days.

GTFS source: `https://www.stm.info/sites/default/files/gtfs/gtfs_stm.zip`

---

## Architecture

```
Sources/TransitHub/
├── Models/
│   └── GTFSModels.swift        — Route, Stop, Trip, ScheduleEntry
├── Services/
│   ├── GTFSDatabase.swift      — SQLite3 wrapper (schema + all queries)
│   ├── GTFSService.swift       — Download ZIP, stream-parse CSV → SQLite
│   └── LocationService.swift   — CLLocationManager wrapper
├── ViewModels/
│   └── AppViewModel.swift      — Central @MainActor ObservableObject
└── Views/
    ├── TransitHubApp.swift     — @main entry + loading / error screens
    ├── MainTabView.swift       — TabView shell
    ├── RoutesView.swift        — Route list + RouteDetailView
    ├── TransitMapView.swift    — MapKit map with stop annotations
    ├── NearbyView.swift        — Nearest-stops list
    ├── StopDetailView.swift    — Timetable (grouped by hour) + favourite toggle
    └── FavoritesView.swift     — Persisted favourites
```

## Notes

- `stop_times.txt` can contain 3–5 million rows. The importer streams the file line-by-line in batches of 50 000 inside SQLite transactions to avoid memory pressure.
- Schedules are queried on-demand from SQLite for today's active service IDs.
- GTFS-RT (real-time vehicle positions) requires an STM API key — register at https://www.stm.info/en/about/developers.
