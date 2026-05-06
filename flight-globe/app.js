/* Flight Routes 3D Globe
 * - Static dataset: OpenFlights (airports, airlines, routes) bundled into data/bundle.json
 * - Live layer: OpenSky Network /api/states/all polled every 15s, filtered by airline ICAO callsign prefix.
 */

const $ = (sel) => document.querySelector(sel);
const els = {
  globe: $('#globe'),
  search: $('#search'),
  list: $('#airline-list'),
  info: $('#info'),
  status: $('#status'),
  tip: $('#hover-tip'),
  toggleLive: $('#toggle-live'),
  toggleRoutes: $('#toggle-routes'),
  toggleAirports: $('#toggle-airports'),
};

const state = {
  bundle: null,
  airlinesFiltered: [],
  selectedAirline: null,   // airline object
  routes: [],              // resolved arc data for selected airline
  airports: [],            // points for selected airline
  liveStates: [],          // raw OpenSky states for selected airline
  livePollTimer: null,
  liveAbort: null,
};

const OPENSKY_URL = 'https://opensky-network.org/api/states/all';
const POLL_MS = 15_000;

// ── Globe setup ────────────────────────────────────────────────────────────
const globe = Globe()(els.globe)
  .globeImageUrl('https://unpkg.com/three-globe@2.32.0/example/img/earth-night.jpg')
  .bumpImageUrl('https://unpkg.com/three-globe@2.32.0/example/img/earth-topology.png')
  .backgroundImageUrl('https://unpkg.com/three-globe@2.32.0/example/img/night-sky.png')
  .showAtmosphere(true)
  .atmosphereColor('#6ee0ff')
  .atmosphereAltitude(0.18);

globe.controls().autoRotate = true;
globe.controls().autoRotateSpeed = 0.35;
globe.controls().enableDamping = true;

// Fit to viewport.
function resize() {
  globe.width(window.innerWidth);
  globe.height(window.innerHeight);
}
window.addEventListener('resize', resize);
resize();

// Arcs (route lines)
globe
  .arcsData([])
  .arcStartLat(d => d.startLat)
  .arcStartLng(d => d.startLng)
  .arcEndLat(d => d.endLat)
  .arcEndLng(d => d.endLng)
  .arcColor(() => ['rgba(110,224,255,0.85)', 'rgba(34,184,255,0.15)'])
  .arcStroke(0.35)
  .arcAltitudeAutoScale(0.4)
  .arcDashLength(0.4)
  .arcDashGap(0.6)
  .arcDashAnimateTime(4000)
  .arcLabel(d => `<b>${d.airline}</b><br/>${d.from} → ${d.to}`);

// Airport points
globe
  .pointsData([])
  .pointLat(d => d.lat)
  .pointLng(d => d.lng)
  .pointColor(() => '#ffd66e')
  .pointAltitude(0.005)
  .pointRadius(0.18)
  .pointLabel(d => `<b>${d.iata}</b> · ${d.name}<br/><span style="opacity:.7">${d.city || ''}${d.city ? ', ' : ''}${d.country || ''}</span>`);

// Live aircraft (rendered as small custom 3D objects so they sit above the surface)
globe
  .objectsData([])
  .objectLat(d => d.lat)
  .objectLng(d => d.lng)
  .objectAltitude(d => Math.min(0.18, (d.alt || 10000) / 200000))
  .objectThreeObject(makePlaneObject)
  .objectLabel(d => `<b>${d.callsign || '—'}</b><br/>${d.origin || ''}<br/>${Math.round(d.speed * 3.6)} km/h · ${Math.round((d.alt || 0))} m`);

function makePlaneObject(d) {
  // Tiny cone pointing in direction of travel.
  const geo = new THREE.ConeGeometry(0.6, 1.6, 4);
  geo.rotateX(Math.PI / 2);
  const mat = new THREE.MeshBasicMaterial({ color: 0xff7a59 });
  const mesh = new THREE.Mesh(geo, mat);
  if (d.heading != null) mesh.rotation.z = -d.heading * Math.PI / 180;
  return mesh;
}

