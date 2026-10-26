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
    targetCopy: ""
  };

  const pendingNet = new Map();
  let netSeq = 0;
  let map;
  let puck;
  let trailLayer;
  let campLayer;
  let routeLayer;
  let toastTimer;

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
        signature: !!spec.signature
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
    return state.filter;
  }

  function pickerTrails() {
    const query = state.query.trim().toLowerCase();
    const seen = new Set();
    let list = allTrails().filter(function (trail) {
      if (seen.has(trail.id)) return false;
      seen.add(trail.id);
      if (query) {
        const hay = (trail.name + " " + trail.region + " " + trail.state + " " + trail.agency).toLowerCase();
        if (!hay.includes(query)) return false;
      }
      if (state.filter === "all" || state.filter === "near") return true;
      return trail.state === state.filter;
    });
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
    const title = !list.length || !trail ? "No routes for " + filterTitle() : fit.verdict + " · " + trail.name;
    const detail = !list.length || !trail ? "Pick another state or tap Near Me." : bannerDetail(trail, fit);
    top.innerHTML = '<div class="fit"><div class="lamp" style="background:' + color + ";color:" + color + '"></div><div class="fit-copy"><div class="fit-title">' + esc(title) + '</div><div class="sub">' + esc(detail) + '</div></div><button type="button" class="pill-btn" data-act="offline">' + (state.offlineSaved ? "Offline" : "Save") + "</button></div>";
  }

  function routeBarHtml() {
    if (!state.route) return "";
    const spot = state.route.destination;
    const remaining = remainingMeters(state.route);
    const seconds = remainingSeconds(state.route, remaining);
    const eta = formatClock(new Date(Date.now() + seconds * 1000));
    const slope = spot.kind === "pad" ? spot.slope.toFixed(1) + "°" : "Trailhead";
    const sky = spot.kind === "pad" ? spot.starlink + "%" : "—";
    const slopeLabel = spot.kind === "pad" ? "pad slope" : "destination";
    const skyLabel = spot.kind === "pad" ? "Starlink" : "sky";
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
    const chips = ['<button type="button" class="chip' + (state.filter === "near" ? " on" : "") + '" data-act="filter" data-id="near">Near Me</button>', '<button type="button" class="chip' + (state.filter === "all" ? " on" : "") + '" data-act="filter" data-id="all">All USA</button>'].concat(ATLAS.states.map(function (box) {
      return '<button type="button" class="chip' + (state.filter === box.code ? " on" : "") + '" data-act="filter" data-id="' + box.code + '">' + box.code + "</button>";
    })).join("");
    const rows = list.map(function (trail) {
      const fit = evaluate(trail);
      const away = state.fix ? " · " + miles(state.fix, trail).toFixed(1) + " mi away" : "";
      return '<button type="button" class="row" data-act="pick" data-id="' + esc(trail.id) + '"><i class="dot" style="background:' + fitColor(fit.verdict) + '"></i><span class="meta"><b>' + esc(trail.state + " · " + trail.name) + "</b><small>" + esc(trail.miles + " mi · " + num(trail.clearance) + '" · ' + shortFit(fit.verdict) + away) + "</small></span></button>";
    }).join("") || '<div class="row"><span class="meta"><b>No matching routes</b></span></div>';
    const pills = list.slice(0, 24).map(function (trail) {
      const label = state.fix ? trail.name + " · " + Math.round(miles(state.fix, trail)) + " mi" : trail.name;
      return '<button type="button" class="trail-pill' + (trail.id === state.selectedId ? " on" : "") + '" data-act="pick" data-id="' + esc(trail.id) + '">' + esc(label) + "</button>";
    }).join("");
    const trail = selected();
    const telemetry = telemetryHtml(trail);
    return '<input class="search" id="search" placeholder="Search trails or state" value="' + esc(state.query) + '" /><div class="chips">' + chips + '</div><button type="button" class="menu-btn" id="trailMenu" data-act="menu">' + esc(countLabel) + '</button><div class="menu' + (state.menuOpen ? " open" : "") + '" id="trailList">' + rows + '</div><div class="pills">' + pills + '</div><div class="status" id="scanStatus">' + esc(state.scanning ? "Scanning USA 4x4 trails…" : state.scanStatus) + "</div>" + telemetry;
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
    const chips = '<div class="chips"><button type="button" class="chip' + (state.filter === "near" ? " on" : "") + '" data-act="filter" data-id="near">Near Me</button>' + ATLAS.states.map(function (box) {
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
    return '<input class="name" data-field="name" value="' + esc(profile.name) + '" aria-label="Rig name" /><div class="rig-live"><div class="dial"><div class="horizon" id="horizon" style="transform:' + horizon + '"></div><div class="cross"></div></div><div class="psi"><b id="psiRead">' + psi.front + "F / " + psi.rear + 'R</b><span>Air-down PSI · ' + esc(state.surface) + '</span><div class="sub" id="tiltRead">Pitch ' + Math.round(state.pitch) + "° · Roll " + Math.round(state.roll) + "°</div></div></div>" + products + '<div class="actions"><button type="button" data-act="restore">Restore purchases</button></div><div class="seg">' + locker("none", "Open diffs") + locker("rear", "Rear locker") + '<button type="button" data-act="snorkel" class="' + (profile.hasSnorkel ? "on" : "") + '">Snorkel</button><button type="button" data-act="bead" class="' + (state.beadlocks ? "on" : "") + '">Beadlocks</button></div><div class="seg" style="margin-top:8px">' + surface + '</div><div class="grid" style="margin-top:8px">' + fields + '</div><div class="foot">TrailForge Overland 1.0.0 · build 5<br><a href="https://krokemoutdoors.github.io/trailforge-overland/#privacy" data-act="privacy">Privacy policy</a></div>';
  }

  function renderSheet() {
    document.getElementById("routebar").innerHTML = routeBarHtml();
    const active = document.activeElement;
    if (active && active.matches && active.matches("input[type=range], input.name")) return;
    const typingSearch = active && active.id === "search";
    const caret = typingSearch ? active.selectionStart : null;
    document.getElementById("sheet").innerHTML = sheetHtml();
    if (!typingSearch) return;
    const search = document.getElementById("search");
    if (!search) return;
    search.focus();
    const pos = Math.min(caret || 0, search.value.length);
    search.setSelectionRange(pos, pos);
  }

  function renderAll() {
    document.getElementById("app").dataset.mode = state.mode;
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
      L.polyline(trail.coordinates, {
        color: "#071018",
        weight: selectedTrail ? 7 : 5,
        opacity: 0.85,
        lineCap: "round",
        lineJoin: "round"
      }).addTo(trailLayer);
      L.polyline(trail.coordinates, {
        color: fitColor(fit.verdict),
        weight: selectedTrail ? 4 : 3,
        opacity: 0.95,
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
          L.marker([spot.lat, spot.lon], { icon: icon, zIndexOffset: 400 }).on("click", function () {
            beginRoute(spot);
          }).addTo(campLayer);
        });
      }
      if (selectedTrail) {
        const head = trailhead(trail);
        const flag = L.divIcon({ className: "flag-pin", html: "<span>⚑</span>", iconAnchor: [12, 12] });
        L.marker([head.lat, head.lon], { icon: flag, zIndexOffset: 450 }).on("click", function () {
          beginRoute(head);
        }).addTo(campLayer);
      }
    });
    drawRoute();
    updatePuck();
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
    if (!state.follow) focusTrail(selected(), state.filter === "all" ? 4 : 8);
    renderAll();
    if (!scan || SHOT) return;
    if (state.filter === "near") scanAt(state.fix || mapCenter());
    else if (state.filter !== "all") {
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
    if (!state.centeredOnce && !state.route && !SHOT) {
      state.centeredOnce = true;
      if (state.filter === "near") applyFilter(true);
      else map.setView([fix.lat, fix.lon], Math.max(map.getZoom(), 12));
    }
    if (state.follow) map.panTo([fix.lat, fix.lon]);
    maybeSpeakCues();
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
        bySite[site] = bySite[site] || { name: name, cfs: 0, height: 0 };
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
      const url = "https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/services/WFIGS_Interagency_Perimeters_Current/FeatureServer/0/query?where=1%3D1&outFields=poly_IncidentName,poly_GISAcres,attr_PercentContained&geometry=" + minLon + "," + minLat + "," + maxLon + "," + maxLat + "&geometryType=esriGeometryEnvelope&inSR=4326&spatialRel=esriSpatialRelIntersects&f=json&resultRecordCount=5";
      const text = await net(url);
      const root = JSON.parse(text);
      state.fires = (root.features || []).map(function (feature) {
        const props = feature.attributes || {};
        return {
          name: props.poly_IncidentName || "Active incident",
          acres: Number(props.poly_GISAcres) || 0,
          contained: Number(props.attr_PercentContained) || 0
        };
      });
    } catch (error) { /* Fire card stays quiet when the feed is down. */ }
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
      focusTrail(selected(), 11);
      renderAll();
      loadTelemetry();
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
    if (act === "privacy") {
      openExternal("https://krokemoutdoors.github.io/trailforge-overland/#privacy");
    }
  }

  function onBack() {
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

  function boot() {
    state.trails = buildBuiltins();
    map = L.map("map", { zoomControl: false, attributionControl: true, minZoom: 3, maxZoom: 18 });
    map.setView([37.9589, -107.7352], 11);
    L.tileLayer("https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}", {
      maxZoom: 19,
      attribution: "Esri, Maxar, Earthstar Geographics"
    }).addTo(map);
    L.tileLayer("https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{z}/{y}/{x}", {
      maxZoom: 16,
      opacity: 0.38,
      attribution: "USGS"
    }).addTo(map);
    L.tileLayer("https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}", {
      maxZoom: 19,
      opacity: 0.9,
      attribution: ""
    }).addTo(map);
    trailLayer = L.layerGroup().addTo(map);
    campLayer = L.layerGroup().addTo(map);
    routeLayer = L.layerGroup().addTo(map);
    map.on("dragstart", function () { state.follow = false; });
    map.on("zoomend", syncMap);
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
    installHost();
    setMuted(state.muted);
    renderAll();
    startGeolocation();
    loadTelemetry();
    bootShot();
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
