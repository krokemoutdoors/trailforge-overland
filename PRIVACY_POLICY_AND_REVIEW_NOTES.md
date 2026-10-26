# TrailForge Overland — App Store Privacy Policy & App Review Notes

## Privacy Policy Summary (App Store Connect "Privacy Policy URL" Content)
- **Data Collection**: TrailForge Overland keeps GPS history, gyroscope pitch/roll telemetry, and the vehicle build profile on your iPhone.
- **Zero Location Tracking or Selling**: We never sell, rent, or transmit your location history to advertising networks or third-party data brokers (`NSPrivacyTracking = false`).
- **Public Telemetry Feeds**: Requests to USGS NWIS, USDA SNOTEL, NIFC Wildfire, and USFS road APIs fetch anonymous regional trail conditions. A trail scan also sends the current map center or GPS coordinate to OpenStreetMap Overpass. Turn-by-turn routing sends the start and destination to Apple. The app does not upload a location history.

## App Store Review Notes (Paste into "Notes for Reviewer" in App Store Connect)
1. **Location Permission**: Used to show the live GPS puck on the map, report elevation and speed, and scan public 4x4 tracks around the current position.
2. **StoreKit 2 In-App Purchases**: Configured via native StoreKit 2 (`com.edwardshin.trailforge.pro.annual`, `com.edwardshin.trailforge.founders.lifetime`, `com.edwardshin.trailforge.pro.monthly`) with a visible "Restore Purchases" button on the paywall.
