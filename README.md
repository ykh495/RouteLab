# RouteLab 0.2

A local iPhone commute recorder, with Chinese and English interfaces, plus an offline Python analysis tool. Start with **START_HERE.md** for Xcode installation and preserving your existing phone records.

## Changes from 0.1

| Your request | Implemented behavior |
|---|---|
| Less repetitive login | Default 15-minute grace period; automatic device authentication when needed; settings for always/grace/never; explicit lock stays locked until you tap Continue. |
| Better destination entry | Apple address/POI autocomplete biased near your location, full-address search, map tap to drop a pin, and map-center selection. |
| Remove specific route buttons | No fixed Koenig or Woodrow–Justin choices in trip setup. Old recorded labels remain available in existing data. |
| Favorite destinations | Home, library, school, parking, and custom categories. Add, rename, select, and delete locally. |
| Fewer departure steps | Foreground location updates automatically; destination selection triggers reference routes; old results cannot replace a newly selected destination. Start rechecks freshness. |
| Readable maps | Green reference route; toggle reference/actual; actual segments use red-to-blue speed colors, gray for unknown speed, and disconnected gaps. |
| Automatic trip analysis | Similar actual traces get route IDs; map matching suggests street names; stops and low speed receive optional cause inferences; construction question after arrival. |
| Bilingual interface | System default or explicit 中文/English at registration and in settings. System prompts still follow iOS localization rules. |

## Requirements and build

- Xcode with an iOS 17+ SDK and support for your connected iPhone. Deployment target remains iOS 17.0; no iOS 18-only APIs.
- Open `RouteLab.xcodeproj`, select your signing Team and unique Bundle Identifier. When upgrading, use **exactly the same Team and Bundle Identifier** as the installed app.
- Run on an iPhone with location access, Precise Location, and a device passcode. A simulator can demonstrate the interface, but meaningful driving data requires real location samples.
- No API key or paid cloud backend. Apple MapKit supplies search and route estimates. Optional OpenStreetMap road queries use a public Overpass service.

This package was prepared in a Linux environment without Xcode or a Swift compiler. Python regression tests and project/resource consistency checks were run here. **Native compilation, Swift core checks, permission dialogs, Face ID, map interactions, and background recording remain to be verified on a Mac/iPhone.** No claim of a successful native build is made.

On a Mac, the optional verification script runs Python tests, the same Swift geometry/statistics code used in the app, and an unsigned simulator build:

```bash
cd /path/to/RouteLab
bash verify-on-mac.sh
```

`Tests/CoreChecks.swift` checks legacy-trip decoding, inference thresholds, route similarity/direction/detours, mph conversion, road matching, ambiguous roads, and statistics. These Swift checks have been supplied but could not be executed in the preparation environment.

## Everyday flow

1. Open RouteLab; permit location and choose a destination by search, favorite, or pin.
2. Reference routes appear automatically; Apple Maps is the default navigation app.
3. Tap **Record and open Maps**. RouteLab snapshots its reference estimate and starts recording before opening the navigation app. Confirm navigation inside that app if necessary.
4. Return to RouteLab after parking and tap **Arrived · finish trip**. Manual finish saves and confirms the trip automatically.
5. Street analysis runs when RouteLab is in the foreground and connected. The final screen asks an optional construction question. Viewing/editing a trip never requires naming roads or correcting stop causes.

GPS updates in the foreground even before a trip, but idle positions are not persisted. Background updates are enabled only for an active recording started in the foreground. This design does not require collecting location continuously when idle. Switching to Maps or locking the screen can continue an active trip; force-quitting, permission revocation, or system termination can interrupt it. Checkpoints permit partial recovery and interrupted records are excluded from comparisons.

Optional arrival detection: after moving at least 300 m, remaining within 60 m of the destination at speed below 0.8 m/s for two minutes creates a candidate arrival at the start of that stop. Confirm or correct it before comparison. Raw points are retained beyond an edited arrival time; statistics use only points within the trip interval.

## Public API boundaries

RouteLab does not observe another app's navigation lifecycle, selected destination, or displayed ETA. It launches Maps for the destination already selected inside RouteLab. A Google Maps callback can provide a way back to an app; it is not a documented destination-and-ETA result API.

The saved automatic estimate is **an independent MapKit reference**, with its capture timestamp, duration, distance, and polyline. Apple Maps or Google Maps may choose a different route, offer different alternatives, or recalculate after launch. Selecting a reference alternative in RouteLab does not force the external app to follow that polyline. v0.1 manually entered external estimates remain readable/exportable; v0.2 does not present an automatic external-ETA claim.

