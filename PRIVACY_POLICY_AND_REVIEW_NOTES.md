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
- **Private property and no trespassing.** The user is 100% responsible for confirming that a trail, road, campsite, waypoint, or off-road area is legally open to public motorized use and is not private property. BLM, USFS, NPS, State Trust, and other masks are approximate agency data, not a cadastral survey, and public land often contains private inholdings, mining claims, ranch roads, locked gates, or roads without a public easement. Signs and gates on the ground govern. Edward Shin and Krokem Outdoors are not liable for trespass claims, fines, citations, towing, impoundment, or disputes from entering private, restricted, or closed property.
- **Assumption of risk.** The user assumes 100% of the risk of off-road and backcountry travel, including vehicle damage, stranding, injury, and death.
- **Driver distraction.** The user must not operate map controls while the vehicle is moving.
- **AS IS.** No warranties. To the fullest extent permitted by law, the total aggregate liability of Edward Shin, Krokem Outdoors, Krokem Outdoors LLC, and their affiliates and licensors shall not exceed the greater of $0.00 USD or the amount paid for the App in the twelve (12) months before the claim.
- **No emergency service.** TrailForge is not an emergency beacon, satellite SOS communicator, or search-and-rescue dispatch service and is not a life-safety device.
- **Gauges and clinometer.** Pitch/roll, clearance comparisons, crux ratings, and USGS/SNOTEL water and snow readings are uncalibrated estimates and do not guarantee rollover safety, clearance, or a safe crossing depth.
- **Arbitration.** Disputes are resolved by binding individual arbitration under the Federal Arbitration Act, with a class-action and jury-trial waiver. Unenforceable terms are severed.
