import React, { useEffect, useMemo, useRef, useState } from "react";
import Globe from "react-globe.gl";

type OpenSkyState = [
  string, // icao24
  string | null, // callsign
  string, // origin_country
  number | null, // time_position
  number | null, // last_contact
  number | null, // longitude
  number | null, // latitude
  number | null, // baro_altitude
  boolean, // on_ground
  number | null, // velocity
  number | null, // true_track
  number | null, // vertical_rate
  number[] | null, // sensors
  number | null, // geo_altitude
  string | null, // squawk
  boolean, // spi
  number // position_source
];

type OpenSkyResponse = {
  time: number;
  states: OpenSkyState[] | null;
};

type Position = {
  lat: number;
  lng: number;
  altitudeKm: number;
};

type FlightPoint = {
  id: string;
  callsign: string;
  country: string;
  lat: number;
  lng: number;
  altitudeKm: number;
  speedKph: number;
  track: number | null;
};

type FlightArc = {
  id: string;
  callsign: string;
  startLat: number;
  startLng: number;
  endLat: number;
  endLng: number;
  altitude: number;
};

type AirlineOption = {
  label: string;
  prefix: string;
  color: string;
};

const AIRLINES: AirlineOption[] = [
  { label: "American Airlines (AAL)", prefix: "AAL", color: "#3b82f6" },
  { label: "Delta Air Lines (DAL)", prefix: "DAL", color: "#ef4444" },
  { label: "United Airlines (UAL)", prefix: "UAL", color: "#22c55e" },
  { label: "Southwest Airlines (SWA)", prefix: "SWA", color: "#f97316" },
  { label: "Lufthansa (DLH)", prefix: "DLH", color: "#a855f7" },
  { label: "British Airways (BAW)", prefix: "BAW", color: "#06b6d4" }
];

const POLL_INTERVAL_MS = 15000;
const OPENSKY_URL = "https://opensky-network.org/api/states/all";

