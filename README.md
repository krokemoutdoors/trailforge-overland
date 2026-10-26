# TrailForge Overland

TrailForge Overland is an iOS cockpit for 4x4 travel. It answers three questions before you leave pavement: whether your exact build fits the trail, where a level legal campsite sits, and what the public gauges say about snow, water, and fire.

Bundle ID: `com.edwardshin.trailforge`. Deployment target: iOS 17.

## One-handed cockpit

`MainCockpitView` is a dark, full-bleed map with a traffic-light banner on top and a thumb sheet on the bottom. The sheet has three modes:

1. **Go Drive** — search the atlas, or pick **Near Me**, **All USA**, or any state. The trail menu and the horizontal route pills refill with only that set, and the menu button shows the count (`Near Me • 14 Routes`, `UT • 6 Routes`). The banner turns green, amber, or red from the rig-fit verdict, and shows gate status, ford depth, and miles from the live GPS fix.
2. **Flat Camp** — a list of verified `<3°` pads for the current filter. Each card shows slope and Starlink sky and has **Route Here**.
3. **My Rig** — set tire size and rear locker. A floating pill on the map shows live pitch and roll from the gyroscope, plus recommended air-down PSI.

The map uses a hybrid style with realistic elevation. `UserAnnotation()` draws the live GPS puck and heading cone after When-In-Use permission. **Center on My GPS** snaps the camera to that fix. **Near My GPS** and **Scan Area for All USA 4x4 Trails** load local tracks from OpenStreetMap Overpass and USFS roads, drawn as rig-fit polylines (green, orange, or red).

## Build 5

Build 5 (`CFBundleVersion` 5) keeps tap-to-route navigation and the state dropdown, and replaces the straight-line fallback with a street route plus spoken turn-by-turn.

**Street routing.** Tapping a flat pad, a trailhead, or **Route Here** builds a driving route from the live GPS fix. The router tries Apple `MKDirections` to the pad, then Apple to the trailhead or the nearest trail vertex, then the public OSRM driving API (`router.project-osrm.org`) with `steps=true`, then shorter Apple legs at 75%, 50%, and 25% of the way to the trail. A route is kept only when it starts near the phone, has more than two points, and is not a long crow-flies segment. The trail polyline is stitched on only after the road route reaches the trail, and the dashed overland spur is drawn only when the remaining gap is under two miles. If every stage fails, the banner says to check the signal instead of drawing a line across town. The selected road is a 3.2 pt cyan stroke inside a 5 pt blue casing. Alternates are 2.2 pt. The spur is a 2.5 pt dashed orange line. The live blue GPS puck stays visible; a small start dot appears only when the route began from a trailhead before GPS locked.

**Live guidance.** `LocationTracker` uses navigation accuracy, no distance filter, automotive activity, and heading updates. The banner counts down to the current maneuver (`In 450 ft • Turn left onto S Harrier Rd`) and advances the step when the phone is within about 35 m of that maneuver. Remaining distance and ETA follow the driven portion of the route. **Follow GPS** locks the camera to the user heading. While a route is active, the three wide map buttons collapse to a single row of icons.

**Spoken directions.** Voice guidance is on by default. `VoiceNavigationAnnouncer` uses `AVSpeechSynthesizer` with an `AVAudioSession` in `.playback` / `.voicePrompt`, ducking other audio. The speaker button on the turn banner mutes and unmutes it. Tapping the banner speaks the current line immediately. The phone speaks an opening summary when a route starts and when **Follow GPS** is tapped, a single approach prompt about 0.2 mi before a maneuver, the maneuver itself (plus the following step) when the step advances, and an arrival line within about 50 m of the pad, including slope. Each of those prompts is remembered per step so a GPS tick cannot repeat it.

