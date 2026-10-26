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
ios-app/                  SwiftUI app, committed Xcode project, XcodeGen spec, StoreKit config
web-landing/              Privacy policy and support page (GitHub Pages)
appstore_assets/          1024 icon and 1290×2796 App Store screenshots
sample_gpx/               Imogene Pass GPX 1.1 track and camp waypoints
scripts/automate_release.py
codemagic.yaml
.github/workflows/        Simulator smoke build and Pages deploy
```

Privacy: GPS, gyroscope, and the rig profile stay on device (`NSPrivacyTracking` is false). Regional trail conditions come from anonymous requests to USGS, SNOTEL, and NIFC. The Pages source is `web-landing/index.html`.

## Build

The Xcode project is committed at `ios-app/TrailForgeOverland.xcodeproj` (shared scheme `TrailForgeOverland`). Bundle ID `com.edwardshin.trailforge`, display name TrailForge Overland, version 1.0.0, deployment target iOS 17. `ios-app/Info.plist` holds the location, Bluetooth, and local-network usage strings. The app icon is `ios-app/Assets.xcassets/AppIcon.appiconset`, which references the 1024×1024 icon.

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

`.github/workflows/ios-testflight.yml` runs on every push to `main` and on `workflow_dispatch`, on `macos-14`:

1. Check out the repo.
2. `brew install xcodegen`, then `xcodegen generate` inside `ios-app/`.
3. Smoke-build with `xcodebuild` for the iPhone 16 Pro simulator and `CODE_SIGNING_ALLOWED=NO`.

`.github/workflows/pages.yml` publishes `web-landing/` to GitHub Pages on push to `main`. It needs the `github-pages` environment and the Pages write permissions already set in the workflow.

### Codemagic

`codemagic.yaml` defines two workflows. Both use the committed `ios-app/TrailForgeOverland.xcodeproj`. If `xcodegen` is already on the machine, the first script runs `xcodegen generate` before building.

`ios-simulator-verify` is the workflow to run before Apple Developer enrollment. It has no `integrations` block and no `ios_signing` block. On a `mac_mini_m2` with Xcode `latest`, it builds an unsigned simulator app (`generic/platform=iOS Simulator`, `CODE_SIGNING_ALLOWED=NO`).

`ios-appstore-release` is the TestFlight workflow for after enrollment. It references the App Store Connect integration `TrailForge_ASC` (the name to create in Codemagic), signs `com.edwardshin.trailforge` for App Store distribution, builds an IPA with `xcode-project build-ipa`, and submits to TestFlight. App Store review submission stays off.

### App Store Connect API

`scripts/automate_release.py` talks to `https://api.appstoreconnect.apple.com/v1`. It no-ops until these environment variables are set:

- `ASC_ISSUER_ID`
- `ASC_KEY_ID`
- `ASC_PRIVATE_KEY` (contents of the AuthKey `.p8`)

With those set, it signs an ES256 JWT, registers `com.edwardshin.trailforge` if it is missing, and looks up the TrailForge Overland app record. Keep the private key in the environment, not in the repo.
