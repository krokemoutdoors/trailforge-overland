/* TrailForge Overland cockpit. Works inside the Android WebView and as a PWA. */
(function () {
  "use strict";

  const SHOT = new URLSearchParams(location.search).get("shot");
  const ATLAS = window.TRAILFORGE_ATLAS;
  const CATALOG = [
    { id: "com.edwardshin.trailforge.pro.annual", title: "TrailForge Pro Annual", price: "$24.99/yr", note: "7-day free trial" },
    { id: "com.edwardshin.trailforge.founders.lifetime", title: "Lifetime Founders Pass", price: "$59.99", note: "One-time unlock", founders: true },
    { id: "com.edwardshin.trailforge.pro.monthly", title: "Weekend Expedition", price: "$4.99/mo", note: "Monthly" }
  ];
  const MAP_ATTRIB = "USGS National Map (Public Domain) • © OpenStreetMap contributors";
  const CORRIDOR_NOTE = "Independent public-road overland corridor compiled from public USFS, BLM, and state highway data. Not affiliated with, endorsed by, or sponsored by Backcountry Discovery Routes®.";
  const USGS_TILES = {
    hybrid: "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryTopo/MapServer/tile/{z}/{y}/{x}",
    satellite: "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/tile/{z}/{y}/{x}",
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
    discovered: [],
    fix: null,
    pitch: 0,
    roll: 0,
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
    lastReroute: 0,
    aim: null,
    targetCopy: "",
    parcelsOn: localStorage.getItem("tf-parcels") !== "0",
    parcel: null,
    parcelCells: [],
    parcelGen: 0,
    parcelTimer: null,
    parcelAnchor: null,
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
    packBusy: false,
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
    parcelNote: ""
  };

  const pendingNet = new Map();
  let netSeq = 0;
  let map;
  let puck;
  let trailLayer;
  let campLayer;
  let routeLayer;
  let parcelLayer;
  let corridorLayer;
  let slopeLayer;
  let hazardLayer;
  let plotLayer;
  let hazardPinLayer;
  let smaLayer;
  let offlineLayer;
  let hybridLayer;
  let imageryLayer;
  let topoLayer;
  let labelLayer;
  let darkLayer;
  let osmLayer;
  let identifyGen = 0;
  let hazardPhoto = "";
  let hazardNote = "";
  let scrubMarker;
  let toastTimer;
  let chromeTimer;
  const REPORTS = ["Open & Clear", "Mud/Snow", "Downed Tree", "Washout", "Gate Locked"];

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
    return trailById(state.selectedId) || pickerTrails()[0] || state.trails[0];
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

  function airDown() {
    const profile = state.rig;
    const highway = profile.rigWeightLbs > 7000 ? 55 : 36;
    const factor = state.surface === "sand" ? 0.42 : state.surface === "rock" ? 0.52 : 0.62;
    const bonus = Math.max(0, (profile.tireInches - 30) * 1.1);
    const minSafe = state.beadlocks ? 10 : 15;
    const front = Math.max(minSafe, Math.round(highway * factor - bonus));
    const rear = front + (profile.rigWeightLbs > 6500 ? 4 : 2);
    return { front: front, rear: rear };
  }

  function filterTitle() {
    if (state.filter === "near") return "Near Me";
    if (state.filter === "all") return "All USA";
    if (state.filter === "bdr") return "Backcountry Corridors";
    return state.filter;
  }

  function corridorLabel(trail) {
    if (!trail || !trail.bdr) return trail ? trail.name : "";
    const code = trail.state || "US";
    return code + " Backcountry Corridor (" + String(trail.id || "corridor").toUpperCase() + " Ref)";
  }

  function pickerTrails() {
    const query = state.query.trim().toLowerCase();
    const seen = new Set();
    let list = allTrails().filter(function (trail) {
      if (seen.has(trail.id)) return false;
      seen.add(trail.id);
      if (query) {
        const corridorHay = trail.bdr ? " bdr wabdr backcountry corridor " + trail.id + " " : "";
        const hay = (trail.name + " " + corridorHay + trail.region + " " + trail.state + " " + (trail.states || []).join(" ") + " " + trail.agency).toLowerCase();
        if (!hay.includes(query)) return false;
      }
      if (state.filter === "bdr") return !!trail.bdr;
      if (state.filter === "all" || state.filter === "near") return true;
      const codes = trail.states && trail.states.length ? trail.states : [trail.state];
      return codes.indexOf(state.filter) >= 0;
    });
    if (state.filter === "bdr") {
      list.sort(function (a, b) { return (a.bdrOrder || 0) - (b.bdrOrder || 0); });
      return list;
    }
    if (state.filter !== "near") return list;
    const origin = state.fix || mapCenter();
    list = list.slice().sort(function (a, b) { return miles(origin, a) - miles(origin, b); });
    if (!state.fix) return list.slice(0, 14);
    const nearby = list.filter(function (trail) { return miles(origin, trail) <= 250; });
    return nearby.length ? nearby : list.slice(0, 14);
  }

  function mapCenter() {
    if (!map) return { lat: 37.9589, lon: -107.7352 };
    const center = map.getCenter();
    return { lat: center.lat, lon: center.lng };
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
    const pads = pickerTrails().flatMap(spotsFor);
    const origin = state.fix;
    if (!origin) return pads.sort(function (a, b) { return a.slope - b.slope; });
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

  function toast(message) {
    const el = document.getElementById("toast");
    el.textContent = message;
    el.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { el.hidden = true; }, 2800);
  }

  function speak(text) {
    if (state.muted || !text) return;
    try {
      if (window.TrailForgeSpeech && TrailForgeSpeech.speak) {
        TrailForgeSpeech.speak(text);
        return;
      }
    } catch (error) { /* Web Speech fallback below. */ }
    if (!window.speechSynthesis) return;
    try {
      const utterance = new SpeechSynthesisUtterance(text);
      utterance.lang = "en-US";
      utterance.rate = 0.96;
      window.speechSynthesis.cancel();
      window.speechSynthesis.speak(utterance);
    } catch (error) { /* No speech engine on this device. */ }
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

  function bannerDetail(trail, fit) {
    const note = fit.notes[0] || "";
    if (state.fix) {
      const away = miles(state.fix, trail).toFixed(1);
      return "Gate: " + trail.gate + " · Ford: " + trail.water + '" · ' + away + " mi · " + note;
    }
    return "Gate: " + trail.gate + " · Ford: " + trail.water + '" · ' + note;
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
    const trail = selected();
    if (state.route) {
      const cue = nextCue();
      const steps = displaySteps(state.route);
      const stepHtml = state.showSteps ? '<div class="steps">' + steps.map(function (step, index) {
        return '<div class="step' + (index === (state.route.stepIndex || 0) ? " on" : "") + '"><span>' + formatDistance(step.distanceMeters) + "</span><span>" + esc(step.instruction) + "</span></div>";
      }).join("") + "</div>" : "";
      top.innerHTML = '<div class="nav"><div class="man" id="navIcon">' + maneuverSvg(cue.step) + '</div><div class="nav-copy"><div class="nav-dist" id="navDist">' + esc(state.routing ? "Recalculating route…" : cue.distance) + '</div><div class="nav-street" id="navStreet">' + esc(cue.street) + '</div><div class="sub" id="navSub">' + esc(cue.text) + '</div></div><button type="button" class="icon-btn" id="muteBtn" data-act="mute" aria-label="Mute voice directions">' + (state.muted ? "🔇" : "🔊") + '</button><button type="button" class="icon-btn" data-act="steps" aria-label="Step list">☰</button></div>' + stepHtml;
      return;
    }
    const list = pickerTrails();
    const fit = trail ? evaluate(trail) : null;
    const color = !list.length || !fit ? "#8ea6bb" : fitColor(fit.verdict);
    const title = !list.length || !trail ? "No routes for " + filterTitle() : fit.verdict + " · " + corridorLabel(trail);
    const detail = !list.length || !trail ? "Pick another state or tap Near Me." : bannerDetail(trail, fit);
    top.innerHTML = '<div class="fit"><div class="lamp" style="background:' + color + ";color:" + color + '"></div><div class="fit-copy"><div class="fit-title">' + esc(title) + '</div><div class="sub">' + esc(detail) + '</div></div><button type="button" class="pill-btn" data-act="offline">' + (state.offlineSaved ? "Offline" : "Save") + "</button></div>";
  }

  function routeBarHtml() {
    if (!state.route) return "";
    const spot = state.route.destination;
    const remaining = remainingMeters(state.route);
    const seconds = remainingSeconds(state.route, remaining);
    const eta = formatClock(new Date(Date.now() + seconds * 1000));
    const slope = spot.kind === "pad" ? spot.slope.toFixed(1) + "°" : spot.kind === "parcel" ? Number(spot.acres || 0).toFixed(1) + " ac" : "Trailhead";
    const sky = spot.kind === "pad" ? spot.starlink + "%" : spot.kind === "parcel" ? (spot.zoning || "—") : "—";
    const slopeLabel = spot.kind === "pad" ? "pad slope" : spot.kind === "parcel" ? "lot size" : "destination";
    const skyLabel = spot.kind === "pad" ? "Starlink" : spot.kind === "parcel" ? "zoning" : "sky";
    return '<div class="route-stats"><div><b id="rbSlope">' + esc(slope) + "</b><span>" + slopeLabel + '</span></div><div><b id="rbSky">' + esc(sky) + "</b><span>" + skyLabel + '</span></div><div><b id="rbEta">' + esc(formatDuration(seconds)) + "</b><span>ETA " + esc(eta) + '</span></div><div><b id="rbMiles">' + esc(formatDistance(remaining)) + '</b><span>remaining</span></div></div><div class="actions"><button type="button" class="primary' + (state.follow ? " on" : "") + '" data-act="follow">Follow GPS</button><button type="button" data-act="overview">Overview</button><button type="button" data-act="gmaps">Open in Google Maps</button><button type="button" class="end" data-act="end">End Route ✕</button></div>';
  }

  function sheetHtml() {
    const modes = ["drive", "camp", "rig"].map(function (mode) {
      const label = mode === "drive" ? "1. Go Drive" : mode === "camp" ? "2. Flat Camp" : "3. My Rig";
      return '<button type="button" data-act="mode" data-mode="' + mode + '" class="' + (state.mode === mode ? "on" : "") + '">' + label + "</button>";
    }).join("");
    let body = "";
    if (state.mode === "drive") body = driveHtml();
    else if (state.mode === "camp") body = campHtml();
    else body = rigHtml();
    return '<div class="modes">' + modes + "</div>" + body;
  }

  function driveHtml() {
    const list = pickerTrails();
    const countLabel = filterTitle() + " • " + list.length + (list.length === 1 ? " Route" : " Routes") + " ▾";
    const chips = ['<button type="button" class="chip' + (state.filter === "near" ? " on" : "") + '" data-act="filter" data-id="near">Near Me</button>', '<button type="button" class="chip' + (state.filter === "all" ? " on" : "") + '" data-act="filter" data-id="all">All USA</button>', '<button type="button" class="chip' + (state.filter === "bdr" ? " on" : "") + '" data-act="filter" data-id="bdr">Backcountry Corridors</button>'].concat(ATLAS.states.map(function (box) {
      return '<button type="button" class="chip' + (state.filter === box.code ? " on" : "") + '" data-act="filter" data-id="' + box.code + '">' + box.code + "</button>";
    })).join("");
    const rows = list.map(function (trail) {
      const fit = evaluate(trail);
      const away = state.fix ? " · " + miles(state.fix, trail).toFixed(1) + " mi away" : "";
      const where = trail.states && trail.states.length > 1 ? trail.states.join("/") : trail.state;
      return '<button type="button" class="row" data-act="pick" data-id="' + esc(trail.id) + '"><i class="dot" style="background:' + fitColor(fit.verdict) + '"></i><span class="meta"><b>' + esc(where + " · " + corridorLabel(trail)) + "</b><small>" + esc(trail.miles + " mi · " + num(trail.clearance) + '" · ' + shortFit(fit.verdict) + away) + "</small></span></button>";
    }).join("") || '<div class="row"><span class="meta"><b>No matching routes</b></span></div>';
    const pills = list.slice(0, 24).map(function (trail) {
      const shown = corridorLabel(trail);
      const label = state.fix ? shown + " · " + Math.round(miles(state.fix, trail)) + " mi" : shown;
      return '<button type="button" class="trail-pill' + (trail.id === state.selectedId ? " on" : "") + '" data-act="pick" data-id="' + esc(trail.id) + '">' + esc(label) + "</button>";
    }).join("");
    const trail = selected();
    const telemetry = profileHtml(trail) + telemetryHtml(trail);
    const convoy = '<div class="convoy"><button type="button" data-act="convoy" data-id="🛑 Stopping Ahead">🛑 Stopping Ahead</button><button type="button" data-act="convoy" data-id="🛞 Airing Down">🛞 Airing Down</button><button type="button" data-act="convoy" data-id="🆘 Stuck — Need Winch/Strap">🆘 Stuck — Need Winch/Strap</button><button type="button" data-act="convoy" data-id="🔒 Gate Locked — Turn Around">🔒 Gate Locked — Turn Around</button></div>';
    return '<input class="search" id="search" placeholder="Search trails or state" value="' + esc(state.query) + '" /><div class="chips">' + chips + '</div><button type="button" class="menu-btn" id="trailMenu" data-act="menu">' + esc(countLabel) + '</button><div class="menu' + (state.menuOpen ? " open" : "") + '" id="trailList">' + rows + '</div><div class="pills">' + pills + '</div><div class="status" id="scanStatus">' + esc(state.scanning ? "Scanning USA 4x4 trails…" : state.scanStatus) + '</div><div class="status" id="parcelNote">' + esc(state.parcelNote || "") + "</div>" + telemetry + convoy;
  }

  function profileHtml(trail) {
    if (!trail) return "";
    const latest = state.reports.find(function (item) { return item.trailId === trail.id; });
    const pills = REPORTS.map(function (status) {
      return '<button type="button" data-act="report" data-id="' + esc(status) + '" class="' + (latest && latest.status === status ? "on" : "") + '">' + esc(status) + "</button>";
    }).join("");
    const queued = latest ? "Queued on device: " + esc(latest.status) : "Reports stay on this device until you have a signal.";
    const crux = cruxPins(trail).map(function (pin) {
      return '<div class="crux">' + esc(pin.title) + "</div>";
    }).join("");
    const badge = mvumBadge(trail);
    const ranger = nearestRanger(trail);
    const rangerBtn = ranger
      ? '<button type="button" data-act="call-ranger" data-id="' + esc(ranger.phone) + '">Call ' + esc(ranger.name) + "</button>"
      : '<button type="button" data-act="ranger-page">Ranger district contacts</button>';
    const disclaimer = trail.bdr ? '<div class="sub">' + esc(CORRIDOR_NOTE) + "</div>" : "";
    return '<div class="profile"><div class="profile-top"><b>Elevation</b><span id="elevRead">—</span></div><canvas id="elevChart" height="92"></canvas><div class="obs-key">💧 Ford · 🪨 Ledge · ⛺ &lt;3° Pad</div>' + (crux ? '<div class="crux-list">' + crux + "</div>" : "") + (badge ? '<div class="sub mvum">' + esc(badge) + "</div>" : "") + '<div class="actions"><button type="button" data-act="share-trip">Share Trip Package (QR / Export)</button>' + rangerBtn + '</div>' + disclaimer + '<div class="reports"><span>Report Trail Status</span>' + pills + '</div><div class="sub">' + queued + "</div></div>";
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
    const psi = airDown();
    const horizon = "rotate(" + state.roll.toFixed(1) + "deg) translateY(" + (state.pitch * 0.6).toFixed(1) + "px)";
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
      return '<div class="pass' + (item.founders ? " founders" : "") + '"><div class="meta"><b>' + esc(item.title) + "</b><small>" + esc(item.note) + " · " + esc(price) + '</small></div><button type="button" data-act="buy" data-id="' + item.id + '">' + owned + "</button></div>";
    }).join("");
    return '<input class="name" data-field="name" value="' + esc(profile.name) + '" aria-label="Rig name" /><div class="rig-live"><div class="dial"><div class="horizon" id="horizon" style="transform:' + horizon + '"></div><div class="cross"></div></div><div class="psi"><b id="psiRead">' + psi.front + "F / " + psi.rear + 'R</b><span>Air-down PSI · ' + esc(state.surface) + '</span><div class="sub" id="tiltRead">Pitch ' + Math.round(state.pitch) + "° · Roll " + Math.round(state.roll) + "°</div></div></div>" + products + '<div class="actions"><button type="button" data-act="restore">Restore purchases</button></div><div class="seg">' + locker("none", "Open diffs") + locker("rear", "Rear locker") + '<button type="button" data-act="snorkel" class="' + (profile.hasSnorkel ? "on" : "") + '">Snorkel</button><button type="button" data-act="bead" class="' + (state.beadlocks ? "on" : "") + '">Beadlocks</button></div><div class="seg" style="margin-top:8px">' + surface + '</div><div class="grid" style="margin-top:8px">' + fields + '</div><div class="foot">TrailForge Overland 1.3.0 · build 9<br>' + MAP_ATTRIB + '<br>' + CORRIDOR_NOTE + '<br><a href="https://krokemoutdoors.github.io/trailforge-overland/#privacy" data-act="privacy">Privacy policy</a></div>';
  }

  function renderSheet() {
    document.getElementById("routebar").innerHTML = routeBarHtml();
    const active = document.activeElement;
    if (active && active.matches && active.matches("input[type=range][data-field], input.name")) return;
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
    if (state.parcel) return state.parcel;
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
    document.getElementById("speedRead").textContent = state.fix ? String(speed) : "—";
    document.getElementById("altRead").textContent = alt;
    const gpsText = state.fix ? formatPair(state.fix) : null;
    const aimText = formatPair(targetPoint());
    state.targetCopy = aimText ? "TARGET: " + aimText : "";
    const gpsRead = document.querySelector("#myGpsRead b");
    const targetRead = document.querySelector("#targetRead b");
    if (gpsRead) gpsRead.textContent = gpsText || "—";
    if (targetRead) targetRead.textContent = aimText || "—";
    const parcelToggle = document.getElementById("parcelToggle");
    if (parcelToggle) parcelToggle.classList.toggle("on", state.parcelsOn);
    const psi = airDown();
    const warn = Math.abs(state.roll) >= 25 || Math.abs(state.pitch) >= 25;
    const pill = document.getElementById("clinPill");
    pill.classList.toggle("warn", warn);
    pill.textContent = "Roll " + Math.round(state.roll) + "° / Pitch " + Math.round(state.pitch) + "° · Air Down " + psi.front + "F / " + psi.rear + "R PSI";
    const horizon = document.getElementById("horizon");
    if (horizon) horizon.style.transform = "rotate(" + state.roll.toFixed(1) + "deg) translateY(" + (state.pitch * 0.6).toFixed(1) + "px)";
    const tilt = document.getElementById("tiltRead");
    if (tilt) tilt.textContent = "Pitch " + Math.round(state.pitch) + "° · Roll " + Math.round(state.roll) + "°";
    const psiRead = document.getElementById("psiRead");
    if (psiRead) psiRead.textContent = psi.front + "F / " + psi.rear + "R";
    const turn = document.getElementById("dashTurn");
    if (turn) {
      if (state.route) {
        const cue = nextCue();
        turn.innerHTML = "<span>NEXT TURN</span><b>" + esc(cue.distance) + "</b><small>" + esc(cue.text) + "</small>";
      } else turn.innerHTML = "<span>NEXT TURN</span><b>—</b>";
    }
    const tiltCard = document.getElementById("dashTilt");
    if (tiltCard) tiltCard.innerHTML = "<span>ROLL / PITCH</span><b>" + Math.round(state.roll) + "° / " + Math.round(state.pitch) + "°</b>";
    const gpsCard = document.getElementById("dashGps");
    if (gpsCard) gpsCard.innerHTML = "<span>MY GPS</span><b>" + esc(gpsText || "—") + "</b><small>" + (state.fix ? speed + " mph" : "") + "</small>";
    const targetCard = document.getElementById("dashTarget");
    if (targetCard) targetCard.innerHTML = "<span>TARGET</span><b>" + esc(aimText || "—") + "</b>";
  }

  function drawableTrails() {
    const list = pickerTrails();
    if (state.filter !== "all" && list.length <= 80) return list;
    const signature = list.filter(function (trail) { return trail.signature || trail.live; });
    const chosen = (signature.length ? signature : list).slice(0, 80);
    const current = selected();
    if (current && !chosen.some(function (trail) { return trail.id === current.id; })) chosen.push(current);
    return chosen;
  }

  function syncMap() {
    if (!map) return;
    trailLayer.clearLayers();
    campLayer.clearLayers();
    const draw = drawableTrails();
    const zoom = map.getZoom();
    draw.forEach(function (trail) {
      if (!trail.coordinates || trail.coordinates.length < 2) return;
      const fit = evaluate(trail);
      const selectedTrail = trail.id === state.selectedId;
      const unverified = !!trail.live && (String(trail.id).indexOf("osm-") === 0 || /openstreetmap/i.test(trail.agency || ""));
      L.polyline(trail.coordinates, {
        color: "#071018",
        weight: selectedTrail ? 7 : 5,
        opacity: 0.85,
        dashArray: unverified ? "8 8" : null,
        lineCap: "round",
        lineJoin: "round"
      }).addTo(trailLayer);
      L.polyline(trail.coordinates, {
        color: fitColor(fit.verdict),
        weight: selectedTrail ? 4 : 3,
        opacity: 0.95,
        dashArray: unverified ? "8 8" : null,
        lineCap: "round",
        lineJoin: "round"
      }).addTo(trailLayer);
      const showPads = state.mode === "camp" || zoom >= 10 || selectedTrail;
      if (showPads) {
        spotsFor(trail).forEach(function (spot) {
          const icon = L.divIcon({
            className: "camp-pin" + (spot.slope >= 2 ? " warn" : ""),
            html: "<span>⛺ " + spot.slope.toFixed(1) + "°</span>",
            iconAnchor: [28, 12]
          });
          L.marker([spot.lat, spot.lon], { icon: icon, zIndexOffset: 400 }).on("click", function (event) {
            if (state.plotting) { onMapClick(event); return; }
            beginRoute(spot);
          }).addTo(campLayer);
        });
      }
      if (selectedTrail) {
        const head = trailhead(trail);
        const flag = L.divIcon({ className: "flag-pin", html: "<span>⚑</span>", iconAnchor: [12, 12] });
        L.marker([head.lat, head.lon], { icon: flag, zIndexOffset: 450 }).on("click", function (event) {
          if (state.plotting) { onMapClick(event); return; }
          beginRoute(head);
        }).addTo(campLayer);
        cruxPins(trail).forEach(function (pin) {
          const icon = L.divIcon({ className: "hazard-pin", html: "<span>" + esc(pin.short) + "</span>", iconAnchor: [14, 12] });
          L.marker([pin.lat, pin.lon], { icon: icon, zIndexOffset: 520 }).addTo(campLayer);
        });
      }
    });
    drawDropped();
    drawRoute();
    updatePuck();
    drawPlot();
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
    if (!list.some(function (trail) { return trail.id === state.selectedId; }) && list[0]) state.selectedId = list[0].id;
    if (!state.follow) {
      const trail = selected();
      if (state.filter === "bdr" && trail && trail.coordinates && trail.coordinates.length && map) map.fitBounds(trail.coordinates, { padding: [28, 28] });
      else focusTrail(trail, state.filter === "all" ? 4 : 8);
    }
    renderAll();
    if (!scan || SHOT) return;
    if (state.filter === "near") scanAt(state.fix || mapCenter());
    else if (state.filter !== "all" && state.filter !== "bdr") {
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
    return (root.elements || []).map(parseWay).filter(Boolean);
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

  function liveTrail(id, name, region, agency, coordinates, mid, fit, seed, tagged) {
    const slope = Math.min(2.7, 1.2 + (Math.abs(seed) % 12) * 0.12);
    const point = coordinates[Math.min(coordinates.length - 1, Math.max(1, Math.floor(coordinates.length / 3)))];
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
      flatCamps: slope < 3 ? [{ name: name + " Flat Pad", lat: point[0], lon: point[1], slope: Math.round(slope * 10) / 10, starlink: 82 + (Math.abs(seed) % 17) }] : [],
      signature: false,
      live: true
    };
  }

  async function fetchOverpass(center) {
    const radius = 25000;
    const query = "[out:json][timeout:25];(" +
      'way["highway"~"track|path"]["tracktype"~"grade2|grade3|grade4|grade5"](around:' + radius + "," + center.lat + "," + center.lon + ");" +
      'way["highway"="track"]["4wd_only"="yes"](around:' + (radius + 10000) + "," + center.lat + "," + center.lon + ");" +
      'way["highway"="unclassified"]["surface"~"unpaved|gravel|dirt|sand|rock"](around:' + Math.max(5000, radius - 5000) + "," + center.lat + "," + center.lon + ");" +
      ");out geom 40;";
    const text = await net("https://overpass-api.de/api/interpreter", { method: "POST", body: query });
    return parseOverpass(text);
  }

  async function fetchUsfs(center) {
    const params = new URLSearchParams({
      where: "1=1",
      geometry: center.lon + "," + center.lat,
      geometryType: "esriGeometryPoint",
      inSR: "4326",
      spatialRel: "esriSpatialRelIntersects",
      distance: "25000",
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

  async function scanAt(center) {
    if (!center || SHOT) return;
    const gen = ++state.scanGen;
    state.scanning = true;
    state.scanStatus = "Scanning USA 4x4 trails…";
    const button = document.getElementById("scanBtn");
    if (button) button.textContent = "Scanning…";
    renderTop();
    const status = document.getElementById("scanStatus");
    if (status) status.textContent = state.scanStatus;
    try {
      const results = await Promise.all([
        fetchOverpass(center).catch(function () { return []; }),
        fetchUsfs(center).catch(function () { return []; })
      ]);
      if (gen !== state.scanGen) return;
      const merged = results[0].concat(results[1]);
      const seen = new Set(allTrails().map(function (trail) { return trail.id; }));
      const fresh = [];
      merged.forEach(function (trail) {
        if (seen.has(trail.id)) return;
        seen.add(trail.id);
        fresh.push(trail);
      });
      state.discovered = state.discovered.concat(fresh);
      state.scanStatus = fresh.length || merged.length ? (state.discovered.length + " local USA trails") : "No public 4x4 tracks returned for this area.";
    } catch (error) {
      if (gen !== state.scanGen) return;
      state.scanStatus = "Trail scan unavailable right now.";
    }
    state.scanning = false;
    if (button) button.textContent = "Scan Area for All USA 4x4 Trails";
    if (state.filter === "near") {
      const list = pickerTrails();
      if (list[0] && list[0].id !== state.selectedId && !state.follow) state.selectedId = list[0].id;
    }
    renderAll();
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
    if (!route || !state.fix || route.arrived) return;
    const option = route.options[route.selected] || route.options[0];
    if (route.stepIndex == null) route.stepIndex = 0;
    while (route.stepIndex < option.steps.length) {
      const step = option.steps[route.stepIndex];
      const distance = meters(state.fix, { lat: step.lat, lon: step.lon }) / 1609.344;
      if (!step.approach && distance <= 0.2 && distance > 0.04 && step.type !== "depart") {
        step.approach = true;
        speak("In 0.2 miles, " + step.instruction);
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
        speak("In 0.2 miles, proceed on the overland spur to " + route.destination.name);
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

  function overlandSpur(road, spot) {
    const last = road[road.length - 1] || [spot.lat, spot.lon];
    return [last, [spot.lat, spot.lon]];
  }

  function fallbackRoad(origin, spot, trail) {
    const line = trail && trail.coordinates && trail.coordinates.length >= 2 ? trail.coordinates : [[origin.lat, origin.lon], [spot.lat, spot.lon]];
    let start = 0;
    let end = 0;
    let bestStart = Infinity;
    let bestEnd = Infinity;
    line.forEach(function (point, index) {
      const fromOrigin = meters(origin, point);
      const fromSpot = meters(spot, point);
      if (fromOrigin < bestStart) { bestStart = fromOrigin; start = index; }
      if (fromSpot < bestEnd) { bestEnd = fromSpot; end = index; }
    });
    const slice = start <= end ? line.slice(start, end + 1) : line.slice(end, start + 1).reverse();
    return [[origin.lat, origin.lon]].concat(slice);
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

  async function beginRoute(spot, refit) {
    if (!spot) return;
    const generation = ++state.routeGen;
    const trail = trailById(spot.trailID) || selected();
    const originWasGPS = !!(state.fix && !state.fix.shotOnly);
    const origin = state.fix || { lat: trailhead(trail).lat, lon: trailhead(trail).lon };
    state.routing = true;
    state.aim = spot;
    state.selectedId = spot.trailID || state.selectedId;
    updateHud();
    renderTop();
    let options = [];
    try {
      const url = "https://router.project-osrm.org/route/v1/driving/" + origin.lon + "," + origin.lat + ";" + spot.lon + "," + spot.lat + "?overview=full&geometries=geojson&steps=true&alternatives=true";
      const text = await net(url);
      if (generation !== state.routeGen) return;
      options = parseOsrm(JSON.parse(text), spot);
    } catch (error) {
      options = [];
    }
    if (generation !== state.routeGen) return;
    if (!options.length) {
      const road = fallbackRoad(origin, spot, trail);
      const distance = polylineMeters(road);
      options = [{
        id: 0,
        title: "Trail approach",
        expectedTravelTime: (distance / 1609.344) / 15 * 3600,
        distanceMeters: distance,
        road: road,
        steps: [{ id: 0, instruction: "Follow the trail toward " + spot.name, distanceMeters: distance, name: trail.name, type: "continue", modifier: "straight", lat: spot.lat, lon: spot.lon, approach: false, at: false }]
      }];
    }
    const road = options[0].road;
    const firstBuild = !state.route || state.route.destination.id !== spot.id;
    state.route = {
      destination: spot,
      options: options,
      selected: 0,
      spur: overlandSpur(road, spot),
      originWasGPS: !!state.fix,
      stepIndex: 0,
      arrived: false,
      spurApproach: false,
      spurAt: false,
      announced: false
    };
    state.routing = false;
    state.showSteps = false;
    state.follow = false;
    renderAll();
    if (refit !== false) {
      requestAnimationFrame(function () {
        map.invalidateSize();
        frameRoute();
      });
    }
    const first = options[0].steps.find(function (step) { return step.type !== "depart"; }) || options[0].steps[0];
    const milesText = (options[0].distanceMeters / 1609.344).toFixed(1);
    if (firstBuild || !state.route.announced) {
      state.route.announced = true;
      speak("Starting route to " + spot.name + ". " + (first ? first.instruction : "Follow the route.") + " " + milesText + " miles.");
    }
    maybeSpeakCues();
    const app = document.getElementById("app");
    app.dataset.route = "1";
    if (SHOT) app.dataset.shotReady = "1";
    if (!originWasGPS) state.route.originWasGPS = false;
  }

  function frameRoute() {
    const route = state.route;
    if (!route || !map) return;
    const coords = roadAndSpur(route).slice();
    if (state.fix) coords.push([state.fix.lat, state.fix.lon]);
    coords.push([route.destination.lat, route.destination.lon]);
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
      beginRoute(route.destination, !state.follow);
      return;
    }
    if (!state.follow || Date.now() - state.lastReroute < 25000) return;
    const line = roadAndSpur(route);
    let best = Infinity;
    for (let index = 1; index < line.length; index += 1) {
      best = Math.min(best, distanceToSegment(state.fix, line[index - 1], line[index]).distance);
    }
    if (best > 450) {
      state.lastReroute = Date.now();
      speak("Recalculating route.");
      beginRoute(route.destination, false);
    }
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
    state.fix = fix;
    updatePuck();
    updateHud();
    noteParcelFix();
    if (!state.centeredOnce && !state.route && !SHOT) {
      state.centeredOnce = true;
      if (state.filter === "near") applyFilter(true);
      else map.setView([fix.lat, fix.lon], Math.max(map.getZoom(), 12));
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
    const pitch = Number(data.pitch) || 0;
    const roll = Number(data.roll) || 0;
    state.pitch += (pitch - state.pitch) * 0.28;
    state.roll += (roll - state.roll) * 0.28;
    if (data.heading != null && Number.isFinite(Number(data.heading))) state.compass = Number(data.heading);
    updateHud();
    if (state.fix && !(state.fix.speedMps > 1.2) && state.compass != null) {
      state.fix.heading = state.compass;
      updatePuck();
    }
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
      state.filter = button.dataset.id;
      state.menuOpen = false;
      state.follow = false;
      applyFilter(true);
      return;
    }
    if (act === "pick") {
      state.selectedId = button.dataset.id;
      state.menuOpen = false;
      state.follow = false;
      const picked = selected();
      if (picked && picked.bdr && picked.coordinates && map) map.fitBounds(picked.coordinates, { padding: [28, 28] });
      else focusTrail(picked, 11);
      renderAll();
      loadTelemetry();
      refreshMvum(picked);
      return;
    }
    if (act === "mode") {
      state.mode = button.dataset.mode;
      renderAll();
      return;
    }
    if (act === "route") {
      beginRoute(findSpot(button.dataset.id));
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
    if (act === "scan") {
      scanAt(state.fix || mapCenter());
      return;
    }
    if (act === "offline") {
      state.offlineSaved = !state.offlineSaved;
      localStorage.setItem("tf-offline", state.offlineSaved ? "1" : "0");
      toast(state.offlineSaved ? "50-state atlas saved on this device." : "Atlas will refresh while you are online.");
      renderTop();
      return;
    }
    if (act === "mute") { setMuted(!state.muted); return; }
    if (act === "steps") { state.showSteps = !state.showSteps; renderTop(); return; }
    if (act === "follow") {
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
    if (act === "parcels") {
      state.parcelsOn = !state.parcelsOn;
      localStorage.setItem("tf-parcels", state.parcelsOn ? "1" : "0");
      if (!state.parcelsOn) {
        state.parcel = null;
        state.parcelCells = [];
        if (parcelLayer) parcelLayer.clearLayers();
        syncSmaTiles();
        renderLotCard();
      } else scheduleParcels();
      updateHud();
      return;
    }
    if (act === "close-lot") { state.parcel = null; renderLotCard(); updateHud(); return; }
    if (act === "copy-lot") {
      if (!state.parcel) return;
      const text = formatPair(state.parcel);
      if (!text) return;
      copyText("TARGET: " + text);
      return;
    }
    if (act === "route-parcel") { routeToParcel(); return; }
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
    if (act === "privacy") {
      openExternal("https://krokemoutdoors.github.io/trailforge-overland/#privacy");
      return;
    }
    if (act === "detent") { setDetent(button.dataset.id); return; }
    if (act === "dash") {
      state.dash = dashOn() ? "off" : "on";
      localStorage.setItem("tf-dash", state.dash);
      applyChrome();
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
    if (act === "layers") {
      state.drawer = state.drawer === "layers" ? null : "layers";
      renderDrawer();
      applyChrome();
      return;
    }
    if (act === "plot") {
      state.plotting = !state.plotting;
      state.drawer = state.plotting ? "plot" : (state.drawer === "plot" ? null : state.drawer);
      if (state.plotting) toast("Tap the map to plot a route");
      renderDrawer();
      applyChrome();
      return;
    }
    if (act === "corridor" || act === "download-corridor") {
      state.drawer = "corridor";
      renderDrawer();
      applyChrome();
      downloadCorridor();
      return;
    }
    if (act === "close-drawer") { state.drawer = null; renderDrawer(); applyChrome(); return; }
    if (act === "basemap") {
      const id = button.dataset.id;
      state.basemap = id === "topo" || id === "satellite" || id === "dark" ? id : "hybrid";
      localStorage.setItem("tf-basemap", state.basemap);
      applyBasemap();
      renderDrawer();
      return;
    }
    if (act === "pack-kind") {
      state.packKind = button.dataset.id === "satellite" ? "satellite" : "topo";
      localStorage.setItem("tf-pack-kind", state.packKind);
      renderDrawer();
      return;
    }
    if (act === "report") { queueReport(button.dataset.id); return; }
    if (act === "export-gpx") { exportGpx(); return; }
    if (act === "import-gpx") {
      const input = document.getElementById("gpxFile");
      if (input) input.click();
      return;
    }
    if (act === "clear-plot") {
      state.plot = [];
      drawPlot();
      renderDrawer();
      toast("Custom route cleared");
      return;
    }
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
      toast(state.thermal ? "Thermal saver on — USGS topo, slower sensors" : "Thermal saver off");
      return;
    }
    if (act === "night") {
      state.night = !state.night;
      localStorage.setItem("tf-night", state.night ? "1" : "0");
      applyChrome();
      return;
    }
    if (act === "hazard") { openHazardSheet(); return; }
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
    const hazard = document.getElementById("hazardSheet");
    if (hazard && !hazard.hidden) { closeHazardSheet(); return true; }
    if (state.drawer) { state.drawer = null; renderDrawer(); applyChrome(); return true; }
    if (state.plotting) { state.plotting = false; drawPlot(); applyChrome(); return true; }
    if (state.parcel) { state.parcel = null; renderLotCard(); updateHud(); return true; }
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

  function startGeolocation() {
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

  const PARCEL_STYLE = {
    private: { fill: "#e2b657", stroke: "#f6e2a4", badge: "PRIVATE LAND" },
    usfs: { fill: "#14915a", stroke: "#b7f5d4", badge: "U.S. FOREST SERVICE" },
    blm: { fill: "#f5e642", stroke: "#fff3a1", badge: "BLM PUBLIC LAND" },
    state: { fill: "#38bdf8", stroke: "#d7f3ff", badge: "STATE TRUST LAND" },
    nps: { fill: "#34d399", stroke: "#d1fae5", badge: "NATIONAL PARK SERVICE" }
  };

  function scheduleParcels() {
    if (!map) return;
    clearTimeout(state.parcelTimer);
    state.parcelTimer = setTimeout(refreshParcels, 420);
  }

  function noteParcelFix() {
    if (!state.parcelsOn || !state.fix) return;
    if (state.parcelAnchor && miles(state.parcelAnchor, state.fix) < 0.25) return;
    state.parcelAnchor = { lat: state.fix.lat, lon: state.fix.lon };
    scheduleParcels();
  }

  function regionBearing(lat, lon) {
    let best = null;
    let bestD = 14000;
    const trails = allTrails();
    for (let index = 0; index < trails.length; index += 1) {
      const trail = trails[index];
      if (!trail.coordinates || trail.coordinates.length < 2) continue;
      if (Math.abs(trail.lat - lat) > 1.4 || Math.abs(trail.lon - lon) > 1.8) continue;
      const step = Math.max(1, Math.ceil(trail.coordinates.length / 10));
      for (let point = step; point < trail.coordinates.length; point += step) {
        const start = { lat: trail.coordinates[point - step][0], lon: trail.coordinates[point - step][1] };
        const end = { lat: trail.coordinates[point][0], lon: trail.coordinates[point][1] };
        const distance = meters({ lat: lat, lon: lon }, start);
        if (distance < bestD) {
          bestD = distance;
          best = bearing(start, end);
        }
      }
    }
    if (best != null) return Math.round(best / 5) * 5;
    return (seedFor(Math.floor(lat * 2) + ":" + Math.floor(lon * 2)) % 50) - 25;
  }

  function localMeters(lat, lon, originLat, originLon, heading) {
    const north = (lat - originLat) * 111320;
    const east = (lon - originLon) * Math.max(20000, 111320 * Math.cos(originLat * Math.PI / 180));
    const angle = heading * Math.PI / 180;
    const cos = Math.cos(angle);
    const sin = Math.sin(angle);
    return { x: north * cos + east * sin, y: -north * sin + east * cos };
  }

  function worldPoint(x, y, originLat, originLon, heading) {
    const angle = heading * Math.PI / 180;
    const cos = Math.cos(angle);
    const sin = Math.sin(angle);
    const north = x * cos - y * sin;
    const east = x * sin + y * cos;
    return [
      originLat + north / 111320,
      originLon + east / Math.max(20000, 111320 * Math.cos(originLat * Math.PI / 180))
    ];
  }

  function pointInRing(lat, lon, ring) {
    if (!ring || ring.length < 3) return false;
    let inside = false;
    for (let index = 0, previous = ring.length - 1; index < ring.length; previous = index, index += 1) {
      const yi = ring[index][0];
      const xi = ring[index][1];
      const yj = ring[previous][0];
      const xj = ring[previous][1];
      const intersect = ((yi > lat) !== (yj > lat)) && (lon < (xj - xi) * (lat - yi) / ((yj - yi) || 1e-12) + xi);
      if (intersect) inside = !inside;
    }
    return inside;
  }

  function parcelAt(lat, lon) {
    const list = state.parcelCells || [];
    for (let index = list.length - 1; index >= 0; index -= 1) {
      if (list[index].ring && pointInRing(lat, lon, list[index].ring)) return list[index];
    }
    return null;
  }

  function publishedEntity(name) {
    const text = String(name || "").trim();
    if (!text || /private landowner/i.test(text)) return "";
    if (/\b(usfs|blm|nps|dnr|forest|service|bureau|county|city|town|park|parks|district|inc\.?|llc|corp|company|trust|agency|department|weyerhaeuser|state|national|public|school)\b/i.test(text)) return text;
    if (/^[A-Z][a-z.'-]+(?:\s+[A-Z][a-z.'-]+){1,2}$/.test(text)) return "";
    return text;
  }

  function drawParcels() {
    if (!parcelLayer) return;
    parcelLayer.clearLayers();
    const fade = Math.max(0, Math.min(100, Number(state.opacity.parcels) || 0)) / 100;
    if (!state.parcelsOn || fade <= 0) return;
    let labels = 0;
    (state.parcelCells || []).forEach(function (parcel) {
      if (!parcel.ring || parcel.ring.length < 3) return;
      const style = PARCEL_STYLE[parcel.kind] || PARCEL_STYLE.private;
      L.polygon(parcel.ring, {
        color: style.stroke,
        weight: 1.6,
        fillColor: style.fill,
        fillOpacity: 0.34 * fade,
        interactive: true,
        bubblingMouseEvents: false
      }).on("click", function (event) {
        if (state.plotting) { onMapClick(event); return; }
        if (event.originalEvent) L.DomEvent.stopPropagation(event.originalEvent);
        openParcel(parcel);
        identifyParcel(parcel.lat, parcel.lon, parcel);
      }).addTo(parcelLayer);
      if (labels < 12 && parcel.owner) {
        labels += 1;
        const acres = Number.isFinite(parcel.acres) ? " · " + parcel.acres.toFixed(1) + " ac" : "";
        const icon = L.divIcon({
          className: "lot-label",
          html: "<span>" + esc(shortOwner(parcel.owner)) + acres + "</span>",
          iconSize: [150, 18],
          iconAnchor: [75, 9]
        });
        L.marker([parcel.lat, parcel.lon], { icon: icon, interactive: false, zIndexOffset: 260 }).addTo(parcelLayer);
      }
    });
  }

  function shortOwner(name) {
    const text = String(name || "");
    return text.length > 28 ? text.slice(0, 27) + "…" : text;
  }

  function openParcel(parcel) {
    state.parcel = parcel;
    renderLotCard();
    updateHud();
  }

  function renderLotCard() {
    const card = document.getElementById("lotCard");
    if (!card) return;
    const parcel = state.parcelsOn ? state.parcel : null;
    if (!parcel) {
      card.hidden = true;
      card.innerHTML = "";
      return;
    }
    const style = PARCEL_STYLE[parcel.kind] || PARCEL_STYLE.private;
    const coord = formatPair(parcel) || "—";
    const acres = Number.isFinite(parcel.acres) ? parcel.acres.toFixed(1) + " ac" : "—";
    const note = state.parcelNote ? '<div class="src">' + esc(state.parcelNote) + "</div>" : "";
    card.hidden = false;
    card.className = "lot-card " + (parcel.kind || "private");
    card.innerHTML = '<div class="lot-top"><span class="badge" style="background:' + style.fill + '">' + esc(parcel.badge || style.badge) + '</span><button type="button" data-act="close-lot" aria-label="Close lot card">✕</button></div><b class="owner">' + esc(parcel.owner || "Published parcel") + '</b><div class="sub">' + esc(parcel.agency || "") + '</div><div class="lot-grid"><div><span>ADDRESS</span><b>' + esc(parcel.address || "—") + '</b></div><div><span>COUNTY</span><b>' + esc(parcel.county || "—") + '</b></div><div><span>CENSUS BLOCK</span><b>' + esc(parcel.censusBlock || "—") + '</b></div><div><span>ACRES</span><b>' + esc(acres) + '</b></div><div><span>ZONING / LAND USE</span><b>' + esc(parcel.zoning || "—") + '</b></div><div><span>PARCEL ID</span><b>' + esc(parcel.parcelId || "Not published") + '</b></div></div><button type="button" class="line" data-act="copy-lot">TARGET: ' + esc(coord) + '</button><button type="button" class="go" data-act="route-parcel">Route to Parcel</button><div class="src">' + esc(parcel.source || "") + "</div>" + note;
  }

  function routeToParcel() {
    const parcel = state.parcel;
    if (!parcel) return;
    let nearest = null;
    let best = Infinity;
    state.trails.forEach(function (trail) {
      const distance = miles(parcel, trail);
      if (distance < best) {
        best = distance;
        nearest = trail;
      }
    });
    const trail = nearest || selected();
    state.parcel = null;
    renderLotCard();
    beginRoute({
      id: parcel.id || "parcel",
      trailID: trail ? trail.id : state.selectedId,
      name: parcel.owner || "Published parcel",
      lat: parcel.lat,
      lon: parcel.lon,
      slope: 0,
      starlink: 0,
      kind: "parcel",
      acres: Number.isFinite(parcel.acres) ? parcel.acres : 0,
      zoning: parcel.zoning || "—"
    });
  }

  function onParcelMapClick(event) {
    if (!state.parcelsOn || SHOT) return;
    const original = event.originalEvent;
    if (original && original.target && original.target.closest && original.target.closest(".leaflet-marker-icon, .camp-pin, .flag-pin")) return;
    const lat = event.latlng.lat;
    const lon = event.latlng.lng;
    const hit = parcelAt(lat, lon);
    if (hit) openParcel(hit);
    identifyParcel(lat, lon, hit);
  }

  function ringCentroidLatLng(ring) {
    let lat = 0;
    let lon = 0;
    ring.forEach(function (point) { lat += point[0]; lon += point[1]; });
    return { lat: lat / ring.length, lon: lon / ring.length };
  }

  function esriLatLngRing(geometry) {
    const rings = geometry && geometry.rings;
    if (!rings || !rings.length) return null;
    let best = rings[0];
    rings.forEach(function (ring) { if (ring && ring.length > best.length) best = ring; });
    if (!best || best.length < 4) return null;
    const latlng = best.map(function (pair) { return [Number(pair[1]), Number(pair[0])]; }).filter(function (point) {
      return Number.isFinite(point[0]) && Number.isFinite(point[1]);
    });
    return downsampleRing(latlng, 80);
  }

  function downsampleRing(points, limit) {
    if (!points || points.length <= limit) return points || [];
    const step = Math.ceil(points.length / limit);
    const ring = [];
    for (let index = 0; index < points.length; index += step) ring.push(points[index]);
    const last = points[points.length - 1];
    const tail = ring[ring.length - 1];
    if (!tail || tail[0] !== last[0] || tail[1] !== last[1]) ring.push(last);
    return ring;
  }

  function polygonAcres(ring) {
    if (!ring || ring.length < 3) return null;
    let meters2 = 0;
    for (let index = 0, previous = ring.length - 1; index < ring.length; previous = index, index += 1) {
      const northA = ring[previous][0] * 111320;
      const eastA = ring[previous][1] * 111320 * Math.cos(ring[previous][0] * Math.PI / 180);
      const northB = ring[index][0] * 111320;
      const eastB = ring[index][1] * 111320 * Math.cos(ring[index][0] * Math.PI / 180);
      meters2 += eastA * northB - eastB * northA;
    }
    const acres = Math.abs(meters2 / 2) / 4046.8564224;
    return Number.isFinite(acres) && acres > 0 ? acres : null;
  }

  async function readGis(url, options) {
    const text = await net(url, options);
    if (!text || text.length > 400000) return null;
    const trimmed = text.trim();
    if (trimmed.charAt(0) !== "{" && trimmed.charAt(0) !== "[") return null;
    const data = JSON.parse(trimmed);
    if (data && data.error) {
      const message = String((data.error && data.error.message) || data.error || "");
      if (/not started|unable to complete|error/i.test(message)) return { down: true, message: message };
      return { down: true, message: message };
    }
    return data;
  }

  function smaKind(code, name, adminState) {
    const unit = publishedEntity(name);
    const stateName = String(adminState || "");
    if (code === "USFS") return { kind: "usfs", owner: unit || "U.S. Forest Service (USFS)", agency: "U.S. Forest Service (USFS)", badge: "U.S. FOREST SERVICE", source: "BLM Surface Management Agency" };
    if (code === "BLM") return { kind: "blm", owner: unit || "Bureau of Land Management (BLM)", agency: "Bureau of Land Management (BLM)", badge: "BLM PUBLIC LAND", source: "BLM Surface Management Agency" };
    if (code === "NPS") return { kind: "nps", owner: unit || "National Park Service", agency: "National Park Service", badge: "NATIONAL PARK SERVICE", source: "BLM Surface Management Agency" };
    if (code === "ST") {
      const wa = stateName === "WA" || /washington/i.test(stateName);
      const label = wa ? "WA Dept. of Natural Resources (DNR)" : (unit || "State Trust Land");
      return { kind: "state", owner: label, agency: label, badge: wa ? "WA DNR" : "STATE TRUST LAND", source: "BLM Surface Management Agency" };
    }
    if (unit) return { kind: "state", owner: unit, agency: unit, badge: "PUBLIC LAND", source: "BLM Surface Management Agency" };
    if (code === "PVT" || code === "UND" || code === "PVTUNK") return { kind: "private", owner: "", agency: "Private land", badge: "PRIVATE LAND", private: true, source: "BLM Surface Management Agency" };
    return null;
  }

  async function smaPoint(layer, point) {
    const geometry = encodeURIComponent(JSON.stringify({ x: point.lon, y: point.lat, spatialReference: { wkid: 4326 } }));
    const url = "https://gis.blm.gov/arcgis/rest/services/lands/BLM_Natl_SMA_Cached_without_PriUnk/MapServer/" + layer + "/query?geometry=" + geometry + "&geometryType=esriGeometryPoint&inSR=4326&spatialRel=esriSpatialRelIntersects&outFields=ADMIN_AGENCY_CODE,ADMIN_UNIT_NAME,ADMIN_ST&returnGeometry=false&f=json";
    const data = await readGis(url);
    if (!data || data.down) return null;
    const attrs = (((data.features || [])[0] || {}).attributes) || null;
    if (!attrs) return null;
    const hit = smaKind(attrs.ADMIN_AGENCY_CODE, attrs.ADMIN_UNIT_NAME, attrs.ADMIN_ST);
    return hit ? Object.assign({ lat: point.lat, lon: point.lon }, hit) : null;
  }

  async function smaIdentify(point) {
    const hits = await Promise.all([7, 8, 9, 14, 15, 1].map(function (layer) {
      return smaPoint(layer, point).catch(function () { return null; });
    }));
    const ranked = hits.filter(Boolean);
    return ranked.find(function (hit) { return !hit.private && hit.owner; }) || ranked.find(function (hit) { return !hit.private; }) || ranked[0] || null;
  }

  async function usfsAt(point, withGeometry) {
    const fields = "forestname";
    const geom = withGeometry ? "true&maxAllowableOffset=0.05&outSR=4326" : "false";
    const url = "https://apps.fs.usda.gov/arcx/rest/services/EDW/EDW_ForestSystemBoundaries_01/MapServer/0/query?geometry=" + point.lon + "," + point.lat + "&geometryType=esriGeometryPoint&inSR=4326&spatialRel=esriSpatialRelIntersects&outFields=" + fields + "&returnGeometry=" + geom + "&f=json";
    const data = await readGis(url);
    if (!data || data.down) return null;
    const feature = (data.features || [])[0];
    if (!feature) return null;
    const attrs = feature.attributes || {};
    const name = publishedEntity(attrs.forestname || attrs.FORESTNAME || "");
    if (!name) return null;
    const ring = withGeometry ? esriLatLngRing(feature.geometry) : null;
    const center = ring && ring.length ? ringCentroidLatLng(ring) : { lat: point.lat, lon: point.lon };
    return {
      id: "usfs-" + name.toLowerCase().replace(/[^a-z0-9]+/g, "-"),
      ring: ring,
      lat: center.lat,
      lon: center.lon,
      acres: ring ? polygonAcres(ring) : null,
      kind: "usfs",
      owner: name,
      agency: "U.S. Forest Service (USFS)",
      badge: "U.S. FOREST SERVICE",
      zoning: "National Forest",
      parcelId: "",
      source: "USFS EDW Forest System Boundaries",
      live: true
    };
  }

  async function censusPlace(point) {
    const url = "https://geocoding.geo.census.gov/geocoder/geographies/coordinates?x=" + point.lon + "&y=" + point.lat + "&benchmark=Public_AR_Current&vintage=Current_Current&format=json";
    const data = await readGis(url);
    if (!data || data.down) return {};
    const geos = ((data.result || {}).geographies) || {};
    const county = (geos.Counties || [])[0] || {};
    const place = (geos["Incorporated Places"] || [])[0] || {};
    const block = (geos["Census Blocks"] || [])[0] || {};
    const st = ((geos.States || [])[0] || {}).STUSAB || "";
    const countyName = county.NAME || county.BASENAME || "";
    return {
      county: countyName ? (countyName.indexOf(",") >= 0 ? countyName : countyName + (st ? ", " + st : "")) : "",
      place: place.NAME || place.BASENAME || "",
      state: st,
      block: block.GEOID || block.BLOCK || "",
      tract: block.TRACT || ""
    };
  }

  function stateAbbr(value) {
    const text = String(value || "");
    const iso = text.match(/US-([A-Z]{2})/);
    if (iso) return iso[1];
    if (/^[A-Za-z]{2}$/.test(text)) return text.toUpperCase();
    const names = { washington: "WA", oregon: "OR", california: "CA", idaho: "ID", colorado: "CO", utah: "UT", nevada: "NV", arizona: "AZ", montana: "MT", wyoming: "WY", "new mexico": "NM", texas: "TX" };
    return names[text.toLowerCase()] || text;
  }

  async function nominatimAddress(point) {
    const url = "https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=" + point.lat + "&lon=" + point.lon + "&zoom=18&addressdetails=1";
    const data = await readGis(url);
    if (!data || data.down) return {};
    const address = data.address || {};
    const org = publishedEntity(address.office || data.name || "");
    return {
      house: address.house_number || "",
      road: address.road || address.pedestrian || "",
      town: address.city || address.town || address.village || address.hamlet || "",
      state: stateAbbr(address["ISO3166-2-lvl4"] || address.state_code || address.state || ""),
      zip: address.postcode || "",
      county: address.county || "",
      org: org
    };
  }

  function formatStreet(address) {
    if (!address) return "";
    const street = [address.house, address.road].filter(Boolean).join(" ");
    const tail = [address.town, [address.state, address.zip].filter(Boolean).join(" ")].filter(Boolean).join(", ");
    if (street && tail) return street + ", " + tail;
    return street || tail || "";
  }

  function residentialTitle(address) {
    const line = formatStreet(address);
    return line ? "Private Residential Lot — " + line : "Private Residential Lot";
  }

  function inClark(point) {
    return point.lat >= 45.5 && point.lat <= 46.05 && point.lon >= -122.85 && point.lon <= -122.25;
  }

  function attrPick(attrs, pattern) {
    const keys = Object.keys(attrs || {});
    for (let index = 0; index < keys.length; index += 1) {
      if (!pattern.test(keys[index])) continue;
      const value = attrs[keys[index]];
      if (value == null || String(value).trim() === "" || String(value) === "Null") continue;
      return String(value).trim();
    }
    return "";
  }

  function clarkParcelFromFeature(feature, index) {
    const attrs = feature.attributes || feature;
    const ring = esriLatLngRing(feature.geometry);
    const ownerRaw = attrPick(attrs, /owner|taxpayer|grantor/i);
    const owner = publishedEntity(ownerRaw);
    const address = attrPick(attrs, /situs|site_?addr|address|prop_?addr/i);
    const parcelId = attrPick(attrs, /parcel|apn|pin\b|tax.?id|prop_?id/i);
    const zoning = attrPick(attrs, /zoning|land.?use|lu_?desc|usecode/i);
    const acresRaw = Number(attrPick(attrs, /acres|gisacres|shape.?area/i));
    const acres = ring ? polygonAcres(ring) : (Number.isFinite(acresRaw) && acresRaw > 0 && acresRaw < 100000 ? acresRaw : null);
    const center = ring && ring.length ? ringCentroidLatLng(ring) : null;
    if (!ring && !address && !parcelId && !owner) return null;
    return {
      id: "clark-" + (parcelId || index),
      ring: ring,
      lat: center ? center.lat : null,
      lon: center ? center.lon : null,
      acres: acres,
      kind: /forest|bureau|blm|usfs|nps|dnr|county|city|park|state/i.test(owner) ? "state" : "private",
      owner: owner || (address ? "Private Residential Lot — " + address : "Private Residential Lot"),
      agency: "Clark County, WA",
      badge: "PRIVATE LAND",
      address: address,
      county: "Clark County, WA",
      zoning: zoning,
      parcelId: parcelId,
      source: "Clark County LandRecords",
      live: true
    };
  }

  async function clarkLots(point) {
    const geometry = encodeURIComponent(JSON.stringify({ x: point.lon, y: point.lat, spatialReference: { wkid: 4326 } }));
    const extent = (point.lon - 0.02) + "," + (point.lat - 0.015) + "," + (point.lon + 0.02) + "," + (point.lat + 0.015);
    const identify = "https://gis.clark.wa.gov/arcgisfed2/rest/services/MAPSOnline/LandRecords/MapServer/identify?geometry=" + geometry + "&geometryType=esriGeometryPoint&sr=4326&layers=all&tolerance=6&mapExtent=" + extent + "&imageDisplay=400,400,96&returnGeometry=true&f=json";
    try {
      const data = await readGis(identify);
      if (!data || data.down) return { down: true, lots: [] };
      const results = data.results || data.features || [];
      const lots = results.map(clarkParcelFromFeature).filter(Boolean).slice(0, 4);
      return { down: false, lots: lots };
    } catch (error) {
      return { down: true, lots: [] };
    }
  }

  function osmParcel(element, index) {
    const geometry = element.geometry || [];
    if (geometry.length < 4) return null;
    const ring = downsampleRing(geometry.map(function (point) { return [point.lat, point.lon]; }), 48);
    if (ring.length < 4) return null;
    const tags = element.tags || {};
    const org = publishedEntity(tags.owner || tags.operator || "");
    const address = {
      house: tags["addr:housenumber"] || "",
      road: tags["addr:street"] || "",
      town: tags["addr:city"] || tags["addr:town"] || "",
      state: stateAbbr(tags["addr:state"] || ""),
      zip: tags["addr:postcode"] || ""
    };
    const street = formatStreet(address);
    const named = publishedEntity(tags.name || "");
    const landuse = tags.landuse || tags.leisure || tags.amenity || tags.boundary || "";
    const kind = /forest service|national forest|usfs/i.test(org + " " + named) ? "usfs" : /bureau of land|\bblm\b/i.test(org + " " + named) ? "blm" : /national park/i.test(org + " " + named + " " + (tags.boundary || "")) ? "nps" : /\bdnr\b|state trust|state land/i.test(org + " " + named) ? "state" : "private";
    const acres = polygonAcres(ring);
    if (!Number.isFinite(acres) || acres < 0.01 || acres > 2500000) return null;
    const center = ringCentroidLatLng(ring);
    let owner = org || (kind !== "private" ? named : "");
    if (!owner && kind === "private") owner = street ? "Private Residential Lot — " + street : (named || "Published OSM footprint");
    if (!owner) owner = named || PARCEL_STYLE[kind].badge;
    return {
      id: "osm-" + (element.id || index),
      ring: ring,
      lat: center.lat,
      lon: center.lon,
      acres: acres,
      kind: kind,
      owner: owner,
      agency: org || "OpenStreetMap",
      address: street,
      zoning: landuse || "",
      parcelId: "",
      source: "OpenStreetMap Overpass",
      live: true
    };
  }

  async function osmFootprints(bounds) {
    const south = bounds.getSouth();
    const west = bounds.getWest();
    const north = bounds.getNorth();
    const east = bounds.getEast();
    const height = north - south;
    const width = east - west;
    const zoom = map.getZoom();
    if (zoom < 11 || height > 0.35 || width > 0.35) return [];
    const box = south + "," + west + "," + north + "," + east;
    let parts = 'way["boundary"="protected_area"](' + box + ');way["boundary"="national_park"](' + box + ');way["landuse"="forest"](' + box + ');';
    if (zoom >= 14 && height <= 0.08 && width <= 0.08) {
      parts += 'way["building"](' + box + ');way["landuse"](' + box + ');way["amenity"](' + box + ');way["leisure"](' + box + ');way["boundary"="lot"](' + box + ');way["addr:housenumber"](' + box + ');';
    }
    const query = "[out:json][timeout:12];(" + parts + ");out tags geom " + (zoom >= 14 ? "16" : "8") + ";";
    let text = "";
    try {
      text = await net("https://overpass-api.de/api/interpreter", { method: "POST", body: query });
    } catch (error) {
      text = await net("https://overpass.kumi.systems/api/interpreter", { method: "POST", body: query });
    }
    if (!text || text.length > 400000) return [];
    const data = JSON.parse(text);
    return (data.elements || []).map(osmParcel).filter(Boolean);
  }

  function showParcelNote(text) {
    state.parcelNote = text || "";
    const node = document.getElementById("parcelNote");
    if (node) node.textContent = state.parcelNote;
  }

  function syncSmaTiles() {
    if (!map || !smaLayer) return;
    const fade = Math.max(0, Math.min(100, Number(state.opacity.parcels) || 0)) / 100;
    toggleTile(smaLayer, !!(state.parcelsOn && fade > 0), fade || 0);
  }

  async function refreshParcels() {
    if (!map || !state.parcelsOn) {
      state.parcelCells = [];
      if (parcelLayer) parcelLayer.clearLayers();
      syncSmaTiles();
      return;
    }
    syncSmaTiles();
    const generation = ++state.parcelGen;
    if (map.getZoom() < 11) {
      state.parcelCells = [];
      drawParcels();
      showParcelNote("Zoom in to load published lot geometry.");
      return;
    }
    if (SHOT) {
      state.parcelCells = [];
      drawParcels();
      showParcelNote("");
      return;
    }
    const center = map.getCenter();
    const point = { lat: center.lat, lon: center.lng };
    const cells = [];
    let clarkDown = false;
    const jobs = [
      usfsAt(point, true).then(function (forest) { if (forest && forest.ring) cells.push(forest); }).catch(function () {}),
      osmFootprints(map.getBounds()).then(function (lots) { lots.forEach(function (lot) { cells.push(lot); }); }).catch(function () {})
    ];
    if (inClark(point)) {
      jobs.push(clarkLots(point).then(function (result) {
        if (!result || result.down) clarkDown = true;
        (result && result.lots || []).forEach(function (lot) {
          if (lot.ring) {
            if (lot.lat == null) { lot.lat = point.lat; lot.lon = point.lon; }
            cells.push(lot);
          }
        });
      }).catch(function () { clarkDown = true; }));
    }
    await Promise.all(jobs);
    if (generation !== state.parcelGen || !state.parcelsOn) return;
    state.parcelCells = cells.filter(function (lot) { return lot.ring && lot.ring.length >= 3; });
    drawParcels();
    if (clarkDown) showParcelNote("Clark County LandRecords is not responding. No tax lot was invented.");
    else if (!state.parcelCells.length) showParcelNote("No published parcel polygon in this view.");
    else showParcelNote("");
    if (state.parcel && state.parcel.ring) {
      const next = parcelAt(state.parcel.lat, state.parcel.lon);
      if (next) openParcel(next);
    }
  }

  async function identifyParcel(lat, lon, hit) {
    const generation = ++identifyGen;
    const point = { lat: lat, lon: lon };
    let sma = null;
    let forest = null;
    let census = {};
    let address = {};
    let clark = null;
    await Promise.all([
      smaIdentify(point).then(function (value) { sma = value; }).catch(function () {}),
      usfsAt(point, !hit || !hit.ring).then(function (value) { forest = value; }).catch(function () {}),
      censusPlace(point).then(function (value) { census = value || {}; }).catch(function () {}),
      nominatimAddress(point).then(function (value) { address = value || {}; }).catch(function () {}),
      inClark(point) ? clarkLots(point).then(function (value) { clark = value; }).catch(function () { clark = { down: true, lots: [] }; }) : Promise.resolve()
    ]);
    if (generation !== identifyGen || !state.parcelsOn) return;
    if (clark && clark.down) showParcelNote("Clark County LandRecords is not responding. No tax lot was invented.");
    const clarkLot = clark && (clark.lots || []).find(function (lot) { return lot.ring && pointInRing(lat, lon, lot.ring); }) || (clark && clark.lots && clark.lots[0]);
    const street = formatStreet(address);
    const county = (census.county) || (address.county ? address.county + (census.state ? ", " + census.state : "") : "") || (hit && hit.county) || "";
    const sources = [];
    let card = {
      id: (hit && hit.id) || ("tap-" + lat.toFixed(5) + "-" + lon.toFixed(5)),
      ring: (hit && hit.ring) || null,
      lat: lat,
      lon: lon,
      acres: hit && Number.isFinite(hit.acres) ? hit.acres : null,
      kind: "private",
      owner: "",
      agency: "",
      address: street || (hit && hit.address) || "",
      county: county,
      censusBlock: census.block || "",
      zoning: (hit && hit.zoning) || "",
      parcelId: (hit && hit.parcelId) || "",
      source: "",
      live: true
    };
    if (clarkLot && clarkLot.ring && (!card.ring || clarkLot.parcelId)) {
      card.ring = clarkLot.ring;
      card.acres = clarkLot.acres;
      card.parcelId = clarkLot.parcelId || card.parcelId;
      card.zoning = clarkLot.zoning || card.zoning;
      card.address = clarkLot.address || card.address;
      card.county = "Clark County, WA";
      if (clarkLot.owner && clarkLot.owner.indexOf("Private Residential") !== 0) card.owner = clarkLot.owner;
      sources.push("Clark County LandRecords");
    }
    if (forest) {
      card.kind = "usfs";
      card.owner = forest.owner;
      card.agency = "U.S. Forest Service (USFS)";
      card.badge = "U.S. FOREST SERVICE";
      card.zoning = card.zoning || "National Forest";
      if (!card.ring && forest.ring) {
        card.ring = forest.ring;
        card.acres = forest.acres;
      }
      sources.push("USFS EDW Forest System Boundaries");
    }
    if (sma && !sma.private) {
      card.kind = sma.kind || card.kind;
      card.owner = card.owner || sma.owner;
      card.agency = sma.agency || card.agency;
      card.badge = sma.badge || card.badge;
      sources.push(sma.source || "BLM Surface Management Agency");
    } else if (sma && sma.private) {
      sources.push("BLM Surface Management Agency");
      if (!card.owner) card.kind = "private";
    }
    if (address.org && card.kind === "private") {
      card.owner = address.org;
      card.agency = address.org;
    }
    if (!card.owner) {
      card.owner = card.kind === "private" ? residentialTitle(address) : (card.agency || "Published parcel");
    }
    if (!card.agency) card.agency = card.kind === "private" ? (county || "County assessor") : card.owner;
    if (hit && hit.source) sources.push(hit.source);
    if (street) sources.push("OpenStreetMap Nominatim");
    if (census.block || census.county) sources.push("U.S. Census Bureau");
    card.source = sources.filter(function (item, index, list) { return item && list.indexOf(item) === index; }).join(" · ");
    if (!card.parcelId) card.parcelId = "";
    if (card.ring && !state.parcelCells.some(function (lot) { return lot.id === card.id; })) {
      state.parcelCells = state.parcelCells.concat([card]);
      drawParcels();
    }
    openParcel(card);
  }
  function loadOpacity() {
    const base = { parcels: 100, corridors: 70, slope: 55, hazards: 80 };
    try { return Object.assign(base, JSON.parse(localStorage.getItem("tf-opacity") || "{}")); }
    catch (error) { return base; }
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
    const dashBtn = document.getElementById("dashBtn");
    if (dashBtn) dashBtn.classList.toggle("on", dashOn());
    renderDrawer();
    if (!map) return;
    clearTimeout(chromeTimer);
    chromeTimer = setTimeout(function () {
      if (map) map.invalidateSize();
      paintElevation();
    }, 60);
  }

  function setDetent(id) {
    if (id !== "peek" && id !== "split" && id !== "full") return;
    state.detent = id;
    localStorage.setItem("tf-detent", id);
    applyChrome();
  }

  function renderDrawer() {
    const drawer = document.getElementById("layerDrawer");
    if (!drawer) return;
    drawer.hidden = !state.drawer;
    drawer.querySelectorAll("[data-panel]").forEach(function (panel) {
      panel.hidden = panel.dataset.panel !== state.drawer;
    });
    const titles = { layers: "Layers & Opacity", corridor: "5-Mile Corridor", plot: "Custom Route" };
    const title = document.getElementById("drawerTitle");
    if (title) title.textContent = titles[state.drawer] || "Layers";
    drawer.querySelectorAll("[data-act=basemap]").forEach(function (button) {
      button.classList.toggle("on", button.dataset.id === state.basemap);
    });
    drawer.querySelectorAll("[data-act=pack-kind]").forEach(function (button) {
      button.classList.toggle("on", button.dataset.id === state.packKind);
    });
    drawer.querySelectorAll("[data-act=plot-mode]").forEach(function (button) {
      button.classList.toggle("on", button.dataset.id === state.plotMode);
    });
    drawer.querySelectorAll("[data-overlay]").forEach(function (input) {
      if (document.activeElement === input) return;
      const value = state.opacity[input.dataset.overlay];
      if (value != null) input.value = value;
    });
    Object.keys(state.opacity).forEach(function (name) {
      const read = document.querySelector('[data-read="' + name + '"]');
      if (read) read.textContent = state.opacity[name] + "%";
    });
    const count = document.getElementById("plotCount");
    const verdict = document.getElementById("plotFit");
    const fit = state.plot.length ? plotFit() : null;
    if (count) count.textContent = state.plot.length + (state.plot.length === 1 ? " point" : " points");
    if (verdict) {
      verdict.textContent = fit ? shortFit(fit.verdict) : "—";
      verdict.style.color = fit ? fitColor(fit.verdict) : "";
    }
    const list = document.getElementById("packList");
    if (list) {
      list.innerHTML = state.packs.length ? state.packs.map(function (pack) {
        const label = pack.kind === "satellite" ? "Max Satellite" : "Standard Topo";
        return '<div class="pack"><b>' + esc(pack.name) + "</b><small>" + esc(label) + " · " + pack.tiles + " tiles</small><button type=\"button\" data-act=\"drop-pack\" data-id=\"" + esc(pack.id) + "\">Remove</button></div>";
      }).join("") : '<div class="sub">No corridor saved on this device yet.</div>';
    }
    const plotBtn = document.querySelector('#rail [data-act="plot"]');
    const layerBtn = document.querySelector('#rail [data-act="layers"]');
    const corridorBtn = document.querySelector('#rail [data-act="corridor"]');
    if (plotBtn) plotBtn.classList.toggle("on", state.plotting);
    if (layerBtn) layerBtn.classList.toggle("on", state.drawer === "layers");
    if (corridorBtn) corridorBtn.classList.toggle("on", state.drawer === "corridor" || state.packBusy);
  }

  function setOverlay(name, value) {
    if (!state.opacity[name] && state.opacity[name] !== 0) return;
    state.opacity[name] = Math.max(0, Math.min(100, Math.round(value)));
    localStorage.setItem("tf-opacity", JSON.stringify(state.opacity));
    const read = document.querySelector('[data-read="' + name + '"]');
    if (read) read.textContent = state.opacity[name] + "%";
    if (name === "parcels") {
      if (state.opacity.parcels > 0 && !state.parcelsOn) {
        state.parcelsOn = true;
        localStorage.setItem("tf-parcels", "1");
        scheduleParcels();
      }
      drawParcels();
      syncSmaTiles();
      updateHud();
      return;
    }
    syncOverlays();
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

  function applyBasemap() {
    if (!hybridLayer || !map) return;
    const center = map.getCenter();
    const outside = !usgsCovers(center.lat, center.lng);
    const deep = map.getZoom() > 16;
    const dark = state.basemap === "dark";
    const mode = state.thermal ? "topo" : state.basemap;
    const showUsgs = !outside && !dark;
    toggleTile(hybridLayer, showUsgs && mode === "hybrid", 1);
    toggleTile(imageryLayer, showUsgs && mode === "satellite", 1);
    toggleTile(topoLayer, showUsgs && mode === "topo", 1);
    toggleTile(darkLayer, dark, 1);
    if (osmLayer) {
      osmLayer.options.minZoom = outside ? 3 : 17;
      toggleTile(osmLayer, !dark && (outside || deep), 1);
      if (map.hasLayer(osmLayer)) osmLayer.redraw();
    }
    if (map.attributionControl) map.attributionControl.setPrefix(MAP_ATTRIB);
    if (offlineLayer) offlineLayer.redraw();
  }

  function isCorridor(trail) {
    if (trail.bdr) return true;
    return /usfs|forest service|national forest|\bblm\b|bureau of land|\bdnr\b|state trust|state forest/i.test(String(trail.agency || ""));
  }

  function syncOverlays() {
    if (!map || !corridorLayer || !slopeLayer || !hazardLayer) return;
    corridorLayer.clearLayers();
    slopeLayer.clearLayers();
    hazardLayer.clearLayers();
    const corridorFade = Math.max(0, Math.min(100, Number(state.opacity.corridors) || 0)) / 100;
    if (corridorFade > 0) {
      drawableTrails().forEach(function (trail) {
        if (!isCorridor(trail) || !trail.coordinates || trail.coordinates.length < 2) return;
        const color = /blm|bureau of land/i.test(trail.agency || "") ? "#f5e642" : "#14915a";
        L.polyline(trail.coordinates, {
          color: color,
          weight: 16,
          opacity: corridorFade * 0.45,
          lineCap: "round",
          lineJoin: "round"
        }).addTo(corridorLayer);
      });
    }
    const slopeFade = Math.max(0, Math.min(100, Number(state.opacity.slope) || 0)) / 100;
    const trail = selected();
    if (slopeFade > 0 && trail) {
      const profile = elevationProfile(trail);
      for (let index = 1; index < profile.length; index += 1) {
        const grade = Math.abs(gradeDegrees(profile[index - 1], profile[index]));
        const color = grade < 3 ? "#3ddc84" : grade < 8 ? "#ff9f1a" : "#ff4d4d";
        L.polyline([[profile[index - 1].lat, profile[index - 1].lon], [profile[index].lat, profile[index].lon]], {
          color: color,
          weight: 8,
          opacity: slopeFade * 0.85,
          lineCap: "round"
        }).addTo(slopeLayer);
      }
    }
    const hazardFade = Math.max(0, Math.min(100, Number(state.opacity.hazards) || 0)) / 100;
    if (hazardFade <= 0) return;
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

  function queueReport(status) {
    const trail = selected();
    if (!trail || REPORTS.indexOf(status) < 0) return;
    state.reports.unshift({
      trailId: trail.id,
      status: status,
      time: Date.now(),
      lat: state.fix ? state.fix.lat : trail.lat,
      lon: state.fix ? state.fix.lon : trail.lon
    });
    state.reports = state.reports.slice(0, 40);
    localStorage.setItem("tf-reports", JSON.stringify(state.reports));
    toast(status + " queued on this device");
    renderSheet();
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

  function drawPlot() {
    if (!plotLayer) return;
    plotLayer.clearLayers();
    const fit = state.plot.length ? plotFit() : null;
    for (let index = 1; index < state.plot.length; index += 1) {
      const prev = state.plot[index - 1];
      const next = state.plot[index];
      const free = prev.mode === "freehand" || next.mode === "freehand";
      const line = [[prev.lat, prev.lon], [next.lat, next.lon]];
      L.polyline(line, { color: "#071428", weight: 5, opacity: 0.95, dashArray: free ? "6 8" : null }).addTo(plotLayer);
      L.polyline(line, { color: fit ? fitColor(fit.verdict) : "#38bdf8", weight: 3.2, opacity: 1, dashArray: free ? "6 8" : null }).addTo(plotLayer);
    }
    state.plot.forEach(function (point, index) {
      const icon = L.divIcon({ className: "flag-pin", html: "<span>" + (index + 1) + "</span>", iconAnchor: [12, 12] });
      L.marker([point.lat, point.lon], { icon: icon, zIndexOffset: 640 }).addTo(plotLayer);
    });
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
    onParcelMapClick(event);
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
    const xml = gpxXml(trail ? trail.name + " custom" : "TrailForge route", state.plot, collectWaypoints(trail));
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

  async function downloadCorridor() {
    if (state.packBusy) { toast("A corridor download is already running"); return; }
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
    const status = document.getElementById("packStatus");
    const keys = [];
    let bytes = 0;
    let failed = 0;
    const root = kind === "satellite"
      ? "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/tile/"
      : "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/";
    try {
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
    } finally {
      state.packBusy = false;
    }
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

  function cruxPins(trail) {
    const coords = trail && trail.coordinates;
    if (!coords || coords.length < 2) return [];
    const pins = [];
    const fit = evaluate(trail);
    const main = fit.verdict.indexOf("NO-GO") >= 0 ? "No-Go" : fit.verdict === "CAUTION" ? "Caution" : "Fits";
    if (Number(trail.clearance) > 0) {
      const inches = Math.max(1, Math.round(Number(trail.clearance)));
      pins.push(Object.assign({
        id: trail.id + "-rock",
        short: "🪨 " + inches + '"',
        title: "🪨 Obstacle #1: " + inches + '" Rock Ledge — Main Line: ' + main + " / Bypass: Fits All Rigs",
        speak: inches + " inch rock ledge. Main line " + main + ". Bypass fits all rigs."
      }, alongTrack(coords, 0.62)));
    }
    if (Number(trail.water) > 0) {
      const inches = Math.max(1, Math.round(Number(trail.water)));
      pins.push(Object.assign({
        id: trail.id + "-ford",
        short: "💧 " + inches + '"',
        title: "💧 Obstacle #2: " + inches + '" Creek Ford — Check USGS Gauge',
        speak: inches + " inch creek ford. Check the USGS gauge."
      }, alongTrack(coords, 0.38)));
    }
    if (trail.gate && String(trail.gate).toUpperCase() !== "OPEN") {
      pins.push(Object.assign({
        id: trail.id + "-gate",
        short: "🔒 Gate",
        title: "🔒 Gate — " + trail.gate,
        speak: "Gate ahead. Status " + trail.gate + "."
      }, alongTrack(coords, 0.18)));
    }
    if (Number(trail.canopy) > 0 && Number(trail.canopy) < 11) {
      pins.push(Object.assign({
        id: trail.id + "-shelf",
        short: "⚠️ Shelf",
        title: "⚠️ Narrow Off-Camber Shelf",
        speak: "Narrow off-camber shelf ahead. Canopy " + num(trail.canopy) + " feet."
      }, alongTrack(coords, 0.78)));
    }
    return pins;
  }

  function speakHazards() {
    if (!state.fix || (!state.route && !state.follow)) return;
    const trail = selected();
    if (!trail) return;
    cruxPins(trail).forEach(function (pin) {
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
    if (state.convoy) marks.push({ lat: state.fix ? state.fix.lat : (trail ? trail.lat : 0), lon: state.fix ? state.fix.lon : (trail ? trail.lon : 0), name: state.convoy, sym: "Convoy", type: "convoy", desc: "Local convoy status" });
    return marks.filter(function (mark) { return Number.isFinite(mark.lat) && Number.isFinite(mark.lon); });
  }

  function tripLine() {
    if (state.plot.length >= 2) return state.plot.map(function (point) { return { lat: point.lat, lon: point.lon }; });
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
    let text = "";
    while (sample.length) {
      text = "TF1|" + name + "|" + sample.map(function (point) { return point.lat.toFixed(4) + "," + point.lon.toFixed(4); }).join(";");
      if (state.convoy) text += "|C|" + state.convoy;
      if (text.length <= 900 || sample.length <= 4) break;
      sample = sample.filter(function (_, index) { return index % 2 === 0; });
    }
    return text;
  }

  function downloadText(text, filename, type) {
    const blob = new Blob([text], { type: type || "application/octet-stream" });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    link.remove();
    setTimeout(function () { URL.revokeObjectURL(url); }, 1500);
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
    if (points.length < 2 && !state.dropped.length) { toast("Select a trail or plot a route first"); return; }
    const name = state.plot.length >= 2 ? "Custom route" : corridorLabel(trail || { name: "TrailForge trip" });
    const xml = gpxXml(name, points.length ? points : [{ lat: state.fix ? state.fix.lat : 0, lon: state.fix ? state.fix.lon : 0 }], collectWaypoints(trail));
    downloadText(xml, "TrailForge-trip.gpx", "application/gpx+xml");
    const compact = tripCompact(name, points.length ? points : collectWaypoints(trail));
    paintQr(compact);
    const modal = document.getElementById("qrModal");
    if (modal) modal.hidden = false;
    const caption = document.getElementById("qrCaption");
    if (caption) caption.textContent = name + (state.convoy ? " · " + state.convoy : "");
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

  function boot() {
    state.trails = buildBuiltins();
    map = L.map("map", { zoomControl: false, attributionControl: true, minZoom: 3, maxZoom: 19 });
    map.setView([37.9589, -107.7352], 11);
    if (map.attributionControl) map.attributionControl.setPrefix(MAP_ATTRIB);
    const usgsOpts = { maxNativeZoom: 16, maxZoom: 19, zIndex: 1, attribution: "" };
    hybridLayer = L.tileLayer(USGS_TILES.hybrid, usgsOpts);
    imageryLayer = L.tileLayer(USGS_TILES.satellite, usgsOpts);
    topoLayer = L.tileLayer(USGS_TILES.topo, usgsOpts);
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
    trailLayer = L.layerGroup().addTo(map);
    campLayer = L.layerGroup().addTo(map);
    routeLayer = L.layerGroup().addTo(map);
    parcelLayer = L.layerGroup().addTo(map);
    hazardLayer = L.layerGroup().addTo(map);
    hazardPinLayer = L.layerGroup().addTo(map);
    plotLayer = L.layerGroup().addTo(map);
    map.on("dragstart", function () { state.follow = false; });
    map.on("zoomend", function () { applyBasemap(); syncMap(); scheduleParcels(); });
    map.on("moveend", function () { applyBasemap(); scheduleParcels(); });
    map.on("click", onMapClick);
    document.addEventListener("click", function (event) {
      const button = event.target.closest("[data-act]");
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
      if (event.target.id === "search") {
        state.query = event.target.value;
        const list = pickerTrails();
        if (!list.some(function (trail) { return trail.id === state.selectedId; }) && list[0]) state.selectedId = list[0].id;
        renderAll();
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
    window.addEventListener("deviceorientation", function (event) {
      if (SHOT) return;
      if (window.TrailForgeSpeech && state.compass != null) return;
      if (event.beta == null) return;
      let pitch = event.beta;
      if (Math.abs(pitch) > 50) pitch -= Math.sign(pitch) * 90;
      onAttitude({ pitch: pitch, roll: event.gamma || 0, heading: event.webkitCompassHeading || event.alpha });
    });
    window.addEventListener("online", function () { state.online = true; });
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
    setMuted(state.muted);
    renderAll();
    syncSmaTiles();
    startGeolocation();
    loadTelemetry();
    bootShot();
    scheduleParcels();
    refreshMvum(selected());
    setTimeout(function () {
      map.invalidateSize();
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