**50-state and Near Me dropdown.** The filter bar lists **Near Me**, **All USA**, and all 50 states. Choosing one immediately replaces the trail menu and the route pills with matching routes only. The previously selected trail is not kept when it is outside the new filter. **Near Me** sorts by distance to the live GPS fix, scans Overpass and USFS roads around that fix, and merges those tracks into the menu with a `mi away` badge. A state pill selects the first route in that state and pans the camera there. Each menu row shows state, name, distance, clearance, and rig-fit (`FITS`, `CAUTION`, `NO-GO`). Live-scanned tracks are tagged with the nearest US state code, so they show up under that state instead of a generic `US` label. The built-in atlas has at least one real route in every state, including Imogene Pass, White Rim, and Lost Coast Usal Road.

## Build-matched rig filter

`RigProfileStore` keeps one vehicle profile: tire size, lift, minimum clearance, roof height, width, rear locker, snorkel, and weight. `evaluate(trail:)` compares that profile to each trail and returns one of:

- **FITS YOUR RIG** — clearance and canopy clear the shelf.
- **CAUTION** — tight clearance, a missing locker on a locker trail, or a deep ford without a snorkel.
- **NO-GO CLEARANCE** — roof height exceeds the canopy, or clearance is more than 0.8 inches under the shelf minimum.

`recommendedAirDownPSI(surface:beadlocks:)` scales highway pressure by surface (sand, rock, or mixed), tire diameter, vehicle weight, and whether the rig has beadlocks.

## Flat camps and Starlink

Dispersed pads are marked when the ground slope is under 3°, so a level sleep does not need stacking blocks. Each pad carries a Starlink clear-sky percentage. The cockpit map annotates two Imogene Basin examples (1.4° at 96% sky, 2.1° at 99% sky). `GPXTrackManager` exports those pads as GPX 1.1 waypoints with slope and sky in the description. A full sample track is in `sample_gpx/Imogene_Pass_Overland.gpx`.

## Live telemetry

`LiveTelemetryService` loads public U.S. government feeds:

- **USGS NWIS** instantaneous values for discharge (parameter `00060`, cubic feet per second) and gage height (parameter `00065`, feet). Default sites are `09010500`, `09180500`, and `10261500`. A captured response lives in `live_usgs_snapshot.json`.
- **USDA NRCS SNOTEL** snow depth, stored on each trail as `snotelSnowIn` and shown with the route (the Imogene sample is 4.2 inches).
- **NIFC WFIGS** current interagency fire perimeters (`poly_IncidentName`, acres, percent contained) for closure awareness.
- **OpenStreetMap Overpass** off-road tracks (`highway=track`, grade 2–5, and unpaved unclassified roads) around the map center or the live GPS fix.
- **USFS EDW RoadBasic** forest roads from the public ArcGIS query, turned into the same trail model with a flat-pad annotation when the estimated slope is under 3°.

`LocationTracker` requests When-In-Use location at navigation accuracy, with heading updates, and publishes elevation in feet and speed in miles per hour. The map centers on the first fix.

Trail cards also carry USFS / BLM agency labels and a gate status string.

## StoreKit 2

`TrailForgeStoreKitManager` loads products with StoreKit 2, purchases through `Product.purchase()`, and unlocks Pro from `Transaction.currentEntitlements`. The local configuration is `ios-app/TrailForgeProducts.storekit`.

| Product | Product ID | Price |
| --- | --- | --- |
| TrailForge Pro Annual (7-day free trial) | `com.edwardshin.trailforge.pro.annual` | $24.99 / year |
| Lifetime Overland Founders Pass | `com.edwardshin.trailforge.founders.lifetime` | $59.99 one time |
| Weekend Expedition Monthly | `com.edwardshin.trailforge.pro.monthly` | $4.99 / month |

Listing copy, keywords, and review notes are in `APP_STORE_CONNECT_LISTING.md`, `APP_STORE_SUBMISSION_GUIDE.md`, and `PRIVACY_POLICY_AND_REVIEW_NOTES.md`.

## Repository layout

```
ios-app/                  SwiftUI app, committed Xcode project, XcodeGen spec, StoreKit config
web-landing/              Privacy policy and support page (GitHub Pages)
appstore_assets/          1024 icon and 1290×2796 App Store screenshots
sample_gpx/               Imogene Pass GPX 1.1 track and camp waypoints
scripts/automate_release.py
codemagic.yaml
.github/workflows/        Simulator smoke build and Pages deploy
```

