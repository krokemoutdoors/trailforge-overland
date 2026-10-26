# TrailForge Overland — App Store Privacy Policy & App Review Notes

## Privacy Policy Summary (App Store Connect "Privacy Policy URL" Content)
- **Data Collection**: TrailForge Overland processes your GPS coordinates, gyroscope pitch/roll telemetry, and vehicle build profile **100% locally on your iPhone**.
- **Zero Location Tracking or Selling**: We never sell, rent, or transmit your location history to advertising networks or third-party data brokers (`NSPrivacyTracking = false`).
- **Public Telemetry Feeds**: Requests to USGS NWIS, USDA SNOTEL, and NIFC Wildfire APIs fetch anonymous regional trail conditions only.

## App Store Review Notes (Paste into "Notes for Reviewer" in App Store Connect)
1. **Location Permission**: Used solely to render the user's vehicle position on offline topographic trail maps and record user-initiated GPX tracks.
2. **StoreKit 2 In-App Purchases**: Configured via native StoreKit 2 (`com.edwardshin.trailforge.pro.annual`, `com.edwardshin.trailforge.founders.lifetime`, `com.edwardshin.trailforge.pro.monthly`) with a visible "Restore Purchases" button on the paywall.