// ── Data loading ───────────────────────────────────────────────────────────
async function loadBundle() {
  setStatus('loading data…', 'loading');
  const res = await fetch('data/bundle.json');
  if (!res.ok) throw new Error('Failed to load bundle.json');
  state.bundle = await res.json();
  state.airlinesFiltered = state.bundle.airlines;
  renderAirlineList();
  setStatus('idle — pick an airline', 'idle');
}

// ── UI: airline list ───────────────────────────────────────────────────────
function renderAirlineList() {
  const q = els.search.value.trim().toLowerCase();
  const filtered = q
    ? state.bundle.airlines.filter(a =>
        a.name.toLowerCase().includes(q) ||
        (a.iata || '').toLowerCase() === q ||
        (a.icao || '').toLowerCase() === q ||
        (a.country || '').toLowerCase().includes(q)
      )
    : state.bundle.airlines;
  state.airlinesFiltered = filtered.slice(0, 200);
  els.list.innerHTML = state.airlinesFiltered.map(a => `
    <li data-iata="${a.iata}" class="${state.selectedAirline?.iata === a.iata ? 'active' : ''}">
      <span><span class="iata">${a.iata}</span>${escapeHtml(a.name)}</span>
      <span class="meta">${a.routeCount}</span>
    </li>
  `).join('');
  for (const li of els.list.querySelectorAll('li')) {
    li.addEventListener('click', () => selectAirline(li.dataset.iata));
  }
}

els.search.addEventListener('input', renderAirlineList);

// ── Airline selection ──────────────────────────────────────────────────────
function selectAirline(iata) {
  const airline = state.bundle.airlines.find(a => a.iata === iata);
  if (!airline) return;
  state.selectedAirline = airline;

  const routeRows = state.bundle.routes[iata] || [];
  const ap = state.bundle.airports;

  const arcs = [];
  const usedAirports = new Map();
  for (const [src, dst] of routeRows) {
    const s = ap[src], d = ap[dst];
    if (!s || !d) continue;
    arcs.push({
      airline: airline.name,
      from: src, to: dst,
      startLat: s[0], startLng: s[1],
      endLat: d[0], endLng: d[1]
    });
    usedAirports.set(src, s);
    usedAirports.set(dst, d);
  }
  state.routes = arcs;
  state.airports = Array.from(usedAirports, ([iata, a]) => ({
    iata, lat: a[0], lng: a[1], name: a[2], city: a[3], country: a[4]
  }));

  renderInfo();
  renderAirlineList();
  applyLayers();
  fitToAirline();
  startLivePolling();
}

function fitToAirline() {
  if (!state.airports.length) return;
  // Fly to the centroid of the airline's airports.
  let x = 0, y = 0, z = 0;
  for (const a of state.airports) {
    const lat = a.lat * Math.PI / 180, lng = a.lng * Math.PI / 180;
    x += Math.cos(lat) * Math.cos(lng);
    y += Math.cos(lat) * Math.sin(lng);
    z += Math.sin(lat);
  }
  const n = state.airports.length;
  x /= n; y /= n; z /= n;
  const lat = Math.atan2(z, Math.hypot(x, y)) * 180 / Math.PI;
  const lng = Math.atan2(y, x) * 180 / Math.PI;
  globe.controls().autoRotate = false;
  globe.pointOfView({ lat, lng, altitude: 2.2 }, 1500);
}

function renderInfo() {
  const a = state.selectedAirline;
  if (!a) {
    els.info.innerHTML = '<div class="placeholder">Select an airline to view its route network.</div>';
    return;
  }
  els.info.innerHTML = `
    <div class="name">${escapeHtml(a.name)}</div>
    <div class="stat"><span>IATA / ICAO</span><b>${a.iata || '—'} / ${a.icao || '—'}</b></div>
    <div class="stat"><span>Country</span><b>${escapeHtml(a.country || '—')}</b></div>
    <div class="stat"><span>Routes</span><b>${state.routes.length}</b></div>
    <div class="stat"><span>Airports served</span><b>${state.airports.length}</b></div>
    <div class="stat"><span>Live aircraft</span><b id="live-count">${state.liveStates.length}</b></div>
  `;
}