Privacy: the gyroscope and the rig profile stay on device (`NSPrivacyTracking` is false). A trail scan sends the map center or GPS coordinate to OpenStreetMap Overpass and the USFS road service. Turn-by-turn routing sends the start and destination to Apple, and to the public OSRM driving service when Apple cannot return a road route. USGS, SNOTEL, and NIFC requests stay anonymous. Spoken prompts stay on the phone. The Pages source is `web-landing/index.html`.

## Build

The Xcode project is committed at `ios-app/TrailForgeOverland.xcodeproj` (shared scheme `TrailForgeOverland`). Bundle ID `com.edwardshin.trailforge`, display name TrailForge Overland, version 1.0 (build 5), deployment target iOS 17. `ios-app/Info.plist` holds the location, Bluetooth, and local-network usage strings. The app icon is `ios-app/Assets.xcassets/AppIcon.appiconset`, which references the 1024×1024 icon.

`ios-app/project.yml` is the XcodeGen spec for the same target. If XcodeGen is installed, `xcodegen generate` rewrites the project from that spec. The committed project is what Codemagic and Xcode open when XcodeGen is not installed.

### On a Mac

```bash
cd ios-app
open TrailForgeOverland.xcodeproj
```

Optional refresh from the spec:

```bash
brew install xcodegen
cd ios-app
xcodegen generate
```

Open the project in Xcode 16 or later. The shared scheme points at `TrailForgeProducts.storekit` for local StoreKit tests. Archive with **Product > Archive** when an Apple Developer team is available.

### GitHub Actions

`.github/workflows/ios-testflight.yml` runs on every push to `main` and on `workflow_dispatch`, on `macos-15`. It archives the committed `ios-app/TrailForgeOverland.xcodeproj` (`objectVersion = 56`, team `25VZT7485A`) and uploads the IPA to TestFlight with `xcrun altool`. Signing material is not stored in the repo. The job publishes a one-time RSA public key on a GitHub issue titled `ephemeral-build-handshake`, waits up to 180 seconds for an encrypted envelope, then closes that issue and deletes the keychain.

`.github/workflows/pages.yml` publishes `web-landing/` to GitHub Pages on push to `main`. It needs the `github-pages` environment and the Pages write permissions already set in the workflow.

### Codemagic

`codemagic.yaml` defines two workflows. Neither one rewrites `ios-app/TrailForgeOverland.xcodeproj` when `project.pbxproj` is already in the repo. `xcodegen generate` runs only if that file is absent. The Apple team id on the target is `25VZT7485A`.

`ios-appstore-release` signs and uploads with the Codemagic CLI. It has no `integrations` block and no `ios_signing` block. Pass these values on `POST https://api.codemagic.io/builds` (or as build environment variables):

- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_KEY_IDENTIFIER`
- `APP_STORE_CONNECT_PRIVATE_KEY`
- `CERTIFICATE_PRIVATE_KEY`

The workflow initializes a keychain, fetches the App Store profile with `app-store-connect fetch-signing-files`, builds an IPA with `xcode-project build-ipa`, and uploads it with `app-store-connect publish`.

`ios-simulator-verify` needs none of those secrets. On a `mac_mini_m2` with Xcode `latest`, it builds an unsigned simulator app (`generic/platform=iOS Simulator`, `CODE_SIGNING_ALLOWED=NO`).

### App Store Connect API

`scripts/automate_release.py` talks to `https://api.appstoreconnect.apple.com/v1`. It no-ops until these environment variables are set:

- `ASC_ISSUER_ID`
- `ASC_KEY_ID`
- `ASC_PRIVATE_KEY` (contents of the AuthKey `.p8`)

With those set, it signs an ES256 JWT, registers `com.edwardshin.trailforge` if it is missing, and looks up the TrailForge Overland app record. Keep the private key in the environment, not in the repo.