export default function HupoApp() {
  const [selectedAirline, setSelectedAirline] = useState<AirlineOption>(AIRLINES[0]);
  const [points, setPoints] = useState<FlightPoint[]>([]);
  const [arcs, setArcs] = useState<FlightArc[]>([]);
  const [lastUpdated, setLastUpdated] = useState<string>("-");
  const [status, setStatus] = useState<string>("Loading flight data...");
  const [error, setError] = useState<string>("");
  const previousPositions = useRef<Map<string, Position>>(new Map());

  const activeColor = selectedAirline.color;

  useEffect(() => {
    let cancelled = false;

    const fetchFlights = async () => {
      try {
        setError("");
        const response = await fetch(OPENSKY_URL, {
          headers: { Accept: "application/json" }
        });

        if (!response.ok) {
          throw new Error(`OpenSky request failed: ${response.status}`);
        }

        const data = (await response.json()) as OpenSkyResponse;
        const states = data.states ?? [];

        const filtered = states.filter((state) => {
          const callsign = state[1]?.trim() ?? "";
          const lat = state[6];
          const lng = state[5];
          return (
            callsign.startsWith(selectedAirline.prefix) &&
            typeof lat === "number" &&
            typeof lng === "number"
          );
        });

        const nextPoints: FlightPoint[] = [];
        const nextArcs: FlightArc[] = [];
        const nextPositionMap = new Map<string, Position>();

        for (const state of filtered) {
          const icao24 = state[0];
          const callsign = state[1]?.trim() ?? "UNKNOWN";
          const country = state[2];
          const lng = state[5] as number;
          const lat = state[6] as number;
          const geoAltitudeM = state[13] ?? state[7] ?? 0;
          const speedMs = state[9] ?? 0;
          const altitudeKm = Math.max(0.1, geoAltitudeM / 1000);

          const currentPosition: Position = {
            lat,
            lng,
            altitudeKm
          };

          nextPoints.push({
            id: icao24,
            callsign,
            country,
            lat,
            lng,
            altitudeKm,
            speedKph: speedMs * 3.6,
            track: state[10]
          });

          const previous = previousPositions.current.get(icao24);
          if (previous) {
            nextArcs.push({
              id: `${icao24}-${data.time}`,
              callsign,
              startLat: previous.lat,
              startLng: previous.lng,
              endLat: lat,
              endLng: lng,
              altitude: Math.max(previous.altitudeKm, altitudeKm) / 6371
            });
          }

          nextPositionMap.set(icao24, currentPosition);
        }

        if (!cancelled) {
          previousPositions.current = nextPositionMap;
          setPoints(nextPoints);
          setArcs(nextArcs);
          setStatus(
            `Tracking ${nextPoints.length} live ${selectedAirline.prefix} flights. Route trails use latest 15s movement.`
          );
          setLastUpdated(new Date(data.time * 1000).toLocaleString());
        }
      } catch (err) {
        if (!cancelled) {
          const message = err instanceof Error ? err.message : "Unknown error";
          setError(message);
          setStatus("Unable to refresh right now. OpenSky may be rate-limiting or unavailable.");
        }
      }
    };

    previousPositions.current = new Map();
    fetchFlights();
    const interval = window.setInterval(fetchFlights, POLL_INTERVAL_MS);

    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, [selectedAirline]);

  const legendItems = useMemo(
    () => [
      { label: "Current aircraft position", color: activeColor },
      { label: "Recent movement route", color: "#facc15" }
    ],
    [activeColor]
  );

  return (
    <main
      style={{
        minHeight: "100vh",
        margin: 0,
        background: "radial-gradient(circle at top, #0f172a, #020617)",
        color: "#e2e8f0",
        fontFamily: "Inter, system-ui, sans-serif",
        display: "grid",
        gridTemplateRows: "auto 1fr",
        gap: "0.5rem"
      }}
    >
      <header style={{ padding: "1rem 1.25rem", display: "grid", gap: "0.5rem" }}>
        <h1 style={{ margin: 0, fontSize: "1.35rem" }}>Real-time Airline Flight Routes (3D Globe)</h1>
        <p style={{ margin: 0, opacity: 0.9 }}>
          Live aircraft data source: OpenSky Network. Select an airline ICAO prefix to view active flights.
        </p>

        <div style={{ display: "flex", gap: "0.75rem", alignItems: "center", flexWrap: "wrap" }}>
          <label htmlFor="airline" style={{ fontWeight: 600 }}>
            Airline:
          </label>
          <select
            id="airline"
            value={selectedAirline.prefix}
            onChange={(event) => {
              const next = AIRLINES.find((a) => a.prefix === event.target.value);
              if (next) {
                setSelectedAirline(next);
              }
            }}
            style={{
              padding: "0.45rem 0.7rem",
              borderRadius: 8,
              border: "1px solid #334155",
              background: "#0b1220",
              color: "#e2e8f0"
            }}
          >
            {AIRLINES.map((airline) => (
              <option key={airline.prefix} value={airline.prefix}>
                {airline.label}
              </option>
            ))}
          </select>

          <span style={{ fontSize: "0.92rem", opacity: 0.85 }}>Last updated: {lastUpdated}</span>
        </div>

        <div style={{ fontSize: "0.92rem", opacity: 0.9 }}>{status}</div>
        {error ? <div style={{ color: "#fca5a5", fontSize: "0.92rem" }}>{error}</div> : null}

        <div style={{ display: "flex", gap: "1rem", flexWrap: "wrap" }}>
          {legendItems.map((item) => (
            <div key={item.label} style={{ display: "flex", alignItems: "center", gap: "0.4rem" }}>
              <span
                style={{
                  width: 12,
                  height: 12,
                  borderRadius: 999,
                  background: item.color,
                  display: "inline-block"
                }}
              />
              <span style={{ fontSize: "0.85rem" }}>{item.label}</span>
            </div>
          ))}
        </div>
      </header>

      <section style={{ minHeight: 0 }}>
        <Globe
          globeImageUrl="https://unpkg.com/three-globe/example/img/earth-blue-marble.jpg"
          bumpImageUrl="https://unpkg.com/three-globe/example/img/earth-topology.png"
          backgroundImageUrl="https://unpkg.com/three-globe/example/img/night-sky.png"
          pointsData={points}
          pointLat="lat"
          pointLng="lng"
          pointAltitude={(d: object) => ((d as FlightPoint).altitudeKm / 6371) * 1.8}
          pointRadius={0.08}
          pointColor={() => activeColor}
          pointLabel={(d: object) => {
            const p = d as FlightPoint;
            return `
              <div style="padding:6px 8px;background:#0f172a;border:1px solid #334155;border-radius:6px;color:#e2e8f0;">
                <strong>${p.callsign}</strong><br/>
                Country: ${p.country}<br/>
                Altitude: ${p.altitudeKm.toFixed(1)} km<br/>
                Speed: ${p.speedKph.toFixed(0)} km/h
              </div>
            `;
          }}
          arcsData={arcs}
          arcStartLat="startLat"
          arcStartLng="startLng"
          arcEndLat="endLat"
          arcEndLng="endLng"
          arcAltitude="altitude"
          arcColor={() => ["#facc15", activeColor]}
          arcDashLength={0.35}
          arcDashGap={0.75}
          arcDashAnimateTime={1800}
          arcStroke={0.5}
          atmosphereColor="#93c5fd"
          atmosphereAltitude={0.16}
        />
      </section>
    </main>
  );
}
