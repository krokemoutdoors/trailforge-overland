# TrailForge Overland — iOS App Store Launch & Monetization Guide

## 1. Competitive Positioning & Pricing (85% Net Payout via Apple Small Business Program)
- **Primary Subscription (`com.edwardshin.trailforge.pro.annual`)**: **$24.99/year** with a 7-day free trial (undercuts Gaia GPS at $59.99/yr and onX Offroad Elite at $99.99/yr).
- **Cash-Flow Booster (`com.edwardshin.trailforge.founders.lifetime`)**: **$149.99 One-Time Founders Pass** (One-Time • 6-Yr Value) for overlanders experiencing subscription fatigue.
- **Weekend Pass (`com.edwardshin.trailforge.pro.monthly`)**: **$4.99/month**.

## 2. Public Data Feeds Integrated (Zero Map Licensing Lock-In)
- **USFS MVUM (Motor Vehicle Use Maps)** & **BLM National Surface Management Agency GIS Polygons** (Public Domain US Gov data).
- **USGS 3DEP 1-Meter LIDAR Slope Shading** for identifying <3° flat dispersed boondocking pads.
- **USDA NRCS SNOTEL** snow telemetry & **USGS Instantaneous Streamflow API** for live river-crossing depths.
- **NIFC Active Wildfire Perimeters** for automatic trail closure warnings.

## 3. Building & Submitting to App Store Connect
1. Open `/workspace/trailforge_overland/ios-app` in Xcode 16+ with Bundle ID `com.edwardshin.trailforge`.
2. Enable Capabilities: **In-App Purchase**, **Background Modes (Location updates)**, and **MultipeerConnectivity** (for offline convoy mesh).
3. Archive (`Product > Archive`) and upload to App Store Connect / TestFlight.
