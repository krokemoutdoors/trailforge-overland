# TrailForge Overland — App Store Privacy Policy & App Review Notes

## Privacy Policy Summary (App Store Connect "Privacy Policy URL" Content)
- **Data Collection**: TrailForge Overland keeps GPS history, gyroscope pitch/roll telemetry, and the vehicle build profile on your iPhone.
- **Zero Location Tracking or Selling**: We never sell, rent, or transmit your location history to advertising networks or third-party data brokers (`NSPrivacyTracking = false`).
- **Public Telemetry Feeds**: Requests to USGS NWIS, USDA SNOTEL, NIFC Wildfire, and USFS road APIs fetch anonymous regional trail conditions. A trail scan also sends the current map center or GPS coordinate to OpenStreetMap Overpass. Turn-by-turn routing sends the start and destination to Apple, and to the public OSRM driving service when Apple cannot return a road route. Spoken turn prompts stay on the phone. The app does not upload a location history.

## App Store Review Notes (Paste into "Notes for Reviewer" in App Store Connect)
1. **Location Permission**: Used to show the live GPS puck on the map, report elevation and speed, and scan public 4x4 tracks around the current position.
2. **StoreKit 2 In-App Purchases**: Configured via native StoreKit 2 (`com.edwardshin.trailforge.pro.annual`, `com.edwardshin.trailforge.founders.lifetime`, `com.edwardshin.trailforge.pro.monthly`) with a visible "Restore Purchases" button on the paywall.
3. **Clickwrap**: The first launch shows a Safety, Assumption of Risk & Liability Disclaimer. Acceptance is stored on device (`trailforge.safetyDisclaimerAccepted.v1`, with a timestamp). The same text can be reopened from “Safety & Legal Disclaimer / Terms of Use” in the cockpit sheet. Public terms: https://krokemoutdoors.github.io/trailforge-overland/#terms

## Terms of Use, EULA & Limitation of Liability
Published at https://krokemoutdoors.github.io/trailforge-overland/#terms and https://krokemoutdoors.github.io/trailforge-overland/#disclaimer

- **Informational only.** Maps, masks, GPX, MVUM/USFS/BLM/State/Park boundaries, fords, SNOTEL, wildfire perimeters, slope shading, and clearance warnings are estimates. They are not a survey and must not be used to decide legal property boundaries or road legality.
- **Assumption of risk.** The user assumes 100% of the risk of off-road and backcountry travel, including vehicle damage, stranding, injury, and death.
- **Driver distraction.** The user must not operate map controls while the vehicle is moving.
- **AS IS.** No warranties. Edward Shin, Krokem Outdoors, and its affiliates disclaim liability to the maximum extent permitted by law and require indemnification for claims arising from the user’s backcountry travel.
