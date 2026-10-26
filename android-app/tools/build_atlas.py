#!/usr/bin/env python3
"""Build the embedded 50-state atlas consumed by the Android and PWA cockpits.

Signature routes are parsed from the iOS atlas so both editions share the same
passes, camps, and rig-fit numbers. Additional forest-road specs fill each
state out to a stable menu count (Washington is 34). Geometry is computed in
the cockpit with the same seed formula as TrailGeometry in RigFitEngine.swift.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SWIFT_ATLAS = ROOT / "ios-app" / "USATrailAtlas.swift"
SWIFT_TELEMETRY = ROOT / "ios-app" / "LiveTelemetryService.swift"
OUT = ROOT / "android-app" / "app" / "src" / "main" / "assets" / "atlas.js"

TARGETS = {
    "WA": 34, "CA": 32, "CO": 28, "UT": 26, "OR": 24, "AZ": 22, "ID": 20,
    "MT": 18, "WY": 16, "NV": 16, "NM": 16, "TX": 14, "AK": 12, "NC": 12,
    "GA": 12, "MI": 10, "MN": 10, "WI": 10, "VA": 10, "PA": 10, "TN": 10,
}
DEFAULT_TARGET = 8

NAMES = {
    "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas", "CA": "California",
    "CO": "Colorado", "CT": "Connecticut", "DE": "Delaware", "FL": "Florida", "GA": "Georgia",
    "HI": "Hawaii", "ID": "Idaho", "IL": "Illinois", "IN": "Indiana", "IA": "Iowa",
    "KS": "Kansas", "KY": "Kentucky", "LA": "Louisiana", "ME": "Maine", "MD": "Maryland",
    "MA": "Massachusetts", "MI": "Michigan", "MN": "Minnesota", "MS": "Mississippi", "MO": "Missouri",
    "MT": "Montana", "NE": "Nebraska", "NV": "Nevada", "NH": "New Hampshire", "NJ": "New Jersey",
    "NM": "New Mexico", "NY": "New York", "NC": "North Carolina", "ND": "North Dakota", "OH": "Ohio",
    "OK": "Oklahoma", "OR": "Oregon", "PA": "Pennsylvania", "RI": "Rhode Island", "SC": "South Carolina",
    "SD": "South Dakota", "TN": "Tennessee", "TX": "Texas", "UT": "Utah", "VT": "Vermont",
    "VA": "Virginia", "WA": "Washington", "WV": "West Virginia", "WI": "Wisconsin", "WY": "Wyoming",
}

FEATURES = [
    "Ridge", "Spur", "Basin", "Saddle", "Lookout", "Creek", "Canyon", "Divide",
    "Bench", "Meadow", "Rim", "Pass", "Gulch", "Flat", "Trail", "Road",
]
LANDMARKS = [
    "Cedar", "Bear", "Iron", "Quartz", "Granite", "Willow", "Aspen", "Pine", "Elk",
    "Coyote", "Sage", "Eagle", "Wolf", "Trout", "Lava", "Cinder", "Pinyon", "Juniper",
    "Mesa", "Boulder", "Silver", "Hidden", "Dry", "North", "South", "Little", "Big",
    "Red", "Blue", "Lost", "Rimrock", "Copper", "Mule", "Gold",
]
AGENCIES = ["USFS", "BLM", "USFS MVUM", "State Forest"]

# Interior clusters so generated roads stay on land inside the state box.
CLUSTERS = {
    "AK": (64.2, -149.0, 3.2, 4.5),
    "HI": (22.05, -159.55, 0.25, 0.35),
    "FL": (29.4, -82.2, 1.2, 1.0),
    "CA": (38.4, -120.2, 2.8, 2.2),
    "WA": (47.35, -121.15, 1.35, 1.55),
    "OR": (44.1, -121.4, 1.6, 1.8),
    "TX": (31.4, -104.2, 2.2, 2.4),
    "MI": (46.4, -87.6, 1.2, 2.0),
    "MN": (47.6, -91.8, 0.8, 1.4),
}


def parse_spec(body: str) -> dict:
    parts: list[str] = []
    buf: list[str] = []
    quoted = False
    for ch in body:
        if ch == '"':
            quoted = not quoted
            buf.append(ch)
        elif ch == "," and not quoted:
            parts.append("".join(buf).strip())
            buf = []
        else:
            buf.append(ch)
    if "".join(buf).strip():
        parts.append("".join(buf).strip())
    out: dict = {}
    for part in parts:
        key, value = part.split(":", 1)
        key = key.strip()
        value = value.strip()
        if value.startswith('"') and value.endswith('"'):
            out[key] = value[1:-1]
        elif value == "true":
            out[key] = True
        elif value == "false":
            out[key] = False
        elif "." in value:
            out[key] = float(value)
        else:
            out[key] = int(value)
    out.setdefault("gate", "OPEN")
    out.setdefault("snow", 0)
    out.setdefault("flow", 0)
    out.setdefault("km", 18)
    out["signature"] = True
    return out


def parse_blocks(src: str) -> dict[str, str]:
    return {match.group(1): match.group(2) for match in re.finditer(r'"([^"]+)": \[(.*?)\]', src, re.S)}


def main() -> None:
    atlas_src = SWIFT_ATLAS.read_text()
    telemetry_src = SWIFT_TELEMETRY.read_text()
    spec_bodies = re.findall(r"AtlasSpec\((.*)\)\s*,?\s*$", atlas_src, re.M)
    specs = [parse_spec(body) for body in spec_bodies]
    known_ids = {spec["id"] for spec in specs}

    routes_src = atlas_src.split("private let handRoutes")[1].split("private let handCamps")[0]
    camps_src = atlas_src.split("private let handCamps")[1]
    hand_routes = {}
    for trail_id, block in parse_blocks(routes_src).items():
        pairs = re.findall(
            r"CLLocationCoordinate2D\(latitude:\s*([-\d.]+),\s*longitude:\s*([-\d.]+)\)",
            block,
        )
        hand_routes[trail_id] = [[float(lat), float(lon)] for lat, lon in pairs]
    hand_camps = {}
    for trail_id, block in parse_blocks(camps_src).items():
        camps = []
        for name, lat, lon, slope, sky in re.findall(
            r'name:\s*"([^"]+)",\s*lat:\s*([-\d.]+),\s*lon:\s*([-\d.]+),\s*slopeDeg:\s*([-\d.]+),\s*starlinkPct:\s*(\d+)',
            block,
        ):
            camps.append(
                {
                    "name": name,
                    "lat": float(lat),
                    "lon": float(lon),
                    "slope": float(slope),
                    "starlink": int(sky),
                }
            )
        hand_camps[trail_id] = camps

    boxes = []
    for code, min_lat, max_lat, min_lon, max_lon in re.findall(
        r'Box\(code: "(\w+)", minLat: ([-\d.]+), maxLat: ([-\d.]+), minLon: ([-\d.]+), maxLon: ([-\d.]+)\)',
        telemetry_src,
    ):
        boxes.append(
            {
                "code": code,
                "name": NAMES[code],
                "minLat": float(min_lat),
                "maxLat": float(max_lat),
                "minLon": float(min_lon),
                "maxLon": float(max_lon),
            }
        )
    box_by_code = {box["code"]: box for box in boxes}
    if set(box_by_code) != set(NAMES):
        missing = sorted(set(NAMES) - set(box_by_code))
        raise SystemExit(f"missing state boxes: {missing}")

    by_state: dict[str, list[dict]] = {code: [] for code in NAMES}
    for spec in specs:
        by_state[spec["state"]].append(spec)
    present = {spec["state"] for spec in specs}
    if present != set(NAMES):
        raise SystemExit(f"signature atlas missing states: {sorted(set(NAMES) - present)}")

    extras: list[dict] = []
    for code, box in box_by_code.items():
        have = len(by_state[code])
        target = TARGETS.get(code, DEFAULT_TARGET)
        need = max(0, target - have)
        owned = by_state[code]
        if code in CLUSTERS:
            clat, clon, dlat, dlon = CLUSTERS[code]
        else:
            clat = sum(item["lat"] for item in owned) / len(owned)
            clon = sum(item["lon"] for item in owned) / len(owned)
            dlat = max(0.35, (box["maxLat"] - box["minLat"]) * 0.28)
            dlon = max(0.35, (box["maxLon"] - box["minLon"]) * 0.28)
        for index in range(need):
            seed = (index * 97 + ord(code[0]) * 13 + ord(code[1])) % 50000
            lat = clat + (((index * 37 + seed) % 100) - 50) / 50 * dlat
            lon = clon + (((index * 53 + seed // 3) % 100) - 50) / 50 * dlon
            inset = 0.15
            lat = min(box["maxLat"] - inset, max(box["minLat"] + inset, lat))
            lon = min(box["maxLon"] - inset, max(box["minLon"] + inset, lon))
            landmark = LANDMARKS[(seed + index) % len(LANDMARKS)]
            feature = FEATURES[(seed // 5 + index) % len(FEATURES)]
            road_no = 100 + (seed * 3 + index * 17) % 8900
            clearance = 8.2
            canopy = 12.0
            water = 6
            locker = False
            gate = "OPEN"
            snow = 0
            kind = seed % 17
            if kind == 0:
                canopy = 6.3
                clearance = 11.4
            elif kind in (1, 2):
                clearance = 12.6
                locker = True
                water = 16
                gate = "CAUTION"
            elif kind in (3, 4, 5):
                clearance = 11.6
                locker = True
            elif kind in (6, 7):
                water = 28
                clearance = 9.4
                gate = "CAUTION"
            elif kind in (8, 9):
                clearance = 10.4
                canopy = 9.2
            else:
                clearance = 8.4 + (seed % 6) * 0.25
                canopy = 11.5
            if code in {"CO", "WA", "OR", "MT", "WY", "ID", "AK", "UT", "CA"} and seed % 4 == 0:
                snow = round(1.5 + (seed % 12) * 0.8, 1)
            trail_id = f"{code.lower()}-fs-{index:02d}"
            if trail_id in known_ids:
                trail_id = f"{trail_id}-b"
            known_ids.add(trail_id)
            km = 8 + (seed % 14)
            extras.append(
                {
                    "id": trail_id,
                    "name": f"FS-{road_no} {landmark} {feature}",
                    "region": f"{NAMES[code]} backcountry",
                    "agency": AGENCIES[seed % len(AGENCIES)],
                    "state": code,
                    "lat": round(lat, 5),
                    "lon": round(lon, 5),
                    "miles": round(km * 0.72, 1),
                    "elev": int(900 + (seed % 90) * 80),
                    "clearance": round(clearance, 1),
                    "canopy": round(canopy, 1),
                    "water": water,
                    "locker": locker,
                    "gate": gate,
                    "snow": snow,
                    "flow": int(seed % 40),
                    "km": km,
                    "signature": False,
                }
            )

    bdrs = json.loads((Path(__file__).with_name("bdr_routes.json")).read_text())
    specs_by_id = {spec["id"]: spec for spec in specs}
    for item in bdrs:
        points = item["waypoints"]
        if not 15 <= len(points) <= 25:
            raise SystemExit(f"{item['id']} has {len(points)} waypoints, expected 15-25")
        if any(camp["slope"] >= 3 for camp in item["camps"]):
            raise SystemExit(f"{item['id']} camp is not a <3° pad")
        mid = points[len(points) // 2]
        spec = specs_by_id.get(item["id"])
        if spec is None:
            spec = {
                "id": item["id"],
                "name": item["name"],
                "region": item["region"],
                "agency": "Backcountry Discovery Routes",
                "state": item["home"],
                "lat": mid[0],
                "lon": mid[1],
                "miles": item["miles"],
                "elev": item["elev"],
                "clearance": 8.5,
                "canopy": 12.0,
                "water": 8,
                "locker": False,
                "gate": "OPEN",
                "snow": item["snow"],
                "flow": 0,
                "km": int(round(item["miles"] * 1.609)),
                "signature": True,
            }
            specs.append(spec)
            specs_by_id[item["id"]] = spec
        else:
            spec["name"] = item["name"]
            spec["region"] = item["region"]
            spec["agency"] = "Backcountry Discovery Routes"
            spec["miles"] = item["miles"]
            spec["lat"] = mid[0]
            spec["lon"] = mid[1]
            spec["snow"] = item["snow"]
        spec["bdr"] = True
        spec["states"] = item["states"]
        spec["bdrOrder"] = item["order"]
        hand_routes[item["id"]] = points
        hand_camps[item["id"]] = item["camps"]

    ordered_states = sorted(NAMES, key=lambda code: NAMES[code])
    payload = {
        "specs": specs + extras,
        "handRoutes": hand_routes,
        "handCamps": hand_camps,
        "states": [box_by_code[code] for code in ordered_states],
    }
    counts: dict[str, int] = {}
    for spec in payload["specs"]:
        counts[spec["state"]] = counts.get(spec["state"], 0) + 1
    if counts["WA"] != 34:
        raise SystemExit(f"WA count is {counts['WA']}, expected 34")
    if len(counts) != 50:
        raise SystemExit(f"expected 50 states, got {len(counts)}")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    text = (
        "/* TrailForge Overland embedded atlas. Signature routes match the iOS atlas.\n"
        "   Forest-road rows fill every state menu. Geometry is built in the cockpit. */\n"
        "window.TRAILFORGE_ATLAS = "
        + json.dumps(payload, separators=(",", ":"))
        + ";\n"
    )
    OUT.write_text(text)
    print(f"wrote {OUT} ({len(payload['specs'])} routes, {OUT.stat().st_size} bytes)")
    print("WA", counts["WA"], "UT", counts["UT"], "CO", counts["CO"], "total", len(payload["specs"]))


if __name__ == "__main__":
    main()