- [Apple address completion](https://developer.apple.com/documentation/mapkit/mklocalsearchcompleter)
- [Apple map coordinate conversion](https://developer.apple.com/documentation/mapkit/mapproxy)
- [Google Maps URLs](https://developers.google.com/maps/documentation/urls/get-started)
- [Google Maps iOS URL schemes and callback behavior](https://developers.google.com/maps/documentation/urls/ios-urlscheme)

## Identification methods and limits

### Actual route grouping

Trips need at least one minute, at least three points, no recorded interruption, and at least 80% observed time coverage before automatic route assignment. Nearby endpoints are within 250 m each. Tracks are sampled roughly every 65 m, capped at 160 points; route matching requires a discrete Fréchet distance of at most 90 m and sampled-length difference no greater than 18%. The oldest available representative of each route is used rather than progressively chaining neighboring tracks.

Route IDs are stable stored keys; numbers are presentation labels for that endpoint neighborhood. Short detours or parallel roads within the tolerance may be grouped together; GPS gaps and noisy endpoints can split otherwise similar routes. This is a local prototype, not a navigation-grade route classifier. No manual road-name field is required.

### Street names and speed limits

After finishing, RouteLab requests roads, mapped traffic signals, level crossings, and shared junction topology from OpenStreetMap through Overpass. A spatial index finds candidates within 35 m; moving direction and one-way tags reject inconsistent segments. Ambiguous matches remain unmatched. Names require at least three consecutive matched samples. The displayed match percentage is the fraction of usable GPS points matched; it does not prove correct identification.

Only explicit numeric `maxspeed` values are used: km/h by default, or mph when tagged. Conditional and directional limits are not collapsed into a guessed value. Missing limits remain unknown. This is contextual analysis, not a speed-limit advisory.

A query uses an outward-rounded bounding area with margins, not the full GPS sequence. Requests are limited to local areas up to 0.25° per axis, with a bounded one-day in-memory cache. Longer trips still record, but may have no road-name lookup. Offline or failed queries leave the trip intact and expose a retry button. Public Overpass availability and mapping completeness are not guaranteed; large deployments would need their own licensed/provisioned data infrastructure.

### Stops and slow travel

For new v0.2 trips:

- Both adjacent valid GPS samples must be below 0.8 m/s before an interval counts as stopped. With second-resolution timestamps, duration **at least 4 seconds** implements “more than 3 seconds.”
- Within 40 m of a mapped signal: inferred signal/intersection wait. Near only a topology junction: inferred intersection wait, explicitly lacking evidence of an actual signal.
- Within 40 m of a mapped railway level crossing and stopped at least 15 seconds: inferred rail wait. Ordinary bridges crossing railways are not automatically level crossings.
- Otherwise the stop cause is unknown. STOP signs, queues, pickups, parking, or unrelated waiting can all resemble these situations.
- Slow travel requires at least 30 seconds. With a mapped limit, threshold is 35% of that limit, capped at 8.33 m/s; without one, threshold is 3 m/s. It suggests congestion but can also be a turn or parking maneuver. Unknown GPS speed is not assigned a stop/slow label.

There are no live camera feeds, signal phases, train movements, or construction reports. User corrections are stored separately from inference and remain optional. Construction is an optional post-trip answer, not automatically detected. The map color shows **your measured vehicle speed**, capped at 80 km/h (about 50 mph) for the blue end; it is not a congestion map or a percent-of-speed-limit display.

Legacy trips retain the original stop rule and event IDs so their saved corrections do not shift. New trips use `stopRuleVersion: 2`.

## Statistics and data

Comparisons separate nearby origin/destination groups, local half-hour departure windows, timezone, and weekday/weekend; outbound and return trips are separate. Each route shows n, mean, median, sample standard deviation (n ≥ 2), and P90 (n ≥ 20). Samples below 5 are flagged as preliminary. Interrupted, unconfirmed candidate arrivals, too-short, sparse, poorly covered, and explicitly excluded trips remain saved but do not enter rankings.

These are observational historical summaries, not proof that an alternative route would have been faster on the same morning. Weather, incidents, day-to-day demand, and departure-time selection can bias comparisons. Low-speed duration is not a counterfactual delay estimate.

Local files live in the existing Application Support/RouteLab directory. Trips remain separate JSON files; recording checkpoints are atomic and written approximately every 5 seconds. New fields are optional so existing v0.1 trips decode. Automatic grouping can be added to older valid records, but an old unconfirmed arrival still needs confirmation. Favorite destinations are a separate protected JSON file and are included in exports. Export schemaVersion remains 1 with additive v0.2 fields; older app versions are not guaranteed to read all new enum values, so do not downgrade over new data.

No cloud accounts, server upload, or cloud synchronization. Files are excluded from device cloud backup. Apple receives map searches/route requests; Overpass receives the query area when road lookup is enabled. Turning lookup off leaves local recording, geometry grouping, and time comparison available. Uninstalling removes unexported app records. A JSON export is an external backup for analysis; the app does not yet offer a restore/import screen.

## Python analysis

Python 3.9+ with only the standard library. This runs fully offline:

```bash
python3 Analysis/analyze.py /path/to/RouteLab-trips.json --out results
```

Multiple exports may be supplied; later files win for duplicate trip IDs. CSV outputs: `trips.csv`, `events.csv`, `points.csv`, `summary.csv`, plus `report.txt`. Added fields include automatic route key, road names, matching coverage, construction answer, and inference evidence. Summaries use stored automatic route IDs when present, otherwise legacy labels. GPS gaps over 30 seconds are not connected for distance or stop inference. CSV strings are escaped against spreadsheet formula interpretation.

```bash
python3 -m unittest discover -s Tests -p 'test_*.py' -v
python3 Analysis/analyze.py Examples/synthetic-trips.json --out /tmp/RouteLab-demo
```

`Examples/synthetic-trips.json` is the original fabricated fixture, not your trips and not measured Austin traffic. Its historical labels remain only as backwards-compatibility examples.

Map context: [© OpenStreetMap contributors, ODbL](https://www.openstreetmap.org/copyright). See [Overpass API](https://wiki.openstreetmap.org/wiki/Overpass_API) and [maxspeed tagging](https://wiki.openstreetmap.org/wiki/Key:maxspeed) for the underlying data conventions.
