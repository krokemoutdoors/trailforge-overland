# TrailForge Overland

TrailForge Overland is an iOS cockpit for 4x4 travel. It answers three questions before you leave pavement: whether your exact build fits the trail, where a level legal campsite sits, and what the public gauges say about snow, water, and fire.

Bundle ID: `com.edwardshin.trailforge`. Deployment target: iOS 17.

## One-handed cockpit

`MainCockpitView` is a dark, full-bleed map with a traffic-light banner on top and a thumb sheet on the bottom. The sheet has three modes:

1. **Go Drive** — pick a trail. The banner turns green, amber, or red from the rig-fit verdict, and shows gate status plus ford depth.
2. **Flat Camp** — the nearest verified dispersed pad, with slope in degrees and a Starlink sky score.
3. **My Rig** — set tire size and rear locker. A floating pill on the map shows live pitch and roll from the gyroscope, plus recommended air-down PSI.

The map uses a hybrid style with realistic elevation. Sample routes in the cockpit are Imogene Pass (FS-869), White Rim & Shafer Trail, and Lost Coast Usal Road.

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
ios-app/                  SwiftUI app, XcodeGen project.yml, StoreKit config
web-landing/              Privacy policy and support page (GitHub Pages)
appstore_assets/          1024 icon and 1290×2796 App Store screenshots
sample_gpx/               Imogene Pass GPX 1.1 track and camp waypoints
scripts/automate_release.py
codemagic.yaml
.github/workflows/        Simulator smoke build and Pages deploy
```

Privacy: GPS, gyroscope, and the rig profile stay on device (`NSPrivacyTracking` is false). Regional trail conditions come from anonymous requests to USGS, SNOTEL, and NIFC. The Pages source is `web-landing/index.html`.

## Build

Generate the Xcode project from `ios-app/project.yml` (bundle prefix `com.edwardshin`, display name TrailForge Overland, version 1.0.0). XcodeGen writes the location, Bluetooth, and local-network usage strings into the target.

### On a Mac

```bash
brew install xcodegen
cd ios-app
xcodegen generate
open TrailForgeOverland.xcodeproj
```

Open the project in Xcode 16 or later. Enable In-App Purchase, Background Modes (location updates), and Multipeer Connectivity, then archive with **Product > Archive** for App Store Connect. The StoreKit configuration file can drive local purchase tests before the products exist in App Store Connect.

### GitHub Actions

`.github/workflows/ios-testflight.yml` runs on every push to `main` and on `workflow_dispatch`, on `macos-14`:

1. Check out the repo.
2. `brew install xcodegen`, then `xcodegen generate` inside `ios-app/`.
3. Smoke-build with `xcodebuild` for the iPhone 16 Pro simulator and `CODE_SIGNING_ALLOWED=NO`.

`.github/workflows/pages.yml` publishes `web-landing/` to GitHub Pages on push to `main`. It needs the `github-pages` environment and the Pages write permissions already set in the workflow.

### Codemagic

`codemagic.yaml` defines the `ios-appstore-release` workflow:

- Runner: `mac_mini_m2`, Xcode `latest`, 30-minute cap.
- Signing: App Store distribution for `com.edwardshin.trailforge`, integration name `Codemagic_AppStoreConnect`.
- Scripts: install XcodeGen and generate the project, apply profiles with `xcode-project use-profiles`, then `xcode-project build-ipa` for scheme `TrailForgeOverland`.
- Artifact: `ios-app/build/ios/ipa/*.ipa`.
- Publishing: upload to TestFlight (`submit_to_testflight: true`). App Store review submission stays off.

Connect the App Store Connect integration in Codemagic before the first cloud build. The workflow reads `BUNDLE_ID`, `XCODE_PROJECT`, and `XCODE_SCHEME` from the environment block.

### App Store Connect API

`scripts/automate_release.py` talks to `https://api.appstoreconnect.apple.com/v1`. It no-ops until these environment variables are set:

- `ASC_ISSUER_ID`
- `ASC_KEY_ID`
- `ASC_PRIVATE_KEY` (contents of the AuthKey `.p8`)

With those set, it signs an ES256 JWT, registers `com.edwardshin.trailforge` if it is missing, and looks up the TrailForge Overland app record. Keep the private key in the environment, not in the repo.
