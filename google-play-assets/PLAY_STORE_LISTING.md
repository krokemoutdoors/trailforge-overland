# Google Play listing — TrailForge Overland

Copy-paste fields for Play Console. Package `com.edwardshin.trailforge`, version `1.0.0` (`versionCode` 5).

## Store listing

- **App name:** TrailForge Overland
- **Short description (80 characters max):** Rig-fit 4x4 maps, flat camps, and live GPS turn-by-turn.
- **Full description:** see below (under 4,000 characters)
- **Category:** Maps & Navigation
- **Tags:** Off-road, Navigation, Camping
- **Contact email:** use the address on the KrokeM Outdoors Play Console account
- **Privacy policy URL:** https://krokemoutdoors.github.io/trailforge-overland/#privacy
- **Content rating:** Everyone (IARC). Community trail reports share a status, rig type, and coordinate with other TrailForge users. No personal names, no violence, no unrestricted web. Location is used for navigation and for a report the driver chooses to publish.

### Full description

TrailForge Overland is the 3-button cockpit for 4x4 travel. Before you leave pavement it tells you whether your exact build fits the trail, where a level legal pad is, and what the public gauges say about snow, water, and fire.

1. Go Drive
Pick Near Me or any of the 50 states. The trail menu fills immediately (WA • 34 Routes, Near Me • 14 Routes, and the rest of the atlas) and every track is colored for your rig: green FITS YOUR RIG, orange CAUTION, red NO-GO. A live scanner pulls OpenStreetMap Overpass tracks and USFS forest roads anywhere in the USA and scores them the same way.

Real-time GPS draws a blue puck and heading cone, with live speed in mph and altitude in feet. Center on My GPS and Near My GPS keep the map on the truck.

2. Flat Camp
Pads under 3 degrees of slope are marked on the satellite and topo hybrid map with a Starlink sky score. Tap a pad, or tap Route Here, and TrailForge asks the OSRM driving router for a street-by-street and forest-road route from your live GPS fix, then draws a thin cyan line with a dark navy casing and a dashed overland spur to the exact pad.

The top banner shows the next maneuver, the distance to the turn, and the road name. Open the step list or mute spoken directions. The bottom bar shows pad slope, Starlink percent, live ETA, miles left, Follow GPS, Overview, Open in Google Maps, and End Route.

Voice prompts speak on departure, 0.2 miles before each turn, at the turn, and when you arrive.

3. My Rig
Set tire size, lift, minimum differential clearance, roof or tent height, and lockers. The pitch and roll clinometer uses the phone accelerometer and gyroscope. The air-down calculator gives front and rear PSI for rock, sand, or mixed tread. USGS streamflow, SNOTEL snow, and NIFC wildfire perimeters sit on the trail card.

TrailForge Pro
- Annual: $24.99/year, 7-day trial
- Founders Lifetime Pass: $149.99 one time (One-Time • 6-Yr Value)
- Weekend Pass: $4.99/month

Purchases are completed with Google Play Billing. The atlas and cockpit also run offline after the first save. Live scans, river gauges, and turn-by-turn routing need a connection.

## Graphics

Upload these files from `google-play-assets/`:

| Asset | File | Size |
| --- | --- | --- |
| High-res icon | `icon-512x512.png` | 512×512 PNG |
| Feature graphic | `feature-graphic-1024x500.png` | 1024×500 PNG |
| Phone screenshots | `screenshots/01-go-drive-1080x2400.png` | 1080×2400 |
| Phone screenshots | `screenshots/02-turn-by-turn-1080x2400.png` | 1080×2400 |
| Phone screenshots | `screenshots/03-my-rig-founders-pass-1080x2400.png` | 1080×2400 |
| Phone screenshots | `screenshots/04-flat-camp-pads-1080x2400.png` | 1080×2400 |

## Data safety

Answer Play Console Data safety as follows. TrailForge does not sell data and does not use advertising IDs.

| Data type | Collected | Shared | Purpose | Notes |
| --- | --- | --- | --- | --- |
| Precise location | Yes | Yes, with other TrailForge users when a driver publishes a trail report | App functionality | Used on device for the GPS puck, Near Me, and turn-by-turn. A route request sends the start and destination to the OSRM public router. A trail scan sends the map center to OpenStreetMap Overpass and the USFS road service. A trail report or hazard pin the driver submits sends that coordinate, status, and rig type to the shared community feed. |
| Approximate location | Yes | No | App functionality | Coarse location is the fallback when precise GPS is denied. |
| Device or other IDs | No | No | — | Not collected by the app. Google Play Billing is handled by Google. |
| Financial info | No | No | — | Prices and purchases stay in Google Play. |
| Photos, contacts, messages, files | No | No | — | Not accessed. |
| App activity / crash logs | No | No | — | Not shipped to a TrailForge server. |
| Sensor readings | No | No | — | Accelerometer and gyroscope pitch/roll stay on the device and are not uploaded. |

Additional answers:

- Data is encrypted in transit (HTTPS) for map tiles, Overpass, USFS, USGS, NIFC, and OSRM.
- Users can delete location history by clearing app storage or uninstalling. The rig profile is stored only on device.
- Location collection is optional. Denying location still opens the atlas; routing and the live puck wait for permission.
- No data is shared with third parties for advertising. Public map and science endpoints receive only the coordinate needed for that request.
- The privacy policy is https://krokemoutdoors.github.io/trailforge-overland/#privacy

## Release artifacts

The Android workflow builds:

- `TrailForge-Overland-v1.0.0-release.apk` — sideload onto a phone
- `TrailForge-Overland-v1.0.0-release.aab` — upload to Play Console

Product IDs, created in Play Console before billing can complete:

- `com.edwardshin.trailforge.pro.annual` (subscription)
- `com.edwardshin.trailforge.founders.lifetime` (one-time)
- `com.edwardshin.trailforge.pro.monthly` (subscription)
