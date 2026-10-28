/* TrailForge Overland cockpit. Works inside the Android WebView and as a PWA. */
(function () {
  "use strict";

  const SHOT = new URLSearchParams(location.search).get("shot");
  const ATLAS = window.TRAILFORGE_ATLAS;
  const CATALOG = [
    { id: "com.edwardshin.trailforge.pro.annual", title: "TrailForge Pro Annual", price: "$24.99/year", note: "7-day free trial", popular: true },
    { id: "com.edwardshin.trailforge.founders.lifetime", title: "Founders Lifetime Pass", price: "$149.99", note: "One-Time • 6-Yr Value", founders: true },
    { id: "com.edwardshin.trailforge.pro.monthly", title: "Weekend Pass", price: "$4.99/month", note: "Monthly" }
  ];
  const MAP_ATTRIB = "Imagery © Esri • USGS National Map (Public Domain) • © OpenStreetMap contributors";
  const CORRIDOR_NOTE = "Independent public-road overland corridor compiled from public USFS, BLM, and state highway data. Not affiliated with, endorsed by, or sponsored by Backcountry Discovery Routes®.";
  const ESRI_IMAGERY = "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}";
  const ESRI_ROADS = "https://services.arcgisonline.com/ArcGIS/rest/services/Reference/World_Transportation/MapServer/tile/{z}/{y}/{x}";
  const ESRI_PLACES = "https://services.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}";
  const USGS_TILES = {
    topo: "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{z}/{y}/{x}"
  };
  const NAME_TO_CODE = {};
  ATLAS.states.forEach(function (box) { NAME_TO_CODE[box.name.toLowerCase()] = box.code; });

  const state = {
    mode: "drive",
    filter: "near",
    query: "",
    selectedId: "imogene",
    trails: [],
    discovered: loadDiscovered(),
    scanAnchors: [],
    fix: null,
    userPanned: false,
    pitch: 0,
    roll: 0,
    rawPitch: 0,
    rawRoll: 0,
    gx: null,
    gy: null,
    gz: null,
    clinZero: loadClinZero(),
    autoPitch: null,
    nativeAttAt: 0,
    lastMotionAt: 0,
    rollLimit: (function () {
      const saved = Number(localStorage.getItem("tf-roll-limit"));
      return saved >= 8 && saved <= 45 ? saved : 25;
    })(),
    places: [],
    placePin: null,
    placeBusy: false,
    placeTimer: null,
    compass: null,
    perm: true,
    follow: false,
    centeredOnce: false,
    route: null,
    routing: false,
    showSteps: false,
    menuOpen: false,
    scanStatus: "",
    scanning: false,
    offlineSaved: localStorage.getItem("tf-offline") !== "0",
    online: navigator.onLine !== false,
    muted: localStorage.getItem("tf-mute") === "1",
    surface: "rock",
    beadlocks: false,
    rig: loadRig(),
    gauges: [],
    fires: [],
    billing: { ready: false, pro: false, products: [] },
    routeGen: 0,
    scanGen: 0,
    lastScanAnchor: null,
    trailScanTimer: null,
    lastReroute: 0,
    aim: null,
    targetCopy: "",
    detent: (function () {
      const saved = localStorage.getItem("tf-detent");
      return saved === "peek" || saved === "full" ? saved : "split";
    })(),
    dash: (function () {
      const saved = localStorage.getItem("tf-dash");
      return saved === "on" || saved === "off" ? saved : "auto";
    })(),
    basemap: localStorage.getItem("tf-basemap") || "hybrid",
    opacity: loadOpacity(),
    drawer: null,
    plotting: false,
    plot: [],
    reports: loadReports(),
    packs: loadPacks(),
    packKind: localStorage.getItem("tf-pack-kind") === "satellite" ? "satellite" : "topo",
    packArea: (function () {
      const saved = localStorage.getItem("tf-pack-area") || "corridor";
      const area = saved === "view" || saved === "corridor" ? saved : "view";
      if (area !== saved) localStorage.setItem("tf-pack-area", area);
      return area;
    })(),
    packBusy: false,
    map3d: localStorage.getItem("tf-map-3d") === "1",
    map3dEnabled: localStorage.getItem("tf-map-3d") === "1",
    mapPitch: (function () {
      const enabled = localStorage.getItem("tf-map-3d") === "1";
      const stored = Number(localStorage.getItem("tf-map-pitch") || 0);
      const next = enabled ? Math.max(0, Math.min(75, Number.isFinite(stored) ? stored : 0)) : 0;
      if (localStorage.getItem("tf-map-pitch") !== String(next)) localStorage.setItem("tf-map-pitch", String(next));
      return next;
    })(),
    plotClearedByUser: false,
    scrubIndex: null,
    scrubTrailId: null,
    plotMode: localStorage.getItem("tf-plot-mode") === "freehand" ? "freehand" : "snap",
    thermal: localStorage.getItem("tf-thermal") === "1",
    night: localStorage.getItem("tf-night") === "1",
    dropped: loadDropped(),
    spokenHazards: {},
    convoy: "",
    mvum: null,
    lastAtt: 0,
    community: loadCommunityStore(),
    communityOps: loadCommunityOps(),
    communityQueue: loadCommunityQueue(),
    communityNotice: localStorage.getItem("tf-community-notice") || "",
    communityFlushing: false,
    recording: false,
    recordPaused: false,
    recordPoints: [],
    recordStarted: 0,
    recordPausedMs: 0,
    recordPauseMark: 0,
    recordName: "",
    recordedRoutes: loadRecordedRoutes(),
    shownRecordId: null,
    droppedPin: null,
    pinCategory: "Waypoint",
    savedMarkers: loadSavedMarkers(),
    activeMarkerId: null,
    landRings: []
  };

  const pendingNet = new Map();
  let netSeq = 0;
  let map;
  let puck;
  let trailLayer;
  let campLayer;
  let routeLayer;
  let corridorLayer;
  let slopeLayer;
  let starlinkLayer;
  let hazardLayer;
  let plotLayer;
  const plotRouteCache = {};
  const plotRoutePending = {};
  let recordLayer;
  let markerLayer;
  let hazardPinLayer;
  let communityLayer;
  let communityChannel = null;
  let smaLayer;
  let offlineLayer;
  let areaPreviewLayer;
  let hybridLayer;
  let imageryLayer;
  let hillshadeLayer;
  let topoLayer;
  let labelLayer;
  let darkLayer;
  let osmLayer;
  let placeSearchGen = 0;
  let placeLayer;
  let hazardPhoto = "";
  let hazardNote = "";
  let scrubMarker;
  let toastTimer;
  let chromeTimer;
  let pitchResizeTimer;
  let pitchStageKey = "";
  const REPORTS = ["Open & Clear", "Mud/Snow", "Downed Tree", "Washout", "Gate Locked"];
  const REPORT_LABELS = {
    "Open & Clear": "✅ Open & Clear",
    "Mud/Snow": "❄️ Mud/Snow",
    "Downed Tree": "🌲 Downed Tree",
    "Washout": "⚠️ Washout",
    "Gate Locked": "🔒 Gate Locked"
  };
  const COMMUNITY_FEED = "https://krokemoutdoors.github.io/trailforge-overland/app/community-reports.json";
  const COMMUNITY_RELAY = "https://ntfy.sh/trailforge-overland-community/json?poll=1&since=all";
  const COMMUNITY_POST = "https://ntfy.sh/trailforge-overland-community";
  const COMMUNITY_SYNCED = "☁️ Synced to All TrailForge Users";
  const COMMUNITY_QUEUED = "📡 Queued Offline — Auto-Syncs on Signal";

  function loadRig() {
    const base = {
      name: "Toyota Tacoma TRD Off-Road",
      tireInches: 33,
      liftInches: 2.5,
      minClearanceIn: 11.2,
      roofHeightFt: 6.8,
      widthIn: 75,
      hasRearLocker: true,
      hasSnorkel: false,
      rigWeightLbs: 5450
    };
    try {
      return Object.assign(base, JSON.parse(localStorage.getItem("tf-rig-v1") || "{}"));
    } catch (error) {
      return base;
    }
  }

  function saveRig() {
    localStorage.setItem("tf-rig-v1", JSON.stringify(state.rig));
  }

  function num(value) {
    return String(Math.round(Number(value) * 10) / 10);
  }

  function esc(value) {
    return String(value == null ? "" : value).replace(/[&<>"']/g, function (ch) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch];
    });
  }

  function seedFor(id) {
    let partial = 0;
    for (const ch of id) partial = (partial * 33 + ch.codePointAt(0)) % 50000;
    return partial;
  }

  function routeGeometry(lat, lon, seed, kilometers) {
    const heading = (Math.abs(seed) % 360) * Math.PI / 180;
    const metersPerDegLat = 111320;
    const metersPerDegLon = Math.max(20000, 111320 * Math.cos(lat * Math.PI / 180));
    const steps = 7;
    const step = (kilometers * 1000) / steps;
    const half = steps / 2;
    const points = [];
    for (let index = 0; index <= steps; index += 1) {
      const wobble = Math.sin(index * 0.85 + (seed % 17)) * 0.28;
      const along = (index - half) * step;
      const side = Math.sin(index + (seed % 9)) * step * 0.18;
      const dLat = (along * Math.cos(heading + wobble) - side * Math.sin(heading)) / metersPerDegLat;
      const dLon = (along * Math.sin(heading + wobble) + side * Math.cos(heading)) / metersPerDegLon;
      points.push([lat + dLat, lon + dLon]);
    }
    return points;
  }

  function padsGeometry(lat, lon, seed) {
    const slopeA = 1.1 + (Math.abs(seed) % 8) * 0.1;
    const slopeB = 1.8 + (Math.abs(Math.trunc(seed / 7)) % 8) * 0.1;
    return [
      { name: "Flat Pad A", lat: lat + 0.012, lon: lon - 0.010, slope: Math.min(slopeA, 2.4), starlink: 88 + (Math.abs(seed) % 11) },
      { name: "Flat Pad B", lat: lat - 0.014, lon: lon + 0.011, slope: Math.min(slopeB, 2.8), starlink: 80 + (Math.abs(Math.trunc(seed / 3)) % 15) }
    ];
  }

  function buildBuiltins() {
    return ATLAS.specs.map(function (spec) {
      const seed = seedFor(spec.id);
      const coordinates = ATLAS.handRoutes[spec.id] || routeGeometry(spec.lat, spec.lon, seed, spec.km || 18);
      let camps = ATLAS.handCamps[spec.id];
      if (!camps) {
        camps = padsGeometry(spec.lat, spec.lon, seed).map(function (pad, index) {
          return Object.assign({}, pad, { name: spec.name + (index === 0 ? " Pad A" : " Pad B") });
        });
      }
      return {
        id: spec.id,
        name: spec.name,
        region: spec.region,
        agency: spec.agency,
        state: spec.state,
        miles: spec.miles,
        elev: spec.elev,
        clearance: spec.clearance,
        canopy: spec.canopy,
        water: spec.water,
        locker: !!spec.locker,
        gate: spec.gate || "OPEN",
        snow: spec.snow || 0,
        flow: spec.flow || 0,
        lat: spec.lat,
        lon: spec.lon,
        coordinates: coordinates,
        flatCamps: camps.filter(function (camp) { return camp.slope < 3; }),
        signature: !!spec.signature,
        bdr: !!spec.bdr,
        states: spec.states && spec.states.length ? spec.states.slice() : [spec.state],
        bdrOrder: spec.bdrOrder || 0
      };
    });
  }

  function allTrails() {
    return state.trails.concat(state.discovered);
  }

  function trailById(id) {
    return allTrails().find(function (trail) { return trail.id === id; }) || null;
  }

  function selected() {
    return trailById(state.selectedId) || pickerTrails().find(function (trail) { return !isBdrTrail(trail); }) || state.trails.find(function (trail) { return !isBdrTrail(trail); }) || state.trails[0];
  }

  function ll(point) {
    if (Array.isArray(point)) return { lat: point[0], lon: point[1] };
    return { lat: point.lat, lon: point.lon };
  }

  function meters(a, b) {
    const start = ll(a);
    const end = ll(b);
    const radius = 6371000;
    const p1 = start.lat * Math.PI / 180;
    const p2 = end.lat * Math.PI / 180;
    const dPhi = (end.lat - start.lat) * Math.PI / 180;
    const dLon = (end.lon - start.lon) * Math.PI / 180;
    const h = Math.sin(dPhi / 2) ** 2 + Math.cos(p1) * Math.cos(p2) * Math.sin(dLon / 2) ** 2;
    return 2 * radius * Math.asin(Math.min(1, Math.sqrt(h)));
  }

  function miles(a, b) {
    return meters(a, b) / 1609.344;
  }

  function nearestMiles(origin, trail) {
    if (!origin || !trail) return Infinity;
    const points = [];
    if (Number.isFinite(Number(trail.lat)) && Number.isFinite(Number(trail.lon))) points.push({ lat: Number(trail.lat), lon: Number(trail.lon) });
    const coords = trail.coordinates || [];
    const step = Math.max(1, Math.floor(coords.length / 24));
    for (let index = 0; index < coords.length; index += step) points.push(ll(coords[index]));
    if (coords.length) points.push(ll(coords[coords.length - 1]));
    let best = Infinity;
    points.forEach(function (point) { best = Math.min(best, miles(origin, point)); });
    return best;
  }

  function polylineMeters(coords) {
    let total = 0;
    for (let index = 1; index < coords.length; index += 1) total += meters(coords[index - 1], coords[index]);
    return total;
  }

  function formatDistance(metersValue) {
    const milesValue = metersValue / 1609.344;
    if (milesValue < 0.1) return Math.round(metersValue * 3.28084) + " ft";
    return milesValue.toFixed(1) + " mi";
  }

  function formatDuration(seconds) {
    const minutes = Math.max(1, Math.round(seconds / 60));
    if (minutes < 60) return minutes + " min";
    const hours = Math.floor(minutes / 60);
    const remainder = minutes % 60;
    return remainder === 0 ? hours + " hr" : hours + " hr " + remainder + " min";
  }

  function formatClock(date) {
    return date.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  }

  function evaluate(trail) {
    const profile = state.rig;
    const notes = [];
    let noGo = false;
    let caution = false;
    if (profile.roofHeightFt > trail.canopy) {
      noGo = true;
      notes.push("Roof height (" + num(profile.roofHeightFt) + " ft) exceeds canopy (" + num(trail.canopy) + " ft).");
    }
    if (profile.minClearanceIn < trail.clearance - 0.8) {
      noGo = true;
      notes.push("Clearance (" + num(profile.minClearanceIn) + '") below shelf minimum (' + num(trail.clearance) + '").');
    } else if (profile.minClearanceIn < trail.clearance) {
      caution = true;
      notes.push("Tight clearance for " + num(trail.clearance) + '" ledges—skid plates advised.');
    }
    if (trail.locker && !profile.hasRearLocker) {
      caution = true;
      notes.push("Rear locker recommended for steep switchbacks.");
    }
    if (trail.water >= 24 && !profile.hasSnorkel) {
      caution = true;
      notes.push("Deep water ford (" + trail.water + '") near stock intake.');
    }
    if (!notes.length) notes.push("Clearance & canopy verified safe for " + profile.name + ".");
    return { verdict: noGo ? "NO-GO CLEARANCE" : caution ? "CAUTION" : "FITS YOUR RIG", notes: notes };
  }

  function shortFit(verdict) {
    if (verdict === "FITS YOUR RIG") return "FITS";
    if (verdict === "CAUTION") return "CAUTION";
    return "NO-GO";
  }

  function fitColor(verdict) {
    if (verdict === "FITS YOUR RIG") return "#3ddc84";
    if (verdict === "CAUTION") return "#ff9f1a";
    return "#ff4d4d";
  }

  function filterTitle() {
    if (state.filter === "near") return "Near Me";
    if (state.filter === "all") return "All USA";
    if (state.filter === "bdr") return "Backcountry Corridors";
    return state.filter;
  }

  function isBdrTrail(trail) {
    if (!trail) return false;
    if (trail.bdr) return true;
    const id = String(trail.id || "").toLowerCase();
    if (id.indexOf("bdr") >= 0) return true;
    return /backcountry discovery|\bBDR\b/i.test(String(trail.name || ""));
  }

  function corridorLabel(trail) {
    if (!trail || !isBdrTrail(trail)) return trail ? trail.name : "";
    const code = trail.state || "US";
    return code + " Backcountry Corridor (" + String(trail.id || "corridor").toUpperCase() + " Ref)";
  }

  function bootMapCenter() {
    return { lat: 37.9589, lon: -107.7352 };
  }

  function mapCenter() {
    if (!map) return bootMapCenter();
    const center = map.getCenter();
    return { lat: center.lat, lon: center.lng };
  }

  function listOrigin() {
    if (state.fix) return { lat: state.fix.lat, lon: state.fix.lon };
    return mapCenter();
  }

  // GPS when it exists, unless the map has been panned well away from it.
  // The boot trailhead is not a Near Me anchor.
  function nearAnchor() {
    if (state.fix) {
      const gps = { lat: state.fix.lat, lon: state.fix.lon };
      if (state.userPanned && map && miles(gps, mapCenter()) > 30) return mapCenter();
      return gps;
    }
    if (state.userPanned && map && miles(mapCenter(), bootMapCenter()) > 15) return mapCenter();
    return null;
  }

  function pickerTrails() {
    const query = state.query.trim().toLowerCase();
    const seen = new Set();
    let list = allTrails().filter(function (trail) {
      if (seen.has(trail.id)) return false;
      seen.add(trail.id);
      if (query) {
        const corridorHay = trail.bdr ? " bdr backcountry corridor " + trail.id + " " : "";
        const hay = (trail.name + " " + corridorHay + trail.region + " " + trail.state + " " + (trail.states || []).join(" ") + " " + trail.agency).toLowerCase();
        if (!hay.includes(query)) return false;
      }
      if (state.filter === "bdr") return isBdrTrail(trail);
      if (state.filter === "near") return !isBdrTrail(trail);
      if (state.filter === "all") return !isBdrTrail(trail) || !!query;
      const codes = trail.states && trail.states.length ? trail.states : [trail.state];
      return codes.indexOf(state.filter) >= 0;
    });
    if (state.filter === "bdr") {
      list.sort(function (a, b) {
        const order = (a.bdrOrder || 99) - (b.bdrOrder || 99);
        return order || String(a.name).localeCompare(String(b.name));
      });
      return list;
    }
    const origin = state.filter === "near" ? nearAnchor() : (state.filter === "all" ? listOrigin() : null);
    if (state.filter === "near" && !origin) return [];
    if (!origin) return list;
    const ranked = list.slice().sort(function (a, b) { return nearestMiles(origin, a) - nearestMiles(origin, b); });
    if (state.filter !== "near") return ranked;
    const nearby = ranked.filter(function (trail) { return nearestMiles(origin, trail) <= 100; });
    return nearby.length ? nearby : ranked.slice(0, 20);
  }

  function spotsFor(trail) {
    return trail.flatCamps.map(function (camp, index) {
      return {
        id: trail.id + "#" + index,
        trailID: trail.id,
        name: camp.name,
        lat: camp.lat,
        lon: camp.lon,
        slope: camp.slope,
        starlink: camp.starlink,
        kind: "pad"
      };
    });
  }

  function trailhead(trail) {
    const start = trail.coordinates[0] || [trail.lat, trail.lon];
    return {
      id: trail.id + "-trailhead",
      trailID: trail.id,
      name: trail.name + " Trailhead",
      lat: start[0],
      lon: start[1],
      slope: 0,
      starlink: 0,
      kind: "trailhead"
    };
  }

  function listedCamps() {
    const source = map ? drawableTrails() : pickerTrails().filter(function (trail) { return !isBdrTrail(trail) || trail.id === state.selectedId; });
    const pads = [];
    source.forEach(function (trail) {
      spotsFor(trail).forEach(function (spot) {
        if (spot.slope < 3) pads.push(spot);
      });
    });
    const origin = mapCenter();
    return pads.sort(function (a, b) { return miles(origin, a) - miles(origin, b); });
  }

  function findSpot(id) {
    for (const trail of pickerTrails()) {
      if (trailhead(trail).id === id) return trailhead(trail);
      const pad = spotsFor(trail).find(function (spot) { return spot.id === id; });
      if (pad) return pad;
    }
    for (const trail of allTrails()) {
      if (trailhead(trail).id === id) return trailhead(trail);
      const pad = spotsFor(trail).find(function (spot) { return spot.id === id; });
      if (pad) return pad;
    }
    return null;
  }

  function toast(message, ms) {
    const el = document.getElementById("toast");
    el.textContent = message;
    el.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { el.hidden = true; }, ms || 2800);
  }

  const NATURAL_VOICE_HINTS = ["natural", "online", "neural", "ava", "samantha (enhanced)", "samantha", "google us english", "alex", "serena"];
  let cachedVoice = null;

  function bestNaturalWebVoice() {
    if (!window.speechSynthesis || !window.speechSynthesis.getVoices) return null;
    const voices = window.speechSynthesis.getVoices() || [];
    const english = voices.filter(function (voice) { return /^en([-_]|$)/i.test(voice.lang || ""); });
    const pool = english.length ? english : voices;
    let best = null;
    let bestScore = 0;
    pool.forEach(function (voice) {
      const blob = ((voice.name || "") + " " + (voice.lang || "")).toLowerCase();
      if (/albert|bad news|bahh|bells|boing|bubbles|cellos|fred|good news|jester|organ|superstar|trinoids|whisper|wobble|zarvox/.test(blob)) return;
      let score = /en-us/.test(blob) ? 8 : 0;
      NATURAL_VOICE_HINTS.forEach(function (hint, index) {
        if (blob.indexOf(hint) >= 0) score += 120 - index;
      });
      if (score > bestScore) {
        bestScore = score;
        best = voice;
      }
    });
    return best;
  }

  function humanizeSpeech(text) {
    return String(text || "")
      .replace(/\b0\.2 miles\b/gi, "a fifth of a mile")
      .replace(/\bpoint two miles\b/gi, "a fifth of a mile")
      .replace(/\bin 0\.2 miles\b/gi, "in a fifth of a mile");
  }

  function speak(text) {
    const spoken = humanizeSpeech(text);
    if (state.muted || !spoken) return;
    try {
      if (window.TrailForgeSpeech && TrailForgeSpeech.speak) {
        TrailForgeSpeech.speak(spoken);
        return;
      }
    } catch (error) { /* Web Speech fallback below. */ }
    if (!window.speechSynthesis) return;
    try {
      const utterance = new SpeechSynthesisUtterance(spoken);
      utterance.lang = "en-US";
      utterance.rate = 0.96;
      utterance.pitch = 1.02;
      const voice = cachedVoice || bestNaturalWebVoice();
      if (voice) {
        cachedVoice = voice;
        try { utterance.voice = voice; } catch (error) { /* Keep the engine default if this voice cannot be selected. */ }
      }
      window.speechSynthesis.cancel();
      window.speechSynthesis.speak(utterance);
    } catch (error) { /* No speech engine on this device. */ }
  }

  if (window.speechSynthesis && window.speechSynthesis.addEventListener) {
    window.speechSynthesis.addEventListener("voiceschanged", function () {
      cachedVoice = bestNaturalWebVoice();
    });
  }

  function setMuted(muted) {
    state.muted = muted;
    localStorage.setItem("tf-mute", muted ? "1" : "0");
    try { if (window.TrailForgeSpeech) TrailForgeSpeech.setMuted(muted); } catch (error) { /* ignore */ }
    if (muted && window.speechSynthesis) window.speechSynthesis.cancel();
    const button = document.getElementById("muteBtn");
    if (button) {
      button.textContent = muted ? "🔇" : "🔊";
      button.setAttribute("aria-label", muted ? "Unmute voice directions" : "Mute voice directions");
    }
  }

  function decodeB64(value) {
    const binary = atob(value || "");
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
    return new TextDecoder("utf-8").decode(bytes);
  }

  function net(url, options) {
    const method = (options && options.method) || "GET";
    const body = (options && options.body) || "";
    let timer = null;
    const timeout = new Promise(function (_, reject) {
      timer = setTimeout(function () { reject(new Error("timeout")); }, 12000);
    });
    timeout.catch(function () {});
    const request = window.TrailForgeNet && TrailForgeNet.fetch
      ? new Promise(function (resolve, reject) {
        const id = "n" + (++netSeq);
        pendingNet.set(id, { resolve: resolve, reject: reject });
        TrailForgeNet.fetch(id, url, method, body);
      })
      : fetch(url, {
        method: method,
        body: method === "POST" ? body : undefined,
        headers: method === "POST" ? { "Content-Type": "text/plain; charset=UTF-8" } : undefined
      }).then(function (response) {
        if (!response.ok) throw new Error("HTTP " + response.status);
        return response.text();
      });
    request.catch(function () {});
    return Promise.race([request, timeout]).finally(function () { clearTimeout(timer); });
  }

  function onNativeFetch(id, ok, payload) {
    const pending = pendingNet.get(id);
    if (!pending) return;
    pendingNet.delete(id);
    if (pending.binary) {
      if (!ok) { pending.reject(new Error("tile failed")); return; }
      try {
        const binary = atob(payload || "");
        const bytes = new Uint8Array(binary.length);
        for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
        const type = bytes.length > 2 && bytes[0] === 0xFF && bytes[1] === 0xD8 ? "image/jpeg" : "image/png";
        pending.resolve(new Blob([bytes], { type: type }));
      } catch (error) {
        pending.reject(error);
      }
      return;
    }
    let text = "";
    try { text = decodeB64(payload); } catch (error) { text = String(payload || ""); }
    if (ok) pending.resolve(text);
    else pending.reject(new Error(text || "network error"));
  }

  function maneuverSvg(step) {
    if (!step || step.type === "arrive") {
      return '<svg viewBox="0 0 48 48"><path fill="currentColor" d="M10 30 V14 h12 l4-6 4 6 h8 v16 l-8 8 h-12 z"/></svg>';
    }
    const turns = { left: -90, "slight left": -40, "sharp left": -130, right: 90, "slight right": 40, "sharp right": 130, straight: 0, uturn: 180 };
    const angle = turns[step.modifier] || 0;
    return '<svg viewBox="0 0 48 48"><g transform="rotate(' + angle + ' 24 24)"><path fill="currentColor" d="M22 40 V18 L14 26 L10 22 L24 8 L38 22 L34 26 L26 18 V40z"/></g></svg>';
  }

  function instructionFor(step) {
    const type = step.maneuver.type || "continue";
    const modifier = step.maneuver.modifier || "";
    const road = [step.ref, step.name].filter(Boolean).join(" ") || "the trail";
    if (type === "arrive") return "Arrive at the destination";
    if (type === "depart") return "Head " + (modifier || "out") + " on " + road;
    if (type === "roundabout" || type === "rotary") return "Enter the roundabout onto " + road;
    if (type === "merge") return "Merge " + (modifier || "") + " onto " + road;
    if (type === "fork" || type === "end of road") return "Keep " + (modifier || "straight") + " onto " + road;
    if (type === "new name" || type === "continue") return "Continue on " + road;
    if (modifier) return "Turn " + modifier + " onto " + road;
    return "Continue on " + road;
  }

  function renderTop() {
    const top = document.getElementById("top");
    if (state.route && !state.route.confirmed) {
      const spot = state.route.destination;
      const remaining = remainingMeters(state.route);
      const seconds = remainingSeconds(state.route, remaining);
      const slope = spot.kind === "pad" ? " · " + Number(spot.slope || 0).toFixed(1) + "° slope" : "";
      top.innerHTML = '<div class="nav preview"><div class="nav-copy"><div class="nav-dist">Previewing Route to ' + esc(spot.name) + '</div><div class="nav-street">' + esc(formatDistance(remaining) + " · " + formatDuration(seconds) + slope) + '</div></div><button type="button" class="primary" data-act="confirm-route">Start GPS Route</button><button type="button" class="ghost" data-act="end">Cancel</button></div>';
      return;
    }
    if (state.route) {
      const cue = nextCue();
      const steps = displaySteps(state.route);
      const stepHtml = state.showSteps ? '<div class="steps">' + steps.map(function (step, index) {
        return '<div class="step' + (index === (state.route.stepIndex || 0) ? " on" : "") + '"><span>' + formatDistance(step.distanceMeters) + "</span><span>" + esc(step.instruction) + "</span></div>";
      }).join("") + "</div>" : "";
      top.innerHTML = '<div class="nav"><div class="man" id="navIcon">' + maneuverSvg(cue.step) + '</div><div class="nav-copy"><div class="nav-dist" id="navDist">' + esc(state.routing ? "Recalculating route…" : cue.distance) + '</div><div class="nav-street" id="navStreet">' + esc(cue.street) + '</div><div class="sub" id="navSub">' + esc(cue.text) + '</div>' + liveFlagHtml() + '</div><button type="button" class="icon-btn" id="muteBtn" data-act="mute" aria-label="Mute voice directions">' + (state.muted ? "🔇" : "🔊") + '</button><button type="button" class="icon-btn" data-act="steps" aria-label="Step list">☰</button></div>' + stepHtml;
      return;
    }
    const list = pickerTrails();
    const locating = state.filter === "near" && !nearAnchor();
    const color = "#8ea6bb";
    const title = locating ? "Near Me • Locating you" : (!list.length ? "No routes for " + filterTitle() : filterTitle() + " • " + list.length + (list.length === 1 ? " Route" : " Routes"));
    const detail = locating ? "Waiting for GPS. Pan the map to browse another area." : (state.filter === "near" || state.filter === "all" ? "Closest trails first" : "Pick a route below");
    top.innerHTML = '<div class="fit"><div class="lamp" style="background:' + color + ";color:" + color + '"></div><div class="fit-copy"><div class="fit-title">' + esc(title) + '</div><div class="sub">' + esc(detail) + '</div>' + liveFlagHtml() + '</div><button type="button" class="pill-btn' + (state.drawer === "corridor" ? " on" : "") + '" data-act="offline">' + (state.offlineSaved ? "Offline Maps" : "Save") + "</button></div>";
  }

  function routeBarHtml() {
    if (!state.route) return "";
    const spot = state.route.destination;
    const remaining = remainingMeters(state.route);
    const seconds = remainingSeconds(state.route, remaining);
    const eta = formatClock(new Date(Date.now() + seconds * 1000));
    const slope = spot.kind === "pad" ? spot.slope.toFixed(1) + "°" : spot.kind === "parcel" ? Number(spot.acres || 0).toFixed(1) + " ac" : spot.kind === "place" ? "Place" : "Trailhead";
    const sky = spot.kind === "pad" ? spot.starlink + "%" : (spot.kind === "parcel" || spot.kind === "place") ? (spot.zoning || "—") : "—";
    const slopeLabel = spot.kind === "pad" ? "pad slope" : spot.kind === "parcel" ? "lot size" : "destination";
    const skyLabel = spot.kind === "pad" ? "Starlink" : spot.kind === "parcel" ? "zoning" : spot.kind === "place" ? "address" : "sky";
    const stats = '<div class="route-stats"><div><b id="rbSlope">' + esc(slope) + "</b><span>" + slopeLabel + '</span></div><div><b id="rbSky">' + esc(sky) + "</b><span>" + skyLabel + '</span></div><div><b id="rbEta">' + esc(formatDuration(seconds)) + "</b><span>ETA " + esc(eta) + '</span></div><div><b id="rbMiles">' + esc(formatDistance(remaining)) + '</b><span>remaining</span></div></div>';
    if (!state.route.confirmed) {
      return stats + '<div class="actions"><button type="button" class="primary on" data-act="confirm-route">Start GPS Route</button><button type="button" data-act="overview">Overview</button><button type="button" data-act="gmaps">Open in Google Maps</button><button type="button" class="end" data-act="end">Cancel ✕</button></div>';
    }
    return stats + '<div class="actions"><button type="button" class="primary' + (state.follow ? " on" : "") + '" data-act="follow">Follow GPS</button><button type="button" data-act="overview">Overview</button><button type="button" data-act="gmaps">Open in Google Maps</button><button type="button" class="end" data-act="end">End Route ✕</button></div>';
  }

  function sheetHtml() {
    const body = state.mode === "drive" ? driveHtml() : state.mode === "camp" ? campHtml() : rigHtml();
    return body + '<button type="button" class="safety-review" data-act="safety-review">Safety &amp; Legal Disclaimer / Terms of Use</button>';
  }

  function renderModebar() {
    document.querySelectorAll("#modebar [data-act=mode]").forEach(function (button) {
      button.classList.toggle("on", button.dataset.mode === state.mode);
    });
  }

  function driveHtml() {
    const list = pickerTrails();
    const countLabel = filterTitle() + " • " + list.length + (list.length === 1 ? " Route" : " Routes") + " ▾";
    const chips = ['<button type="button" class="chip' + (state.filter === "near" ? " on" : "") + '" data-act="filter" data-id="near">Near Me</button>', '<button type="button" class="chip' + (state.filter === "all" ? " on" : "") + '" data-act="filter" data-id="all">All USA</button>', '<button type="button" class="chip' + (state.filter === "bdr" ? " on" : "") + '" data-act="filter" data-id="bdr">Backcountry Corridors</button>'].concat(ATLAS.states.map(function (box) {
      return '<button type="button" class="chip' + (state.filter === box.code ? " on" : "") + '" data-act="filter" data-id="' + box.code + '">' + box.code + "</button>";
    })).join("");
    const origin = (state.filter === "near" && nearAnchor()) || listOrigin();
    const rows = list.map(function (trail) {
      const fit = evaluate(trail);
      const away = " · " + nearestMiles(origin, trail).toFixed(1) + " mi away";
      const where = trail.states && trail.states.length > 1 ? trail.states.join("/") : trail.state;
      return '<button type="button" class="row" data-act="pick" data-id="' + esc(trail.id) + '"><i class="dot" style="background:' + fitColor(fit.verdict) + '"></i><span class="meta"><b>' + esc(where + " · " + corridorLabel(trail)) + "</b><small>" + esc(trail.miles + " mi · " + num(trail.clearance) + '" · ' + shortFit(fit.verdict) + away) + "</small></span></button>";
    }).join("") || '<div class="row"><span class="meta"><b>No matching routes</b></span></div>';
    const pills = list.slice(0, 24).map(function (trail) {
      const shown = corridorLabel(trail);
      const label = shown + " · " + Math.round(nearestMiles(origin, trail)) + " mi";
      return '<button type="button" class="trail-pill' + (trail.id === state.selectedId ? " on" : "") + '" data-act="pick" data-id="' + esc(trail.id) + '">' + esc(label) + "</button>";
    }).join("");
    const trail = selected();
    const telemetry = profileHtml(trail) + telemetryHtml(trail);
    const convoy = '<div class="convoy"><button type="button" data-act="convoy" data-id="🛑 Stopping Ahead">🛑 Stopping Ahead</button><button type="button" data-act="convoy" data-id="🛞 Airing Down">🛞 Airing Down</button><button type="button" data-act="convoy" data-id="🆘 Stuck — Need Winch/Strap">🆘 Stuck — Need Winch/Strap</button><button type="button" data-act="convoy" data-id="🔒 Gate Locked — Turn Around">🔒 Gate Locked — Turn Around</button></div>';
    const placeRows = (state.places || []).map(function (place) {
      const away = state.fix ? " · " + miles(state.fix, place).toFixed(1) + " mi from MY GPS" : "";
      return '<div class="place-card"><button type="button" class="row" data-act="place-route" data-id="' + esc(place.id) + '"><span class="meta"><b>' + esc(place.name) + "</b><small>" + esc(place.address || "") + esc(away) + '</small></span></button><div class="actions"><button type="button" data-act="place-show" data-id="' + esc(place.id) + '">Show on Map</button><button type="button" class="primary" data-act="place-route" data-id="' + esc(place.id) + '">Route Here</button></div></div>';
    }).join("");
    const places = (state.placeBusy || placeRows) ? '<div class="status">Places &amp; Addresses</div>' + (state.placeBusy ? '<div class="status">Searching addresses and stores…</div>' : "") + placeRows : "";
    return savedMarkersHtml() + plotWaypointsHtml() + '<div class="search-row"><input class="search" id="search" placeholder="Search trails, state, address, or store" value="' + esc(state.query) + '" /><button type="button" class="search-go" data-act="search-place">Search</button></div>' + places + '<div class="chips">' + chips + '</div><button type="button" class="menu-btn" id="trailMenu" data-act="menu">' + esc(countLabel) + '</button><div class="menu' + (state.menuOpen ? " open" : "") + '" id="trailList">' + rows + '</div><div class="pills">' + pills + '</div><div class="status" id="scanStatus">' + esc(state.scanning ? "Scanning USA 4x4 trails…" : state.scanStatus) + "</div>" + telemetry + convoy;
  }

  function profileHtml(trail) {
    if (!trail) return "";
    const active = state.community.filter(function (item) { return item.trailId === trail.id && !item.cleared; }).sort(function (a, b) { return b.time - a.time; });
    const latest = active[0] || state.reports.find(function (item) { return item.trailId === trail.id; });
    const pills = REPORTS.map(function (status) {
      return '<button type="button" data-act="report" data-id="' + esc(status) + '" class="' + (latest && latest.status === status ? "on" : "") + '">' + esc(reportLabel(status)) + "</button>";
    }).join("");
    const pins = visibleCruxPins();
    const crux = pins.map(function (pin) {
      return '<div class="crux">' + esc(pin.title) + "</div>";
    }).join("");
    const badge = mvumBadge(trail);
    const ranger = nearestRanger(trail);
    const rangerBtn = ranger
      ? '<button type="button" data-act="call-ranger" data-id="' + esc(ranger.phone) + '">Call ' + esc(ranger.name) + "</button>"
      : '<button type="button" data-act="ranger-page">Ranger district contacts</button>';
    const disclaimer = isBdrTrail(trail) ? '<div class="sub">' + esc(CORRIDOR_NOTE) + "</div>" : "";
    return '<div class="profile"><div class="profile-top"><b>Elevation</b><span id="elevRead">—</span></div><canvas id="elevChart" height="92"></canvas><div class="obs-key">💧 Ford · 🪨 Ledge · ⛺ &lt;3° Pad</div>' + (crux ? '<div class="crux-list" id="cruxSection"><b>Crux Obstacles</b>' + crux + "</div>" : "") + (badge ? '<div class="sub mvum">' + esc(badge) + "</div>" : "") + '<div class="actions"><button type="button" data-act="share-trip">Share Trip Package (QR / Export)</button>' + rangerBtn + '</div>' + disclaimer + '<div class="reports"><span>Report Trail Status</span>' + pills + "</div>" + communityListHtml(trail) + "</div>";
  }

  function telemetryHtml(trail) {
    if (!trail) return "";
    const gauges = state.gauges.length ? state.gauges.map(function (gauge) {
      return esc(gauge.name) + ": " + Math.round(gauge.cfs) + " cfs · " + gauge.height.toFixed(1) + " ft";
    }).join("<br>") : "USGS ford gauge " + trail.flow + " cfs";
    const fires = state.fires.length ? state.fires.slice(0, 2).map(function (fire) {
      return esc(fire.name) + " · " + Math.round(fire.acres) + " ac · " + Math.round(fire.contained) + "% contained";
    }).join("<br>") : "No active NIFC perimeter in this view";
    return '<div class="telemetry"><b>Live telemetry</b><br>SNOTEL ' + Number(trail.snow).toFixed(1) + " in snow · Gate " + esc(trail.gate) + "<br>" + gauges + "<br>" + fires + "</div>";
  }

  function campHtml() {
    const pads = listedCamps();
    const title = pads.length ? "Tap a &lt;3° pad to route" : "No &lt;3° pads in " + esc(filterTitle());
    const cards = pads.slice(0, 40).map(function (spot) {
      const trail = trailById(spot.trailID);
      return '<div class="pad"><div class="meta"><b>' + esc(spot.name) + "</b><small>" + spot.slope.toFixed(1) + "° Slope · " + spot.starlink + "% Starlink · " + esc(trail ? trail.name : "Trail") + '</small></div><button type="button" class="cta" data-act="route" data-id="' + esc(spot.id) + '">Route Here</button></div>';
    }).join("");
    const chips = '<div class="chips"><button type="button" class="chip' + (state.filter === "near" ? " on" : "") + '" data-act="filter" data-id="near">Near Me</button><button type="button" class="chip' + (state.filter === "bdr" ? " on" : "") + '" data-act="filter" data-id="bdr">Backcountry Corridors</button>' + ATLAS.states.map(function (box) {
      return '<button type="button" class="chip' + (state.filter === box.code ? " on" : "") + '" data-act="filter" data-id="' + box.code + '">' + box.code + "</button>";
    }).join("") + "</div>";
    return chips + '<div class="status">' + title + "</div>" + cards;
  }

  function rigHtml() {
    const profile = state.rig;
    const fields = [
      ["tireInches", "Tire size", "29", "40", "0.5", '"'],
      ["liftInches", "Lift", "0", "6", "0.5", '"'],
      ["minClearanceIn", "Min diff clearance", "6", "16", "0.1", '"'],
      ["roofHeightFt", "Roof / tent height", "5", "12", "0.1", " ft"],
      ["widthIn", "Width", "65", "96", "1", '"'],
      ["rigWeightLbs", "Weight", "3000", "12000", "50", " lb"]
    ].map(function (field) {
      return '<label class="field"><span>' + field[1] + "<b>" + num(profile[field[0]]) + field[5] + '</b></span><input type="range" data-field="' + field[0] + '" min="' + field[2] + '" max="' + field[3] + '" step="' + field[4] + '" value="' + profile[field[0]] + '" /></label>';
    }).join("");
    const locker = function (id, label) {
      const on = (id === "rear" && profile.hasRearLocker) || (id === "none" && !profile.hasRearLocker);
      return '<button type="button" data-act="locker" data-id="' + id + '" class="' + (on ? "on" : "") + '">' + label + "</button>";
    };
    const surface = ["rock", "sand", "mixed"].map(function (name) {
      return '<button type="button" data-act="surface" data-id="' + name + '" class="' + (state.surface === name ? "on" : "") + '">' + name[0].toUpperCase() + name.slice(1) + "</button>";
    }).join("");
    const products = CATALOG.map(function (item) {
      const live = (state.billing.products || []).find(function (product) { return product.id === item.id; });
      const price = live && live.price ? live.price : item.price;
      const owned = state.billing.pro ? "Unlocked" : "Get";
      const badge = item.popular ? '<em class="pop">MOST POPULAR</em>' : "";
      return '<div class="pass' + (item.popular ? " popular" : "") + (item.founders ? " founders" : "") + '"><div class="meta">' + badge + "<b>" + esc(item.title) + "</b><small>" + esc(item.note) + " · " + esc(price) + '</small></div><button type="button" data-act="buy" data-id="' + item.id + '">' + owned + "</button></div>";
    }).join("");
    return '<input class="name" data-field="name" value="' + esc(profile.name) + '" aria-label="Rig name" />' + products + '<div class="actions"><button type="button" data-act="restore">Restore purchases</button></div><div class="seg">' + locker("none", "Open diffs") + locker("rear", "Rear locker") + '<button type="button" data-act="snorkel" class="' + (profile.hasSnorkel ? "on" : "") + '">Snorkel</button><button type="button" data-act="bead" class="' + (state.beadlocks ? "on" : "") + '">Beadlocks</button></div><div class="seg" style="margin-top:8px">' + surface + '</div><div class="grid" style="margin-top:8px">' + fields + '</div><div class="foot">TrailForge Overland 1.6.8 · build 30<br>' + MAP_ATTRIB + '<br>' + CORRIDOR_NOTE + '<br><a href="https://krokemoutdoors.github.io/trailforge-overland/#privacy" data-act="privacy">Privacy policy</a></div>';
  }

  function renderSheet() {
    document.getElementById("routebar").innerHTML = routeBarHtml();
    renderModebar();
    const active = document.activeElement;
    if (active && active.matches && active.matches("input[type=range][data-field], input.name, #recordName, #pinName, #markerName")) return;
    const typingSearch = active && active.id === "search";
    const caret = typingSearch ? active.selectionStart : null;
    document.getElementById("sheet").innerHTML = sheetHtml();
    paintElevation();
    if (!typingSearch) return;
    const search = document.getElementById("search");
    if (!search) return;
    search.focus();
    const pos = Math.min(caret || 0, search.value.length);
    search.setSelectionRange(pos, pos);
  }

  function renderAll() {
    document.getElementById("app").dataset.mode = state.mode;
    applyChrome();
    renderTop();
    renderSheet();
    updateHud();
    syncMap();
  }

  function formatPair(point) {
    if (!point || !Number.isFinite(Number(point.lat)) || !Number.isFinite(Number(point.lon))) return null;
    const lat = Number(point.lat);
    const lon = Number(point.lon);
    const ns = lat >= 0 ? "N" : "S";
    const ew = lon >= 0 ? "E" : "W";
    return Math.abs(lat).toFixed(5) + "° " + ns + ", " + Math.abs(lon).toFixed(5) + "° " + ew;
  }

  function targetPoint() {
    if (state.route && state.route.destination) return state.route.destination;
    if (state.routing && state.aim) return state.aim;
    if (state.placePin) return state.placePin;
    const trail = selected();
    if (!trail) return null;
    if (state.mode === "camp") {
      const pads = spotsFor(trail).filter(function (spot) { return spot.slope < 3; });
      if (pads.length) return pads.slice().sort(function (a, b) { return a.slope - b.slope; })[0];
    }
    return trailhead(trail);
  }

  function copyText(text) {
    function done() { toast("Target copied"); }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, function () { fallbackCopy(text, done); });
      return;
    }
    fallbackCopy(text, done);
  }

  function fallbackCopy(text, done) {
    const area = document.createElement("textarea");
    area.value = text;
    area.setAttribute("readonly", "");
    area.style.position = "fixed";
    area.style.left = "-9999px";
    document.body.appendChild(area);
    area.select();
    try {
      document.execCommand("copy");
      done();
    } catch (error) {
      toast(text);
    }
    area.remove();
  }

  function updateHud() {
    const speed = state.fix && state.fix.speedMps != null && state.fix.speedMps >= 0 ? Math.round(state.fix.speedMps * 2.2369362920544) : 0;
    const alt = state.fix && state.fix.altitudeM != null ? Math.round(state.fix.altitudeM * 3.280839895).toLocaleString("en-US") : "—";
    const speedRead = document.getElementById("speedRead");
    if (speedRead) speedRead.textContent = state.fix ? String(speed) : "—";
    const altRead = document.getElementById("altRead");
    if (altRead) altRead.textContent = alt;
    const gpsText = state.fix ? formatPair(state.fix) : null;
    const aimText = formatPair(targetPoint());
    state.targetCopy = aimText ? "TARGET: " + aimText : "";
    const gpsRead = document.querySelector("#myGpsRead b");
    const targetRead = document.querySelector("#targetRead b");
    if (gpsRead) gpsRead.textContent = gpsText || "—";
    if (targetRead) targetRead.textContent = aimText || "—";
    const limit = state.rollLimit || 25;
    const warn = Math.abs(state.roll) >= limit || Math.abs(state.pitch) >= limit;
    const pill = document.getElementById("clinPill");
    if (pill) pill.classList.toggle("warn", warn);
    const clinRead = document.getElementById("clinRead");
    if (clinRead) clinRead.textContent = "Roll " + Math.round(state.roll) + "° / Pitch " + Math.round(state.pitch) + "°";
    const clinBar = document.getElementById("clinBar");
    if (clinBar) clinBar.style.transform = "rotate(" + (-state.roll).toFixed(1) + "deg) translateY(" + (Math.max(-18, Math.min(18, state.pitch)) * 0.35).toFixed(1) + "px)";
    const horizon = document.getElementById("horizon");
    if (horizon) horizon.style.transform = "rotate(" + state.roll.toFixed(1) + "deg) translateY(" + (state.pitch * 0.6).toFixed(1) + "px)";
    const tilt = document.getElementById("tiltRead");
    if (tilt) tilt.textContent = "Pitch " + Math.round(state.pitch) + "° · Roll " + Math.round(state.roll) + "°";
    const turn = document.getElementById("dashTurn");
    if (turn) {
      if (state.route) {
        const cue = nextCue();
        turn.innerHTML = "<span>NEXT TURN</span><b>" + esc(cue.distance) + "</b><small>" + esc(cue.text) + "</small>";
      } else turn.innerHTML = "<span>NEXT TURN</span><b>—</b>";
    }
    const tiltCard = document.getElementById("dashTilt");
    if (tiltCard) tiltCard.classList.toggle("warn", warn);
    const tiltRead = document.getElementById("dashTiltRead");
    if (tiltRead) tiltRead.textContent = Math.round(state.roll) + "° / " + Math.round(state.pitch) + "°";
    const gpsCard = document.getElementById("dashGps");
    if (gpsCard) gpsCard.innerHTML = "<span>MY GPS</span><b>" + esc(gpsText || "—") + "</b><small>" + (state.fix ? speed + " mph" : "") + "</small>";
    const targetCard = document.getElementById("dashTarget");
    if (targetCard) targetCard.innerHTML = "<span>TARGET</span><b>" + esc(aimText || "—") + "</b>";
  }

  function trailInView(trail, bounds) {
    if (!bounds) return true;
    const lat = Number(trail.lat);
    const lon = Number(trail.lon);
    if (Number.isFinite(lat) && Number.isFinite(lon) && bounds.contains([lat, lon])) return true;
    const coords = trail.coordinates || [];
    const step = Math.max(1, Math.ceil(coords.length / 12));
    for (let index = 0; index < coords.length; index += step) {
      if (bounds.contains(coords[index])) return true;
    }
    return false;
  }

  function drawableTrails() {
    const bounds = map && map.getBounds ? map.getBounds().pad(0.65) : null;
    const seen = new Set();
    const visible = [];
    allTrails().forEach(function (trail) {
      if (!trail || seen.has(trail.id)) return;
      if (isBdrTrail(trail) && trail.id !== state.selectedId) return;
      if (bounds && trail.id !== state.selectedId && !trailInView(trail, bounds)) return;
      seen.add(trail.id);
      visible.push(trail);
    });
    const origin = mapCenter();
    if (visible.length < 12) {
      const extras = [];
      allTrails().forEach(function (trail) {
        if (!trail || isBdrTrail(trail) || seen.has(trail.id)) return;
        extras.push(trail);
      });
      extras.sort(function (a, b) { return meters(origin, a) - meters(origin, b); });
      extras.forEach(function (trail) {
        if (visible.length >= 12) return;
        seen.add(trail.id);
        visible.push(trail);
      });
    }
    visible.sort(function (a, b) { return meters(origin, a) - meters(origin, b); });
    const chosen = visible.slice(0, 80);
    const current = selected();
    if (current && (!isBdrTrail(current) || current.id === state.selectedId) && !chosen.some(function (trail) { return trail.id === current.id; })) chosen.push(current);
    return chosen;
  }

  function syncMap() {
    if (!map) return;
    trailLayer.clearLayers();
    campLayer.clearLayers();
    const draw = drawableTrails();
    const zoom = map.getZoom();
    const view = map.getBounds().pad(0.5);
    draw.forEach(function (trail) {
      if (!trail.coordinates || trail.coordinates.length < 2) return;
      const fit = evaluate(trail);
      const selectedTrail = trail.id === state.selectedId;
      const unverified = !!trail.live && (String(trail.id).indexOf("osm-") === 0 || /openstreetmap/i.test(trail.agency || ""));
      const trailFade = Math.max(0, Math.min(100, Number(state.opacity.trails) || 0)) / 100;
      if (trailFade <= 0) return;
      const scale = 0.6 + trailFade * 0.7;
      const alpha = 0.15 + trailFade * 0.85;
      L.polyline(trail.coordinates, {
        color: "#071018",
        weight: Math.max(1.5, (selectedTrail ? 7 : 5) * scale),
        opacity: alpha,
        dashArray: unverified ? "8 8" : null,
        lineCap: "round",
        lineJoin: "round"
      }).addTo(trailLayer);
      L.polyline(trail.coordinates, {
        color: fitColor(fit.verdict),
        weight: Math.max(1.5, (selectedTrail ? 4 : 3) * scale),
        opacity: alpha,
        dashArray: unverified ? "8 8" : null,
        lineCap: "round",
        lineJoin: "round"
      }).addTo(trailLayer);
      const showPads = zoom >= 5 || state.mode === "camp" || selectedTrail;
      if (showPads) {
        spotsFor(trail).forEach(function (spot) {
          if (spot.slope >= 3 || !view.contains([spot.lat, spot.lon])) return;
          const icon = L.divIcon({
            className: "camp-pin" + (spot.slope >= 2 ? " warn" : ""),
            html: "<span>⛺ " + spot.slope.toFixed(1) + "°</span>",
            iconAnchor: [28, 12]
          });
          L.marker([spot.lat, spot.lon], { icon: icon, zIndexOffset: 400 }).on("click", function () {
            if (state.plotting) { connectPlotWaypoint(spot.lat, spot.lon); return; }
            beginRoute(spot, true, spot.kind === "pad");
          }).addTo(campLayer);
        });
      }
      const head = trailhead(trail);
      if (selectedTrail || view.contains([head.lat, head.lon])) {
        const flag = L.divIcon({ className: "flag-pin", html: "<span>⚑</span>", iconAnchor: [12, 12] });
        L.marker([head.lat, head.lon], { icon: flag, zIndexOffset: 450 }).on("click", function () {
          if (state.plotting) { connectPlotWaypoint(head.lat, head.lon); return; }
          beginRoute(head);
        }).addTo(campLayer);
      }
    });
    visibleCruxPins().forEach(function (pin) {
      const icon = L.divIcon({ className: "hazard-pin", html: "<span>" + esc(pin.short) + "</span>", iconAnchor: [14, 12] });
      L.marker([pin.lat, pin.lon], { icon: icon, zIndexOffset: 520 }).addTo(campLayer);
    });
    drawDropped();
    drawCommunity();
    drawRoute();
    updatePuck();
    drawPlot();
    drawRecorded();
    drawSavedMarkers();
    drawPlacePin();
    syncOverlays();
  }

  function drawRoute() {
    routeLayer.clearLayers();
    const route = state.route;
    if (!route) return;
    const option = route.options[route.selected] || route.options[0];
    if (!option) return;
    if (option.road.length >= 2) {
      L.polyline(option.road, { color: "#071428", weight: 5, opacity: 0.95, lineCap: "round", lineJoin: "round" }).addTo(routeLayer);
      L.polyline(option.road, { color: "#38bdf8", weight: 3.2, opacity: 1, lineCap: "round", lineJoin: "round" }).addTo(routeLayer);
    }
    if (route.spur.length >= 2) {
      L.polyline(route.spur, { color: "#071428", weight: 5, opacity: 0.8, dashArray: "2 10", lineCap: "round" }).addTo(routeLayer);
      L.polyline(route.spur, { color: "#7dd3fc", weight: 3.2, opacity: 1, dashArray: "6 8", lineCap: "round" }).addTo(routeLayer);
    }
  }

  function updatePuck() {
    if (!map || !state.fix) {
      if (puck) { map.removeLayer(puck); puck = null; }
      return;
    }
    const heading = state.fix.heading == null ? 0 : state.fix.heading;
    if (!puck) {
      const icon = L.divIcon({
        className: "puck-icon",
        iconSize: [86, 86],
        iconAnchor: [43, 43],
        html: '<div class="puck" style="--h:' + heading + 'deg"><div class="cone-rot"><div class="cone"></div></div><div class="pulse"></div><div class="dot"></div></div>'
      });
      puck = L.marker([state.fix.lat, state.fix.lon], { icon: icon, zIndexOffset: 800, interactive: false }).addTo(map);
    } else {
      puck.setLatLng([state.fix.lat, state.fix.lon]);
      const el = puck.getElement();
      if (el) {
        const node = el.querySelector(".puck");
        if (node) node.style.setProperty("--h", heading + "deg");
      }
    }
  }

  function focusTrail(trail, zoom) {
    if (!trail || !map || state.follow) return;
    map.setView([trail.lat, trail.lon], zoom || 10);
  }

  function applyFilter(scan) {
    const list = pickerTrails();
    if (state.filter === "bdr") {
      const current = list.find(function (trail) { return trail.id === state.selectedId && isBdrTrail(trail); });
      if (!current) {
        state.menuOpen = true;
        if (state.detent === "peek") {
          state.detent = "split";
          localStorage.setItem("tf-detent", "split");
        }
      }
    } else if (!list.some(function (trail) { return trail.id === state.selectedId; })) {
      const fallback = list.find(function (trail) { return !isBdrTrail(trail); });
      if (fallback) state.selectedId = fallback.id;
    }
    if (!state.follow) {
      if (state.filter === "near") {
        const anchor = nearAnchor();
        if (anchor && state.fix && map && miles(anchor, { lat: state.fix.lat, lon: state.fix.lon }) < 1) {
          map.setView([anchor.lat, anchor.lon], Math.max(map.getZoom(), 11));
        }
      } else {
        const trail = selected();
        if (state.filter === "bdr" && trail && isBdrTrail(trail) && trail.coordinates && trail.coordinates.length && map) map.fitBounds(trail.coordinates, { padding: [28, 28] });
        else if (state.filter !== "bdr") focusTrail(trail, state.filter === "all" ? 4 : 8);
      }
    }
    renderAll();
    if (!scan || SHOT) return;
    if (state.filter === "near") {
      const anchor = nearAnchor();
      if (!anchor) return;
      const closest = list.length ? nearestMiles(anchor, list[0]) : Infinity;
      if (closest > 50 || !areaScanned(anchor)) scanAt(anchor);
    } else if (state.filter !== "all" && state.filter !== "bdr") {
      const trail = selected();
      if (trail) scanAt({ lat: trail.lat, lon: trail.lon });
    }
  }

  function stateCode(lat, lon, tagged) {
    if (tagged) {
      const trimmed = String(tagged).trim();
      const upper = trimmed.toUpperCase();
      if (ATLAS.states.some(function (box) { return box.code === upper; })) return upper;
      if (NAME_TO_CODE[trimmed.toLowerCase()]) return NAME_TO_CODE[trimmed.toLowerCase()];
    }
    let best = null;
    let bestArea = Infinity;
    ATLAS.states.forEach(function (box) {
      if (lat < box.minLat || lat > box.maxLat || lon < box.minLon || lon > box.maxLon) return;
      const area = (box.maxLat - box.minLat) * (box.maxLon - box.minLon);
      if (area < bestArea) { bestArea = area; best = box.code; }
    });
    return best || "US";
  }

  function clearanceEstimate(tracktype, surface, fourWheelOnly) {
    if (tracktype === "grade5") return { clearance: 12, canopy: 9, water: 18, locker: true };
    if (tracktype === "grade4") return { clearance: 10.5, canopy: 10, water: 14, locker: fourWheelOnly };
    if (tracktype === "grade3") return { clearance: 9.2, canopy: 11.5, water: 10, locker: false };
    if (tracktype === "grade2") return { clearance: 8, canopy: 12.5, water: 6, locker: false };
    if (fourWheelOnly) return { clearance: 10.2, canopy: 11, water: 12, locker: true };
    if (surface && surface.indexOf("rock") >= 0) return { clearance: 10.4, canopy: 13, water: 8, locker: false };
    if (surface && surface.indexOf("sand") >= 0) return { clearance: 9, canopy: 14, water: 0, locker: false };
    return { clearance: 8.6, canopy: 12.5, water: 6, locker: false };
  }

  function parseOverpass(text) {
    const root = JSON.parse(text);
    return (root.elements || []).map(parseElement).filter(Boolean);
  }

  function parseElement(element) {
    if (!element) return null;
    if (element.type === "node") return parseCampNode(element);
    return parseWay(element);
  }

  function parseCampNode(element) {
    const tags = element.tags || {};
    const lat = Number(element.lat);
    const lon = Number(element.lon);
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) return null;
    const id = "osm-camp-" + element.id;
    const name = tags.name || tags.ref || "Camp";
    const seed = seedFor(id);
    const slope = Math.min(2.4, 1.1 + (Math.abs(seed) % 10) * 0.1);
    return {
      id: id,
      name: name,
      region: "Camp",
      agency: tags.operator || "OpenStreetMap",
      state: stateCode(lat, lon, tags["addr:state"] || tags["is_in:state"]),
      miles: 0.1,
      elev: 0,
      clearance: 8.6,
      canopy: 12.5,
      water: 0,
      locker: false,
      gate: "CHECK",
      snow: 0,
      flow: 0,
      lat: lat,
      lon: lon,
      coordinates: [[lat, lon]],
      flatCamps: [{ name: name, lat: lat, lon: lon, slope: Math.round(slope * 10) / 10, starlink: 82 + (Math.abs(seed) % 17) }],
      signature: false,
      live: true
    };
  }

  function parseWay(element) {
    if (!element || element.type !== "way" || !element.geometry || element.geometry.length < 2) return null;
    const tags = element.tags || {};
    const coordinates = element.geometry.map(function (point) { return [point.lat, point.lon]; });
    const mid = coordinates[Math.floor(coordinates.length / 2)];
    const fit = clearanceEstimate(tags.tracktype, (tags.surface || "").toLowerCase(), tags["4wd_only"] === "yes");
    const seed = seedFor("osm-" + element.id);
    const name = tags.name || tags.ref || tags.official_name || ("OSM " + element.id);
    return liveTrail("osm-" + element.id, name, "OpenStreetMap", tags.operator || "OpenStreetMap", coordinates, mid, fit, seed, tags["addr:state"] || tags["is_in:state"]);
  }

  function parseUsfs(text) {
    const root = JSON.parse(text);
    return (root.features || []).map(function (feature, index) {
      const attributes = feature.attributes || {};
      const paths = feature.geometry && feature.geometry.paths;
      if (!paths || !paths[0] || paths[0].length < 2) return null;
      let coordinates = paths[0].map(function (pair) { return [pair[1], pair[0]]; });
      if (coordinates.length > 60) {
        const stride = (coordinates.length - 1) / 59;
        coordinates = Array.from({ length: 60 }, function (_, index) {
          return coordinates[Math.min(coordinates.length - 1, Math.round(index * stride))];
        });
      }
      const mid = coordinates[Math.floor(coordinates.length / 2)];
      const rawName = String(attributes.NAME || attributes.ROAD_NAME || attributes.ROAD_SYMBOL || attributes.ID || ("USFS Road " + (index + 1)));
      const name = /^(FS|FR)/.test(rawName) ? rawName : "FS " + rawName;
      const surface = String(attributes.SURFACE_TYPE || attributes.SURFACE || "").toLowerCase();
      const fit = clearanceEstimate(null, surface, false);
      const id = "usfs-" + (attributes.ID || attributes.OBJECTID || attributes.GLOBALID || index);
      return liveTrail(id, name, "USFS road", "USFS", coordinates, mid, fit, seedFor(id), attributes.STATE || attributes.STATE_CODE || attributes.ADMIN_STATE);
    }).filter(Boolean);
  }

  function livePads(name, coordinates, seed) {
    if (!coordinates || coordinates.length < 2) return [];
    const slopeA = Math.min(2.7, 1.2 + (Math.abs(seed) % 12) * 0.12);
    const indexes = coordinates.length >= 4
      ? [Math.floor(coordinates.length / 3), Math.floor(coordinates.length * 2 / 3)]
      : [Math.min(coordinates.length - 1, Math.max(1, Math.floor(coordinates.length / 3)))];
    const pads = [];
    indexes.forEach(function (index, padIndex) {
      const point = coordinates[index];
      const slope = padIndex === 0 ? slopeA : Math.min(2.8, slopeA + 0.4);
      if (slope >= 3) return;
      const label = coordinates.length >= 4 ? (name + (padIndex === 0 ? " Pad A" : " Pad B")) : (name + " Flat Pad");
      pads.push({
        name: label,
        lat: point[0],
        lon: point[1],
        slope: Math.round(slope * 10) / 10,
        starlink: 82 + (Math.abs(seed + padIndex * 3) % 17)
      });
    });
    return pads;
  }

  function liveTrail(id, name, region, agency, coordinates, mid, fit, seed, tagged) {
    return {
      id: id,
      name: name,
      region: region,
      agency: agency,
      state: stateCode(mid[0], mid[1], tagged),
      miles: Math.max(0.4, Math.round(polylineMeters(coordinates) / 1609.344 * 10) / 10),
      elev: 0,
      clearance: fit.clearance,
      canopy: fit.canopy,
      water: fit.water,
      locker: fit.locker,
      gate: "CHECK",
      snow: 0,
      flow: 0,
      lat: mid[0],
      lon: mid[1],
      coordinates: coordinates,
      flatCamps: livePads(name, coordinates, seed),
      signature: false,
      live: true
    };
  }

  async function fetchOverpass(center) {
    const south = center.lat - 0.09;
    const north = center.lat + 0.09;
    const west = center.lon - 0.11;
    const east = center.lon + 0.11;
    const box = south + "," + west + "," + north + "," + east;
    const query = "[out:json][timeout:10];(" +
      'way["highway"~"track|path"]["tracktype"~"grade2|grade3|grade4|grade5"](' + box + ");" +
      'way["highway"="track"]["4wd_only"="yes"](' + box + ");" +
      'way["highway"="unclassified"]["surface"~"unpaved|gravel|dirt|sand|rock"](' + box + ");" +
      'node["tourism"~"camp_site|camp_pitch"](' + box + ");" +
      ");out geom 60;";
    const urls = [
      "https://overpass-api.de/api/interpreter",
      "https://overpass.kumi.systems/api/interpreter"
    ];
    for (let index = 0; index < urls.length; index += 1) {
      try {
        const text = await net(urls[index], { method: "POST", body: query });
        return parseOverpass(text);
      } catch (error) { /* try the next Overpass mirror */ }
    }
    return [];
  }

  async function fetchUsfs(center) {
    const params = new URLSearchParams({
      where: "1=1",
      geometry: center.lon + "," + center.lat,
      geometryType: "esriGeometryPoint",
      inSR: "4326",
      spatialRel: "esriSpatialRelIntersects",
      distance: "18000",
      units: "esriSRUnit_Meter",
      outFields: "NAME,ROAD_NAME,ROAD_SYMBOL,ID,OBJECTID,SURFACE_TYPE,SURFACE,STATE,STATE_CODE,ADMIN_STATE",
      returnGeometry: "true",
      outSR: "4326",
      resultRecordCount: "40",
      f: "json"
    });
    const text = await net("https://apps.fs.usda.gov/arcx/rest/services/EDW/EDW_RoadBasic_01/MapServer/0/query?" + params.toString());
    return parseUsfs(text);
  }

  function areaScanned(center) {
    return state.scanAnchors.some(function (anchor) { return meters(anchor, center) < 1500; });
  }

  function scheduleTrailScan() {
    if (!map || SHOT) return;
    clearTimeout(state.trailScanTimer);
    state.trailScanTimer = setTimeout(function () {
      const center = mapCenter();
      if (areaScanned(center)) return;
      scanAt(center);
    }, 180);
  }

  function absorbDiscovered(center, incoming, gen) {
    if (gen !== state.scanGen || !incoming || !incoming.length) return;
    const byId = {};
    state.discovered.forEach(function (trail) { byId[trail.id] = trail; });
    incoming.forEach(function (trail) {
      if (trail && trail.id) byId[trail.id] = trail;
    });
    let merged = Object.keys(byId).map(function (id) { return byId[id]; });
    if (merged.length > 200) {
      merged.sort(function (a, b) { return meters(center, a) - meters(center, b); });
      merged = merged.slice(0, 200);
    }
    state.discovered = merged;
    saveDiscovered();
    state.scanStatus = merged.length + " local USA trails";
    renderAll();
  }

  function scanAt(center) {
    if (!center || SHOT || areaScanned(center)) return;
    if (state.scanning && state.lastScanAnchor && meters(state.lastScanAnchor, center) < 1500) return;
    const gen = ++state.scanGen;
    state.scanning = true;
    state.lastScanAnchor = { lat: center.lat, lon: center.lon };
    state.scanStatus = "Scanning USA 4x4 trails…";
    renderTop();
    const status = document.getElementById("scanStatus");
    if (status) status.textContent = state.scanStatus;
    let pending = 2;
    function finish() {
      pending -= 1;
      if (gen !== state.scanGen || pending > 0) return;
      state.scanning = false;
      state.scanAnchors.push({ lat: center.lat, lon: center.lon });
      if (state.scanAnchors.length > 40) state.scanAnchors = state.scanAnchors.slice(-40);
      state.scanStatus = state.discovered.length ? (state.discovered.length + " local USA trails") : "No public 4x4 tracks returned for this area.";
      renderTop();
    }
    fetchOverpass(center).then(function (trails) {
      absorbDiscovered(center, trails, gen);
    }).catch(function () {}).finally(finish);
    fetchUsfs(center).then(function (trails) {
      absorbDiscovered(center, trails, gen);
    }).catch(function () {}).finally(finish);
  }

  function thinLine(coordinates, limit) {
    if (!coordinates || coordinates.length <= limit) return coordinates || [];
    const step = (coordinates.length - 1) / (limit - 1);
    const line = [];
    for (let index = 0; index < limit; index += 1) {
      line.push(coordinates[Math.min(coordinates.length - 1, Math.round(index * step))]);
    }
    return line;
  }

  function loadDiscovered() {
    try {
      const parsed = JSON.parse(localStorage.getItem("tf-discovered-trails") || "[]");
      return Array.isArray(parsed) ? parsed.slice(0, 200) : [];
    } catch (error) {
      return [];
    }
  }

  function saveDiscovered() {
    try {
      const slim = state.discovered.slice(0, 200).map(function (trail) {
        return {
          id: trail.id,
          name: trail.name,
          region: trail.region,
          agency: trail.agency,
          state: trail.state,
          miles: trail.miles,
          elev: trail.elev || 0,
          clearance: trail.clearance,
          canopy: trail.canopy,
          water: trail.water,
          locker: !!trail.locker,
          gate: trail.gate || "CHECK",
          snow: trail.snow || 0,
          flow: trail.flow || 0,
          lat: trail.lat,
          lon: trail.lon,
          coordinates: thinLine(trail.coordinates, 60),
          flatCamps: trail.flatCamps || [],
          signature: false,
          live: true
        };
      });
      localStorage.setItem("tf-discovered-trails", JSON.stringify(slim));
    } catch (error) { /* storage full */ }
  }

  function displaySteps(route) {
    const option = route.options[route.selected] || route.options[0];
    const steps = option.steps.slice();
    const spurMeters = polylineMeters(route.spur);
    if (spurMeters > 40) {
      const end = route.spur[route.spur.length - 1];
      steps.push({
        id: 10000,
        instruction: "Proceed on overland spur to " + route.destination.name,
        distanceMeters: spurMeters,
        name: "Overland spur",
        type: "spur",
        modifier: "",
        lat: end[0],
        lon: end[1]
      });
    }
    return steps;
  }

  function roadAndSpur(route) {
    const option = route.options[route.selected] || route.options[0];
    if (route.spur.length < 2) return option.road;
    return option.road.concat(route.spur.slice(1));
  }

  function distanceToSegment(point, start, end) {
    const origin = ll(point);
    const a = ll(start);
    const b = ll(end);
    const lonScale = 111320 * Math.cos(origin.lat * Math.PI / 180);
    const latScale = 111320;
    const bx = (b.lon - a.lon) * lonScale;
    const by = (b.lat - a.lat) * latScale;
    const px = (origin.lon - a.lon) * lonScale;
    const py = (origin.lat - a.lat) * latScale;
    const length2 = bx * bx + by * by;
    const fraction = length2 < 1 ? 0 : Math.min(1, Math.max(0, (px * bx + py * by) / length2));
    const dx = px - bx * fraction;
    const dy = py - by * fraction;
    return { distance: Math.sqrt(dx * dx + dy * dy), fraction: fraction };
  }

  function traveledMeters(user, coords) {
    if (coords.length < 2) return 0;
    let best = Infinity;
    let traveled = 0;
    let running = 0;
    for (let index = 1; index < coords.length; index += 1) {
      const segment = meters(coords[index - 1], coords[index]);
      const hit = distanceToSegment(user, coords[index - 1], coords[index]);
      if (hit.distance < best) {
        best = hit.distance;
        traveled = running + segment * hit.fraction;
      }
      running += segment;
    }
    return traveled;
  }

  function nextCue() {
    const route = state.route;
    const steps = displaySteps(route);
    const fallback = steps[0] || { instruction: "Head toward " + route.destination.name, name: route.destination.name, type: "continue" };
    if (!state.fix) return { distance: "—", street: fallback.name || route.destination.name, text: "Head toward " + route.destination.name, step: fallback };
    const traveled = traveledMeters(state.fix, roadAndSpur(route));
    let cursor = 0;
    for (const step of steps) {
      cursor += step.distanceMeters;
      if (cursor > traveled + 20) {
        return {
          distance: formatDistance(Math.max(0, cursor - traveled)),
          street: step.name || route.destination.name,
          text: step.instruction,
          step: step
        };
      }
    }
    return { distance: "0 ft", street: route.destination.name, text: "Arriving at " + route.destination.name, step: { type: "arrive", modifier: "" } };
  }

  function remainingMeters(route) {
    const total = polylineMeters(roadAndSpur(route));
    if (!state.fix) return total;
    return Math.max(0, total - traveledMeters(state.fix, roadAndSpur(route)));
  }

  function remainingSeconds(route, remaining) {
    const option = route.options[route.selected] || route.options[0];
    const total = Math.max(option.distanceMeters + polylineMeters(route.spur), 1);
    return option.expectedTravelTime * (remaining / total);
  }

  function updateRouteProgress() {
    if (!state.route) return;
    const cue = nextCue();
    const dist = document.getElementById("navDist");
    const street = document.getElementById("navStreet");
    const sub = document.getElementById("navSub");
    const icon = document.getElementById("navIcon");
    if (dist && !state.routing) dist.textContent = cue.distance;
    if (street) street.textContent = cue.street;
    if (sub) sub.textContent = cue.text;
    if (icon) icon.innerHTML = maneuverSvg(cue.step);
    const remaining = remainingMeters(state.route);
    const seconds = remainingSeconds(state.route, remaining);
    const eta = document.getElementById("rbEta");
    const milesLeft = document.getElementById("rbMiles");
    if (eta) eta.textContent = formatDuration(seconds);
    if (milesLeft) milesLeft.textContent = formatDistance(remaining);
    const etaLabel = eta && eta.nextElementSibling;
    if (etaLabel) etaLabel.textContent = "ETA " + formatClock(new Date(Date.now() + seconds * 1000));
  }

  function maybeSpeakCues() {
    const route = state.route;
    if (!route || !route.confirmed || !state.fix || route.arrived) return;
    const option = route.options[route.selected] || route.options[0];
    if (route.stepIndex == null) route.stepIndex = 0;
    while (route.stepIndex < option.steps.length) {
      const step = option.steps[route.stepIndex];
      const distance = meters(state.fix, { lat: step.lat, lon: step.lon }) / 1609.344;
      if (!step.approach && distance <= 0.2 && distance > 0.04 && step.type !== "depart") {
        step.approach = true;
        speak("In a fifth of a mile, " + step.instruction);
      }
      if (distance <= 0.04) {
        if (!step.at && step.type !== "depart") speak(step.instruction);
        step.at = true;
        route.stepIndex += 1;
        continue;
      }
      break;
    }
    if (route.spur.length >= 2) {
      const spurStart = { lat: route.spur[0][0], lon: route.spur[0][1] };
      const spurDistance = meters(state.fix, spurStart) / 1609.344;
      if (!route.spurApproach && spurDistance <= 0.2 && spurDistance > 0.04) {
        route.spurApproach = true;
        speak("In a fifth of a mile, proceed on the overland spur to " + route.destination.name);
      }
      if (!route.spurAt && spurDistance <= 0.04) {
        route.spurAt = true;
        speak("Proceed on the overland spur to " + route.destination.name);
      }
    }
    const padDistance = meters(state.fix, route.destination) / 1609.344;
    if (padDistance <= 0.05) {
      route.arrived = true;
      if (route.destination.kind === "pad") {
        speak("You have arrived at " + route.destination.name + ". Slope " + route.destination.slope.toFixed(1) + " degrees. Starlink " + route.destination.starlink + " percent.");
      } else if (route.destination.kind === "parcel") {
        speak("You have arrived at " + route.destination.name + ". " + Number(route.destination.acres || 0).toFixed(1) + " acre lot.");
      } else {
        speak("You have arrived at " + route.destination.name + ".");
      }
      updateRouteProgress();
    }
  }

  function allowsTrailStitch(spot) {
    if (!spot) return false;
    const kind = spot.kind || "";
    const id = String(spot.id || "");
    if (kind === "place" || kind === "parcel") return false;
    if (id.indexOf("pin-") === 0 || id.indexOf("place-") === 0 || id.indexOf("parcel-") === 0) return false;
    return kind === "pad" || kind === "trailhead";
  }

  function spurLimit(spot) {
    return allowsTrailStitch(spot) ? 3218 : 250;
  }

  function routeOrigin(spot) {
    const view = mapCenter();
    const gps = state.fix && !state.fix.shotOnly ? state.fix : null;
    if (gps && (meters(gps, view) <= 500000 || meters(gps, spot) <= 500000)) {
      return { lat: gps.lat, lon: gps.lon, gps: true };
    }
    return { lat: view.lat, lon: view.lon, gps: false };
  }

  function roadLooksDrivable(road, origin) {
    if (!road || road.length < 2) return false;
    if (meters(road[0], origin) > 5000) return false;
    const direct = meters(road[0], road[road.length - 1]);
    if (direct < 800) return true;
    if (road.length <= 3 && direct > 1500) return false;
    const path = polylineMeters(road);
    if (path < direct * 1.08 && direct > 3000 && road.length < 12) return false;
    return true;
  }

  function overlandSpur(road, spot) {
    if (!road || !road.length) return [];
    const last = road[road.length - 1];
    const gap = meters(last, spot);
    const limit = spurLimit(spot);
    if (gap < 30 || gap > limit) return [];
    return [last, [spot.lat, spot.lon]];
  }

  function stitchPadTrail(option, trail, spot) {
    if (!allowsTrailStitch(spot) || !trail || !trail.coordinates || trail.coordinates.length < 2) return option;
    const road = option.road.slice();
    if (road.length < 2) return option;
    const end = { lat: road[road.length - 1][0], lon: road[road.length - 1][1] };
    if (meters(end, spot) <= 80) return option;
    const coords = trail.coordinates;
    let startIndex = 0;
    let endIndex = 0;
    let bestStart = Infinity;
    let bestEnd = Infinity;
    coords.forEach(function (point, index) {
      const fromEnd = meters(end, point);
      const fromSpot = meters(spot, point);
      if (fromEnd < bestStart) { bestStart = fromEnd; startIndex = index; }
      if (fromSpot < bestEnd) { bestEnd = fromSpot; endIndex = index; }
    });
    if (bestStart > 3218) return option;
    const slice = startIndex <= endIndex ? coords.slice(startIndex, endIndex + 1) : coords.slice(endIndex, startIndex + 1).slice().reverse();
    if (slice.length < 2) return option;
    const gap = meters(end, slice[0]);
    if (gap > 3218) return option;
    const joined = gap < 40 ? road.concat(slice.slice(1)) : road.concat(slice);
    const next = Object.assign({}, option);
    next.road = joined;
    next.distanceMeters = polylineMeters(joined);
    return next;
  }

  function drivingRouteBases() {
    return [
      "https://router.project-osrm.org/route/v1/driving/",
      "https://routing.openstreetmap.de/routed-car/route/v1/driving/"
    ];
  }

  async function fetchOsrmOptions(origin, spot) {
    const path = origin.lon + "," + origin.lat + ";" + spot.lon + "," + spot.lat + "?overview=full&geometries=geojson&steps=true&alternatives=true";
    const bases = drivingRouteBases();
    for (let index = 0; index < bases.length; index += 1) {
      try {
        const text = await net(bases[index] + path);
        const options = parseOsrm(JSON.parse(text), spot).filter(function (option) {
          return roadLooksDrivable(option.road, origin);
        });
        if (options.length) return options;
      } catch (error) { /* try the next router */ }
    }
    return [];
  }

  function parseOsrm(data, spot) {
    return (data.routes || []).map(function (route, index) {
      const road = (route.geometry.coordinates || []).map(function (pair) { return [pair[1], pair[0]]; });
      const steps = [];
      (route.legs || []).forEach(function (leg) {
        (leg.steps || []).forEach(function (step) {
          const location = step.maneuver && step.maneuver.location;
          if (!location) return;
          steps.push({
            id: steps.length,
            instruction: instructionFor(step),
            distanceMeters: step.distance || 0,
            name: step.name || step.ref || "",
            type: step.maneuver.type || "continue",
            modifier: step.maneuver.modifier || "",
            lat: location[1],
            lon: location[0],
            approach: false,
            at: false
          });
        });
      });
      if (!steps.length && road.length) {
        steps.push({ id: 0, instruction: "Continue to " + spot.name, distanceMeters: route.distance || polylineMeters(road), name: "Trail", type: "continue", modifier: "straight", lat: road[0][0], lon: road[0][1], approach: false, at: false });
      }
      return {
        id: index,
        title: "Route " + (index + 1),
        expectedTravelTime: route.duration || 0,
        distanceMeters: route.distance || polylineMeters(road),
        road: road,
        steps: steps
      };
    }).filter(function (option) { return option.road.length >= 2; });
  }

  async function beginRoute(spot, refit, previewOnly) {
    if (!spot) return;
    const generation = ++state.routeGen;
    const preview = !!previewOnly;
    const trail = trailById(spot.trailID);
    const originWasGPS = !!(state.fix && !state.fix.shotOnly);
    const origin = routeOrigin(spot);
    const prior = state.route;
    const wasFollowing = !!(prior && state.follow && refit === false && !preview);
    const sameDestination = !!(prior && prior.destination && prior.destination.id === spot.id);
    state.routing = true;
    state.aim = spot;
    state.selectedId = spot.trailID || state.selectedId;
    if (!sameDestination) {
      state.route = null;
      if (routeLayer) routeLayer.clearLayers();
    }
    updateHud();
    renderTop();
    let options = await fetchOsrmOptions(origin, spot);
    if (generation !== state.routeGen) return;
    if (options.length && allowsTrailStitch(spot)) {
      options = options.map(function (option) { return stitchPadTrail(option, trail, spot); });
    }
    if (!options.length) {
      options = [{
        id: 0,
        title: "No road route",
        expectedTravelTime: 0,
        distanceMeters: 0,
        road: [],
        steps: [{ id: 0, instruction: "No drivable road route yet. Check the signal and try again.", distanceMeters: 0, name: spot.name, type: "continue", modifier: "", lat: spot.lat, lon: spot.lon, approach: false, at: false }]
      }];
    }
    const road = options[0].road;
    const keepAnnounced = sameDestination && prior && prior.announced && !preview;
    state.route = {
      destination: spot,
      options: options,
      selected: 0,
      spur: overlandSpur(road, spot),
      originWasGPS: originWasGPS,
      stepIndex: 0,
      arrived: false,
      spurApproach: false,
      spurAt: false,
      announced: !!keepAnnounced,
      confirmed: !preview
    };
    state.routing = false;
    state.showSteps = false;
    state.follow = wasFollowing;
    if (preview) {
      state.detent = "peek";
      localStorage.setItem("tf-detent", "peek");
    }
    renderAll();
    if (refit !== false && road.length >= 2) {
      requestAnimationFrame(function () {
        map.invalidateSize();
        frameRoute();
      });
    } else if (refit !== false && map) {
      map.setView([spot.lat, spot.lon], Math.max(map.getZoom(), 12));
    }
    const first = options[0].steps.find(function (step) { return step.type !== "depart"; }) || options[0].steps[0];
    const milesText = (options[0].distanceMeters / 1609.344).toFixed(1);
    if (!preview && road.length >= 2 && !state.route.announced) {
      state.route.announced = true;
      speak("Starting GPS route to " + spot.name + ". " + (first ? first.instruction : "Follow the route.") + " " + milesText + " miles.");
    } else if (!preview && road.length < 2) {
      toast("No drivable road route yet. Check the signal and try again.");
    }
    if (!preview && road.length >= 2) maybeSpeakCues();
    const app = document.getElementById("app");
    app.dataset.route = "1";
    if (SHOT) app.dataset.shotReady = "1";
  }

  function frameRoute() {
    const route = state.route;
    if (!route || !map) return;
    const option = route.options[route.selected] || route.options[0];
    const coords = option && option.road ? option.road.slice() : [];
    if (route.spur && route.spur.length >= 2) coords.push.apply(coords, route.spur);
    if (route.originWasGPS && state.fix) coords.push([state.fix.lat, state.fix.lon]);
    if (coords.length < 2) {
      map.setView([route.destination.lat, route.destination.lon], Math.max(map.getZoom(), 12));
      return;
    }
    map.fitBounds(coords, { padding: [28, 28] });
  }

  function endRoute() {
    state.routeGen += 1;
    state.route = null;
    state.aim = null;
    state.follow = false;
    state.routing = false;
    state.showSteps = false;
    document.getElementById("app").dataset.route = "0";
    renderAll();
  }

  function handleLiveReroute() {
    const route = state.route;
    if (!route || !state.fix) return;
    if (!route.originWasGPS) {
      route.originWasGPS = true;
      beginRoute(route.destination, !state.follow, !route.confirmed);
      return;
    }
    if (!route.confirmed) return;
    if (!state.follow || Date.now() - state.lastReroute < 25000) return;
    const line = roadAndSpur(route);
    let best = Infinity;
    for (let index = 1; index < line.length; index += 1) {
      best = Math.min(best, distanceToSegment(state.fix, line[index - 1], line[index]).distance);
    }
    if (best > 450) {
      state.lastReroute = Date.now();
      speak("Recalculating route.");
      beginRoute(route.destination, false, false);
    }
  }

  function showSafetyModal(force) {
    const modal = document.getElementById("safetyModal");
    if (!modal) return;
    const accepted = localStorage.getItem("tf_disclaimer_accepted_v1");
    modal.classList.remove("closing");
    if (force || !accepted) {
      document.documentElement.classList.remove("safety-ok");
      modal.hidden = false;
    } else {
      document.documentElement.classList.add("safety-ok");
      modal.hidden = true;
    }
  }

  function acceptSafety() {
    localStorage.setItem("tf_disclaimer_accepted_v1", new Date().toISOString());
    const modal = document.getElementById("safetyModal");
    if (!modal) return;
    modal.classList.add("closing");
    setTimeout(function () {
      document.documentElement.classList.add("safety-ok");
      modal.hidden = true;
      modal.classList.remove("closing");
    }, 180);
  }

  function openExternal(url) {
    if (window.TrailForgeHost && TrailForgeHost.openUrl) {
      TrailForgeHost.openUrl(url);
      return;
    }
    window.open(url, "_blank", "noopener");
  }

  function normalizeFix(raw) {
    const data = typeof raw === "string" ? JSON.parse(raw) : raw;
    return {
      lat: Number(data.lat),
      lon: Number(data.lon),
      accuracy: data.accuracy == null ? null : Number(data.accuracy),
      altitudeM: data.altitude == null ? null : Number(data.altitude),
      speedMps: data.speed == null ? null : Number(data.speed),
      heading: data.heading == null ? null : Number(data.heading),
      time: data.time || Date.now(),
      shot: !!data.shot
    };
  }

  function onFix(raw) {
    const fix = normalizeFix(raw);
    if (!Number.isFinite(fix.lat) || !Number.isFinite(fix.lon)) return;
    if (SHOT && state.fix && state.fix.shot && !fix.shot) return;
    const previous = state.fix;
    if (!(fix.speedMps > 1.2) || fix.heading == null) {
      if (state.compass != null && !(fix.speedMps > 1.2)) fix.heading = state.compass;
      else if (previous && meters(previous, fix) > 8) fix.heading = bearing(previous, fix);
      else if (previous && previous.heading != null) fix.heading = previous.heading;
    }
    if (!(fix.speedMps >= 0)) {
      if (previous && Number.isFinite(Number(fix.time)) && Number.isFinite(Number(previous.time))) {
        const dt = (Number(fix.time) - Number(previous.time)) / 1000;
        if (dt > 0.2 && dt < 60) fix.speedMps = meters(previous, fix) / dt;
        else fix.speedMps = 0;
      } else fix.speedMps = 0;
    }
    if (fix.speedMps < 0) fix.speedMps = 0;
    state.fix = fix;
    appendRecording(fix);
    updatePuck();
    updateHud();
    if (!state.centeredOnce && !state.route && !SHOT) {
      state.centeredOnce = true;
      state.userPanned = false;
      if (state.filter === "near") applyFilter(true);
      else if (map) map.setView([fix.lat, fix.lon], Math.max(map.getZoom(), 12));
    }
    if (state.follow) map.panTo([fix.lat, fix.lon]);
    maybeSpeakCues();
    speakHazards();
    updateRouteProgress();
    handleLiveReroute();
    renderTop();
  }

  function bearing(a, b) {
    const start = ll(a);
    const end = ll(b);
    const y = Math.sin((end.lon - start.lon) * Math.PI / 180) * Math.cos(end.lat * Math.PI / 180);
    const x = Math.cos(start.lat * Math.PI / 180) * Math.sin(end.lat * Math.PI / 180) - Math.sin(start.lat * Math.PI / 180) * Math.cos(end.lat * Math.PI / 180) * Math.cos((end.lon - start.lon) * Math.PI / 180);
    return (Math.atan2(y, x) * 180 / Math.PI + 360) % 360;
  }

  function onAttitude(raw) {
    const data = typeof raw === "string" ? JSON.parse(raw) : raw;
    if (SHOT && state.attitudeLocked) return;
    if (state.thermal && Date.now() - state.lastAtt < 500) return;
    state.lastAtt = Date.now();
    if (!data.web) state.nativeAttAt = Date.now();
    let pitch = Number(data.pitch) || 0;
    let roll = Number(data.roll) || 0;
    if (Number.isFinite(Number(data.sx)) && Number.isFinite(Number(data.sy)) && Number.isFinite(Number(data.sz))) {
      state.gx = Number(data.sx);
      state.gy = Number(data.sy);
      state.gz = Number(data.sz);
      const angles = gravityAngles(state.gx, state.gy, state.gz);
      roll = angles.roll;
      pitch = angles.pitch;
    } else {
      state.rawRoll = roll;
      state.rawPitch = pitch;
      const leveled = levelAttitude(roll, pitch);
      roll = leveled.roll;
      pitch = leveled.pitch;
    }
    state.pitch += (pitch - state.pitch) * 0.22;
    state.roll += (roll - state.roll) * 0.22;
    if (data.heading != null && Number.isFinite(Number(data.heading))) state.compass = Number(data.heading);
    syncNavArrow();
    updateHud();
    if (state.fix && !(state.fix.speedMps > 1.2) && state.compass != null) {
      state.fix.heading = state.compass;
      updatePuck();
    }
  }

  function unitGravity(x, y, z) {
    const mag = Math.sqrt(x * x + y * y + z * z) || 1;
    return { x: x / mag, y: y / mag, z: z / mag };
  }

  function levelAttitude(rawRoll, rawPitch) {
    const zero = state.clinZero;
    if (zero && Number.isFinite(zero.sx)) return { roll: rawRoll, pitch: rawPitch };
    if (zero && Number.isFinite(zero.roll)) {
      return { roll: rawRoll - zero.roll, pitch: rawPitch - zero.pitch };
    }
    if (state.autoPitch == null) state.autoPitch = rawPitch;
    return { roll: rawRoll, pitch: rawPitch - state.autoPitch };
  }

  function gravityAngles(sx, sy, sz) {
    const gravity = unitGravity(sx, sy, sz);
    const rawRoll = Math.atan2(gravity.x, Math.sqrt(gravity.y * gravity.y + gravity.z * gravity.z)) * 180 / Math.PI;
    const rawPitch = Math.atan2(-gravity.z, -gravity.y) * 180 / Math.PI;
    state.rawRoll = rawRoll;
    state.rawPitch = rawPitch;
    const zero = state.clinZero;
    if (zero && Number.isFinite(zero.sx) && Number.isFinite(zero.sy) && Number.isFinite(zero.sz)) {
      return relativeGravity(gravity, unitGravity(zero.sx, zero.sy, zero.sz));
    }
    return levelAttitude(rawRoll, rawPitch);
  }

  function relativeGravity(gravity, down) {
    let right = { x: 1 - down.x * down.x, y: 0 - down.x * down.y, z: 0 - down.x * down.z };
    let rightLen = Math.sqrt(right.x * right.x + right.y * right.y + right.z * right.z);
    if (rightLen < 0.25) {
      const up = { x: 0 - down.y * down.x, y: 1 - down.y * down.y, z: 0 - down.y * down.z };
      const upLen = Math.sqrt(up.x * up.x + up.y * up.y + up.z * up.z);
      right = upLen < 0.05 ? { x: 1, y: 0, z: 0 } : { x: up.x / upLen, y: up.y / upLen, z: up.z / upLen };
    } else {
      right = { x: right.x / rightLen, y: right.y / rightLen, z: right.z / rightLen };
    }
    let forward = {
      x: right.y * down.z - right.z * down.y,
      y: right.z * down.x - right.x * down.z,
      z: right.x * down.y - right.y * down.x
    };
    if (forward.y < 0) forward = { x: -forward.x, y: -forward.y, z: -forward.z };
    const alongDown = gravity.x * down.x + gravity.y * down.y + gravity.z * down.z;
    const alongRight = gravity.x * right.x + gravity.y * right.y + gravity.z * right.z;
    const alongForward = gravity.x * forward.x + gravity.y * forward.y + gravity.z * forward.z;
    return {
      roll: Math.atan2(alongRight, alongDown) * 180 / Math.PI,
      pitch: Math.atan2(-alongForward, alongDown) * 180 / Math.PI
    };
  }

  function loadClinZero() {
    try {
      const parsed = JSON.parse(localStorage.getItem("tf-clinometer-zero") || "null");
      if (!parsed || typeof parsed !== "object") return null;
      if (Number.isFinite(Number(parsed.sx)) && Number.isFinite(Number(parsed.sy)) && Number.isFinite(Number(parsed.sz))) {
        return { sx: Number(parsed.sx), sy: Number(parsed.sy), sz: Number(parsed.sz) };
      }
      if (Number.isFinite(Number(parsed.roll)) && Number.isFinite(Number(parsed.pitch))) {
        return { roll: Number(parsed.roll), pitch: Number(parsed.pitch) };
      }
    } catch (error) { /* Keep the live attitude until the driver taps Zero. */ }
    return null;
  }

  function requestMotionPermission() {
    const jobs = [];
    const Orientation = window.DeviceOrientationEvent;
    const Motion = window.DeviceMotionEvent;
    if (Orientation && typeof Orientation.requestPermission === "function") {
      jobs.push(Orientation.requestPermission().catch(function () { return "denied"; }));
    }
    if (Motion && typeof Motion.requestPermission === "function") {
      jobs.push(Motion.requestPermission().catch(function () { return "denied"; }));
    }
    return Promise.all(jobs);
  }

  function zeroClinometer() {
    requestMotionPermission().then(function () {
      if (Number.isFinite(state.gx) && Number.isFinite(state.gy) && Number.isFinite(state.gz)) {
        state.clinZero = { sx: state.gx, sy: state.gy, sz: state.gz };
      } else {
        state.clinZero = { roll: state.rawRoll || 0, pitch: state.rawPitch || 0 };
      }
      state.autoPitch = null;
      try { localStorage.setItem("tf-clinometer-zero", JSON.stringify(state.clinZero)); } catch (error) {}
      state.roll = 0;
      state.pitch = 0;
      updateHud();
      toast("Clinometer zeroed");
    });
  }

  function resetClinometer() {
    state.clinZero = null;
    state.autoPitch = null;
    try { localStorage.removeItem("tf-clinometer-zero"); } catch (error) {}
    updateHud();
    toast("Clinometer calibration cleared");
  }

  function screenAngleDeg() {
    const orientation = window.screen && window.screen.orientation;
    const angle = orientation && typeof orientation.angle === "number" ? orientation.angle : Number(window.orientation || 0);
    if (!Number.isFinite(angle)) return 0;
    return ((angle % 360) + 360) % 360;
  }

  function remapScreenGravity(x, y, z) {
    const angle = screenAngleDeg();
    if (angle === 90) return { x: -y, y: x, z: z };
    if (angle === 270) return { x: y, y: -x, z: z };
    if (angle === 180) return { x: -x, y: -y, z: z };
    return { x: x, y: y, z: z };
  }

  function ingestWebGravity(x, y, z, heading) {
    if (state.nativeAttAt && Date.now() - state.nativeAttAt < 1200) {
      if (heading != null && Number.isFinite(Number(heading))) state.compass = Number(heading);
      return;
    }
    const screenG = remapScreenGravity(x, y, z);
    onAttitude({ pitch: 0, roll: 0, heading: heading, sx: screenG.x, sy: screenG.y, sz: screenG.z, web: true });
  }

  async function loadTelemetry() {
    if (SHOT) return;
    try {
      const text = await net("https://waterservices.usgs.gov/nwis/iv/?format=json&sites=09010500,09180500,10261500&parameterCd=00060,00065");
      const root = JSON.parse(text);
      const series = (((root.value || {}).timeSeries) || []);
      const bySite = {};
      series.forEach(function (item) {
        const site = (((item.sourceInfo || {}).siteCode || [])[0] || {}).value;
        const name = (item.sourceInfo || {}).siteName || site;
        const code = ((((item.variable || {}).variableCode) || [])[0] || {}).value;
        const values = ((((item.values || [])[0] || {}).value) || []);
        const latest = values.length ? Number(values[values.length - 1].value) : 0;
        if (!site) return;
        const geo = (((item.sourceInfo || {}).geoLocation || {}).geogLocation) || {};
        bySite[site] = bySite[site] || { name: name, cfs: 0, height: 0, lat: Number(geo.latitude), lon: Number(geo.longitude) };
        if (Number.isFinite(Number(geo.latitude)) && Number.isFinite(Number(geo.longitude))) {
          bySite[site].lat = Number(geo.latitude);
          bySite[site].lon = Number(geo.longitude);
        }
        if (code === "00060") bySite[site].cfs = latest;
        if (code === "00065") bySite[site].height = latest;
      });
      state.gauges = Object.keys(bySite).map(function (id) { return bySite[id]; });
    } catch (error) { /* Atlas flow numbers remain on the card. */ }
    try {
      const trail = selected();
      const minLon = trail.lon - 1.2;
      const minLat = trail.lat - 1.2;
      const maxLon = trail.lon + 1.2;
      const maxLat = trail.lat + 1.2;
      const url = "https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/services/WFIGS_Interagency_Perimeters_Current/FeatureServer/0/query?where=1%3D1&outFields=poly_IncidentName,poly_GISAcres,attr_PercentContained&geometry=" + minLon + "," + minLat + "," + maxLon + "," + maxLat + "&geometryType=esriGeometryEnvelope&inSR=4326&spatialRel=esriSpatialRelIntersects&outSR=4326&returnGeometry=true&f=json&resultRecordCount=5";
      const text = await net(url);
      const root = JSON.parse(text);
      state.fires = (root.features || []).map(function (feature) {
        const props = feature.attributes || {};
        const center = ringCentroid(feature.geometry);
        return {
          name: props.poly_IncidentName || "Active incident",
          acres: Number(props.poly_GISAcres) || 0,
          contained: Number(props.attr_PercentContained) || 0,
          lat: center ? center.lat : null,
          lon: center ? center.lon : null
        };
      });
    } catch (error) { /* Fire card stays quiet when the feed is down. */ }
    syncOverlays();
    if (state.mode === "drive" && !state.route) renderSheet();
  }

  function onBilling(raw) {
    try { state.billing = typeof raw === "string" ? JSON.parse(raw) : raw; } catch (error) { return; }
    if (state.mode === "rig") renderSheet();
  }

  function buy(id) {
    if (window.TrailForgeBilling && TrailForgeBilling.purchase) {
      TrailForgeBilling.purchase(id);
      return;
    }
    toast("Open the TrailForge Android app to buy with Google Play.");
  }

  function handle(button) {
    const act = button.dataset.act;
    if (act === "menu") {
      state.menuOpen = !state.menuOpen;
      const list = document.getElementById("trailList");
      if (list) list.classList.toggle("open", state.menuOpen);
      return;
    }
    if (act === "filter") {
      const next = button.dataset.id;
      state.menuOpen = false;
      state.follow = false;
      if (next === "near") {
        state.userPanned = false;
        requestGpsFix();
        if (state.fix && map) map.setView([state.fix.lat, state.fix.lon], Math.max(map.getZoom(), 11));
      }
      state.filter = next;
      applyFilter(true);
      return;
    }
    if (act === "pick") {
      state.selectedId = button.dataset.id;
      state.menuOpen = false;
      state.follow = false;
      const picked = selected();
      if (picked && isBdrTrail(picked) && picked.coordinates && map) map.fitBounds(picked.coordinates, { padding: [28, 28] });
      else focusTrail(picked, 11);
      renderAll();
      loadTelemetry();
      refreshMvum(picked);
      refreshCommunity(false);
      return;
    }
    if (act === "mode") {
      state.mode = button.dataset.mode;
      if (state.detent === "peek" || (button.dataset.mode === "rig" && state.detent === "full")) {
        state.detent = "split";
        localStorage.setItem("tf-detent", "split");
      }
      renderAll();
      return;
    }
    if (act === "route") {
      const spot = findSpot(button.dataset.id);
      beginRoute(spot, true, !!(spot && spot.kind === "pad"));
      return;
    }
    if (act === "confirm-route") {
      confirmRoute();
      return;
    }
    if (act === "center") {
      state.follow = false;
      if (!state.fix) { toast("Waiting for GPS…"); return; }
      map.setView([state.fix.lat, state.fix.lon], Math.max(map.getZoom(), 14));
      return;
    }
    if (act === "near") {
      state.follow = false;
      state.filter = "near";
      if (state.fix) map.setView([state.fix.lat, state.fix.lon], Math.max(map.getZoom(), 11));
      applyFilter(true);
      return;
    }
    if (act === "offline") {
      toggleOfflineMaps(false);
      return;
    }
    if (act === "mute") { setMuted(!state.muted); return; }
    if (act === "steps") { state.showSteps = !state.showSteps; renderTop(); return; }
    if (act === "follow") {
      if (state.route && !state.route.confirmed) {
        confirmRoute();
        return;
      }
      state.follow = true;
      setDetent("peek");
      if (state.fix) map.setView([state.fix.lat, state.fix.lon], Math.max(map.getZoom(), 15));
      renderSheet();
      return;
    }
    if (act === "overview") { state.follow = false; frameRoute(); renderSheet(); return; }
    if (act === "gmaps") {
      if (!state.route) return;
      const spot = state.route.destination;
      const origin = state.fix ? "&origin=" + state.fix.lat + "," + state.fix.lon : "";
      openExternal("https://www.google.com/maps/dir/?api=1" + origin + "&destination=" + spot.lat + "," + spot.lon + "&travelmode=driving");
      return;
    }
    if (act === "end") { endRoute(); return; }
    if (act === "copy-target") {
      if (!state.targetCopy) { toast("No target yet."); return; }
      copyText(state.targetCopy);
      return;
    }
    if (act === "surface") { state.surface = button.dataset.id; updateHud(); renderSheet(); return; }
    if (act === "locker") {
      state.rig.hasRearLocker = button.dataset.id === "rear";
      saveRig();
      renderAll();
      return;
    }
    if (act === "snorkel") { state.rig.hasSnorkel = !state.rig.hasSnorkel; saveRig(); renderAll(); return; }
    if (act === "bead") { state.beadlocks = !state.beadlocks; updateHud(); renderSheet(); return; }
    if (act === "buy") { buy(button.dataset.id); return; }
    if (act === "restore") {
      if (window.TrailForgeBilling && TrailForgeBilling.restore) TrailForgeBilling.restore();
      else toast("Restore runs inside the Android app with Google Play.");
      return;
    }
    if (act === "privacy" || act === "terms") {
      openExternal(act === "terms" ? "https://krokemoutdoors.github.io/trailforge-overland/#terms" : "https://krokemoutdoors.github.io/trailforge-overland/#privacy");
      return;
    }
    if (act === "safety-review") { showSafetyModal(true); return; }
    if (act === "safety-agree") { acceptSafety(); return; }
    if (act === "detent") { setDetent(button.dataset.id); return; }
    if (act === "dash") {
      state.dash = dashOn() ? "off" : "on";
      localStorage.setItem("tf-dash", state.dash);
      applyChrome();
      return;
    }
    if (act === "zero-clinometer") { zeroClinometer(); return; }
    if (act === "reset-clinometer") { resetClinometer(); return; }
    if (act === "search-place") {
      clearTimeout(state.placeTimer);
      searchPlaces(state.query, true);
      return;
    }
    if (act === "place-show" || act === "place-route") {
      const hit = (state.places || []).find(function (place) { return place.id === button.dataset.id; });
      if (hit) showPlace(hit, act === "place-route");
      return;
    }
    if (act === "recenter") {
      if (!state.fix || !map) { toast("Waiting for GPS…"); return; }
      state.follow = true;
      if (state.route) setDetent("peek");
      else applyChrome();
      map.setView([state.fix.lat, state.fix.lon], Math.max(map.getZoom(), 15));
      const heading = state.fix.heading == null ? null : Math.round(((state.fix.heading % 360) + 360) % 360);
      toast(heading == null ? "Centered on My GPS" : "Heading " + String(heading).padStart(3, "0") + "°");
      renderSheet();
      return;
    }
    if (act === "toggle-overlay") {
      const name = button.dataset.overlay;
      const onValue = Number(button.dataset.on);
      const current = Number(state.opacity[name]) || 0;
      setOverlay(name, current > 2 ? 0 : (Number.isFinite(onValue) ? onValue : 75));
      return;
    }
    if (act === "layers") {
      state.drawer = state.drawer === "layers" ? null : "layers";
      if (state.drawer) leaveFullDetent();
      renderDrawer();
      applyChrome();
      return;
    }
    if (act === "plot") {
      state.plotting = !state.plotting;
      state.drawer = state.plotting ? "plot" : (state.drawer === "plot" ? null : state.drawer);
      if (state.plotting) leaveFullDetent();
      if (state.plotting && !state.plotClearedByUser && state.plot.length < 2 && seedPlotFromMarkers()) {
        drawPlot();
        toast("Connected " + state.plot.length + " saved waypoints");
      } else if (state.plotting) {
        toast("Tap the map to plot a route");
      } else {
        drawPlot();
      }
      drawSavedMarkers();
      renderDrawer();
      applyChrome();
      return;
    }
    if (act === "connect-markers") {
      connectSavedWaypoints();
      return;
    }
    if (act === "compass-north") {
      const arrow = document.getElementById("compassArrow");
      if (arrow) arrow.style.transform = "rotate(0deg)";
      toast("North");
      return;
    }
    if (act === "corridor") {
      toggleOfflineMaps(true);
      return;
    }
    if (act === "download-corridor") {
      if (state.drawer !== "corridor") {
        state.drawer = "corridor";
        leaveFullDetent();
        renderDrawer();
        applyChrome();
      }
      downloadCorridor();
      return;
    }
    if (act === "close-drawer") { state.drawer = null; renderDrawer(); applyChrome(); syncAreaPreview(); return; }
    if (act === "toggle-3d") {
      set3DMode(!state.map3dEnabled);
      return;
    }
    if (act === "map-3d") {
      set3DMode(button.dataset.id === "on");
      return;
    }
    if (act === "basemap") {
      const id = button.dataset.id;
      state.basemap = id === "topo" || id === "satellite" || id === "dark" ? id : "hybrid";
      if ((state.basemap === "satellite" || state.basemap === "hybrid") && state.thermal) {
        state.thermal = false;
        localStorage.setItem("tf-thermal", "0");
      }
      localStorage.setItem("tf-basemap", state.basemap);
      applyBasemap();
      renderDrawer();
      applyChrome();
      return;
    }
    if (act === "pack-kind") {
      state.packKind = button.dataset.id === "satellite" ? "satellite" : "topo";
      localStorage.setItem("tf-pack-kind", state.packKind);
      renderDrawer();
      return;
    }
    if (act === "pack-area") {
      const id = button.dataset.id;
      state.packArea = id === "view" || id === "corridor" ? id : "view";
      localStorage.setItem("tf-pack-area", state.packArea);
      refreshAreaChrome();
      renderDrawer();
      return;
    }
    if (act === "focus-pack") {
      const pack = state.packs.find(function (item) { return item.id === button.dataset.id; });
      if (pack && map && pack.minLat != null) {
        map.fitBounds([[pack.minLat, pack.minLon], [pack.maxLat, pack.maxLon]], { padding: [28, 28] });
        state.drawer = null;
        renderDrawer();
      }
      return;
    }
    if (act === "report") { queueReport(button.dataset.id); return; }
    if (act === "refresh-live") { refreshCommunity(true); return; }
    if (act === "still-here") { confirmCommunity(button.dataset.id); return; }
    if (act === "mark-cleared") { clearCommunity(button.dataset.id); return; }
    if (act === "apply-trip") {
      const code = document.getElementById("tripCode");
      applyTripCode(code ? code.value : "");
      return;
    }
    if (act === "export-gpx") { exportGpx(); return; }
    if (act === "import-gpx") {
      const input = document.getElementById("gpxFile");
      if (input) input.click();
      return;
    }
    if (act === "undo-plot") {
      if (state.plot.length) state.plot.pop();
      drawPlot();
      renderSheet();
      renderDrawer();
      toast("Removed last waypoint");
      return;
    }
    if (act === "del-waypoint") {
      const index = Number(button.dataset.idx);
      if (Number.isInteger(index) && index >= 0 && index < state.plot.length) state.plot.splice(index, 1);
      drawPlot();
      renderSheet();
      renderDrawer();
      return;
    }
    if (act === "clear-plot") {
      state.plot = [];
      state.plotClearedByUser = true;
      drawPlot();
      renderSheet();
      renderDrawer();
      toast("Deleted all waypoints");
      return;
    }
    if (act === "del-marker") { deleteMarkerById(button.dataset.id); return; }
    if (act === "clear-markers") { clearSavedMarkers(); return; }
    if (act === "drop-pack") { dropPack(button.dataset.id); return; }
    if (act === "plot-mode") {
      state.plotMode = button.dataset.id === "freehand" ? "freehand" : "snap";
      localStorage.setItem("tf-plot-mode", state.plotMode);
      renderDrawer();
      toast(state.plotMode === "freehand" ? "Freehand / wash bridge" : "Snap to trail");
      return;
    }
    if (act === "thermal") {
      state.thermal = !state.thermal;
      localStorage.setItem("tf-thermal", state.thermal ? "1" : "0");
      applyBasemap();
      applyChrome();
      toast(state.thermal ? "Thermal saver on — slower sensors. Satellite and Hybrid stay on imagery." : "Thermal saver off");
      return;
    }
    if (act === "night") {
      state.night = !state.night;
      localStorage.setItem("tf-night", state.night ? "1" : "0");
      applyChrome();
      return;
    }
    if (act === "hazard") { openHazardSheet(); return; }
    if (act === "record-toggle") { toggleRecording(); return; }
    if (act === "record-start") { startRecording(); return; }
    if (act === "record-pause") { pauseRecording(); return; }
    if (act === "record-save") { stopAndSaveRecording(); return; }
    if (act === "record-view") { navigateRecorded(button.dataset.id); return; }
    if (act === "record-share") { shareRecorded(button.dataset.id); return; }
    if (act === "record-delete") { deleteRecorded(button.dataset.id); return; }
    if (act === "close-pin") { closePinSheet(); return; }
    if (act === "pin-cat") { state.pinCategory = button.dataset.id || "Waypoint"; markCategory("#pinCats", state.pinCategory); return; }
    if (act === "pin-route") { routeDroppedPin(); return; }
    if (act === "pin-save") { saveDroppedPin(); return; }
    if (act === "pin-gmaps") { googleDroppedPin(); return; }
    if (act === "marker-open") { openMarker(button.dataset.id); return; }
    if (act === "close-marker") { closeMarkerSheet(); return; }
    if (act === "marker-cat") { setMarkerCategory(button.dataset.id); return; }
    if (act === "marker-route") { routeActiveMarker(); return; }
    if (act === "marker-rename") { renameActiveMarker(); return; }
    if (act === "marker-share") { shareActiveMarker(); return; }
    if (act === "marker-delete") { deleteActiveMarker(); return; }
    if (act === "close-hazard") { closeHazardSheet(); return; }
    if (act === "hazard-voice") { captureHazardVoice(); return; }
    if (act === "drop-hazard") { saveHazard(button.dataset.id); return; }
    if (act === "share-trip") { shareTrip(); return; }
    if (act === "close-qr") { closeQr(); return; }
    if (act === "convoy") { setConvoy(button.dataset.id); return; }
    if (act === "call-ranger") {
      const phone = button.dataset.id || "";
      if (phone.indexOf("+") === 0) window.location.href = "tel:" + phone;
      return;
    }
    if (act === "ranger-page") {
      openExternal("https://www.fs.usda.gov/r06/offices");
      return;
    }
  }

  function onBack() {
    const qr = document.getElementById("qrModal");
    if (qr && !qr.hidden) { closeQr(); return true; }
    const pin = document.getElementById("pinSheet");
    if (pin && !pin.hidden) { closePinSheet(); return true; }
    const markerSheet = document.getElementById("markerSheet");
    if (markerSheet && !markerSheet.hidden) { closeMarkerSheet(); return true; }
    const hazard = document.getElementById("hazardSheet");
    if (hazard && !hazard.hidden) { closeHazardSheet(); return true; }
    if (state.drawer) { state.drawer = null; renderDrawer(); applyChrome(); return true; }
    if (state.plotting) { state.plotting = false; drawPlot(); applyChrome(); return true; }
    if (state.menuOpen) { state.menuOpen = false; renderSheet(); return true; }
    if (state.showSteps) { state.showSteps = false; renderTop(); return true; }
    if (state.route) { endRoute(); return true; }
    if (state.mode !== "drive") { state.mode = "drive"; renderAll(); return true; }
    return false;
  }

  function bootShot() {
    if (!SHOT) return;
    state.attitudeLocked = true;
    if (SHOT === "drive" || SHOT === "menu") {
      state.fix = { lat: 47.45, lon: -121.35, altitudeM: 1176, speedMps: 11.6, heading: 48, time: Date.now(), shot: true };
      state.pitch = 3.2;
      state.roll = -7.4;
      state.filter = "WA";
      state.selectedId = "wabdr";
      state.menuOpen = SHOT === "menu";
      applyFilter(false);
      focusTrail(selected(), 8);
    } else if (SHOT === "route") {
      state.fix = { lat: 38.0228, lon: -107.6714, altitudeM: 2370, speedMps: 7.2, heading: 220, time: Date.now(), shot: true };
      state.filter = "CO";
      state.selectedId = "imogene";
      applyFilter(false);
      const pad = spotsFor(selected()).find(function (spot) { return spot.kind === "pad"; }) || spotsFor(trailById("imogene"))[0];
      beginRoute(pad);
    } else if (SHOT === "rig") {
      state.fix = { lat: 37.96, lon: -107.73, altitudeM: 3200, speedMps: 0, heading: 12, time: Date.now(), shot: true };
      state.mode = "rig";
      state.pitch = 6.5;
      state.roll = -11;
      state.filter = "CO";
      state.selectedId = "imogene";
      renderAll();
      map.setView([37.96, -107.73], 11);
    } else if (SHOT === "camp") {
      state.fix = { lat: 37.97, lon: -107.74, altitudeM: 3400, speedMps: 3, heading: 190, time: Date.now(), shot: true };
      state.mode = "camp";
      state.filter = "CO";
      state.selectedId = "imogene";
      applyFilter(false);
      map.setView([37.96, -107.74], 11);
    }
    requestAnimationFrame(function () {
      map.invalidateSize();
      if (SHOT !== "route") document.getElementById("app").dataset.shotReady = "1";
    });
  }

  function requestGpsFix() {
    if (!navigator.geolocation || SHOT) return;
    navigator.geolocation.getCurrentPosition(function (position) {
      onFix({
        lat: position.coords.latitude,
        lon: position.coords.longitude,
        accuracy: position.coords.accuracy,
        altitude: position.coords.altitude,
        speed: position.coords.speed,
        heading: position.coords.heading,
        time: position.timestamp,
        source: "web"
      });
    }, function () {}, { enableHighAccuracy: true, maximumAge: 0, timeout: 15000 });
  }

  function startGeolocation() {
    requestGpsFix();
    if (!navigator.geolocation || SHOT) return;
    navigator.geolocation.watchPosition(function (position) {
      onFix({
        lat: position.coords.latitude,
        lon: position.coords.longitude,
        accuracy: position.coords.accuracy,
        altitude: position.coords.altitude,
        speed: position.coords.speed,
        heading: position.coords.heading,
        time: position.timestamp,
        source: "web"
      });
    }, function () {
      if (!state.fix) toast("GPS is off. Center on My GPS after location is allowed.");
    }, { enableHighAccuracy: true, maximumAge: 1000, timeout: 20000 });
  }

  function installHost() {
    const queued = (window.TrailForge._q || []).splice(0);
    window.TrailForge.onNativeFix = onFix;
    window.TrailForge.onNativeAttitude = onAttitude;
    window.TrailForge.onNativeFetch = onNativeFetch;
    window.TrailForge.onBilling = onBilling;
    window.TrailForge.onNetwork = function (online) { state.online = !!online; };
    window.TrailForge.onLocationPermission = function (granted) {
      state.perm = !!granted;
      if (granted) startGeolocation();
    };
    window.TrailForge.onBack = onBack;
    queued.forEach(function (item) {
      if (item[0] === "fix") onFix(item[1]);
      else if (item[0] === "att") onAttitude(item[1]);
      else if (item[0] === "fetch") onNativeFetch(item[1], item[2], item[3]);
      else if (item[0] === "bill") onBilling(item[1]);
      else if (item[0] === "net") state.online = !!item[1];
      else if (item[0] === "perm") window.TrailForge.onLocationPermission(item[1]);
    });
  }

  function syncSmaTiles() {
    if (!map || !smaLayer) return;
    const fade = Math.max(0, Math.min(100, Number(state.opacity.blm) || 0)) / 100;
    toggleTile(smaLayer, fade > 0, fade || 0);
    if (fade > 0 && smaLayer.getContainer) {
      const container = smaLayer.getContainer();
      if (container) container.style.opacity = String(fade);
    }
  }

  function loadOpacity() {
    const base = { blm: 75, usfs: 75, state: 75, slope: 75, hazards: 85, starlink: 80, trails: 85 };
    try {
      const saved = JSON.parse(localStorage.getItem("tf-opacity") || "{}");
      const merged = Object.assign(base, saved && typeof saved === "object" ? saved : {});
      if (saved && saved.corridors != null && saved.blm == null) {
        merged.blm = saved.corridors;
        merged.usfs = saved.corridors;
        merged.state = saved.corridors;
      }
      return merged;
    } catch (error) { return base; }
  }

  function loadDropped() {
    try {
      const parsed = JSON.parse(localStorage.getItem("tf-hazards") || "[]");
      return Array.isArray(parsed) ? parsed : [];
    } catch (error) { return []; }
  }

  function loadReports() {
    try {
      const parsed = JSON.parse(localStorage.getItem("tf-reports") || "[]");
      return Array.isArray(parsed) ? parsed : [];
    } catch (error) { return []; }
  }

  function loadPacks() {
    try {
      const parsed = JSON.parse(localStorage.getItem("tf-packs") || "[]");
      return Array.isArray(parsed) ? parsed : [];
    } catch (error) { return []; }
  }

  function savePacks() {
    localStorage.setItem("tf-packs", JSON.stringify(state.packs));
  }

  function toggleOfflineMaps(startDownload) {
    if (state.drawer === "corridor") {
      state.drawer = null;
    } else {
      state.drawer = "corridor";
      leaveFullDetent();
      if (startDownload) downloadCorridor();
    }
    renderDrawer();
    applyChrome();
    syncAreaPreview();
    renderTop();
  }

  function placeRail() {
    const rail = document.getElementById("rail");
    const dock = document.getElementById("dock");
    const stage = document.getElementById("stage");
    if (!rail || !dock || !stage) return;
    const landscape = window.matchMedia("(orientation: landscape)").matches;
    if (dashOn() || landscape || state.detent === "full") {
      rail.style.top = "";
      rail.style.maxHeight = "";
      rail.style.position = "";
      return;
    }
    const start = Math.round(window.innerHeight * 0.5);
    const room = dock.getBoundingClientRect().top - start - 8;
    if (room >= 120) {
      rail.style.position = "fixed";
      rail.style.top = start + "px";
      rail.style.maxHeight = room + "px";
      return;
    }
    const stageBox = stage.getBoundingClientRect();
    const fit = Math.min(220, Math.max(88, stageBox.height - 12));
    rail.style.position = "absolute";
    rail.style.top = Math.max(8, stageBox.height - fit) + "px";
    rail.style.maxHeight = fit + "px";
  }

  function dashOn() {
    if (state.dash === "on") return true;
    if (state.dash === "off") return false;
    return window.matchMedia("(orientation: landscape)").matches;
  }

  function applyChrome() {
    const app = document.getElementById("app");
    if (!app) return;
    app.dataset.detent = state.detent;
    app.dataset.dash = dashOn() ? "1" : "0";
    app.dataset.night = state.night ? "1" : "0";
    document.querySelectorAll("[data-act=thermal]").forEach(function (button) {
      button.classList.toggle("on", state.thermal);
    });
    document.querySelectorAll("[data-act=night]").forEach(function (button) {
      button.classList.toggle("on", state.night);
    });
    document.querySelectorAll("[data-act=detent]").forEach(function (button) {
      button.classList.toggle("on", button.dataset.id === state.detent);
    });
    renderModebar();
    const dashBtn = document.getElementById("dashBtn");
    if (dashBtn) dashBtn.classList.toggle("on", dashOn());
    renderDrawer();
    if (!map) return;
    clearTimeout(chromeTimer);
    chromeTimer = setTimeout(function () {
      if (map) map.invalidateSize();
      refreshPitchForStage();
      paintElevation();
      placeRail();
    }, 60);
    placeRail();
  }

  function setDetent(id) {
    if (id !== "peek" && id !== "split" && id !== "full") return;
    state.detent = id;
    localStorage.setItem("tf-detent", id);
    applyChrome();
  }

  function leaveFullDetent() {
    if (dashOn()) return;
    if (state.detent === "full") setDetent("split");
  }

  function renderDrawer() {
    const drawer = document.getElementById("layerDrawer");
    if (!drawer) return;
    drawer.hidden = !state.drawer;
    drawer.querySelectorAll("[data-panel]").forEach(function (panel) {
      panel.hidden = panel.dataset.panel !== state.drawer;
    });
    const titles = { layers: "Map Layers", corridor: "Offline Maps", plot: "Custom Route" };
    const title = document.getElementById("drawerTitle");
    if (title) title.textContent = titles[state.drawer] || "Layers";
    drawer.querySelectorAll("[data-act=basemap]").forEach(function (button) {
      button.classList.toggle("on", button.dataset.id === state.basemap);
    });
    drawer.querySelectorAll("[data-act=pack-kind]").forEach(function (button) {
      button.classList.toggle("on", button.dataset.id === state.packKind);
    });
    drawer.querySelectorAll("[data-act=pack-area]").forEach(function (button) {
      button.classList.toggle("on", button.dataset.id === state.packArea);
      if (button.dataset.id === "view") button.textContent = currentScreenLabel();
    });
    const downloadBtn = drawer.querySelector("[data-act=download-corridor]");
    if (downloadBtn) {
      downloadBtn.textContent = state.packArea === "corridor" ? "Download 5-Mile Route Corridor" : "Download " + areaChoiceLabel();
    }
    const estimate = document.getElementById("packEstimate");
    if (estimate) estimate.textContent = areaEstimateText();
    drawer.querySelectorAll("[data-act=plot-mode]").forEach(function (button) {
      button.classList.toggle("on", button.dataset.id === state.plotMode);
    });
    Object.keys(state.opacity).forEach(function (name) {
      const read = document.querySelector('[data-read="' + name + '"]');
      if (read) read.textContent = Number(state.opacity[name]) > 2 ? "ON" : "OFF";
    });
    const count = document.getElementById("plotCount");
    const verdict = document.getElementById("plotFit");
    const fit = state.plot.length ? plotFit() : null;
    if (count) {
      const milesText = state.plot.length >= 2 ? " · " + (plotMeters() / 1609.344).toFixed(1) + " mi" : "";
      count.textContent = state.plot.length + (state.plot.length === 1 ? " point" : " points") + milesText;
    }
    const plotList = document.getElementById("plotWaypointList");
    if (plotList) plotList.innerHTML = plotWaypointRowsHtml();
    if (verdict) {
      verdict.textContent = fit ? shortFit(fit.verdict) : "—";
      verdict.style.color = fit ? fitColor(fit.verdict) : "";
    }
    const list = document.getElementById("packList");
    if (list) {
      list.innerHTML = state.packs.length ? state.packs.map(function (pack) {
        const badge = pack.badge || ((pack.kind === "satellite" ? "Max Satellite" : "Standard Topo") + " · " + pack.tiles + " tiles");
        const focus = pack.minLat != null ? '<button type="button" data-act="focus-pack" data-id="' + esc(pack.id) + '">Focus on Map</button>' : "";
        return '<div class="pack"><b>' + esc(pack.name) + "</b><small>" + esc(badge) + "</small><div class=\"pack-actions\">" + focus + '<button type="button" data-act="drop-pack" data-id="' + esc(pack.id) + '">Remove</button></div></div>';
      }).join("") : '<div class="sub">No offline pack saved on this device yet.</div>';
    }
    const plotBtn = document.querySelector('#rail [data-act="plot"]');
    const layerBtn = document.querySelector('#rail [data-act="layers"]');
    const corridorBtn = document.querySelector('#rail [data-act="corridor"]');
    if (plotBtn) plotBtn.classList.toggle("on", state.plotting);
    if (layerBtn) layerBtn.classList.toggle("on", state.drawer === "layers");
    if (corridorBtn) corridorBtn.classList.toggle("on", state.drawer === "corridor" || state.packBusy);
    drawer.querySelectorAll("[data-act=map-3d]").forEach(function (button) {
      const enabled = !!state.map3dEnabled;
      button.classList.toggle("on", button.dataset.id === "on" ? enabled : !enabled);
    });
    const tiltBtn = document.getElementById("tiltBtn");
    if (tiltBtn) {
      tiltBtn.classList.remove("on");
      tiltBtn.textContent = state.map3dEnabled ? "2D" : "3D";
      tiltBtn.setAttribute("aria-label", state.map3dEnabled ? "Switch to 2D map" : "Switch to 3D map");
    }
    const connectBtn = document.getElementById("connectMarkers");
    if (connectBtn) connectBtn.hidden = state.savedMarkers.length < 2;
    syncMaskChrome();
    syncAreaPreview();
  }

  function syncMaskChrome() {
    document.querySelectorAll("label.mask, button.mask").forEach(function (row) {
      row.classList.toggle("on", Number(state.opacity[row.dataset.mask]) > 0);
    });
    document.querySelectorAll("[data-mask-key]").forEach(function (item) {
      item.hidden = !(Number(state.opacity[item.dataset.maskKey]) > 0);
    });
  }

  function setOverlay(name, value) {
    if (!state.opacity[name] && state.opacity[name] !== 0) return;
    state.opacity[name] = Math.max(0, Math.min(100, Math.round(value)));
    localStorage.setItem("tf-opacity", JSON.stringify(state.opacity));
    const read = document.querySelector('[data-read="' + name + '"]');
    if (read) read.textContent = state.opacity[name] > 2 ? "ON" : "OFF";
    syncOverlays();
    if (name === "blm") syncSmaTiles();
    if (name === "trails") syncMap();
    if (name === "blm" || name === "usfs" || name === "state") scheduleLandPolygons();
    syncMaskChrome();
  }

  function toggleTile(layer, on, opacity) {
    if (!map || !layer) return;
    if (on) {
      if (!map.hasLayer(layer)) layer.addTo(map);
      layer.setOpacity(opacity);
    } else if (map.hasLayer(layer)) map.removeLayer(layer);
  }

  function usgsCovers(lat, lon) {
    if (lat >= 24.4 && lat <= 49.5 && lon >= -125 && lon <= -66.5) return true;
    if (lat >= 51 && lat <= 71.5 && lon >= -170 && lon <= -129) return true;
    if (lat >= 18.8 && lat <= 22.3 && lon >= -160.3 && lon <= -154.7) return true;
    if (lat >= 17.6 && lat <= 18.6 && lon >= -67.5 && lon <= -65.2) return true;
    if (lat >= 17.6 && lat <= 18.5 && lon >= -65.1 && lon <= -64.5) return true;
    if (lat >= 13.2 && lat <= 13.7 && lon >= 144.6 && lon <= 145) return true;
    if (lat >= -14.4 && lat <= -11 && lon >= -171.1 && lon <= -169.4) return true;
    return false;
  }

  function set3DMode(enabled) {
    const on = !!enabled;
    state.map3dEnabled = on;
    state.map3d = on;
    localStorage.setItem("tf-map-3d", on ? "1" : "0");
    if (!on) {
      state.mapPitch = 0;
      localStorage.setItem("tf-map-pitch", "0");
    }
    applyMapPitch(false);
    applyBasemap();
    renderDrawer();
  }

  function setMapPitch(pitch, live) {
    const next = Math.max(0, Math.min(75, Number(pitch) || 0));
    const wasRelief = state.map3d && state.mapPitch > 1;
    state.mapPitch = next;
    localStorage.setItem("tf-map-pitch", String(next));
    applyMapPitch(!!live);
    const relief = !!(state.map3d && next > 1);
    if (!live || wasRelief !== relief) applyBasemap();
    if (live) return;
    renderDrawer();
  }

  const pitchFitCache = { key: "", value: null };

  function pitchVisual(userDeg) {
    const user = Math.max(0, Math.min(75, Number(userDeg) || 0));
    const angle = user;
    const scale = 1 + (angle / 75) * 0.42;
    const perspective = 1100;
    if (angle < 1) {
      return { user: user, angle: 0, scale: 1, originY: 0.65, perspective: perspective, bleed: 0, bleedBottom: 0, bleedSide: 0 };
    }
    const stage = document.getElementById("stage");
    const height = Math.max(180, stage ? stage.clientHeight : 480);
    const width = Math.max(200, stage ? stage.clientWidth : 390);
    const key = angle.toFixed(1) + "|" + height + "|" + width;
    if (pitchFitCache.key !== key) {
      pitchFitCache.key = key;
      pitchFitCache.value = fitPitchPlane(angle, scale, perspective, width, height);
    }
    return {
      user: user,
      angle: angle,
      scale: scale,
      originY: pitchFitCache.value.originY,
      perspective: perspective,
      bleed: pitchFitCache.value.bleed,
      bleedBottom: pitchFitCache.value.bleedBottom,
      bleedSide: pitchFitCache.value.bleedSide
    };
  }

  function fitPitchPlane(angle, scale, perspective, width, height) {
    const rad = angle * Math.PI / 180;
    const cosine = Math.cos(rad);
    const sine = Math.sin(rad);
    let originStageY = (perspective * cosine - Math.max(200, perspective * cosine * 0.78)) / sine;
    originStageY = Math.max(12, Math.min(height * 0.42, originStageY));
    if (perspective * cosine - originStageY * sine < 160) {
      originStageY = Math.max(12, (perspective * cosine - 160) / sine);
    }
    function localAt(screenX, screenY) {
      const denom = perspective * cosine + screenY * sine;
      return {
        localX: (screenX * perspective * cosine) / (scale * denom),
        localY: (screenY * perspective) / (scale * denom)
      };
    }
    const margin = 8;
    const yTop = localAt(0, -originStageY).localY;
    const yBot = localAt(0, height - originStageY).localY;
    let bleed = Math.max(0, Math.ceil(-yTop - originStageY + margin));
    const bleedBottom = Math.max(0, Math.ceil(yBot - (height - originStageY) + margin));
    for (let step = 0; step <= 8; step += 1) {
      const screenY = (height * step) / 8 - originStageY;
      const sample = localAt(width / 2, screenY);
      bleed = Math.max(bleed, Math.ceil(Math.abs(sample.localX) - width / 2 + margin));
    }
    const elementHeight = height + bleed + bleedBottom;
    return {
      originY: (originStageY + bleed) / elementHeight,
      bleed: bleed,
      bleedBottom: bleedBottom,
      bleedSide: bleed
    };
  }

  function refreshPitchForStage() {
    const stage = document.getElementById("stage");
    if (!stage) return;
    const key = stage.clientWidth + "x" + stage.clientHeight;
    if (key === pitchStageKey) return;
    applyMapPitch(false);
  }

  function applyMapPitch(live) {
    const el = document.getElementById("map");
    const stage = document.getElementById("stage");
    if (!el) return;
    const visual = state.map3d ? pitchVisual(state.mapPitch) : pitchVisual(0);
    el.classList.toggle("map-tilted", visual.user > 0.5);
    el.classList.toggle("map-tilt-live", !!live && visual.user > 0.5);
    if (stage) stage.classList.remove("map-horizon");
    if (visual.user <= 0.5) {
      el.style.transform = "";
      el.style.transformOrigin = "";
      el.style.top = "";
      el.style.right = "";
      el.style.bottom = "";
      el.style.left = "";
      if (stage) pitchStageKey = stage.clientWidth + "x" + stage.clientHeight;
      return;
    }
    el.style.top = (-visual.bleed) + "px";
    el.style.right = (-visual.bleedSide) + "px";
    el.style.bottom = (-visual.bleedBottom) + "px";
    el.style.left = (-visual.bleedSide) + "px";
    el.style.transformOrigin = "50% " + (visual.originY * 100).toFixed(2) + "%";
    el.style.transform = "perspective(" + visual.perspective + "px) rotateX(" + visual.angle.toFixed(2) + "deg) scale(" + visual.scale.toFixed(4) + ")";
    if (stage) pitchStageKey = stage.clientWidth + "x" + stage.clientHeight;
  }

  function mapContainerPoint(clientX, clientY) {
    if (!map) return L.point(0, 0);
    const mapEl = map.getContainer();
    const parent = mapEl.offsetParent || mapEl.parentElement || document.body;
    const parentRect = parent.getBoundingClientRect();
    const left = parentRect.left + mapEl.offsetLeft;
    const top = parentRect.top + mapEl.offsetTop;
    const width = mapEl.offsetWidth || mapEl.clientWidth || 1;
    const height = mapEl.offsetHeight || mapEl.clientHeight || 1;
    const visual = state.map3d ? pitchVisual(state.mapPitch) : pitchVisual(0);
    if (visual.user <= 0.5) return L.point(clientX - left, clientY - top);
    const scale = visual.scale;
    const rad = visual.angle * Math.PI / 180;
    const distance = visual.perspective;
    const cosine = Math.cos(rad);
    const sine = Math.sin(rad);
    const screenX = clientX - (left + width * 0.5);
    const screenY = clientY - (top + height * visual.originY);
    const denom = distance * cosine + screenY * sine;
    const localY = Math.abs(denom) < 1e-4 ? screenY / scale : (screenY * distance) / (scale * denom);
    const unperspY = localY * scale;
    const unperspZ = unperspY * sine;
    const localX = (screenX * (distance - unperspZ)) / (scale * distance);
    return L.point(width * 0.5 + localX, height * visual.originY + localY);
  }

  function installPitchGesture() {
    if (!map || !window.L || !L.DomEvent || L.DomEvent.__tfPitch) return;
    const original = L.DomEvent.getMousePosition;
    L.DomEvent.getMousePosition = function (event, container) {
      if (state.map3d && state.mapPitch > 0.5 && map && container === map.getContainer() && event && event.clientX != null) {
        return mapContainerPoint(event.clientX, event.clientY);
      }
      return original.call(L.DomEvent, event, container);
    };
    L.DomEvent.__tfPitch = true;
    const container = map.getContainer();
    const pointers = new Map();
    let span = 0;
    let pitching = false;
    function spanNow() {
      const pts = Array.from(pointers.values());
      if (pts.length < 2) return 0;
      return Math.hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y);
    }
    function averageY(list, key) {
      if (!list.length) return 0;
      let sum = 0;
      for (let index = 0; index < list.length; index += 1) sum += list[index][key];
      return sum / list.length;
    }
    function releaseMapGestures() {
      if (map && map.dragging) map.dragging.enable();
      if (map && map.touchZoom) map.touchZoom.enable();
    }
    container.addEventListener("pointerdown", function (event) {
      pointers.set(event.pointerId, { x: event.clientX, y: event.clientY, startY: event.clientY });
      span = spanNow();
      pitching = false;
    });
    container.addEventListener("pointermove", function (event) {
      if (!pointers.has(event.pointerId)) return;
      const before = Array.from(pointers.values());
      const prevAvgY = averageY(before, "y");
      const current = pointers.get(event.pointerId);
      pointers.set(event.pointerId, { x: event.clientX, y: event.clientY, startY: current.startY });
      const two = pointers.size >= 2;
      const shiftDrag = pointers.size === 1 && event.shiftKey;
      if (!two && !shiftDrag) return;
      if (!state.map3dEnabled) return;
      const nextSpan = spanNow();
      if (two && !pitching && span && Math.abs(nextSpan - span) > 45) {
        releaseMapGestures();
        return;
      }
      const active = Array.from(pointers.values());
      const avgY = averageY(active, "y");
      const avgStartY = averageY(active, "startY");
      if (!pitching && Math.abs(avgY - avgStartY) < 6) return;
      pitching = true;
      if (map.dragging) map.dragging.disable();
      if (map.touchZoom) map.touchZoom.disable();
      const dy = avgY - prevAvgY;
      setMapPitch(Math.max(0, Math.min(75, (state.mapPitch || 0) - dy * 0.28)), true);
    });
    function endPitch(event) {
      pointers.delete(event.pointerId);
      if (pointers.size >= 2) return;
      if (pitching) setMapPitch(state.mapPitch, false);
      pitching = false;
      releaseMapGestures();
    }
    container.addEventListener("pointerup", endPitch);
    container.addEventListener("pointercancel", endPitch);
  }

  function applyBasemap() {
    if (!imageryLayer || !map) return;
    const center = map.getCenter();
    const outside = !usgsCovers(center.lat, center.lng);
    const deep = map.getZoom() > 16;
    const dark = state.basemap === "dark";
    const imageryChoice = state.basemap === "satellite" || state.basemap === "hybrid";
    const mode = state.thermal && !imageryChoice ? "topo" : state.basemap;
    const showImagery = !dark && (mode === "satellite" || mode === "hybrid");
    toggleTile(imageryLayer, showImagery, 1);
    toggleTile(hybridLayer, showImagery && mode === "hybrid", 1);
    toggleTile(labelLayer, showImagery && mode === "hybrid", 1);
    toggleTile(topoLayer, !dark && mode === "topo" && !outside && !deep, 1);
    toggleTile(darkLayer, dark, 1);
    if (osmLayer) {
      osmLayer.options.minZoom = outside ? 3 : 17;
      toggleTile(osmLayer, !dark && mode === "topo" && (outside || deep), 1);
      if (map.hasLayer(osmLayer)) osmLayer.redraw();
    }
    if (map.attributionControl) map.attributionControl.setPrefix(MAP_ATTRIB);
    if (offlineLayer) offlineLayer.redraw();
    const relief = !dark && state.map3d && state.mapPitch > 1 && (mode === "topo" || mode === "satellite" || mode === "hybrid");
    toggleTile(hillshadeLayer, relief, 0.34);
  }

  function maskKind(trail) {
    const agency = String(trail.agency || "");
    const text = (String(trail.name || "") + " " + String(trail.region || "")).toLowerCase();
    if (/blm|bureau of land/i.test(agency)) return "blm";
    if (/state trust|\bdnr\b|state forest/i.test(agency)) return "state";
    if (trail.bdr || /usfs|forest service|national forest/i.test(agency)) return "usfs";
    if (/forest|\bfs\b|\bnf\b/.test(text)) return "usfs";
    if (/state|\bdnr\b/.test(text)) return "state";
    if (/blm|canyon|desert/.test(text)) return "blm";
    const mid = trailMidpoint(trail);
    if (mid && state.landRings) {
      for (let index = 0; index < state.landRings.length; index += 1) {
        const ring = state.landRings[index];
        if (pointInRing(mid.lat, mid.lon, ring.latlngs)) return ring.kind;
      }
    }
    const fades = maskFades();
    const active = ["blm", "usfs", "state"].filter(function (kind) { return fades[kind] > 0; });
    if (!active.length) return "";
    let hash = 0;
    const id = String(trail.id || "");
    for (let index = 0; index < id.length; index += 1) hash = (hash * 33 + id.charCodeAt(index)) >>> 0;
    return active[hash % active.length];
  }

  function maskFades() {
    return {
      blm: Math.max(0, Math.min(100, Number(state.opacity.blm) || 0)) / 100,
      usfs: Math.max(0, Math.min(100, Number(state.opacity.usfs) || 0)) / 100,
      state: Math.max(0, Math.min(100, Number(state.opacity.state) || 0)) / 100
    };
  }

  function trailMidpoint(trail) {
    const coords = trail && trail.coordinates;
    if (!coords || !coords.length) return null;
    const point = coords[Math.floor(coords.length / 2)];
    if (!point) return null;
    if (Array.isArray(point)) return { lat: Number(point[0]), lon: Number(point[1]) };
    return { lat: Number(point.lat), lon: Number(point.lon != null ? point.lon : point.lng) };
  }

  function pointInRing(lat, lon, ring) {
    if (!ring || ring.length < 3) return false;
    let inside = false;
    for (let index = 0, previous = ring.length - 1; index < ring.length; previous = index, index += 1) {
      const yi = ring[index][0];
      const xi = ring[index][1];
      const yj = ring[previous][0];
      const xj = ring[previous][1];
      const crosses = (yi > lat) !== (yj > lat);
      if (crosses && lon < ((xj - xi) * (lat - yi)) / ((yj - yi) || 1e-12) + xi) inside = !inside;
    }
    return inside;
  }

  const LAND_LAYERS = { blm: 22, usfs: 24, state: 29 };
  let landTimer = 0;
  let landAbort = null;

  function scheduleLandPolygons() {
    clearTimeout(landTimer);
    landTimer = setTimeout(loadLandPolygons, 350);
  }

  function loadLandPolygons() {
    if (!map) return;
    const fades = maskFades();
    const kinds = Object.keys(LAND_LAYERS).filter(function (kind) { return fades[kind] > 0; });
    if (!kinds.length) {
      state.landRings = [];
      syncOverlays();
      return;
    }
    if (landAbort) landAbort.abort();
    const controller = new AbortController();
    landAbort = controller;
    const bounds = map.getBounds();
    const minLat = bounds.getSouth();
    const maxLat = bounds.getNorth();
    const minLon = bounds.getWest();
    const maxLon = bounds.getEast();
    const geometry = [minLon, minLat, maxLon, maxLat].join(",");
    Promise.all(kinds.map(function (kind) {
      const url = "https://gis.blm.gov/arcgis/rest/services/lands/BLM_Natl_SMA_LimitedScale/MapServer/" + LAND_LAYERS[kind] + "/query?where=1%3D1&geometry=" + encodeURIComponent(geometry) + "&geometryType=esriGeometryEnvelope&inSR=4326&spatialRel=esriSpatialRelIntersects&outSR=4326&returnGeometry=true&maxAllowableOffset=0.002&f=json";
      return fetch(url, { signal: controller.signal }).then(function (response) { return response.json(); }).then(function (payload) {
        return keepLandRings(kind, payload && payload.features, minLon, minLat, maxLon, maxLat);
      }).catch(function () { return []; });
    })).then(function (groups) {
      if (controller.signal.aborted) return;
      state.landRings = groups.reduce(function (all, group) { return all.concat(group); }, []);
      syncOverlays();
    });
  }

  function keepLandRings(kind, features, minLon, minLat, maxLon, maxLat) {
    const ranked = [];
    (features || []).forEach(function (feature) {
      const rings = feature && feature.geometry && feature.geometry.rings;
      (rings || []).forEach(function (ring) {
        if (!ring || ring.length < 3) return;
        let west = Infinity;
        let east = -Infinity;
        let south = Infinity;
        let north = -Infinity;
        const latlngs = [];
        ring.forEach(function (pair) {
          if (!pair || pair.length < 2) return;
          const lon = Number(pair[0]);
          const lat = Number(pair[1]);
          west = Math.min(west, lon);
          east = Math.max(east, lon);
          south = Math.min(south, lat);
          north = Math.max(north, lat);
          latlngs.push([lat, lon]);
        });
        if (latlngs.length < 3) return;
        if (!(east >= minLon && west <= maxLon && north >= minLat && south <= maxLat)) return;
        ranked.push({ area: Math.max(0, east - west) * Math.max(0, north - south), latlngs: downsampleRing(latlngs) });
      });
    });
    ranked.sort(function (a, b) { return b.area - a.area; });
    return ranked.slice(0, 40).map(function (ring, index) {
      return { id: kind + "-" + index, kind: kind, latlngs: ring.latlngs };
    });
  }

  function downsampleRing(ring) {
    if (ring.length <= 80) return ring;
    const step = Math.ceil(ring.length / 80);
    const reduced = [];
    for (let index = 0; index < ring.length; index += step) reduced.push(ring[index]);
    const first = ring[0];
    const last = reduced[reduced.length - 1];
    if (!last || last[0] !== first[0] || last[1] !== first[1]) reduced.push(first);
    return reduced;
  }

  function syncOverlays() {
    if (!map || !corridorLayer || !slopeLayer || !hazardLayer || !starlinkLayer) return;
    corridorLayer.clearLayers();
    slopeLayer.clearLayers();
    hazardLayer.clearLayers();
    starlinkLayer.clearLayers();
    const fades = maskFades();
    const maskColor = { blm: "#f5e642", usfs: "#14915a", state: "#38bdf8" };
    (state.landRings || []).forEach(function (ring) {
      const fade = fades[ring.kind] || 0;
      if (fade <= 0 || !ring.latlngs || ring.latlngs.length < 3) return;
      L.polygon(ring.latlngs, {
        color: maskColor[ring.kind],
        weight: 1 + fade * 2.5,
        opacity: 0.30 + fade * 0.65,
        fillColor: maskColor[ring.kind],
        fillOpacity: 0.10 + fade * 0.50,
        interactive: false
      }).addTo(corridorLayer);
    });
    drawableTrails().forEach(function (trail) {
      const kind = maskKind(trail);
      if (!kind || fades[kind] <= 0 || !trail.coordinates || trail.coordinates.length < 2) return;
      const fade = fades[kind];
      L.polyline(trail.coordinates, {
        color: maskColor[kind],
        weight: 8 + Math.round(fade * 16),
        opacity: 0.18 + fade * 0.74,
        lineCap: "round",
        lineJoin: "round",
        interactive: false
      }).addTo(corridorLayer);
    });
    const slopeFade = Math.max(0, Math.min(100, Number(state.opacity.slope) || 0)) / 100;
    const trail = selected();
    if (slopeFade > 0 && trail) {
      const profile = elevationProfile(trail);
      for (let index = 1; index < profile.length; index += 1) {
        const grade = Math.abs(gradeDegrees(profile[index - 1], profile[index]));
        const color = grade < 3 ? "#3ddc84" : grade < 8 ? "#ff9f1a" : "#ff4d4d";
        L.polyline([[profile[index - 1].lat, profile[index - 1].lon], [profile[index].lat, profile[index].lon]], {
          color: color,
          weight: 6 + Math.round(slopeFade * 12),
          opacity: 0.22 + slopeFade * 0.7,
          lineCap: "round"
        }).addTo(slopeLayer);
      }
    }
    const hazardFade = Math.max(0, Math.min(100, Number(state.opacity.hazards) || 0)) / 100;
    if (hazardFade > 0) {
    state.fires.forEach(function (fire) {
      if (!Number.isFinite(fire.lat) || !Number.isFinite(fire.lon) || Math.abs(fire.lat) > 90) return;
      const icon = L.divIcon({ className: "hazard-pin", html: "<span>🔥 " + esc(fire.name) + "</span>", iconAnchor: [12, 12] });
      L.marker([fire.lat, fire.lon], { icon: icon, opacity: hazardFade, zIndexOffset: 300 }).addTo(hazardLayer);
    });
    state.gauges.forEach(function (gauge) {
      if (!Number.isFinite(gauge.lat) || !Number.isFinite(gauge.lon)) return;
      const icon = L.divIcon({ className: "hazard-pin", html: "<span>💧 " + Math.round(gauge.cfs) + " cfs</span>", iconAnchor: [12, 12] });
      L.marker([gauge.lat, gauge.lon], { icon: icon, opacity: hazardFade, zIndexOffset: 300 }).addTo(hazardLayer);
    });
    }
    const starlinkFade = Math.max(0, Math.min(100, Number(state.opacity.starlink) || 0)) / 100;
    if (starlinkFade <= 0) return;
    let drawn = 0;
    drawableTrails().some(function (trail) {
      const spots = spotsFor(trail);
      for (let index = 0; index < spots.length; index += 1) {
        const spot = spots[index];
        if (spot.slope >= 3) continue;
        L.circle([spot.lat, spot.lon], {
          radius: 180 + starlinkFade * 180,
          color: "#3ecbff",
          weight: 1 + Math.round(starlinkFade * 3),
          opacity: 0.28 + starlinkFade * 0.68,
          fillColor: "#3ecbff",
          fillOpacity: 0.08 + starlinkFade * 0.5,
          interactive: false
        }).addTo(starlinkLayer);
        drawn += 1;
        if (drawn >= 24) return true;
      }
      return false;
    });
  }

  function ringCentroid(geometry) {
    const rings = geometry && (geometry.rings || (geometry.coordinates && geometry.coordinates[0] ? [geometry.coordinates[0]] : null));
    const ring = rings && rings[0];
    if (!ring || !ring.length) return null;
    const step = Math.max(1, Math.floor(ring.length / 40));
    let lat = 0;
    let lon = 0;
    let count = 0;
    for (let index = 0; index < ring.length; index += step) {
      const pair = ring[index];
      if (!pair || pair.length < 2) continue;
      lon += Number(pair[0]);
      lat += Number(pair[1]);
      count += 1;
    }
    if (!count) return null;
    return { lat: lat / count, lon: lon / count };
  }

  function elevationProfile(trail) {
    const coords = trail.coordinates && trail.coordinates.length ? trail.coordinates : [[trail.lat, trail.lon]];
    const seed = seedFor(trail.id || "trail");
    const count = Math.max(coords.length, 24);
    const samples = [];
    let traveled = 0;
    let previous = null;
    for (let index = 0; index < count; index += 1) {
      const t = count === 1 ? 0 : index / (count - 1);
      const coord = coords[Math.min(coords.length - 1, Math.round(t * (coords.length - 1)))];
      const point = { lat: coord[0], lon: coord[1] };
      if (previous) traveled += miles(previous, point);
      const elev = Math.round((trail.elev || 4000) + Math.sin(t * Math.PI) * (380 + (seed % 280)) + Math.sin(t * 6.2 + seed) * 70);
      samples.push({ lat: point.lat, lon: point.lon, miles: traveled, elev: elev, obstacle: null });
      previous = point;
    }
    if (trail.water > 0 && samples.length) {
      const at = Math.min(samples.length - 1, Math.round(samples.length * 0.4));
      samples[at].obstacle = { icon: "💧", label: "Ford" };
    }
    if (trail.clearance >= 11 && samples.length) {
      const at = Math.min(samples.length - 1, Math.round(samples.length * 0.65));
      if (!samples[at].obstacle) samples[at].obstacle = { icon: "🪨", label: "Ledge" };
    }
    (trail.flatCamps || []).forEach(function (camp) {
      let best = 0;
      let bestDistance = Infinity;
      samples.forEach(function (sample, index) {
        const distance = Math.abs(sample.lat - camp.lat) + Math.abs(sample.lon - camp.lon);
        if (distance < bestDistance) { bestDistance = distance; best = index; }
      });
      samples[best].obstacle = { icon: "⛺", label: "<3° Pad" };
      samples[best].lat = camp.lat;
      samples[best].lon = camp.lon;
    });
    return samples;
  }

  function gradeDegrees(start, end) {
    const run = Math.max(1, miles(start, end) * 1609.344);
    const rise = (end.elev - start.elev) * 0.3048;
    return Math.atan2(rise, run) * 180 / Math.PI;
  }

  function paintElevation() {
    const canvas = document.getElementById("elevChart");
    const trail = selected();
    if (!canvas || !trail) return;
    if (!canvas.clientWidth) {
      if (canvas.dataset.waiting === "1") return;
      canvas.dataset.waiting = "1";
      requestAnimationFrame(function () {
        if (document.getElementById("elevChart") !== canvas || !canvas.clientWidth) return;
        canvas.dataset.waiting = "";
        paintElevation();
      });
      return;
    }
    canvas.dataset.waiting = "";
    if (state.scrubTrailId && state.scrubTrailId !== trail.id) {
      state.scrubIndex = null;
      if (scrubMarker && map) { map.removeLayer(scrubMarker); scrubMarker = null; }
    }
    state.scrubTrailId = trail.id;
    const profile = elevationProfile(trail);
    const width = canvas.clientWidth || 320;
    const height = 92;
    const ratio = window.devicePixelRatio || 1;
    canvas.width = Math.round(width * ratio);
    canvas.height = Math.round(height * ratio);
    const ctx = canvas.getContext("2d");
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
    ctx.fillStyle = "#0c1824";
    ctx.fillRect(0, 0, width, height);
    const elevs = profile.map(function (sample) { return sample.elev; });
    const min = Math.min.apply(null, elevs) - 30;
    const max = Math.max.apply(null, elevs) + 30;
    function xAt(index) { return profile.length < 2 ? width / 2 : (index / (profile.length - 1)) * (width - 12) + 6; }
    function yAt(elev) { return height - 14 - ((elev - min) / Math.max(1, max - min)) * (height - 28); }
    for (let index = 1; index < profile.length; index += 1) {
      const grade = Math.abs(gradeDegrees(profile[index - 1], profile[index]));
      ctx.beginPath();
      ctx.moveTo(xAt(index - 1), yAt(profile[index - 1].elev));
      ctx.lineTo(xAt(index), yAt(profile[index].elev));
      ctx.strokeStyle = grade < 3 ? "#3ddc84" : grade < 8 ? "#ff9f1a" : "#ff4d4d";
      ctx.lineWidth = 2.5;
      ctx.stroke();
    }
    ctx.font = "13px sans-serif";
    profile.forEach(function (sample, index) {
      if (!sample.obstacle) return;
      ctx.fillText(sample.obstacle.icon, xAt(index) - 7, yAt(sample.elev) - 6);
    });
    if (state.scrubIndex != null && profile[state.scrubIndex]) {
      ctx.strokeStyle = "#e8f1f8";
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(xAt(state.scrubIndex), 6);
      ctx.lineTo(xAt(state.scrubIndex), height - 8);
      ctx.stroke();
    }
    const sample = profile[state.scrubIndex != null ? state.scrubIndex : profile.length - 1];
    const read = document.getElementById("elevRead");
    if (read && sample) {
      const tag = sample.obstacle ? " · " + sample.obstacle.icon + " " + sample.obstacle.label : "";
      read.textContent = sample.elev.toLocaleString("en-US") + " ft · " + sample.miles.toFixed(1) + " mi" + tag;
    }
  }

  function scrubElevation(event) {
    const canvas = event.target;
    const rect = canvas.getBoundingClientRect();
    const trail = selected();
    if (!trail || !rect.width) return;
    const profile = elevationProfile(trail);
    const ratio = Math.max(0, Math.min(1, (event.clientX - rect.left) / rect.width));
    state.scrubIndex = Math.round(ratio * (profile.length - 1));
    state.scrubTrailId = trail.id;
    const sample = profile[state.scrubIndex];
    if (map && sample) {
      const icon = L.divIcon({
        className: "scrub-pin",
        html: "<span>" + (sample.obstacle ? sample.obstacle.icon + " " : "") + sample.elev.toLocaleString("en-US") + " ft</span>",
        iconAnchor: [36, 14]
      });
      if (!scrubMarker) scrubMarker = L.marker([sample.lat, sample.lon], { icon: icon, zIndexOffset: 760, interactive: false }).addTo(map);
      else { scrubMarker.setLatLng([sample.lat, sample.lon]); scrubMarker.setIcon(icon); }
    }
    paintElevation();
  }


  function loadCommunityStore() {
    try { return JSON.parse(localStorage.getItem("tf-community") || "[]"); }
    catch (error) { return []; }
  }

  function loadCommunityOps() {
    try { return JSON.parse(localStorage.getItem("tf-community-ops") || "{}"); }
    catch (error) { return {}; }
  }

  function loadCommunityQueue() {
    try { return JSON.parse(localStorage.getItem("tf-community-queue") || "[]"); }
    catch (error) { return []; }
  }

  function reportLabel(status) {
    return REPORT_LABELS[status] || status;
  }

  function communityCode(item) {
    if (item.status === "Gate Locked") return "G";
    if (item.status === "Downed Tree") return "T";
    if (item.status === "Washout") return "W";
    if (item.status === "Mud/Snow") return "M";
    if (item.status === "Open & Clear") return "O";
    return "H";
  }

  function statusFromCode(code) {
    return { G: "Gate Locked", T: "Downed Tree", W: "Washout", M: "Mud/Snow", O: "Open & Clear", H: "Washout" }[code] || "Washout";
  }

  function canonicalCommunityStatus(status) {
    const text = String(status || "").trim();
    const compact = text.replace(/\s*\/\s*/g, "/");
    if (REPORTS.indexOf(compact) >= 0) return compact;
    if (REPORTS.indexOf(text) >= 0) return text;
    return text.slice(0, 40);
  }

  function statusFromHazardCategory(category) {
    const text = String(category || "");
    if (text.indexOf("Gate") >= 0) return "Gate Locked";
    if (text.indexOf("Tree") >= 0) return "Downed Tree";
    if (text.indexOf("Mud") >= 0 || text.indexOf("Snow") >= 0) return "Mud/Snow";
    if (text.indexOf("Pad") >= 0) return "Verified Pad";
    return "Washout";
  }

  function communityTime(raw) {
    if (typeof raw.time === "number" && Number.isFinite(raw.time)) return raw.time;
    const stamp = raw.updatedAt || raw.createdAt || raw.time;
    if (typeof stamp === "number" && Number.isFinite(stamp)) return stamp;
    const parsed = Date.parse(stamp || "");
    return Number.isFinite(parsed) ? parsed : Date.now();
  }

  function normalizeCommunity(raw) {
    if (!raw || typeof raw !== "object") return null;
    const lat = Number(raw.lat != null ? raw.lat : raw.latitude);
    const lon = Number(raw.lon != null ? raw.lon : raw.longitude);
    const trailId = raw.trailId || raw.trailID;
    let status = canonicalCommunityStatus(raw.status || "");
    if (!status && raw.category) status = canonicalCommunityStatus(statusFromHazardCategory(raw.category));
    if (!raw.id || !trailId || !Number.isFinite(lat) || !Number.isFinite(lon)) return null;
    const kind = raw.kind === "hazard" || raw.category ? "hazard" : "condition";
    if (REPORTS.indexOf(status) < 0 && kind !== "hazard" && status.indexOf("Pad") < 0) return null;
    const confirm = raw.confirmCount != null ? raw.confirmCount : raw.confirmations;
    return {
      id: String(raw.id).slice(0, 80),
      trailId: String(trailId).slice(0, 80),
      lat: lat,
      lon: lon,
      status: status,
      kind: kind,
      rig: String(raw.rig || "Overland rig").slice(0, 60),
      time: communityTime(raw),
      confirmCount: Math.max(0, Number(confirm) || 0),
      cleared: !!raw.cleared,
      note: String(raw.note || "").slice(0, 140)
    };
  }

  function mergeCommunity(older, incoming) {
    const newer = (incoming.time || 0) >= (older.time || 0) ? incoming : older;
    const previous = newer === incoming ? older : incoming;
    return {
      id: older.id,
      trailId: newer.trailId || previous.trailId,
      lat: newer.lat,
      lon: newer.lon,
      status: newer.status,
      kind: newer.kind || previous.kind,
      rig: newer.rig || previous.rig,
      time: Math.max(older.time || 0, incoming.time || 0),
      confirmCount: Math.max(older.confirmCount || 0, incoming.confirmCount || 0),
      cleared: !!(older.cleared || incoming.cleared),
      note: newer.note || previous.note || ""
    };
  }

  function saveCommunity() {
    try { localStorage.setItem("tf-community", JSON.stringify(state.community)); } catch (error) {}
    const keys = Object.keys(state.communityOps);
    if (keys.length > 400) {
      const trimmed = {};
      keys.slice(-400).forEach(function (key) { trimmed[key] = 1; });
      state.communityOps = trimmed;
    }
    try { localStorage.setItem("tf-community-ops", JSON.stringify(state.communityOps)); } catch (error) {}
  }

  function saveCommunityQueue() {
    try { localStorage.setItem("tf-community-queue", JSON.stringify(state.communityQueue)); } catch (error) {}
  }

  function setCommunityNotice(text) {
    state.communityNotice = text;
    try { localStorage.setItem("tf-community-notice", text); } catch (error) {}
  }

  function absorbCommunityReport(raw) {
    const item = normalizeCommunity(raw);
    if (!item) return;
    const index = state.community.findIndex(function (row) { return row.id === item.id; });
    if (index < 0) state.community.unshift(item);
    else state.community[index] = mergeCommunity(state.community[index], item);
    if (state.community.length > 240) state.community = state.community.slice(0, 240);
  }

  function absorbCommunityFeed(payload) {
    const list = payload && payload.reports;
    if (list && list.forEach) list.forEach(absorbCommunityReport);
    const hazards = payload && payload.hazards;
    if (!hazards || !hazards.forEach) return;
    hazards.forEach(function (hazard) {
      absorbCommunityReport(Object.assign({}, hazard, {
        kind: "hazard",
        status: hazard.status || statusFromHazardCategory(hazard.category),
        trailId: hazard.trailId || hazard.trailID,
        lat: hazard.lat != null ? hazard.lat : hazard.latitude,
        lon: hazard.lon != null ? hazard.lon : hazard.longitude,
        time: hazard.time || hazard.updatedAt || hazard.createdAt,
        confirmCount: hazard.confirmCount != null ? hazard.confirmCount : hazard.confirmations
      }));
    });
  }

  function applyCommunityEvent(event) {
    if (!event || !event.opId || state.communityOps[event.opId]) return;
    state.communityOps[event.opId] = 1;
    if (event.op === "upsert") absorbCommunityReport(event.report);
    else if (event.op === "confirm") {
      const row = state.community.find(function (item) { return item.id === event.id; });
      if (row) row.confirmCount += 1;
    } else if (event.op === "clear") {
      const row = state.community.find(function (item) { return item.id === event.id; });
      if (row) {
        row.cleared = true;
        row.time = Math.max(row.time || 0, Number(event.time) || Date.now());
      }
    }
  }

  function absorbCommunityRelay(text) {
    String(text || "").split("\n").forEach(function (line) {
      if (!line.trim()) return;
      let row = null;
      try { row = JSON.parse(line); } catch (error) { return; }
      if (!row || row.event !== "message" || !row.message) return;
      let event = null;
      try { event = JSON.parse(row.message); } catch (error) { return; }
      if (!event.opId && row.id) event.opId = "ntfy-" + row.id;
      applyCommunityEvent(event);
    });
  }

  function publishCommunity(event) {
    applyCommunityEvent(event);
    saveCommunity();
    try { if (communityChannel) communityChannel.postMessage(event); } catch (error) {}
    if (navigator.onLine === false) {
      state.communityQueue.push(event);
      saveCommunityQueue();
      setCommunityNotice(COMMUNITY_QUEUED);
    } else {
      net(COMMUNITY_POST, { method: "POST", body: JSON.stringify(event) }).then(function () {
        setCommunityNotice(COMMUNITY_SYNCED);
        renderAll();
      }).catch(function () {
        state.communityQueue.push(event);
        saveCommunityQueue();
        setCommunityNotice(COMMUNITY_QUEUED);
        renderAll();
      });
    }
    renderAll();
  }

  function flushCommunityQueue() {
    if (state.communityFlushing || navigator.onLine === false || !state.communityQueue.length) return;
    state.communityFlushing = true;
    const event = state.communityQueue[0];
    net(COMMUNITY_POST, { method: "POST", body: JSON.stringify(event) }).then(function () {
      state.communityQueue.shift();
      saveCommunityQueue();
      state.communityFlushing = false;
      setCommunityNotice(COMMUNITY_SYNCED);
      renderAll();
      if (state.communityQueue.length) flushCommunityQueue();
    }).catch(function () {
      state.communityFlushing = false;
      setCommunityNotice(COMMUNITY_QUEUED);
      renderAll();
    });
  }

  function refreshCommunity(manual) {
    const jobs = [fetch("./community-reports.json").then(function (response) {
      if (!response.ok) throw new Error("seed");
      return response.json();
    }).catch(function () { return null; })];
    if (!SHOT && navigator.onLine !== false) {
      jobs.push(net(COMMUNITY_FEED).then(function (text) { return JSON.parse(text); }).catch(function () { return null; }));
      jobs.push(net(COMMUNITY_RELAY).then(function (body) { return body; }).catch(function () { return null; }));
    }
    return Promise.all(jobs).then(function (parts) {
      if (parts[0]) absorbCommunityFeed(parts[0]);
      if (parts[1]) absorbCommunityFeed(parts[1]);
      if (typeof parts[2] === "string") absorbCommunityRelay(parts[2]);
      saveCommunity();
      drawCommunity();
      if (manual) toast("Live conditions updated");
      renderAll();
    }).catch(function () {
      if (manual) toast("Live conditions stayed on this device");
    });
  }

  function confirmCommunity(id) {
    if (!id) return;
    publishCommunity({ v: 1, op: "confirm", opId: "c-" + Date.now().toString(36) + "-" + String(id).slice(0, 12), id: id });
  }

  function clearCommunity(id) {
    if (!id) return;
    publishCommunity({ v: 1, op: "clear", opId: "x-" + Date.now().toString(36) + "-" + String(id).slice(0, 12), id: id, time: Date.now() });
  }

  function communityBanner(trail) {
    if (!trail) return null;
    const rows = state.community.filter(function (item) { return item.trailId === trail.id && !item.cleared; });
    if (rows.some(function (item) { return item.status === "Gate Locked"; })) {
      return { kind: "gate", text: "🔒 GATE LOCKED (USER REPORT)" };
    }
    if (rows.some(function (item) { return item.status !== "Open & Clear" && item.status.indexOf("Pad") < 0; })) {
      return { kind: "obstacle", text: "⚠️ OBSTACLE REPORTED" };
    }
    return null;
  }

  function liveFlagHtml() {
    const flag = communityBanner(selected());
    if (!flag) return "";
    return '<div class="live-flag ' + flag.kind + '">' + flag.text + "</div>";
  }

  function communityListHtml(trail) {
    const rows = state.community.filter(function (item) { return item.trailId === trail.id && !item.cleared; })
      .sort(function (a, b) { return b.time - a.time; })
      .slice(0, 8);
    const cards = rows.map(function (item) {
      return '<div class="community-card"><b>' + esc(reportLabel(item.status)) + "</b><small>" + esc(item.rig) + " · " + esc(new Date(item.time).toLocaleString()) + '</small><div class="community-actions"><button type="button" data-act="still-here" data-id="' + esc(item.id) + '">👍 Still Here (' + item.confirmCount + ')</button><button type="button" data-act="mark-cleared" data-id="' + esc(item.id) + '">✅ Cleared / Gate Open</button></div></div>';
    }).join("");
    const noticeClass = state.communityNotice.indexOf("Synced") >= 0 ? "sync-ok" : "sync-wait";
    const notice = state.communityNotice ? '<div class="sub ' + noticeClass + '">' + esc(state.communityNotice) + "</div>" : "";
    const empty = cards ? "" : '<div class="sub">No active community reports on this trail.</div>';
    return '<div class="community"><button type="button" data-act="refresh-live">↻ Refresh Live Conditions</button>' + notice + cards + empty + "</div>";
  }

  function drawCommunity() {
    if (!communityLayer) return;
    communityLayer.clearLayers();
    state.community.forEach(function (item) {
      if (item.cleared || !Number.isFinite(item.lat) || !Number.isFinite(item.lon)) return;
      const gate = item.status === "Gate Locked";
      const icon = L.divIcon({
        className: "community-pin" + (gate ? " gate" : ""),
        html: "<span>" + esc(reportLabel(item.status)) + "</span>",
        iconAnchor: [18, 12]
      });
      const popup = '<div class="community-pop"><b>' + esc(reportLabel(item.status)) + "</b><div>" + esc(item.rig) + '</div><button type="button" data-act="still-here" data-id="' + esc(item.id) + '">👍 Still Here (' + item.confirmCount + ')</button><button type="button" data-act="mark-cleared" data-id="' + esc(item.id) + '">✅ Cleared / Gate Open</button></div>';
      L.marker([item.lat, item.lon], { icon: icon, zIndexOffset: 640 }).bindPopup(popup).addTo(communityLayer);
    });
  }

  function installCommunityChannel() {
    try {
      communityChannel = new BroadcastChannel("trailforge-community");
      communityChannel.onmessage = function (event) {
        if (!event || !event.data) return;
        applyCommunityEvent(event.data);
        saveCommunity();
        drawCommunity();
        renderAll();
      };
    } catch (error) { /* This WebView has no BroadcastChannel. */ }
  }

  function applyTripCode(text) {
    const raw = String(text || "").trim();
    let count = 0;
    const marker = "|R|";
    const at = raw.lastIndexOf(marker);
    if (at >= 0) {
      raw.slice(at + marker.length).split("|")[0].split(";").forEach(function (piece) {
        const bits = piece.split(",");
        if (bits.length < 4) return;
        const lat = Number(bits[0]);
        const lon = Number(bits[1]);
        if (!Number.isFinite(lat) || !Number.isFinite(lon)) return;
        absorbCommunityReport({
          id: "qr-" + bits[3] + "-" + lat.toFixed(4) + "-" + bits[2],
          trailId: bits[3],
          lat: lat,
          lon: lon,
          status: statusFromCode(bits[2]),
          kind: "hazard",
          rig: "Trip package",
          time: Date.now(),
          confirmCount: 1,
          cleared: false,
          note: "From a trailhead QR scan"
        });
        count += 1;
      });
      saveCommunity();
    }
    if (raw.indexOf("TF1|") === 0) {
      const line = (raw.split("|")[2] || "").split(";").map(function (pair) {
        const bits = pair.split(",");
        return { lat: Number(bits[0]), lon: Number(bits[1]), snapped: false, trailId: null };
      }).filter(function (point) { return Number.isFinite(point.lat) && Number.isFinite(point.lon); });
      if (line.length >= 2) {
        state.plot = line;
        state.plotting = true;
        state.drawer = "plot";
        drawPlot();
      }
    }
    drawCommunity();
    renderAll();
    toast(count ? "Trip package added " + count + " community pins" : "Trip code applied");
  }

  function queueReport(status) {
    const trail = selected();
    if (!trail || REPORTS.indexOf(status) < 0) return;
    const now = Date.now();
    state.reports.unshift({
      trailId: trail.id,
      status: status,
      time: now,
      lat: state.fix ? state.fix.lat : trail.lat,
      lon: state.fix ? state.fix.lon : trail.lon
    });
    state.reports = state.reports.slice(0, 40);
    localStorage.setItem("tf-reports", JSON.stringify(state.reports));
    const report = {
      id: "r-" + now.toString(36) + "-" + Math.floor(Math.random() * 1e6).toString(36),
      trailId: trail.id,
      lat: state.fix ? state.fix.lat : trail.lat,
      lon: state.fix ? state.fix.lon : trail.lon,
      status: status,
      kind: "condition",
      rig: state.rig.name || "Overland rig",
      time: now,
      confirmCount: 1,
      cleared: false,
      note: ""
    };
    if (status === "Open & Clear") {
      state.community.filter(function (item) { return item.trailId === trail.id && !item.cleared; }).forEach(function (item) {
        publishCommunity({ v: 1, op: "clear", opId: "open-" + report.id + "-" + item.id, id: item.id, time: now });
      });
    }
    publishCommunity({ v: 1, op: "upsert", opId: report.id, report: report });
  }

  function nearestVertex(latlng) {
    const origin = { lat: latlng.lat, lon: latlng.lng != null ? latlng.lng : latlng.lon };
    let best = null;
    let bestMeters = 400;
    let trailId = null;
    allTrails().forEach(function (trail) {
      (trail.coordinates || []).forEach(function (coord) {
        const distance = meters(origin, { lat: coord[0], lon: coord[1] });
        if (distance < bestMeters) {
          bestMeters = distance;
          best = { lat: coord[0], lon: coord[1] };
          trailId = trail.id;
        }
      });
    });
    return best ? { lat: best.lat, lon: best.lon, trailId: trailId } : null;
  }

  function plotFit() {
    const ids = {};
    state.plot.forEach(function (point) { if (point.trailId) ids[point.trailId] = true; });
    const keys = Object.keys(ids);
    if (!keys.length) return evaluate({ clearance: 9, canopy: 12, water: 6, locker: false, name: "custom route" });
    let worst = null;
    keys.forEach(function (id) {
      const trail = trailById(id);
      if (!trail) return;
      const fit = evaluate(trail);
      const rank = fit.verdict.indexOf("NO-GO") >= 0 ? 2 : fit.verdict === "CAUTION" ? 1 : 0;
      if (!worst || rank > worst.rank) worst = { rank: rank, fit: fit };
    });
    return worst ? worst.fit : evaluate({ clearance: 9, canopy: 12, water: 6, locker: false, name: "custom route" });
  }

  function plotSegmentKey(prev, next) {
    return Number(prev.lat).toFixed(5) + "," + Number(prev.lon).toFixed(5) + "->" + Number(next.lat).toFixed(5) + "," + Number(next.lon).toFixed(5);
  }

  function projectOntoSegment(point, start, end) {
    const latScale = 111320;
    const lonScale = 111320 * Math.cos(point.lat * Math.PI / 180);
    const ax = start.lon * lonScale;
    const ay = start.lat * latScale;
    const bx = end.lon * lonScale;
    const by = end.lat * latScale;
    const px = point.lon * lonScale;
    const py = point.lat * latScale;
    const dx = bx - ax;
    const dy = by - ay;
    const length2 = dx * dx + dy * dy;
    const t = length2 > 1 ? Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / length2)) : 0;
    return {
      lat: start.lat + (end.lat - start.lat) * t,
      lon: start.lon + (end.lon - start.lon) * t
    };
  }

  function projectOntoTrail(point, coordinates) {
    let best = null;
    for (let index = 0; index < coordinates.length - 1; index += 1) {
      const start = { lat: coordinates[index][0], lon: coordinates[index][1] };
      const end = { lat: coordinates[index + 1][0], lon: coordinates[index + 1][1] };
      const hit = projectOntoSegment(point, start, end);
      const distance = meters(point, hit);
      if (!best || distance < best.distance) best = { index: index, lat: hit.lat, lon: hit.lon, distance: distance };
    }
    return best;
  }

  function trailBoxContains(coordinates, prev, next, limitMeters) {
    if (!coordinates || !coordinates.length) return false;
    let minLat = coordinates[0][0];
    let maxLat = coordinates[0][0];
    let minLon = coordinates[0][1];
    let maxLon = coordinates[0][1];
    for (let index = 1; index < coordinates.length; index += 1) {
      minLat = Math.min(minLat, coordinates[index][0]);
      maxLat = Math.max(maxLat, coordinates[index][0]);
      minLon = Math.min(minLon, coordinates[index][1]);
      maxLon = Math.max(maxLon, coordinates[index][1]);
    }
    const midLat = (Number(prev.lat) + Number(next.lat)) / 2;
    const dLat = limitMeters / 111320;
    const dLon = limitMeters / (111320 * Math.max(0.2, Math.cos(midLat * Math.PI / 180)));
    function inside(point) {
      return point.lat >= minLat - dLat && point.lat <= maxLat + dLat && point.lon >= minLon - dLon && point.lon <= maxLon + dLon;
    }
    return inside(prev) && inside(next);
  }

  function dedupeLine(line) {
    const cleaned = [];
    line.forEach(function (point) {
      const last = cleaned[cleaned.length - 1];
      if (last && meters(last, point) < 8) return;
      cleaned.push(point);
    });
    return cleaned;
  }

  function trailSlice(prev, next, coordinates) {
    if (!coordinates || coordinates.length < 2) return [];
    if (!trailBoxContains(coordinates, prev, next, 1200)) return [];
    const startHit = projectOntoTrail(prev, coordinates);
    const endHit = projectOntoTrail(next, coordinates);
    if (!startHit || !endHit || startHit.distance > 1200 || endHit.distance > 1200) return [];
    const line = [{ lat: Number(prev.lat), lon: Number(prev.lon) }, { lat: startHit.lat, lon: startHit.lon }];
    if (startHit.index < endHit.index) {
      for (let index = startHit.index + 1; index <= endHit.index; index += 1) {
        line.push({ lat: coordinates[index][0], lon: coordinates[index][1] });
      }
    } else if (startHit.index > endHit.index) {
      for (let index = startHit.index; index >= endHit.index + 1; index -= 1) {
        line.push({ lat: coordinates[index][0], lon: coordinates[index][1] });
      }
    }
    line.push({ lat: endHit.lat, lon: endHit.lon }, { lat: Number(next.lat), lon: Number(next.lon) });
    const cleaned = dedupeLine(line);
    const direct = Math.max(meters(prev, next), 1);
    if (polylineMeters(cleaned) > direct * 8) return [];
    return cleaned;
  }

  function bestTrailSlice(prev, next) {
    const chosen = selected();
    const trails = allTrails();
    const ordered = chosen ? [chosen].concat(trails.filter(function (trail) { return trail.id !== chosen.id; })) : trails;
    let best = null;
    ordered.forEach(function (trail) {
      const slice = trailSlice(prev, next, trail.coordinates);
      if (slice.length < 2) return;
      const closeness = meters(prev, slice[Math.min(1, slice.length - 1)]) + meters(next, slice[Math.max(0, slice.length - 2)]);
      if (!best || closeness < best.closeness) best = { closeness: closeness, line: slice };
    });
    return best ? best.line : [];
  }

  function fetchPlotRoad(prev, next, key) {
    if (plotRoutePending[key]) return;
    plotRoutePending[key] = true;
    const bases = drivingRouteBases();
    const path = prev.lon + "," + prev.lat + ";" + next.lon + "," + next.lat + "?overview=full&geometries=geojson&steps=true";
    function tryIndex(index) {
      if (index >= bases.length) {
        plotRoutePending[key] = false;
        drawPlot();
        return;
      }
      fetch(bases[index] + path).then(function (response) { return response.json(); }).then(function (data) {
        const coords = data && data.code === "Ok" && data.routes && data.routes[0] && data.routes[0].geometry && data.routes[0].geometry.coordinates;
        const road = coords && coords.length >= 2 ? coords.map(function (pair) { return [pair[1], pair[0]]; }) : null;
        if (road && roadLooksDrivable(road, prev)) {
          plotRoutePending[key] = false;
          plotRouteCache[key] = road;
          drawPlot();
          renderDrawer();
          return;
        }
        tryIndex(index + 1);
      }).catch(function () { tryIndex(index + 1); });
    }
    tryIndex(0);
  }

  function resolvePlotSegment(prev, next) {
    const free = prev.mode === "freehand" || next.mode === "freehand";
    if (free) return [[Number(prev.lat), Number(prev.lon)], [Number(next.lat), Number(next.lon)]];
    const slice = bestTrailSlice(prev, next);
    if (slice.length >= 3) return slice.map(function (point) { return [point.lat, point.lon]; });
    const key = plotSegmentKey(prev, next);
    if (plotRouteCache[key] && plotRouteCache[key].length >= 2 && roadLooksDrivable(plotRouteCache[key], prev)) return plotRouteCache[key];
    fetchPlotRoad(prev, next, key);
    if (slice.length >= 2) return slice.map(function (point) { return [point.lat, point.lon]; });
    return [[Number(prev.lat), Number(prev.lon)], [Number(next.lat), Number(next.lon)]];
  }

  function fullPlotPolyline() {
    if (state.plot.length < 2) return state.plot.map(function (point) { return { lat: point.lat, lon: point.lon }; });
    const line = [];
    for (let index = 1; index < state.plot.length; index += 1) {
      resolvePlotSegment(state.plot[index - 1], state.plot[index]).forEach(function (pair, pairIndex) {
        if (line.length && pairIndex === 0) return;
        line.push({ lat: pair[0], lon: pair[1] });
      });
    }
    return line;
  }

  function plotMeters() {
    return polylineMeters(fullPlotPolyline());
  }

  function plotWaypointRowsHtml() {
    return state.plot.map(function (point, index) {
      return '<div class="place-card"><div class="meta"><b>Waypoint ' + (index + 1) + "</b><small>" + esc(formatPair(point) || "") + '</small></div><div class="actions"><button type="button" class="end" data-act="del-waypoint" data-idx="' + index + '">✕ Delete</button></div></div>';
    }).join("");
  }

  function plotWaypointsHtml() {
    if (!state.plot.length) return "";
    return '<div class="marker-list"><b>Plotted Route Waypoints</b><div class="actions"><button type="button" data-act="undo-plot">Undo Last Waypoint</button><button type="button" class="end" data-act="clear-plot">Delete All Waypoints</button></div>' + plotWaypointRowsHtml() + "</div>";
  }

  function drawPlot() {
    if (!plotLayer) return;
    plotLayer.clearLayers();
    for (let index = 1; index < state.plot.length; index += 1) {
      const prev = state.plot[index - 1];
      const next = state.plot[index];
      const free = prev.mode === "freehand" || next.mode === "freehand";
      const line = resolvePlotSegment(prev, next);
      const drawn = line && line.length >= 2 ? line : [[Number(prev.lat), Number(prev.lon)], [Number(next.lat), Number(next.lon)]];
      L.polyline(drawn, { color: "#3a2a08", weight: 7, opacity: 0.9, lineCap: "round", lineJoin: "round", dashArray: free ? "6 8" : null }).addTo(plotLayer);
      L.polyline(drawn, { color: "#fbbf24", weight: 4.5, opacity: 1, lineCap: "round", lineJoin: "round", dashArray: free ? "6 8" : null }).addTo(plotLayer);
    }
    state.plot.forEach(function (point, index) {
      const icon = L.divIcon({ className: "flag-pin", html: "<span>" + (index + 1) + "</span>", iconAnchor: [12, 12] });
      const popup = "<b>Waypoint " + (index + 1) + "</b><div>" + esc(formatPair(point) || "") + '</div><button type="button" class="end" data-act="del-waypoint" data-idx="' + index + '">🗑️ Delete Waypoint</button>';
      L.marker([point.lat, point.lon], { icon: icon, zIndexOffset: 640 }).bindPopup(popup).addTo(plotLayer);
    });
  }

  function syncNavArrow() {
    const heading = state.compass == null || !Number.isFinite(Number(state.compass)) ? 0 : Number(state.compass);
    const compass = document.getElementById("compassArrow");
    if (compass) compass.style.transform = "rotate(" + ((-heading % 360) + 360) % 360 + "deg)";
    const locate = document.getElementById("locateArrow");
    if (locate) locate.style.transform = "rotate(" + ((heading % 360) + 360) % 360 + "deg)";
  }

  function markersForPlot() {
    const markers = state.savedMarkers.slice();
    if (!map || markers.length < 2) return [];
    const center = map.getCenter();
    const origin = { lat: center.lat, lon: center.lng };
    const limit = 50 * 1609.344;
    return markers.filter(function (marker) {
      return meters(origin, marker) <= limit;
    });
  }

  function seedPlotFromMarkers() {
    const markers = markersForPlot();
    if (markers.length < 2) return false;
    const ordered = markers.slice().sort(function (a, b) { return (a.createdAt || 0) - (b.createdAt || 0); });
    const mode = state.plotMode === "freehand" ? "freehand" : "snap";
    state.plot = ordered.map(function (marker) {
      return { lat: marker.lat, lon: marker.lon, snapped: false, trailId: null, mode: mode, name: marker.name };
    });
    return true;
  }

  function connectSavedWaypoints() {
    state.plotClearedByUser = false;
    state.plotting = true;
    state.drawer = "plot";
    leaveFullDetent();
    if (!seedPlotFromMarkers()) {
      toast("Save at least two waypoints within 50 miles");
      renderDrawer();
      applyChrome();
      return;
    }
    drawPlot();
    renderDrawer();
    applyChrome();
    renderSheet();
    toast("Connected " + state.plot.length + " saved waypoints");
  }

  function connectPlotWaypoint(lat, lon) {
    if (!Number.isFinite(Number(lat)) || !Number.isFinite(Number(lon))) return;
    const mode = state.plotMode === "freehand" ? "freehand" : "snap";
    state.plot.push({ lat: Number(lat), lon: Number(lon), snapped: false, trailId: null, mode: mode });
    drawPlot();
    renderDrawer();
    renderSheet();
    toast("Connected waypoint to plotted route");
  }

  function onMapClick(event) {
    if (state.plotting) {
      const mode = state.plotMode === "freehand" ? "freehand" : "snap";
      const hit = mode === "snap" ? nearestVertex(event.latlng) : null;
      const point = hit
        ? { lat: hit.lat, lon: hit.lon, snapped: true, trailId: hit.trailId, mode: mode }
        : { lat: event.latlng.lat, lon: event.latlng.lng, snapped: false, trailId: null, mode: mode };
      state.plot.push(point);
      drawPlot();
      renderDrawer();
      const prefix = mode === "freehand" ? "Freehand · " : (point.snapped ? "Snapped · " : "Off trail · ");
      toast(prefix + shortFit(plotFit().verdict));
      return;
    }
  }

  function gpxXml(name, points, waypoints) {
    const body = points.map(function (point) {
      return '<trkpt lat="' + Number(point.lat).toFixed(6) + '" lon="' + Number(point.lon).toFixed(6) + '"></trkpt>';
    }).join("");
    const marks = (waypoints || []).map(function (point) {
      return '<wpt lat="' + Number(point.lat).toFixed(6) + '" lon="' + Number(point.lon).toFixed(6) + '"><name>' + esc(point.name || "") + "</name><sym>" + esc(point.sym || "") + "</sym><type>" + esc(point.type || "") + "</type><desc>" + esc(point.desc || "") + "</desc></wpt>";
    }).join("");
    return '<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="TrailForge Overland" xmlns="http://www.topografix.com/GPX/1/1">\n' + marks + "<trk><name>" + esc(name) + "</name><trkseg>" + body + "</trkseg></trk>\n</gpx>\n";
  }

  function exportGpx() {
    if (state.plot.length < 2) { toast("Plot at least two points"); return; }
    const trail = selected();
    const xml = gpxXml(trail ? trail.name + " custom" : "TrailForge route", fullPlotPolyline(), collectWaypoints(trail));
    const blob = new Blob([xml], { type: "application/gpx+xml" });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = "TrailForge-route.gpx";
    document.body.appendChild(link);
    link.click();
    link.remove();
    setTimeout(function () { URL.revokeObjectURL(url); }, 1500);
    fallbackCopy(xml, function () { toast("GPX 1.1 exported"); });
  }

  function importGpx(text) {
    const xml = new DOMParser().parseFromString(text, "text/xml");
    if (!xml || xml.getElementsByTagName("parsererror").length) { toast("That file is not GPX"); return; }
    const points = [];
    const nodes = xml.getElementsByTagName("*");
    for (let index = 0; index < nodes.length; index += 1) {
      const local = nodes[index].localName;
      if (local !== "trkpt" && local !== "rtept" && local !== "wpt") continue;
      const lat = Number(nodes[index].getAttribute("lat"));
      const lon = Number(nodes[index].getAttribute("lon"));
      if (!Number.isFinite(lat) || !Number.isFinite(lon)) continue;
      if (local === "wpt") {
        const named = nodes[index].getElementsByTagName("name")[0];
        const title = named && named.textContent ? named.textContent : "";
        if (title.indexOf("TFCR|") === 0) {
          const parts = title.split("|");
          if (parts.length >= 5) {
            absorbCommunityReport({
              id: "gpx-" + parts[2] + "-" + lat.toFixed(4),
              trailId: parts[2],
              lat: lat,
              lon: lon,
              status: parts[1],
              kind: "hazard",
              rig: "Trip package",
              time: Date.now(),
              confirmCount: Number(parts[3]) || 1,
              cleared: parts[4] === "1",
              note: "From a trip package"
            });
            saveCommunity();
          }
          continue;
        }
      }
      const hit = nearestVertex({ lat: lat, lng: lon });
      points.push({ lat: lat, lon: lon, snapped: false, trailId: hit ? hit.trailId : null });
    }
    if (!points.length) { toast("No GPX points found"); return; }
    state.plot = points;
    state.plotting = true;
    state.drawer = "plot";
    drawPlot();
    renderDrawer();
    applyChrome();
    if (map) map.fitBounds(points.map(function (point) { return [point.lat, point.lon]; }), { padding: [28, 28] });
    toast("Imported " + points.length + " GPX points · " + shortFit(plotFit().verdict));
  }

  let packDbPromise = null;
  function packDb() {
    if (!packDbPromise) {
      packDbPromise = new Promise(function (resolve, reject) {
        if (!window.indexedDB) { reject(new Error("no indexedDB")); return; }
        const request = indexedDB.open("trailforge-offline", 1);
        request.onupgradeneeded = function () {
          if (!request.result.objectStoreNames.contains("tiles")) request.result.createObjectStore("tiles");
        };
        request.onsuccess = function () { resolve(request.result); };
        request.onerror = function () { packDbPromise = null; reject(request.error); };
      });
    }
    return packDbPromise;
  }

  function idbGet(key) {
    return packDb().then(function (db) {
      return new Promise(function (resolve, reject) {
        const request = db.transaction("tiles", "readonly").objectStore("tiles").get(key);
        request.onsuccess = function () { resolve(request.result || null); };
        request.onerror = function () { reject(request.error); };
      });
    });
  }

  function idbPut(key, value) {
    return packDb().then(function (db) {
      return new Promise(function (resolve, reject) {
        const tx = db.transaction("tiles", "readwrite");
        tx.objectStore("tiles").put(value, key);
        tx.oncomplete = function () { resolve(); };
        tx.onerror = function () { reject(tx.error); };
      });
    });
  }

  function idbDelete(key) {
    return packDb().then(function (db) {
      return new Promise(function (resolve, reject) {
        const tx = db.transaction("tiles", "readwrite");
        tx.objectStore("tiles").delete(key);
        tx.oncomplete = function () { resolve(); };
        tx.onerror = function () { reject(tx.error); };
      });
    });
  }

  function netBlob(url) {
    let timer = null;
    const request = window.TrailForgeNet && TrailForgeNet.fetchBytes
      ? new Promise(function (resolve, reject) {
        const id = "b" + (++netSeq);
        pendingNet.set(id, { resolve: resolve, reject: reject, binary: true });
        TrailForgeNet.fetchBytes(id, url);
      })
      : fetch(url).then(function (response) {
        if (!response.ok) throw new Error("HTTP " + response.status);
        return response.blob();
      });
    request.catch(function () {});
    const timeout = new Promise(function (_, reject) {
      timer = setTimeout(function () { reject(new Error("timeout")); }, 20000);
    });
    timeout.catch(function () {});
    return Promise.race([request, timeout]).finally(function () { clearTimeout(timer); });
  }

  function squareBounds(lat, lon, sqMiles) {
    const half = Math.sqrt(Math.max(sqMiles, 0.1)) * 1609.344 / 2;
    const dLat = half / 111320;
    const dLon = half / (111320 * Math.max(0.2, Math.cos(lat * Math.PI / 180)));
    return { minLat: lat - dLat, maxLat: lat + dLat, minLon: lon - dLon, maxLon: lon + dLon };
  }

  function boxSqMiles(box) {
    const mid = (box.minLat + box.maxLat) / 2;
    const height = (box.maxLat - box.minLat) * 111320 / 1609.344;
    const width = (box.maxLon - box.minLon) * 111320 * Math.cos(mid * Math.PI / 180) / 1609.344;
    return Math.max(0, height * width);
  }

  function currentViewBounds() {
    if (!map) return null;
    const bounds = map.getBounds();
    return { minLat: bounds.getSouth(), maxLat: bounds.getNorth(), minLon: bounds.getWest(), maxLon: bounds.getEast() };
  }

  function liveAreaBox() {
    if (!map || state.packArea === "corridor") return null;
    const box = currentViewBounds();
    if (!box) return null;
    box.sqMiles = boxSqMiles(box);
    box.mode = "view";
    return box;
  }

  function currentScreenLabel() {
    const bounds = currentViewBounds();
    const miles = bounds ? Math.round(boxSqMiles(bounds)) : 0;
    return "Current Screen View (~" + miles + " sq mi)";
  }

  function areaChoiceLabel() {
    const box = liveAreaBox();
    if (!box) return "5-Mi Route Corridor";
    if (box.mode === "view") return currentScreenLabel();
    return "5-Mi Route Corridor";
  }

  function areaZooms(box) {
    if (!box || box.sqMiles <= 45) return [11, 12, 13, 14, 15];
    return [11, 12, 13, 14];
  }

  function lonTile(lon, zoom) {
    const n = 2 ** zoom;
    return Math.floor((lon + 180) / 360 * n);
  }

  function latTile(lat, zoom) {
    const n = 2 ** zoom;
    const rad = lat * Math.PI / 180;
    return Math.floor((1 - Math.log(Math.tan(rad) + 1 / Math.cos(rad)) / Math.PI) / 2 * n);
  }

  function areaBoxTiles(center, sqMiles, zoomLevels, bounds) {
    const box = bounds || squareBounds(center.lat, center.lon, sqMiles);
    const tiles = [];
    const seen = new Set();
    let capped = false;
    const levels = zoomLevels && zoomLevels.length ? zoomLevels : [11, 12, 13, 14];
    for (let index = 0; index < levels.length && !capped; index += 1) {
      const zoom = levels[index];
      const n = 2 ** zoom;
      let minX = lonTile(box.minLon, zoom);
      let maxX = lonTile(box.maxLon, zoom);
      let northY = latTile(box.maxLat, zoom);
      let southY = latTile(box.minLat, zoom);
      if (minX > maxX) { const swap = minX; minX = maxX; maxX = swap; }
      if (northY > southY) { const swap = northY; northY = southY; southY = swap; }
      for (let x = minX; x <= maxX && !capped; x += 1) {
        for (let y = northY; y <= southY; y += 1) {
          if (y < 0 || y >= n) continue;
          const wrapped = ((x % n) + n) % n;
          const key = zoom + "/" + wrapped + "/" + y;
          if (seen.has(key)) continue;
          seen.add(key);
          tiles.push({ x: wrapped, y: y, z: zoom });
          if (tiles.length >= 600) { capped = true; break; }
        }
      }
    }
    return { tiles: tiles, capped: capped, bounds: box };
  }

  function featuresInside(box) {
    const trails = allTrails().filter(function (trail) {
      const lat = Number(trail.lat);
      const lon = Number(trail.lon);
      if (Number.isFinite(lat) && Number.isFinite(lon) && lat >= box.minLat && lat <= box.maxLat && lon >= box.minLon && lon <= box.maxLon) return true;
      return (trail.coordinates || []).some(function (point) {
        return point[0] >= box.minLat && point[0] <= box.maxLat && point[1] >= box.minLon && point[1] <= box.maxLon;
      });
    }).slice(0, 40);
    const camps = [];
    trails.forEach(function (trail) {
      (trail.flatCamps || []).forEach(function (camp) {
        if (camp.lat >= box.minLat && camp.lat <= box.maxLat && camp.lon >= box.minLon && camp.lon <= box.maxLon) camps.push(camp);
      });
    });
    return { trails: trails, camps: camps };
  }

  function areaEstimateText() {
    const box = liveAreaBox();
    if (!box) return "5-mile buffer along the selected trail, backcountry corridor, or active GPS route.";
    const plan = areaBoxTiles({ lat: (box.minLat + box.maxLat) / 2, lon: (box.minLon + box.maxLon) / 2 }, box.sqMiles, areaZooms(box), box);
    const inside = featuresInside(box);
    const mb = Math.max(1, Math.round(plan.tiles.length * 20 / 1024));
    const cap = plan.capped ? " · capped at 600 tiles" : "";
    return areaChoiceLabel() + " · ~" + plan.tiles.length + " tiles · " + inside.trails.length + " trails · ~" + mb + " MB" + cap;
  }

  function offlinePreviewVisible() {
    return state.drawer === "corridor" || state.drawer === "offline" || !!state.packBusy;
  }

  function syncAreaPreview() {
    if (!map || !window.L) return;
    if (!areaPreviewLayer) areaPreviewLayer = L.layerGroup().addTo(map);
    areaPreviewLayer.clearLayers();
    if (!offlinePreviewVisible()) return;
    state.packs.forEach(function (pack) {
      if (pack.minLat == null) return;
      L.rectangle([[pack.minLat, pack.minLon], [pack.maxLat, pack.maxLon]], {
        color: "#e2b657",
        weight: 2,
        dashArray: "4 6",
        fill: false,
        interactive: false
      }).addTo(areaPreviewLayer);
    });
    const box = liveAreaBox();
    if (!box) return;
    L.rectangle([[box.minLat, box.minLon], [box.maxLat, box.maxLon]], {
      color: "#3ecbff",
      weight: 3,
      dashArray: "8 6",
      fillColor: "#3ecbff",
      fillOpacity: 0.12,
      interactive: false
    }).addTo(areaPreviewLayer);
  }

  function refreshAreaChrome() {
    syncAreaPreview();
    const estimate = document.getElementById("packEstimate");
    if (estimate) estimate.textContent = areaEstimateText();
    const viewBtn = document.querySelector('[data-act="pack-area"][data-id="view"]');
    if (viewBtn) viewBtn.textContent = currentScreenLabel();
  }

  function corridorLine() {
    if (state.route) {
      const line = roadAndSpur(state.route);
      if (line && line.length >= 2) {
        return { name: state.route.destination.name || "Active route", coords: line, trailId: state.route.destination.trailID || state.selectedId };
      }
    }
    const trail = selected();
    if (trail && trail.coordinates && trail.coordinates.length >= 2) return { name: trail.name, coords: trail.coordinates, trailId: trail.id };
    return null;
  }

  function corridorTiles(coords, zoom) {
    const wanted = new Set();
    let capped = false;
    const n = 2 ** zoom;
    function add(lat, lon) {
      const x = Math.floor(((lon + 180) / 360) * n);
      const latRad = lat * Math.PI / 180;
      const y = Math.floor((1 - Math.log(Math.tan(latRad) + 1 / Math.cos(latRad)) / Math.PI) / 2 * n);
      const metersPerTile = 40075016.68557849 * Math.cos(latRad) / n;
      const radius = Math.max(1, Math.ceil(8046.72 / metersPerTile));
      for (let dx = -radius; dx <= radius; dx += 1) {
        for (let dy = -radius; dy <= radius; dy += 1) {
          const tileY = y + dy;
          if (tileY < 0 || tileY >= n) continue;
          const tileX = ((x + dx) % n + n) % n;
          wanted.add(tileX + "/" + tileY);
          if (wanted.size >= 220) { capped = true; return true; }
        }
      }
      return false;
    }
    if (coords.length) add(coords[0][0], coords[0][1]);
    for (let index = 1; index < coords.length && !capped; index += 1) {
      const steps = Math.max(1, Math.ceil(meters(coords[index - 1], coords[index]) / 3218.69));
      for (let step = 1; step <= steps && !capped; step += 1) {
        const t = step / steps;
        const lat = coords[index - 1][0] + (coords[index][0] - coords[index - 1][0]) * t;
        const lon = coords[index - 1][1] + (coords[index][1] - coords[index - 1][1]) * t;
        add(lat, lon);
      }
    }
    return {
      capped: capped,
      tiles: Array.from(wanted).map(function (key) {
        const parts = key.split("/");
        return { x: Number(parts[0]), y: Number(parts[1]), z: zoom };
      })
    };
  }

  async function fetchTilePlan(plan, kind) {
    const keys = [];
    let bytes = 0;
    let failed = 0;
    const root = kind === "satellite"
      ? "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/"
      : "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/";
    const status = document.getElementById("packStatus");
    for (let index = 0; index < plan.tiles.length; index += 3) {
      const batch = plan.tiles.slice(index, index + 3);
      await Promise.all(batch.map(function (tile) {
        const key = kind + "/" + tile.z + "/" + tile.x + "/" + tile.y;
        return idbGet(key).then(function (existing) {
          if (existing) { keys.push(key); bytes += existing.size || 0; return; }
          return netBlob(root + tile.z + "/" + tile.y + "/" + tile.x).then(function (blob) {
            return idbPut(key, blob).then(function () { keys.push(key); bytes += blob.size || 0; });
          });
        }).catch(function () { failed += 1; });
      }));
      if (status) status.textContent = Math.min(plan.tiles.length, index + batch.length) + " / " + plan.tiles.length + " tiles";
    }
    return { keys: keys, bytes: bytes, failed: failed };
  }

  async function downloadCorridor() {
    if (state.packBusy) { toast("An offline download is already running"); return; }
    if (state.packArea !== "corridor") {
      await downloadAreaPack();
      return;
    }
    const line = corridorLine();
    if (!line) { toast("Select a trail or start a route first"); return; }
    const kind = state.packKind === "satellite" ? "satellite" : "topo";
    const zoom = kind === "satellite" ? 14 : 13;
    if (window.Notification && Notification.permission === "default") {
      try { Notification.requestPermission(); } catch (error) { /* Permission stays at the default. */ }
    }
    const plan = corridorTiles(line.coords, zoom);
    if (!plan.tiles.length) { toast("No tiles for this corridor"); return; }
    state.packBusy = true;
    renderDrawer();
    let saved = { keys: [], bytes: 0, failed: 0 };
    try {
      saved = await fetchTilePlan(plan, kind);
    } finally {
      state.packBusy = false;
      syncAreaPreview();
    }
    const keys = saved.keys;
    const bytes = saved.bytes;
    const failed = saved.failed;
    if (keys.length) {
      state.packs.unshift({
        id: "pack-" + Date.now(),
        name: line.name,
        kind: kind,
        zoom: zoom,
        tiles: keys.length,
        bytes: bytes,
        created: Date.now(),
        trailId: line.trailId,
        keys: keys
      });
      state.packs = state.packs.slice(0, 12);
      savePacks();
    }
    if (offlineLayer) offlineLayer.redraw();
    renderDrawer();
    const cap = plan.capped ? " Capped at 220 tiles." : "";
    if (keys.length) {
      toast("Saved " + keys.length + " USGS public-domain tiles for " + line.name + "." + cap);
      if (window.Notification && Notification.permission === "granted") {
        try { new Notification("TrailForge corridor ready", { body: "Saved " + keys.length + " USGS public-domain tiles for " + line.name }); } catch (error) { /* The toast already confirmed the save. */ }
      }
    }
    else toast(failed ? "Corridor download failed" : "No tiles saved");
  }

  async function downloadAreaPack() {
    const box = liveAreaBox();
    if (!box || !map) { toast("Pan the map to choose an area first"); return; }
    const kind = state.packKind === "satellite" ? "satellite" : "topo";
    const center = map.getCenter();
    const plan = areaBoxTiles({ lat: center.lat, lon: center.lng }, box.sqMiles, areaZooms(box), box);
    if (!plan.tiles.length) { toast("No tiles in this area"); return; }
    if (window.Notification && Notification.permission === "default") {
      try { Notification.requestPermission(); } catch (error) { /* Permission stays at the default. */ }
    }
    const inside = featuresInside(box);
    const label = areaChoiceLabel();
    const style = kind === "satellite" ? "Satellite" : "Topo";
    state.packBusy = true;
    renderDrawer();
    let saved = { keys: [], bytes: 0, failed: 0 };
    try {
      saved = await fetchTilePlan(plan, kind);
    } finally {
      state.packBusy = false;
      syncAreaPreview();
    }
    if (saved.keys.length) {
      state.packs.unshift({
        id: "pack-" + Date.now(),
        name: label,
        kind: kind,
        zoom: plan.tiles[0].z,
        tiles: saved.keys.length,
        bytes: saved.bytes,
        created: Date.now(),
        trailId: inside.trails[0] ? inside.trails[0].id : state.selectedId,
        keys: saved.keys,
        mode: box.mode,
        areaSqMiles: Math.round(box.sqMiles),
        minLat: box.minLat,
        maxLat: box.maxLat,
        minLon: box.minLon,
        maxLon: box.maxLon,
        trailCount: inside.trails.length,
        campCount: inside.camps.length,
        badge: label + " • " + style + " + Trails",
        trails: inside.trails.map(function (trail) { return { id: trail.id, name: trail.name }; })
      });
      state.packs = state.packs.slice(0, 12);
      savePacks();
    }
    if (offlineLayer) offlineLayer.redraw();
    syncAreaPreview();
    renderDrawer();
    const cap = plan.capped ? " Capped at 600 tiles." : "";
    if (saved.keys.length) {
      toast("Saved " + saved.keys.length + " tiles for " + label + "." + cap);
      if (window.Notification && Notification.permission === "granted") {
        try { new Notification("TrailForge offline area ready", { body: label + " · " + saved.keys.length + " tiles" }); } catch (error) { /* The toast already confirmed the save. */ }
      }
    } else toast(saved.failed ? "Area download failed" : "No tiles saved");
  }

  async function dropPack(id) {
    const pack = state.packs.find(function (item) { return item.id === id; });
    state.packs = state.packs.filter(function (item) { return item.id !== id; });
    savePacks();
    if (pack && pack.keys) {
      for (let index = 0; index < pack.keys.length; index += 1) {
        try { await idbDelete(pack.keys[index]); } catch (error) { /* The tile is already gone. */ }
      }
    }
    if (offlineLayer) offlineLayer.redraw();
    renderDrawer();
    toast("Corridor removed from this device");
  }

  function alongTrack(coords, fraction) {
    const index = Math.min(coords.length - 1, Math.max(0, Math.round(fraction * (coords.length - 1))));
    return { lat: coords[index][0], lon: coords[index][1] };
  }

  function trailDifficulty(trail) {
    if (!trail) return "easy";
    const id = String(trail.id || "");
    if (trail.live || id.indexOf("osm-") === 0 || id.indexOf("usfs-") === 0) return "easy";
    const clearance = Number(trail.clearance) || 0;
    const water = Number(trail.water) || 0;
    if (trail.locker && clearance >= 11.5) return "extreme";
    if (trail.locker || clearance >= 10.5 || water >= 18) return "hard";
    if (clearance >= 9 || water >= 8) return "moderate";
    return "easy";
  }

  function cruxPins(trail) {
    const coords = trail && trail.coordinates;
    if (!coords || coords.length < 2) return [];
    const difficulty = trailDifficulty(trail);
    if (difficulty === "easy") return [];
    const pins = [];
    const gate = String(trail.gate || "OPEN").toUpperCase();
    if (gate !== "OPEN" && gate !== "CHECK") {
      pins.push(Object.assign({
        id: trail.id + "-gate",
        short: "🔒 Gate",
        title: "🔒 Gate — " + trail.gate,
        speak: "Gate ahead. Status " + trail.gate + "."
      }, alongTrack(coords, 0.18)));
    }
    if (Number(trail.water) > 0) {
      const inches = Math.max(1, Math.round(Number(trail.water)));
      pins.push(Object.assign({
        id: trail.id + "-ford",
        short: "💧 " + inches + '"',
        title: "💧 Obstacle: " + inches + '" Creek Ford — Check USGS Gauge',
        speak: inches + " inch creek ford. Check the USGS gauge."
      }, alongTrack(coords, 0.38)));
    }
    if (difficulty === "hard" || difficulty === "extreme") {
      const fit = evaluate(trail);
      const main = fit.verdict.indexOf("NO-GO") >= 0 ? "No-Go" : fit.verdict === "CAUTION" ? "Caution" : "Fits";
      const inches = Math.max(1, Math.round(Number(trail.clearance) || 0));
      pins.push(Object.assign({
        id: trail.id + "-rock",
        short: "🪨 " + inches + '"',
        title: "🪨 Obstacle: " + inches + '" Rock Ledge — Main Line: ' + main + " / Bypass: Walk it first",
        speak: inches + " inch rock ledge. Main line " + main + ". Walk the bypass before you commit."
      }, alongTrack(coords, 0.62)));
    }
    return pins;
  }

  function contextNear(point) {
    if (!point) return false;
    const here = { lat: Number(point.lat), lon: Number(point.lon) };
    if (!Number.isFinite(here.lat) || !Number.isFinite(here.lon)) return false;
    if (map && map.getBounds && map.getBounds().pad(0.2).contains([here.lat, here.lon])) return true;
    if (meters(mapCenter(), here) <= 40000) return true;
    if (state.fix && !state.fix.shotOnly && meters(state.fix, here) <= 40000) return true;
    return false;
  }

  function trailIsNearContext(trail) {
    if (!trail) return false;
    const bounds = map && map.getBounds ? map.getBounds().pad(0.35) : null;
    if (bounds && trailInView(trail, bounds)) return true;
    if (meters(mapCenter(), trail) <= 40000) return true;
    if (state.fix && !state.fix.shotOnly && meters(state.fix, trail) <= 40000) return true;
    return false;
  }

  function visibleCruxPins() {
    const seen = {};
    const pins = [];
    allTrails().forEach(function (trail) {
      if (!trail || seen[trail.id] || !trailIsNearContext(trail)) return;
      seen[trail.id] = true;
      cruxPins(trail).forEach(function (pin) {
        if (seen[pin.id] || !contextNear(pin)) return;
        seen[pin.id] = true;
        pins.push(pin);
      });
    });
    return pins;
  }

  function speakHazards() {
    if (!state.fix || (!state.route && !state.follow)) return;
    const trail = selected();
    if (!trail) return;
    visibleCruxPins().forEach(function (pin) {
      if (state.spokenHazards[pin.id]) return;
      const distance = meters(state.fix, pin) / 1609.344;
      if (distance > 0.15) return;
      state.spokenHazards[pin.id] = true;
      speak(pin.speak + " About " + Math.max(1, Math.round(distance * 5280)) + " feet.");
    });
  }

  function mvumBadge(trail) {
    if (state.mvum && state.mvum.trailId === trail.id && state.mvum.hit) {
      return "✅ USFS MVUM / BLM Verified • Seasonal Open Window" + (state.mvum.window ? " · " + state.mvum.window : "");
    }
    const osm = !!trail.live && (String(trail.id).indexOf("osm-") === 0 || /openstreetmap/i.test(trail.agency || ""));
    if (osm) return "⚠️ Unverified OSM Track — Check Local MVUM & Gate Status";
    if (trail.bdr || /usfs|blm|forest|bureau|dnr/i.test((trail.agency || "") + " " + (trail.region || ""))) return "Confirm the local MVUM before you roll.";
    return "";
  }

  function nearestRanger(trail) {
    const point = trail || state.fix;
    if (!point) return null;
    const offices = [
      { name: "Cowlitz Valley Ranger District", phone: "+13604971103", lat: 46.535, lon: -121.957 },
      { name: "Mt. Adams Ranger District", phone: "+15093953402", lat: 46.001, lon: -121.529 },
      { name: "Gifford Pinchot National Forest", phone: "+13608915000", lat: 45.632, lon: -122.662 },
      { name: "Mount St. Helens National Volcanic Monument", phone: "+13604497800", lat: 46.15, lon: -122.18 },
      { name: "Darrington Ranger District", phone: "+13604361155", lat: 48.253, lon: -121.603 },
      { name: "Enumclaw Ranger District", phone: "+13608256585", lat: 47.204, lon: -121.988 },
      { name: "Mt. Baker Ranger District", phone: "+13605992714", lat: 48.85, lon: -121.68 },
      { name: "Sedro-Woolley Ranger District", phone: "+13608542553", lat: 48.504, lon: -122.236 },
      { name: "Skykomish Ranger District", phone: "+13606772414", lat: 47.711, lon: -121.361 },
      { name: "Colville National Forest", phone: "+15096847000", lat: 48.54, lon: -117.9 },
      { name: "Newport Ranger District", phone: "+15094477300", lat: 48.18, lon: -117.04 },
      { name: "Republic Ranger District", phone: "+15097757400", lat: 48.648, lon: -118.737 },
      { name: "Tonasket Ranger District", phone: "+15094862186", lat: 48.706, lon: -119.437 },
      { name: "Bend-Fort Rock Ranger District", phone: "+15413835300", lat: 44.058, lon: -121.315 },
      { name: "Sisters Ranger District", phone: "+15415497700", lat: 44.291, lon: -121.549 },
      { name: "Crescent Ranger District", phone: "+15414333200", lat: 43.473, lon: -121.692 },
      { name: "Emigrant Creek Ranger District", phone: "+15415734300", lat: 43.548, lon: -118.623 },
      { name: "Prairie City Ranger District", phone: "+15418203800", lat: 44.463, lon: -118.709 }
    ];
    let best = null;
    let bestMiles = 150;
    offices.forEach(function (office) {
      const distance = miles(point, office);
      if (distance < bestMiles) {
        bestMiles = distance;
        best = office;
      }
    });
    return best;
  }

  async function refreshMvum(trail) {
    if (!trail || SHOT) return;
    const env = (trail.lon - 0.04) + "," + (trail.lat - 0.03) + "," + (trail.lon + 0.04) + "," + (trail.lat + 0.03);
    const base = "https://apps.fs.usda.gov/arcx/rest/services/EDW/EDW_MVUM_01/MapServer/";
    let hit = null;
    for (let layer = 1; layer <= 2 && !hit; layer += 1) {
      try {
        const url = base + layer + "/query?geometry=" + encodeURIComponent(env) + "&geometryType=esriGeometryEnvelope&inSR=4326&spatialRel=esriSpatialRelIntersects&outFields=name,mvum_symbol_name,seasonal,passengervehicle_datesopen,jurisdiction&returnGeometry=false&f=json&resultRecordCount=1";
        const data = await readGis(url);
        const feature = data && data.features && data.features[0];
        const attrs = feature && feature.attributes;
        if (!attrs || (!attrs.mvum_symbol_name && !attrs.name && !attrs.jurisdiction)) continue;
        hit = {
          trailId: trail.id,
          hit: true,
          window: attrs.passengervehicle_datesopen || attrs.seasonal || "",
          name: attrs.name || "",
          symbol: attrs.mvum_symbol_name || ""
        };
      } catch (error) { /* No MVUM checkmark without a live feature. */ }
    }
    if (selected() && selected().id === trail.id) {
      state.mvum = hit;
      if (state.mode === "drive" && !state.route) renderSheet();
    }
  }

  const HAZARD_KINDS = {
    rock: "🪨 Rock Ledge",
    ford: "💧 Deep Ford",
    tree: "🌲 Downed Tree",
    pad: "⛺ Verified <3° Pad",
    gate: "🔒 Locked Gate"
  };

  function drawDropped() {
    if (!hazardPinLayer) return;
    hazardPinLayer.clearLayers();
    state.dropped.forEach(function (pin) {
      const icon = L.divIcon({
        className: "hazard-pin",
        html: "<span>" + esc(pin.name || "Hazard") + (pin.elevFt != null ? " · " + pin.elevFt + " ft" : "") + "</span>",
        iconAnchor: [16, 12]
      });
      L.marker([pin.lat, pin.lon], { icon: icon, zIndexOffset: 680 }).addTo(hazardPinLayer);
    });
  }

  function openHazardSheet() {
    const sheet = document.getElementById("hazardSheet");
    if (!sheet) return;
    leaveFullDetent();
    sheet.hidden = false;
    const where = document.getElementById("hazardWhere");
    if (where) {
      const gps = state.fix ? formatPair(state.fix) : null;
      const elev = state.fix && state.fix.altitudeM != null ? " · " + Math.round(state.fix.altitudeM * 3.280839895) + " ft" : "";
      where.textContent = gps ? "MY GPS " + gps + elev : "Waiting for GPS…";
    }
    const note = document.getElementById("hazardNote");
    if (note) note.textContent = hazardNote || "";
  }

  function closeHazardSheet() {
    const sheet = document.getElementById("hazardSheet");
    if (sheet) sheet.hidden = true;
  }

  function captureHazardVoice() {
    const Rec = window.SpeechRecognition || window.webkitSpeechRecognition;
    if (!Rec) { toast("Voice notes need the device speech engine"); return; }
    const rec = new Rec();
    rec.lang = "en-US";
    rec.onresult = function (event) {
      hazardNote = (event.results[0] && event.results[0][0] && event.results[0][0].transcript) || "";
      const note = document.getElementById("hazardNote");
      if (note) note.textContent = hazardNote;
    };
    try { rec.start(); toast("Listening for a voice note…"); }
    catch (error) { toast("Voice note did not start"); }
  }

  function persistHazards() {
    const slim = state.dropped.map(function (pin) {
      const copy = Object.assign({}, pin);
      if (copy.photo && copy.photo.length > 90000) copy.photo = "";
      return copy;
    });
    try {
      localStorage.setItem("tf-hazards", JSON.stringify(slim));
      state.dropped = slim;
    } catch (error) {
      const quieter = slim.map(function (pin) { const copy = Object.assign({}, pin); copy.photo = ""; return copy; });
      try { localStorage.setItem("tf-hazards", JSON.stringify(quieter)); state.dropped = quieter; }
      catch (again) { toast("Hazard pin kept for this session"); }
    }
  }

  function saveHazard(kind) {
    if (!state.fix) { toast("Waiting for GPS…"); return; }
    const label = HAZARD_KINDS[kind] || HAZARD_KINDS.rock;
    const pin = {
      id: "hz-" + Date.now(),
      kind: kind || "rock",
      name: label,
      lat: state.fix.lat,
      lon: state.fix.lon,
      elevFt: state.fix.altitudeM != null ? Math.round(state.fix.altitudeM * 3.280839895) : null,
      note: hazardNote || "",
      photo: hazardPhoto || "",
      time: Date.now()
    };
    state.dropped.unshift(pin);
    state.dropped = state.dropped.slice(0, 40);
    hazardPhoto = "";
    hazardNote = "";
    persistHazards();
    drawDropped();
    closeHazardSheet();
    const trail = selected();
    const near = nearestVertex({ lat: pin.lat, lng: pin.lon });
    const status = kind === "gate" ? "Gate Locked" : kind === "tree" ? "Downed Tree" : kind === "pad" ? "Verified Pad" : "Washout";
    publishCommunity({
      v: 1,
      op: "upsert",
      opId: pin.id,
      report: {
        id: pin.id,
        trailId: trail ? trail.id : (near && near.trailId) || "custom",
        lat: pin.lat,
        lon: pin.lon,
        status: status,
        kind: "hazard",
        rig: state.rig.name || "Overland rig",
        time: pin.time,
        confirmCount: 1,
        cleared: false,
        note: String(pin.note || label).slice(0, 140)
      }
    });
    toast(label + " dropped at MY GPS");
  }

  function attachHazardPhoto(file) {
    if (!file) return;
    const reader = new FileReader();
    reader.onload = function () {
      const image = new Image();
      image.onload = function () {
        const scale = Math.min(1, 480 / Math.max(image.width, image.height));
        const canvas = document.createElement("canvas");
        canvas.width = Math.max(1, Math.round(image.width * scale));
        canvas.height = Math.max(1, Math.round(image.height * scale));
        canvas.getContext("2d").drawImage(image, 0, 0, canvas.width, canvas.height);
        hazardPhoto = canvas.toDataURL("image/jpeg", 0.62);
        toast("Photo attached");
      };
      image.src = String(reader.result || "");
    };
    reader.readAsDataURL(file);
  }

  function collectWaypoints(trail) {
    const marks = [];
    if (trail) {
      cruxPins(trail).forEach(function (pin) {
        marks.push({ lat: pin.lat, lon: pin.lon, name: pin.title, sym: pin.short, type: "crux", desc: pin.speak || "" });
      });
      spotsFor(trail).forEach(function (spot) {
        if (spot.slope >= 3) return;
        marks.push({ lat: spot.lat, lon: spot.lon, name: spot.name, sym: "Camp", type: "pad", desc: spot.slope.toFixed(1) + " degree pad" });
      });
    }
    state.dropped.forEach(function (pin) {
      marks.push({ lat: pin.lat, lon: pin.lon, name: pin.name, sym: pin.kind || "Hazard", type: "hazard", desc: (pin.note || "") + (pin.elevFt != null ? " " + pin.elevFt + " ft" : "") });
    });
    state.community.forEach(function (item) {
      if (item.cleared) return;
      marks.push({
        lat: item.lat,
        lon: item.lon,
        name: "TFCR|" + item.status + "|" + item.trailId + "|" + item.confirmCount + "|0",
        sym: "Community",
        type: "community",
        desc: item.rig + " " + item.status
      });
    });
    if (state.convoy) marks.push({ lat: state.fix ? state.fix.lat : (trail ? trail.lat : 0), lon: state.fix ? state.fix.lon : (trail ? trail.lon : 0), name: state.convoy, sym: "Convoy", type: "convoy", desc: "Local convoy status" });
    return marks.filter(function (mark) { return Number.isFinite(mark.lat) && Number.isFinite(mark.lon); });
  }

  function tripLine() {
    if (state.plot.length >= 2) return fullPlotPolyline();
    const trail = selected();
    const coords = trail && trail.coordinates;
    if (!coords || coords.length < 2) return [];
    const stride = Math.max(1, Math.ceil(coords.length / 40));
    const line = [];
    for (let index = 0; index < coords.length; index += stride) line.push({ lat: coords[index][0], lon: coords[index][1] });
    const last = coords[coords.length - 1];
    line.push({ lat: last[0], lon: last[1] });
    return line;
  }

  function tripCompact(name, points) {
    let sample = points.slice();
    const hazards = state.community.filter(function (item) { return !item.cleared; }).slice(0, 12);
    const hazardText = hazards.length ? "|R|" + hazards.map(function (item) {
      return item.lat.toFixed(4) + "," + item.lon.toFixed(4) + "," + communityCode(item) + "," + item.trailId;
    }).join(";") : "";
    let text = "";
    while (sample.length) {
      text = "TF1|" + name + "|" + sample.map(function (point) { return point.lat.toFixed(4) + "," + point.lon.toFixed(4); }).join(";");
      if (state.convoy) text += "|C|" + state.convoy;
      text += hazardText;
      if (text.length <= 1400 || sample.length <= 4) break;
      sample = sample.filter(function (_, index) { return index % 2 === 0; });
    }
    return text;
  }

  function paintQr(text) {
    const canvas = document.getElementById("qrCanvas");
    if (!canvas || typeof qrcode !== "function") return;
    const qr = qrcode(0, "M");
    qr.addData(text);
    qr.make();
    const count = qr.getModuleCount();
    const size = 220;
    canvas.width = size;
    canvas.height = size;
    const ctx = canvas.getContext("2d");
    ctx.fillStyle = "#ffffff";
    ctx.fillRect(0, 0, size, size);
    const cell = size / count;
    ctx.fillStyle = "#041018";
    for (let row = 0; row < count; row += 1) {
      for (let col = 0; col < count; col += 1) {
        if (qr.isDark(row, col)) ctx.fillRect(Math.floor(col * cell), Math.floor(row * cell), Math.ceil(cell), Math.ceil(cell));
      }
    }
  }

  function closeQr() {
    const modal = document.getElementById("qrModal");
    if (modal) modal.hidden = true;
  }

  function shareTrip() {
    const trail = selected();
    const points = tripLine();
    const sharedPins = state.community.some(function (item) { return !item.cleared; });
    if (points.length < 2 && !state.dropped.length && !sharedPins) { toast("Select a trail or plot a route first"); return; }
    const name = state.plot.length >= 2 ? "Custom route" : corridorLabel(trail || { name: "TrailForge trip" });
    const xml = gpxXml(name, points.length ? points : [{ lat: state.fix ? state.fix.lat : 0, lon: state.fix ? state.fix.lon : 0 }], collectWaypoints(trail));
    downloadText("TrailForge-trip.gpx", xml, "application/gpx+xml");
    const compact = tripCompact(name, points.length ? points : collectWaypoints(trail));
    paintQr(compact);
    const code = document.getElementById("tripCode");
    if (code) code.value = compact;
    const modal = document.getElementById("qrModal");
    if (modal) modal.hidden = false;
    const caption = document.getElementById("qrCaption");
    if (caption) caption.textContent = name + (state.convoy ? " · " + state.convoy : "") + " · community pins included";
    if (navigator.share) navigator.share({ title: name, text: compact }).catch(function () {});
    toast("Trip package ready");
  }

  function setConvoy(label) {
    state.convoy = label || "";
    const banner = document.getElementById("convoyBanner");
    if (banner) {
      banner.hidden = !state.convoy;
      banner.textContent = state.convoy;
    }
    if (state.convoy) toast(state.convoy);
  }

  function schedulePlaceSearch() {
    clearTimeout(state.placeTimer);
    const query = state.query.trim();
    if (query.length < 3) return;
    state.placeTimer = setTimeout(function () { searchPlaces(query, false); }, 400);
  }

  async function searchPlaces(query, routeFirst) {
    const trimmed = String(query || "").trim();
    if (trimmed.length < 3) {
      if (routeFirst) toast("Enter at least 3 characters to search an address or store.");
      return;
    }
    const generation = ++placeSearchGen;
    state.placeBusy = true;
    if (state.mode === "drive") renderSheet();
    let hits = [];
    try { hits = await fetchPlaceHits(trimmed); } catch (error) { hits = []; }
    if (generation !== placeSearchGen) return;
    state.placeBusy = false;
    state.places = hits.slice(0, 6);
    if (state.mode === "drive") renderSheet();
    if (routeFirst && state.places[0]) showPlace(state.places[0], true);
    else if (routeFirst) toast("No address or store matched that search.");
  }

  async function fetchPlaceHits(query) {
    const encoded = encodeURIComponent(query);
    const nominatimURL = "https://nominatim.openstreetmap.org/search?format=jsonv2&addressdetails=1&limit=5&countrycodes=us&q=" + encoded;
    const censusURL = "https://geocoding.geo.census.gov/geocoder/locations/onelineaddress?address=" + encoded + "&benchmark=Public_AR_Current&format=json";
    const pair = await Promise.all([
      readGis(nominatimURL).catch(function () { return null; }),
      readGis(censusURL).catch(function () { return null; })
    ]);
    const hits = [];
    const nominatim = Array.isArray(pair[0]) ? pair[0] : [];
    nominatim.forEach(function (row, index) {
      const lat = Number(row.lat);
      const lon = Number(row.lon);
      if (!Number.isFinite(lat) || !Number.isFinite(lon)) return;
      if (hits.some(function (hit) { return meters(hit, { lat: lat, lon: lon }) < 150; })) return;
      const display = row.display_name || "";
      const name = row.name || display.split(",")[0] || query;
      hits.push({ id: "osm-" + index + "-" + lat.toFixed(4), name: name, address: display || name, lat: lat, lon: lon });
    });
    const matches = pair[1] && pair[1].result && pair[1].result.addressMatches || [];
    matches.forEach(function (row, index) {
      const coords = row.coordinates || {};
      const lat = Number(coords.y);
      const lon = Number(coords.x);
      if (!Number.isFinite(lat) || !Number.isFinite(lon)) return;
      if (hits.some(function (hit) { return meters(hit, { lat: lat, lon: lon }) < 150; })) return;
      const address = row.matchedAddress || query;
      hits.push({ id: "census-" + index + "-" + lat.toFixed(4), name: address.split(",")[0] || address, address: address, lat: lat, lon: lon });
    });
    if (state.fix) hits.sort(function (a, b) { return miles(state.fix, a) - miles(state.fix, b); });
    return hits;
  }

  function showPlace(hit, route) {
    if (!hit) return;
    state.placePin = { id: hit.id, name: hit.name, address: hit.address, lat: hit.lat, lon: hit.lon };
    state.aim = state.placePin;
    if (!route) {
      if (map) map.setView([hit.lat, hit.lon], Math.max(map.getZoom(), 15));
      drawPlacePin(true);
      updateHud();
      toast(hit.name);
      return;
    }
    const trail = selected();
    beginRoute({
      id: hit.id,
      trailID: trail ? trail.id : state.selectedId,
      name: hit.name,
      lat: hit.lat,
      lon: hit.lon,
      slope: 0,
      starlink: 0,
      kind: "place",
      acres: 0,
      zoning: hit.address || "Address"
    });
    setTimeout(function () { drawPlacePin(true); }, 450);
  }

  function drawPlacePin(openPopup) {
    if (!placeLayer) return;
    placeLayer.clearLayers();
    const pin = state.placePin;
    if (!pin || !Number.isFinite(Number(pin.lat)) || !Number.isFinite(Number(pin.lon))) return;
    const icon = L.divIcon({
      className: "place-pin",
      html: "<span>📍 " + esc(pin.name || "Place") + "</span>",
      iconAnchor: [14, 12]
    });
    const marker = L.marker([pin.lat, pin.lon], { icon: icon, zIndexOffset: 740 }).bindPopup(
      "<b>" + esc(pin.name || "Place") + "</b><br>" + esc(pin.address || "") + "<br>" + Number(pin.lat).toFixed(5) + ", " + Number(pin.lon).toFixed(5)
    );
    marker.addTo(placeLayer);
    if (openPopup) marker.openPopup();
  }

  function loadRecordedRoutes() {
    try {
      const parsed = JSON.parse(localStorage.getItem("tf-recorded-routes-v1") || "[]");
      return Array.isArray(parsed) ? parsed : [];
    } catch (error) { return []; }
  }

  function saveRecordedRoutes() {
    localStorage.setItem("tf-recorded-routes-v1", JSON.stringify(state.recordedRoutes.slice(0, 40)));
  }

  function loadSavedMarkers() {
    try {
      const parsed = JSON.parse(localStorage.getItem("tf-saved-markers-v1") || "[]");
      return Array.isArray(parsed) ? parsed : [];
    } catch (error) { return []; }
  }

  function saveSavedMarkers() {
    localStorage.setItem("tf-saved-markers-v1", JSON.stringify(state.savedMarkers.slice(0, 80)));
  }

  function mmss(seconds) {
    const total = Math.max(0, Math.round(Number(seconds) || 0));
    return String(Math.floor(total / 60)).padStart(2, "0") + ":" + String(total % 60).padStart(2, "0");
  }

  function recordElapsed() {
    if (!state.recordStarted) return 0;
    const now = state.recordPaused ? state.recordPauseMark : Date.now();
    return Math.max(0, (now - state.recordStarted - state.recordPausedMs) / 1000);
  }

  function pointsStats(points) {
    let metersTotal = 0;
    let gain = 0;
    for (let index = 1; index < points.length; index += 1) {
      metersTotal += meters(points[index - 1], points[index]);
      const prev = points[index - 1].altitudeM;
      const next = points[index].altitudeM;
      if (prev != null && next != null && next > prev) gain += (next - prev) * 3.280839895;
    }
    return { miles: metersTotal / 1609.344, gain: Math.round(gain), points: points.length };
  }

  function defaultRouteName(date) {
    return "Trail Run • " + date.toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
  }

  function headUnitHtml() {
    return "";
  }

  function confirmRoute() {
    const route = state.route;
    if (!route) return;
    route.confirmed = true;
    state.follow = true;
    setDetent("peek");
    if (state.fix && map) map.setView([state.fix.lat, state.fix.lon], Math.max(map.getZoom(), 15));
    const spot = route.destination;
    const option = route.options[route.selected] || route.options[0];
    const first = option && option.steps ? option.steps.find(function (step) { return step.type !== "depart"; }) || option.steps[0] : null;
    const milesText = option ? (option.distanceMeters / 1609.344).toFixed(1) : "";
    if (!route.announced) {
      route.announced = true;
      speak("Starting GPS route to " + spot.name + ". " + (first ? first.instruction : "Follow the route.") + (milesText ? " " + milesText + " miles." : ""));
    }
    maybeSpeakCues();
    toast("Obey posted signs, verify private property, and keep your eyes on the trail.", 4500);
    renderAll();
  }

  function recorderHtml() {
    return "";
  }

  function savedMarkersHtml() {
    const rows = state.savedMarkers.map(function (marker) {
      return '<div class="place-card"><button type="button" class="row" data-act="marker-open" data-id="' + esc(marker.id) + '"><span class="meta"><b>' + esc(marker.name) + "</b><small>" + esc(marker.category) + " · " + esc(formatPair(marker) || "") + '</small></span></button><div class="actions"><button type="button" class="end" data-act="del-marker" data-id="' + esc(marker.id) + '">🗑️ Delete Waypoint</button></div></div>';
    }).join("");
    const clear = state.savedMarkers.length >= 2 ? '<div class="actions"><button type="button" data-act="connect-markers">Connect Saved Waypoints</button><button type="button" class="end" data-act="clear-markers">Delete All</button></div>' : "";
    return '<div class="marker-list"><b>Saved Markers / Waypoints</b>' + clear + '<div class="sub">Tap and hold the map to drop a pin.</div>' + (rows || '<div class="sub">No saved markers yet.</div>') + "</div>";
  }

  function toggleRecording() {
    if (state.recording) stopAndSaveRecording();
    else startRecording();
  }

  function startRecording() {
    state.recording = true;
    state.recordPaused = false;
    state.recordPoints = [];
    state.recordStarted = Date.now();
    state.recordPausedMs = 0;
    state.recordPauseMark = 0;
    if (!state.recordName.trim()) state.recordName = defaultRouteName(new Date());
    renderSheet();
    drawRecorded();
    toast("Recording trail route");
  }

  function pauseRecording() {
    if (!state.recording) return;
    if (state.recordPaused) {
      state.recordPausedMs += Date.now() - state.recordPauseMark;
      state.recordPaused = false;
    } else {
      state.recordPauseMark = Date.now();
      state.recordPaused = true;
    }
    renderSheet();
  }

  function stopAndSaveRecording() {
    if (!state.recording) return;
    if (state.recordPaused) state.recordPausedMs += Date.now() - state.recordPauseMark;
    const stats = pointsStats(state.recordPoints);
    state.recording = false;
    state.recordPaused = false;
    if (state.recordPoints.length >= 2) {
      const route = {
        id: "rec-" + Date.now(),
        name: state.recordName.trim() || defaultRouteName(new Date()),
        createdAt: Date.now(),
        durationSeconds: recordElapsed(),
        distanceMiles: stats.miles,
        elevationGainFt: stats.gain,
        maxElevationFt: Math.round(Math.max.apply(null, state.recordPoints.map(function (point) { return point.altitudeM == null ? 0 : point.altitudeM * 3.280839895; }))),
        points: state.recordPoints.slice()
      };
      state.recordedRoutes.unshift(route);
      state.shownRecordId = route.id;
      saveRecordedRoutes();
      toast("Saved " + route.name);
    } else toast("Need at least two GPS points to save");
    state.recordPoints = [];
    state.recordName = "";
    state.recordStarted = 0;
    renderSheet();
    drawRecorded();
  }

  function appendRecording(fix) {
    if (!state.recording || state.recordPaused || !fix) return;
    const last = state.recordPoints[state.recordPoints.length - 1];
    if (last && meters(last, fix) < 1) return;
    state.recordPoints.push({
      lat: fix.lat,
      lon: fix.lon,
      altitudeM: fix.altitudeM,
      speedMps: fix.speedMps,
      time: fix.time || Date.now()
    });
    drawRecorded();
    const distance = document.getElementById("recDistance");
    if (distance) {
      const stats = pointsStats(state.recordPoints);
      distance.textContent = stats.miles.toFixed(2);
      const duration = document.getElementById("recDuration");
      const gain = document.getElementById("recGain");
      const count = document.getElementById("recPoints");
      if (duration) duration.textContent = mmss(recordElapsed());
      if (gain) gain.textContent = "+" + stats.gain;
      if (count) count.textContent = String(stats.points);
    }
  }

  function deleteRecorded(id) {
    state.recordedRoutes = state.recordedRoutes.filter(function (route) { return route.id !== id; });
    if (state.shownRecordId === id) state.shownRecordId = null;
    saveRecordedRoutes();
    renderSheet();
    drawRecorded();
  }

  function navigateRecorded(id) {
    const route = state.recordedRoutes.find(function (item) { return item.id === id; });
    if (!route || !route.points || route.points.length < 2) return;
    state.shownRecordId = route.id;
    const end = route.points[route.points.length - 1];
    const road = route.points.map(function (point) { return [point.lat, point.lon]; });
    const distance = route.distanceMiles * 1609.344;
    state.route = {
      destination: { id: "rec-" + route.id, trailID: state.selectedId, name: route.name, lat: end.lat, lon: end.lon, slope: 0, starlink: 0, kind: "trailhead" },
      options: [{
        id: 0,
        title: "Recorded trail",
        expectedTravelTime: Math.max(60, distance / 8),
        distanceMeters: Math.max(distance, 1),
        road: road,
        steps: [{ id: 0, instruction: "Follow recorded route " + route.name, distanceMeters: Math.max(distance, 1), name: route.name, type: "continue", modifier: "straight", lat: end.lat, lon: end.lon, approach: false, at: false }]
      }],
      selected: 0,
      spur: [],
      originWasGPS: true,
      stepIndex: 0,
      arrived: false,
      spurApproach: false,
      spurAt: false,
      announced: true,
      confirmed: true
    };
    state.follow = true;
    renderAll();
    if (map) map.fitBounds(road, { padding: [28, 28] });
    speak("Starting recorded route " + route.name);
  }

  function routeToGpx(route) {
    const points = (route.points || []).map(function (point) {
      const ele = point.altitudeM == null ? "" : "<ele>" + Number(point.altitudeM).toFixed(1) + "</ele>";
      const time = point.time ? "<time>" + new Date(point.time).toISOString() + "</time>" : "";
      return '<trkpt lat="' + Number(point.lat).toFixed(6) + '" lon="' + Number(point.lon).toFixed(6) + '">' + ele + time + "</trkpt>";
    }).join("");
    return '<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="TrailForge Overland" xmlns="http://www.topografix.com/GPX/1/1"><metadata><name>' + esc(route.name) + "</name></metadata><trk><name>" + esc(route.name) + "</name><trkseg>" + points + "</trkseg></trk></gpx>\n";
  }

  function downloadText(filename, text, type) {
    const blob = new Blob([text], { type: type || "application/gpx+xml" });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    link.remove();
    setTimeout(function () { URL.revokeObjectURL(url); }, 1500);
  }

  function shareRecorded(id) {
    const route = state.recordedRoutes.find(function (item) { return item.id === id; });
    if (!route) return;
    const xml = routeToGpx(route);
    const fileName = "TrailForge-" + String(route.name).replace(/[^\w.-]+/g, "-") + ".gpx";
    const summary = route.name + " · " + Number(route.distanceMiles).toFixed(2) + " mi";
    const file = new File([xml], fileName, { type: "application/gpx+xml" });
    if (navigator.canShare && navigator.canShare({ files: [file] })) {
      navigator.share({ files: [file], title: route.name, text: summary }).catch(function (error) {
        if (!error || error.name !== "AbortError") downloadText(fileName, xml);
      });
      return;
    }
    if (navigator.share) {
      navigator.share({ title: route.name, text: summary }).catch(function (error) {
        if (!error || error.name !== "AbortError") downloadText(fileName, xml);
      });
      return;
    }
    downloadText(fileName, xml);
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(summary);
    toast("GPX downloaded");
  }

  function drawRecorded() {
    if (!recordLayer) return;
    recordLayer.clearLayers();
  }

  function drawSavedMarkers() {
    if (!markerLayer) return;
    markerLayer.clearLayers();
    if (state.droppedPin) {
      const pin = L.marker([state.droppedPin.lat, state.droppedPin.lon], {
        icon: L.divIcon({ className: "flag-pin", html: "<span>📍</span>", iconAnchor: [12, 12] }),
        zIndexOffset: 800
      });
      pin.addTo(markerLayer);
    }
    state.savedMarkers.forEach(function (marker) {
      const icon = L.divIcon({ className: "flag-pin", html: "<span>📍 " + esc(marker.name) + "</span>", iconAnchor: [14, 12] });
      const popup = "<b>" + esc(marker.name) + "</b><div>" + esc(marker.category) + " · " + esc(formatPair(marker) || "") + '</div><div class="actions"><button type="button" data-act="marker-open" data-id="' + esc(marker.id) + '">Open</button><button type="button" class="end" data-act="del-marker" data-id="' + esc(marker.id) + '">🗑️ Delete Waypoint</button></div>';
      const pin = L.marker([marker.lat, marker.lon], { icon: icon, zIndexOffset: 760 });
      if (state.plotting) {
        pin.on("click", function () { connectPlotWaypoint(marker.lat, marker.lon); });
      } else {
        pin.bindPopup(popup);
      }
      pin.addTo(markerLayer);
    });
  }

  function installLongPress() {
    if (!map) return;
    const container = map.getContainer();
    let timer = null;
    let start = null;
    map.on("contextmenu", function (event) {
      if (event && event.originalEvent && event.originalEvent.preventDefault) event.originalEvent.preventDefault();
      const source = event && event.originalEvent;
      if (source && source.clientX != null) {
        startHold(source.clientX, source.clientY);
        return;
      }
      if (event && event.latlng) dropPinAt(event.latlng.lat, event.latlng.lng);
    });
    function ignoredTarget(target) {
      return !!(target && target.closest && target.closest("button, input, a, .leaflet-marker-icon, .leaflet-interactive"));
    }
    function startHold(clientX, clientY) {
      if (!map) return;
      const point = mapContainerPoint(clientX, clientY);
      const ll = map.containerPointToLatLng(point);
      dropPinAt(ll.lat, ll.lng);
    }
    function arm(clientX, clientY, target) {
      if (ignoredTarget(target)) return;
      clearPress();
      start = { x: clientX, y: clientY };
      timer = setTimeout(function () {
        if (!start) return;
        startHold(start.x, start.y);
        start = null;
      }, 450);
    }
    function moved(clientX, clientY) {
      if (!start) return;
      if (Math.hypot(clientX - start.x, clientY - start.y) > 14) clearPress();
    }
    container.addEventListener("touchstart", function (event) {
      if (event.touches.length !== 1) { clearPress(); return; }
      const touch = event.touches[0];
      arm(touch.clientX, touch.clientY, event.target);
    }, { passive: true });
    container.addEventListener("pointerdown", function (event) {
      if (event.pointerType === "touch") return;
      if (event.pointerType === "mouse" && event.button !== 0) return;
      arm(event.clientX, event.clientY, event.target);
    });
    container.addEventListener("touchmove", function (event) {
      if (!start || !event.touches[0] || event.touches.length > 1) { clearPress(); return; }
      moved(event.touches[0].clientX, event.touches[0].clientY);
    }, { passive: true, capture: true });
    container.addEventListener("pointermove", function (event) {
      if (event.pointerType === "touch") return;
      moved(event.clientX, event.clientY);
    }, true);
    container.addEventListener("touchend", clearPress);
    container.addEventListener("touchcancel", clearPress);
    container.addEventListener("pointerup", clearPress);
    container.addEventListener("pointercancel", clearPress);
    function clearPress() {
      if (timer) clearTimeout(timer);
      timer = null;
      start = null;
    }
    setInterval(function () {
      if (!state.recording) return;
      const duration = document.getElementById("recDuration");
      if (duration) duration.textContent = mmss(recordElapsed());
    }, 1000);
  }

  let lastPinDrop = 0;

  function dropPinAt(lat, lon) {
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) return;
    const now = Date.now();
    if (now - lastPinDrop < 600) return;
    lastPinDrop = now;
    if (navigator.vibrate) navigator.vibrate(25);
    state.droppedPin = { lat: lat, lon: lon, name: "Saved Pin " + (state.savedMarkers.length + 1), place: "Looking up this point…" };
    state.pinCategory = "Waypoint";
    openPinSheet();
    drawSavedMarkers();
    reversePin(lat, lon);
  }

  function openPinSheet() {
    const sheet = document.getElementById("pinSheet");
    if (!sheet || !state.droppedPin) return;
    leaveFullDetent();
    sheet.hidden = false;
    document.getElementById("pinCoord").textContent = formatPair(state.droppedPin) || "";
    document.getElementById("pinPlace").textContent = state.droppedPin.place || "";
    document.getElementById("pinName").value = state.droppedPin.name || "";
    markCategory("#pinCats", state.pinCategory);
  }

  function closePinSheet() {
    const sheet = document.getElementById("pinSheet");
    if (sheet) sheet.hidden = true;
  }

  function markCategory(selector, category) {
    document.querySelectorAll(selector + " button").forEach(function (button) {
      button.classList.toggle("on", button.dataset.id === category);
    });
  }

  function reversePin(lat, lon) {
    const url = "https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=" + lat + "&lon=" + lon;
    fetch(url, { headers: { Accept: "application/json" } }).then(function (response) {
      return response.ok ? response.json() : null;
    }).then(function (data) {
      if (!state.droppedPin || state.droppedPin.lat !== lat || state.droppedPin.lon !== lon) return;
      const place = data && (data.name || data.display_name) ? String(data.name || data.display_name).split(",").slice(0, 2).join(", ") : "";
      if (place) {
        if (!state.droppedPin.place || state.droppedPin.place.indexOf("Looking") === 0) state.droppedPin.place = place;
        else if (state.droppedPin.place.indexOf(place) < 0) state.droppedPin.place = place + " · " + state.droppedPin.place;
        if ((state.droppedPin.name || "").indexOf("Saved Pin") === 0) state.droppedPin.name = place;
      } else if (!state.droppedPin.place || state.droppedPin.place.indexOf("Looking") === 0) {
        state.droppedPin.place = formatPair(state.droppedPin) || "";
      }
      openPinSheet();
    }).catch(function () {
      if (state.droppedPin && (!state.droppedPin.place || state.droppedPin.place.indexOf("Looking") === 0)) {
        state.droppedPin.place = formatPair(state.droppedPin) || "";
        openPinSheet();
      }
    });
  }

  function readPinName() {
    const input = document.getElementById("pinName");
    return (input && input.value.trim()) || (state.droppedPin && state.droppedPin.name) || "Saved Pin";
  }

  function startGpsNavigationToCoord(lat, lon, label) {
    const spot = {
      id: "pin-" + Date.now(),
      trailID: state.selectedId,
      name: label || "Dropped Pin",
      lat: lat,
      lon: lon,
      slope: 0,
      starlink: 0,
      kind: "trailhead"
    };
    beginRoute(spot, true);
  }

  function routeDroppedPin() {
    if (!state.droppedPin) return;
    startGpsNavigationToCoord(state.droppedPin.lat, state.droppedPin.lon, readPinName());
    closePinSheet();
  }

  function googleDroppedPin() {
    if (!state.droppedPin) return;
    const origin = state.fix ? "&origin=" + state.fix.lat + "," + state.fix.lon : "";
    openExternal("https://www.google.com/maps/dir/?api=1" + origin + "&destination=" + state.droppedPin.lat + "," + state.droppedPin.lon + "&travelmode=driving");
  }

  function saveDroppedPin() {
    if (!state.droppedPin) return;
    const marker = {
      id: "mark-" + Date.now(),
      name: readPinName(),
      category: state.pinCategory || "Waypoint",
      lat: state.droppedPin.lat,
      lon: state.droppedPin.lon,
      createdAt: Date.now()
    };
    state.savedMarkers.unshift(marker);
    state.plotClearedByUser = false;
    saveSavedMarkers();
    state.droppedPin = null;
    closePinSheet();
    drawSavedMarkers();
    renderSheet();
    toast("Saved " + marker.name);
  }

  function markerById(id) {
    return state.savedMarkers.find(function (marker) { return marker.id === id; });
  }

  function openMarker(id) {
    const marker = markerById(id);
    if (!marker) return;
    if (state.plotting) {
      connectPlotWaypoint(marker.lat, marker.lon);
      return;
    }
    state.activeMarkerId = id;
    const sheet = document.getElementById("markerSheet");
    if (!sheet) return;
    leaveFullDetent();
    sheet.hidden = false;
    document.getElementById("markerTitle").textContent = marker.category || "Saved Marker";
    document.getElementById("markerCoord").textContent = formatPair(marker) || "";
    document.getElementById("markerName").value = marker.name;
    markCategory("#markerCats", marker.category || "Waypoint");
  }

  function closeMarkerSheet() {
    const sheet = document.getElementById("markerSheet");
    if (sheet) sheet.hidden = true;
  }

  function setMarkerCategory(category) {
    const marker = markerById(state.activeMarkerId);
    if (!marker) return;
    marker.category = category || "Waypoint";
    saveSavedMarkers();
    markCategory("#markerCats", marker.category);
    document.getElementById("markerTitle").textContent = marker.category;
  }

  function routeActiveMarker() {
    const marker = markerById(state.activeMarkerId);
    if (!marker) return;
    const input = document.getElementById("markerName");
    startGpsNavigationToCoord(marker.lat, marker.lon, (input && input.value.trim()) || marker.name);
    closeMarkerSheet();
  }

  function renameActiveMarker() {
    const marker = markerById(state.activeMarkerId);
    if (!marker) return;
    const input = document.getElementById("markerName");
    marker.name = (input && input.value.trim()) || marker.name;
    saveSavedMarkers();
    drawSavedMarkers();
    renderSheet();
    toast("Renamed marker");
  }

  function shareActiveMarker() {
    const marker = markerById(state.activeMarkerId);
    if (!marker) return;
    const text = marker.name + " · " + (formatPair(marker) || "");
    const xml = '<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="TrailForge Overland" xmlns="http://www.topografix.com/GPX/1/1"><wpt lat="' + Number(marker.lat).toFixed(6) + '" lon="' + Number(marker.lon).toFixed(6) + '"><name>' + esc(marker.name) + "</name><type>" + esc(marker.category) + "</type><desc>" + esc(text) + "</desc></wpt></gpx>\n";
    const fileName = "TrailForge-" + String(marker.name).replace(/[^\w.-]+/g, "-") + ".gpx";
    const file = new File([xml], fileName, { type: "application/gpx+xml" });
    if (navigator.canShare && navigator.canShare({ files: [file] })) {
      navigator.share({ files: [file], title: marker.name, text: text }).catch(function (error) {
        if (!error || error.name !== "AbortError") downloadText(fileName, xml);
      });
      return;
    }
    downloadText(fileName, xml);
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text);
    toast("Marker GPX downloaded");
  }

  function deleteMarkerById(id) {
    state.savedMarkers = state.savedMarkers.filter(function (marker) { return marker.id !== id; });
    if (state.activeMarkerId === id) {
      state.activeMarkerId = null;
      closeMarkerSheet();
    }
    saveSavedMarkers();
    drawSavedMarkers();
    renderSheet();
  }

  function clearSavedMarkers() {
    state.savedMarkers = [];
    state.activeMarkerId = null;
    saveSavedMarkers();
    closeMarkerSheet();
    drawSavedMarkers();
    renderSheet();
    toast("Deleted all waypoints");
  }

  function deleteActiveMarker() {
    deleteMarkerById(state.activeMarkerId);
  }

  function boot() {
    state.trails = buildBuiltins();
    map = L.map("map", { zoomControl: false, attributionControl: true, minZoom: 3, maxZoom: 19 });
    map.setView([37.9589, -107.7352], 11);
    if (map.attributionControl) map.attributionControl.setPrefix(MAP_ATTRIB);
    const imageryOpts = { maxNativeZoom: 19, maxZoom: 19, zIndex: 1, attribution: "Tiles © Esri" };
    imageryLayer = L.tileLayer(ESRI_IMAGERY, imageryOpts);
    hybridLayer = L.tileLayer(ESRI_ROADS, { maxNativeZoom: 19, maxZoom: 19, zIndex: 2, attribution: "" });
    labelLayer = L.tileLayer(ESRI_PLACES, { maxNativeZoom: 19, maxZoom: 19, zIndex: 3, attribution: "" });
    topoLayer = L.tileLayer(USGS_TILES.topo, { maxNativeZoom: 16, maxZoom: 19, zIndex: 1, attribution: "" });
    hillshadeLayer = L.tileLayer("https://services.arcgisonline.com/ArcGIS/rest/services/Elevation/World_Hillshade/MapServer/tile/{z}/{y}/{x}", {
      opacity: 0.34,
      maxNativeZoom: 16,
      maxZoom: 19,
      zIndex: 5,
      className: "hillshade-tiles",
      attribution: ""
    });
    darkLayer = L.tileLayer("https://basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png", {
      maxZoom: 20,
      zIndex: 1,
      attribution: "© CARTO"
    });
    osmLayer = L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
      minZoom: 17,
      maxZoom: 19,
      zIndex: 2,
      attribution: ""
    });
    smaLayer = L.tileLayer("https://gis.blm.gov/arcgis/rest/services/lands/BLM_Natl_SMA_Cached_without_PriUnk/MapServer/tile/{z}/{y}/{x}", {
      maxNativeZoom: 13,
      maxZoom: 19,
      opacity: 0,
      zIndex: 4
    });
    offlineLayer = L.gridLayer({ zIndex: 3 });
    offlineLayer.createTile = function (coords, done) {
      const img = document.createElement("img");
      img.alt = "";
      img.width = 256;
      img.height = 256;
      const preferred = state.basemap === "topo" || state.packKind === "topo" ? "topo" : "satellite";
      const keys = [preferred + "/" + coords.z + "/" + coords.x + "/" + coords.y, (preferred === "topo" ? "satellite" : "topo") + "/" + coords.z + "/" + coords.x + "/" + coords.y];
      idbGet(keys[0]).then(function (blob) {
        return blob || idbGet(keys[1]);
      }).then(function (blob) {
        if (!blob) { done(null, img); return; }
        const url = URL.createObjectURL(blob);
        img.onload = function () { URL.revokeObjectURL(url); done(null, img); };
        img.onerror = function () { URL.revokeObjectURL(url); done(null, img); };
        img.src = url;
      }).catch(function () { done(null, img); });
      return img;
    };
    applyBasemap();
    offlineLayer.addTo(map);
    corridorLayer = L.layerGroup().addTo(map);
    slopeLayer = L.layerGroup().addTo(map);
    starlinkLayer = L.layerGroup().addTo(map);
    trailLayer = L.layerGroup().addTo(map);
    campLayer = L.layerGroup().addTo(map);
    routeLayer = L.layerGroup().addTo(map);
    hazardLayer = L.layerGroup().addTo(map);
    hazardPinLayer = L.layerGroup().addTo(map);
    communityLayer = L.layerGroup().addTo(map);
    placeLayer = L.layerGroup().addTo(map);
    plotLayer = L.layerGroup().addTo(map);
    recordLayer = L.layerGroup().addTo(map);
    markerLayer = L.layerGroup().addTo(map);
    installLongPress();
    installPitchGesture();
    applyMapPitch(false);
    map.on("dragstart", function () { state.follow = false; state.userPanned = true; });
    map.on("zoomend", function () { applyBasemap(); syncMap(); renderTop(); renderSheet(); refreshAreaChrome(); scheduleTrailScan(); });
    map.on("moveend", function () { applyBasemap(); syncMap(); renderTop(); renderSheet(); refreshAreaChrome(); scheduleTrailScan(); scheduleLandPolygons(); });
    map.on("move", function () { syncAreaPreview(); });
    refreshAreaChrome();
    map.on("click", onMapClick);
    document.addEventListener("click", function (event) {
      const button = event.target.closest("[data-act]");
      if (button && (button.dataset.act === "terms" || button.dataset.act === "privacy")) event.preventDefault();
      if (!button) {
        if (state.menuOpen && !event.target.closest("#trailList")) {
          state.menuOpen = false;
          const list = document.getElementById("trailList");
          if (list) list.classList.remove("open");
        }
        return;
      }
      handle(button);
    });
    document.addEventListener("input", function (event) {
      if (event.target.id === "recordName") { state.recordName = event.target.value; return; }
      if (event.target.id === "pinName") { if (state.droppedPin) state.droppedPin.name = event.target.value; return; }
      if (event.target.id === "markerName") { return; }
      if (event.target.id === "search") {
        state.query = event.target.value;
        const list = pickerTrails();
        if (state.filter === "bdr") state.menuOpen = true;
        else if (!list.some(function (trail) { return trail.id === state.selectedId; })) {
          const fallback = list.find(function (trail) { return !isBdrTrail(trail); });
          if (fallback) state.selectedId = fallback.id;
        }
        if (state.query.trim().length < 3) {
          state.places = [];
          state.placeBusy = false;
        }
        schedulePlaceSearch();
        renderAll();
        return;
      }
      if (event.target.hasAttribute("data-roll-limit")) {
        const limit = Number(event.target.value);
        state.rollLimit = limit >= 8 && limit <= 45 ? limit : 25;
        localStorage.setItem("tf-roll-limit", String(state.rollLimit));
        const read = document.getElementById("rollLimitRead");
        if (read) read.textContent = Math.round(state.rollLimit) + "°";
        updateHud();
        return;
      }
      if (event.target.dataset.overlay) {
        setOverlay(event.target.dataset.overlay, Number(event.target.value));
        return;
      }
      const field = event.target.dataset.field;
      if (!field) return;
      if (field === "name") state.rig.name = event.target.value;
      else state.rig[field] = Number(event.target.value);
      saveRig();
      const label = event.target.parentElement && event.target.parentElement.querySelector("b");
      if (label && field !== "name") {
        const suffix = field === "roofHeightFt" ? " ft" : field === "rigWeightLbs" ? " lb" : '"';
        label.textContent = num(state.rig[field]) + suffix;
      }
      updateHud();
      renderTop();
      syncMap();
    });
    window.addEventListener("devicemotion", function (event) {
      if (SHOT) return;
      const gravity = event.accelerationIncludingGravity;
      if (!gravity || gravity.x == null || gravity.y == null || gravity.z == null) return;
      state.lastMotionAt = Date.now();
      ingestWebGravity(gravity.x, gravity.y, gravity.z, state.compass);
    });
    window.addEventListener("deviceorientation", function (event) {
      if (SHOT) return;
      if (event.beta == null) return;
      const heading = event.webkitCompassHeading || event.alpha;
      if (Date.now() - state.lastMotionAt < 800) {
        if (heading != null && Number.isFinite(Number(heading))) state.compass = Number(heading);
        return;
      }
      const beta = event.beta * Math.PI / 180;
      const gamma = event.gamma * Math.PI / 180;
      const gx = Math.sin(gamma);
      const gy = -Math.cos(gamma) * Math.sin(beta);
      const gz = -Math.cos(beta) * Math.cos(gamma);
      ingestWebGravity(gx, gy, gz, heading);
    });
    document.addEventListener("keydown", function (event) {
      if (event.key !== "Enter" || !event.target || event.target.id !== "search") return;
      event.preventDefault();
      clearTimeout(state.placeTimer);
      searchPlaces(state.query, true);
    });
    window.addEventListener("online", function () {
      state.online = true;
      flushCommunityQueue();
    });
    window.addEventListener("storage", function (event) {
      if (event.key !== "tf-community" || !event.newValue) return;
      try { state.community = JSON.parse(event.newValue); } catch (error) { return; }
      drawCommunity();
      renderAll();
    });
    window.addEventListener("offline", function () { state.online = false; });
    const landscape = window.matchMedia("(orientation: landscape)");
    if (landscape.addEventListener) landscape.addEventListener("change", function () {
      if (state.dash === "auto") applyChrome();
    });
    document.addEventListener("pointerdown", function (event) {
      if (event.target.id === "elevChart") scrubElevation(event);
    });
    document.addEventListener("pointermove", function (event) {
      if (event.target.id === "elevChart" && event.buttons) scrubElevation(event);
    });
    const gpxFile = document.getElementById("gpxFile");
    if (gpxFile) gpxFile.addEventListener("change", function () {
      const file = gpxFile.files && gpxFile.files[0];
      gpxFile.value = "";
      if (!file) return;
      const reader = new FileReader();
      reader.onload = function () { importGpx(String(reader.result || "")); };
      reader.readAsText(file);
    });
    const hazardPhotoInput = document.getElementById("hazardPhoto");
    if (hazardPhotoInput) hazardPhotoInput.addEventListener("change", function () {
      const file = hazardPhotoInput.files && hazardPhotoInput.files[0];
      hazardPhotoInput.value = "";
      if (file) attachHazardPhoto(file);
    });
    installHost();
    installCommunityChannel();
    setMuted(state.muted);
    renderAll();
    showSafetyModal(false);
    syncSmaTiles();
    scheduleLandPolygons();
    startGeolocation();
    loadTelemetry();
    bootShot();
    scheduleTrailScan();
    refreshMvum(selected());
    refreshCommunity(false);
    window.addEventListener("resize", function () {
      clearTimeout(pitchResizeTimer);
      pitchResizeTimer = setTimeout(function () {
        refreshPitchForStage();
        placeRail();
      }, 60);
    });
    setTimeout(function () {
      map.invalidateSize();
      refreshPitchForStage();
      if (state.route && !state.follow) frameRoute();
    }, 400);
    if ("serviceWorker" in navigator && location.protocol.indexOf("http") === 0 && location.host.indexOf("androidplatform") < 0 && navigator.userAgent.indexOf("TrailForgeOverland/") < 0) {
      navigator.serviceWorker.register("./sw.js").catch(function () {});
    }
  }

  if (!ATLAS || !window.L) {
    document.body.innerHTML = "<p style='padding:24px'>TrailForge atlas failed to load.</p>";
    return;
  }
  boot();
})();