// ── Layer toggles ──────────────────────────────────────────────────────────
function applyLayers() {
  globe.arcsData(els.toggleRoutes.checked ? state.routes : []);
  globe.pointsData(els.toggleAirports.checked ? state.airports : []);
  globe.objectsData(els.toggleLive.checked ? state.liveStates : []);
}
[els.toggleRoutes, els.toggleAirports, els.toggleLive].forEach(el =>
  el.addEventListener('change', () => {
    if (el === els.toggleLive) {
      if (el.checked) startLivePolling();
      else stopLivePolling();
    }
    applyLayers();
  })
);

// ── OpenSky live polling ───────────────────────────────────────────────────
function startLivePolling() {
  stopLivePolling();
  if (!els.toggleLive.checked) return;
  if (!state.selectedAirline) return;
  pollLive();
  state.livePollTimer = setInterval(pollLive, POLL_MS);
}
function stopLivePolling() {
  if (state.livePollTimer) clearInterval(state.livePollTimer);
  state.livePollTimer = null;
  if (state.liveAbort) state.liveAbort.abort();
  state.liveAbort = null;
}

async function pollLive() {
  const a = state.selectedAirline;
  if (!a) return;
  setStatus('fetching live aircraft…', 'loading');
  try {
    if (state.liveAbort) state.liveAbort.abort();
    state.liveAbort = new AbortController();
    const res = await fetch(OPENSKY_URL, { signal: state.liveAbort.signal });
    if (!res.ok) throw new Error(`OpenSky HTTP ${res.status}`);
    const data = await res.json();
    state.liveStates = filterByAirline(data.states || [], a);
    applyLayers();
    const cnt = document.getElementById('live-count');
    if (cnt) cnt.textContent = state.liveStates.length;
    setStatus(`live · ${state.liveStates.length} aircraft · updated ${new Date().toLocaleTimeString()}`, 'live');
  } catch (err) {
    if (err.name === 'AbortError') return;
    console.warn(err);
    setStatus('OpenSky unreachable (rate-limited?). Retrying…', 'error');
  }
}

// OpenSky state vector layout:
// [icao24, callsign, origin_country, time_position, last_contact, longitude, latitude,
//  baro_altitude, on_ground, velocity, true_track, vertical_rate, sensors, geo_altitude, ...]
function filterByAirline(states, airline) {
  const icao = (airline.icao || '').toUpperCase();
  const out = [];
  for (const s of states) {
    const cs = (s[1] || '').trim().toUpperCase();
    if (!cs) continue;
    if (icao && !cs.startsWith(icao)) continue;
    if (!icao) {
      // Airline has no ICAO code in OpenFlights — fall back to IATA-2 prefix on callsign.
      if (!cs.startsWith((airline.iata || '').toUpperCase())) continue;
    }
    if (s[5] == null || s[6] == null) continue; // need lon/lat
    out.push({
      callsign: cs,
      origin: s[2],
      lat: s[6],
      lng: s[5],
      alt: s[13] ?? s[7] ?? 0,
      speed: s[9] || 0,
      heading: s[10],
    });
  }
  return out;
}

// ── Misc helpers ───────────────────────────────────────────────────────────
function setStatus(text, kind = 'idle') {
  els.status.className = `status ${kind}`;
  els.status.textContent = text;
}

function escapeHtml(s) {
  return String(s ?? '').replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])
  );
}

// ── Boot ───────────────────────────────────────────────────────────────────
loadBundle().catch(err => {
  console.error(err);
  setStatus('failed to load data', 'error');
});
