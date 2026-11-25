# Loine

**Routing, isolines and cost matrices directly in your PostgreSQL database.**

📖 Full documentation: [www.casageo.de/loine.html](https://www.casageo.de/loine.html)

Loine delivers a ready-to-use road network for PostgreSQL/PostGIS together with a set of SQL functions for routing and reachability analysis. Install it in your own database and run routes, isolines, reachable grid cells and cost matrices with plain SQL – no external routing service, no API limits, no data leaving your infrastructure.

## Features

- **Routes** – fastest or shortest path between two points with travel time, distance and geometry
- **Isolines** – reachability polygons for one or several travel times or distances, from or to a location
- **Reachable segments** – every road segment within a budget, with its exact cost
- **Reachable grid cells** – 100 m grid cells within a budget, with their exact cost, for location and catchment analytics
- **Cost matrices** – travel time or distance between all pairs of an arbitrary set of points in a single call
- **Several modes of transport** – multiple car profiles, pedestrian and an unrestricted network mode
- **Realistic network** – one-way streets, turn restrictions and turn costs
- **Cross-border** – neighbouring countries are connected at their border crossings, so routes and isolines continue across borders

## How it works

The country data is delivered by casaGeo as a complete delivery: one PostgreSQL dump with all ordered countries in its own schema `pgr_YYYYMMDD`. Each country contains:

| Table | Content |
|---|---|
| `edges` | Directed, routable road network with length, travel time and street category |
| `grids` | 100 m grid cells linked to the road network |
| `cluster`, `kacheln`, `partition` | 10 km clusters and 100 km tiles for fast preselection |
| `meta` | Data source, release and build information |

The network is based on HERE or OpenStreetMap data. Within Europe the grid follows the INSPIRE grid (EPSG:3035); outside Europe Loine uses continental equal-area projections with the same grid structure (Africa, North America incl. Central America).

The SQL functions use pgRouting and select only the part of the network a request needs, so queries stay fast even on country-wide or multi-country networks.

### Road network tables

The Loine routing functions work on two tables: `pgr.edges` (road network) and `pgr.grids` (100 m grid cells linked to the road network). The tables can also be used without the Loine functions, for example directly with pgRouting or in QGIS.

Preparing the road networks is not part of the Loine software. casaGeo provides prepared networks for Loine per country. If you want to prepare your own network, see the requirements in [Preparing your own networks](docs/tables.md#preparing-your-own-networks).

## Requirements

- PostgreSQL 18 with PostGIS and pgRouting (4.1.0 or later recommended; older versions work, but are much slower)
- PostgreSQL client tools `psql` and `pg_restore`, version 18 or later

## Quick start

The software is in this repository. The country data is not part of it; it is delivered by casaGeo (see [Contact](#contact)). A new delivery is installed next to the running installation `pgr`, tested and then switched to `pgr`, so applications keep working during the installation. The commands below use the delivery `pgr_20261124` as an example.

Prepare the database (once, and again with every new Loine version):

```
psql -h localhost -U postgres -d mydb -f install/loine_admin.sql
```

Restore the delivery. This creates the schema `pgr_20261124` with data, indexes, statistics and the base network for routes:

```
pg_restore -h localhost -U postgres -d mydb --no-owner -j 4 loine_pgr_20261124_<network>_<countries>.dump
```

Install the functions into the schema of the delivery: `install/loine_functions.sql` with every `pgr.` replaced by `pgr_20261124.`, for example with Perl (Linux, macOS):

```
perl -pe 's/\bpgr\./pgr_20261124./g' install/loine_functions.sql | psql -h localhost -U postgres -d mydb
```

Check the delivery and switch it to `pgr`:

```sql
SELECT * FROM loine_admin.check_installation('pgr_20261124');
CALL loine_admin.switch_installation('pgr_20261124');                    -- previous installation is kept as pgr_<date>
CALL loine_admin.switch_installation('pgr_20261124', p_old => 'drop');   -- or: previous installation is dropped
```

Other administration commands:

```sql
SELECT * FROM loine_admin.installations();                 -- all installations in the database
CALL loine_admin.switch_installation('pgr_20250510');      -- switch back to an earlier installation
CALL loine_admin.drop_installation('pgr_20250510');        -- drop an inactive installation
```

After switching, applications should reconnect to the database.

Check the installed version:

```sql
SELECT * FROM pgr.loine_info();
```

### Updating the software

A new Loine version without new country data only replaces the functions of the running installation:

```
psql -h localhost -U postgres -d mydb -f install/loine_admin.sql
psql -h localhost -U postgres -d mydb -f install/loine_functions.sql
```

The release notes say if a new version needs new country data (file `DATA_FORMATS`).

## Usage

All coordinates are WGS84 longitude/latitude.

```sql
-- Route by travel time
SELECT * FROM pgr.cgo_path(17.107, 48.148, 21.258, 48.716, 'car', 'time');

-- 15-minute isoline from a location
SELECT pgr.cgo_isoline(17.107, 48.148, 15, 'car', 'time', 'from');

-- 5, 10 and 15-minute isolines in one call
SELECT * FROM pgr.cgo_multiisolines(17.107, 48.148, '5,10,15', 'car', 'time', 'from');

-- 100 m grid cells reachable within 10 minutes
SELECT * FROM pgr.cgo_grids(17.107, 48.148, 10, 'car', 'time', 'from');

-- Travel time matrix between all points of a table (columns node_id, x, y)
SELECT * FROM pgr.cgo_costmatrix('my_schema.my_locations', 'card', 'time');
```

### Functions

| Function | Returns |
|---|---|
| `pgr.cgo_path(start_lon, start_lat, end_lon, end_lat, mode, calc)` | Route time, distance, traffic cost and geometry |
| `pgr.cgo_isoline(lon, lat, value, mode, calc, direction)` | Isoline polygon |
| `pgr.cgo_multiisolines(lon, lat, 'v1,v2,…', mode, calc, direction)` | One isoline per value |
| `pgr.cgo_isoline_static(lon, lat, value, mode, calc, direction)` | Isoline polygon, static catchment variant |
| `pgr.cgo_segments(lon, lat, value, mode, calc, direction)` | Reachable road segments with cost |
| `pgr.cgo_grids(lon, lat, value, mode, calc, direction)` | Reachable 100 m grid cells with cost |
| `pgr.cgo_costmatrix(input_table, mode, calc)` | Cost between all point pairs (N×N) |
| `pgr.cgo_costmatrix_snap_report(input_table, mode)` | Distance between input points and their position on the network |

### Parameters

| Parameter | Values |
|---|---|
| `mode` – routes | `car`, `card`, `caro`, `care`, `carl`, `pedestrian` |
| `mode` – isolines, segments, grid cells | `car`, `card`, `caro`, `care`, `pedestrian`, `no_mode` |
| `mode` – cost matrices | `card`, `caro`, `care`, `pedestrian`, `no_mode` |
| `calc` | `time` (minutes), `distance` (metres), `traffic` (minutes; not for cost matrices) |
| `direction` | `from` (outbound from the location), `to` (inbound to the location) |

## Repository layout

| Path | Content |
|---|---|
| `install/loine_install.sql` | Schema `pgr` with empty target tables and `loine_finalize`, for your own networks (see `docs/tables.md`); not needed for a delivery |
| `install/loine_functions.sql` | All functions in one file, generated from `install/upgrade_drops.sql` and `functions/` |
| `install/upgrade_drops.sql` | Removes functions whose signature changed compared to earlier versions |
| `install/loine_admin.sql` | Schema `loine_admin`: switch between complete deliveries (schema `pgr_YYYYMMDD` → `pgr`) and drop old ones |
| `functions/` | One file per function or procedure |
| `docs/tables.md` | Structure of the tables `pgr.edges` and `pgr.grids` and requirements for your own networks |
| `VERSION` | Version of this release, also returned by `pgr.loine_info()` |
| `DATA_FORMATS` | Data formats of the country data this release can read, also returned by `pgr._data_formats()` |

All objects are created in the schema `pgr`, except the administration of complete deliveries in `loine_admin`. Names starting with `cgo_` are the query functions, names starting with `loine_` are administration routines you call directly, and names starting with `_` are internal helpers that are not meant to be called directly.

## Typical applications

- Catchment areas and drive-time zones for retail, healthcare and public services
- Location planning and site comparison
- Population and potential analysis on 100 m grid cells
- Accessibility studies and coverage analysis
- Distance and travel time matrices for logistics and planning

## Documentation

This README gives a short overview. The full documentation is available on our website:

**https://www.casageo.de/loine.html**

It covers:

- Downloads of the software and the country data
- Installation and update on Windows, Linux and macOS, with psql, pgAdmin and DataGrip
- All functions with their parameters and return values
- Modes of transport and the road categories they use
- Application examples for isolines, grid analyses and cost matrices
- Available countries and data sources

## Contributing to Loine

Loine is dual-licensed (AGPL-3.0-only and a commercial license). To allow this, every contributor
must sign the Individual Contributor License Agreement ([ICLA.txt](ICLA.txt)) before a pull request
can be merged. You sign it by commenting on your first pull request as described by the CLA bot.
Contributions on behalf of a company require a Corporate CLA – contact info@casageo.de.

## License

Loine is developed and maintained by **casaGeo Data + Services GmbH**.

Copyright © 2026 casaGeo Data + Services GmbH.

Loine is available under a **dual licensing model**:

### Open Source License — AGPL-3.0-only

Loine is licensed under the GNU Affero General Public License version 3 only (AGPL-3.0-only).

You are free to use, modify, and redistribute Loine under the terms of this license.

The AGPL-3.0 requires compliance with its copyleft obligations, including applicable source code disclosure requirements when distributing modified versions or providing modified software over a network.

See the [LICENSE](LICENSE) file for the complete license terms.

### Commercial License

For organizations that wish to use or integrate Loine without being subject to the obligations of the AGPL-3.0, a separate commercial license is available.

Commercial licensing terms are provided by casaGeo Data + Services GmbH upon request.

### Road network data

This repository contains software only, no road network data. Networks prepared from OpenStreetMap are licensed under the [Open Database License (ODbL) 1.0](https://opendatacommons.org/licenses/odbl/1-0/) (© OpenStreetMap contributors); networks prepared from HERE data are subject to the HERE license terms.

### Copyright and Attribution

All applicable copyright and license notices must be preserved in accordance with the AGPL-3.0.

Loine and casaGeo are names associated with casaGeo Data + Services GmbH. No trademark rights are granted by the open-source license.

## Contact

Loine is developed by casaGeo Data + Services GmbH. For coverage, data sources and licensing, please get in touch.

E: info@casageo.de  
W: https://www.casageo.de/
