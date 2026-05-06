# Flight Routes 3D Globe

Interactive 3D globe that renders an airline's full route network and overlays
real-time aircraft positions. All client-side — no API keys.

![](https://img.shields.io/badge/3D-globe.gl-6ee0ff) ![](https://img.shields.io/badge/data-OpenFlights-22b8ff) ![](https://img.shields.io/badge/live-OpenSky-4adf73)

## Features

- **3D globe** rendered with [globe.gl](https://globe.gl) (three.js).
- **Pick any airline** (516 active airlines, 67k routes).
- **Animated route arcs** between origin / destination airports.
- **Airport markers** for the airline's network.
- **Live aircraft layer** — OpenSky Network state vectors are polled every 15 s
  and filtered by the airline's ICAO callsign prefix; planes are drawn as
  oriented cones at their true altitude.
- **Search** by airline name, IATA, ICAO, or country.
- Layer toggles for routes / airports / live aircraft.

## Run

```sh
cd flight-globe
ruby server.rb            # → http://localhost:8000/
```

(Any static file server works — `python3 -m http.server`, `npx serve`, etc.)

## Data

| Source | What it provides |
|---|---|
| [OpenFlights](https://openflights.org/data.html) | Airports, airlines, routes (`data/*.dat`) |
| [OpenSky Network](https://opensky-network.org/apidoc/rest.html) | Live aircraft state vectors (`/api/states/all`) |

The OpenFlights `.dat` files are preprocessed into a single
`data/bundle.json` at build time:

```sh
cd flight-globe/data
ruby build.rb             # regenerate bundle.json
```

## Layout

```
flight-globe/
├── index.html        # page + globe.gl / three.js CDN
├── style.css         # dark glassmorphic UI
├── app.js            # globe setup, airline selection, live polling
├── server.rb         # static file server (WEBrick)
└── data/
    ├── airports.dat  # OpenFlights raw
    ├── airlines.dat
    ├── routes.dat
    ├── build.rb      # → bundle.json
    └── bundle.json   # what the browser actually loads (~1.4 MB)
```

## Notes

- OpenSky's anonymous endpoint is rate-limited; if it returns 429 the status
  bar shows an error and the next 15 s tick will retry.
- A live aircraft is matched to an airline when its callsign starts with the
  airline's ICAO code (e.g. `BAW123` → British Airways). For airlines with no
  ICAO code in OpenFlights, the IATA-2 prefix is used as a fallback.
