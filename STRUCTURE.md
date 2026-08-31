# Project structure

**DEPTH / Field Notes on a Moving Coast** — annual Pacific coastline positions from
Landsat, 2000–2021. The shipping app is **v3**.

Run it:

```bash
Rscript app/serve.R          # then open http://127.0.0.1:8000/v3.html
```

`serve.R` starts two servers: `pmtiles serve` on :8081 (vector + raster tiles straight
out of the `.pmtiles` archives) and `httpuv` on :8000 (static files from `app/`). It
rewrites `app/data/tiles.json` on every start, so the tile port is never hard-coded in
the JS. Ctrl-C stops both. Requires `pmtiles` on PATH (`brew install pmtiles`).

There is no `index.html` any more — the app lives at `/v3.html`. `/` returns 404 by
design.

---

## Folders

```
app/          the served app - everything under here is v3 runtime
  v3.html       page skeleton, all prose copy, section markup
  v3.css        palettes, type, layout, all styling
  v3.js         charts, maps, glyph grid, drawer, boot
  serve.R       the two-server launcher
  vendor/       maplibre-gl.js + .css, vendored (no CDN)
  img/          barkcloth.webp - the hero cloth, cut into strips by CSS
  glyphs/lines/ 200 shoreline glyph SVGs, lazy-loaded as CSS masks
  data/         the eight JSON payloads the page fetches (below)

R/            the pipeline that builds app/data and data/*.pmtiles, 01 -> 18
data/         tile archives (served) + pipeline sources (gpkg, worldpop, osm, satellite)
output/       pipeline intermediates that later scripts read back in
archive/      everything not needed to run or rebuild v3 (see the last section)
```

### `app/data/` — what each payload feeds, and which script writes it

| File | Feeds | Built by |
|---|---|---|
| `stats.json` | every number and chart on the page; the territory table | `R/06_app_data.R` |
| `tiles.json` | tile endpoints + zoom limits | **rewritten by `app/serve.R` on each start** |
| `boundaries.geojson` | region map borders + ISO labels | `R/08_reference_layers.R` |
| `motifs.json` | the per-territory pattern stamps (s4) | `R/12_pattern_motifs.R` |
| `country_hotspots.json` | up to 3 sites per territory, drawer map | `R/13_` then `R/15_` (adds `admin`) |
| `population_ramp.json` | the raster legend breaks | `R/14_population_raster_tiles.R` |
| `background_lines.json` | per-site year strips behind the five towns | `R/16_background_lines.R` |
| `glyph_sites.json` | the 200-glyph grid: rates, names, wiki links, SVG paths | `R/17_` then `R/18_` (adds `pop_near`) |

`glyph_sites.json` also carries a `glyph_satellite` path. v3 never reads it — the
satellite renders are in `archive/app/glyphs/satellite/`.

### `data/` — served vs. source

Served by `pmtiles serve` (the app hits these live):

- `dep_coastlines_slim.pmtiles` (108 MB) — the coastlines. Quality filters are **baked
  in**, so it has no `certainty`/`sig` columns and the page must not filter on them.
- `pac_population_1km.pmtiles` — population points
- `pac_population_raster.pmtiles` — population as a 1 km RGBA grid

Pipeline sources (never served, only read by `R/`):

- `dep_ls_coastlines_0-7-0-55.gpkg` (1.8 GB) — the raw DEP release, input to 06/07/12/13/17
- `worldpop/`, `osm/`, `reference/`, `satellite/` — cached downloads

---

## Changing the app by hand

Almost every edit lands in one of three files.

### Text, headings, section order → `app/v3.html`

Six sections, `#s1`–`#s6`:

| id | line | Section |
|---|---|---|
| `s1` | 46 | What the record adds up to |
| `s2` | 263 | Where the land went |
| `s3` | 346 | Nine hundred thousand (population) |
| `s4` | 426 | Patterns of movement |
| `s5` | 520 | Read one pattern at a time (glyph grid) |
| `s6` | 629 | Down to the beach (drawer) |

Numbers inside the prose are placeholders filled at runtime — `<span id="shKirGood">`
and friends are set by `v3.js`, so editing the digits in the HTML does nothing. Change
the source data, or the `set(...)` call in the JS.

The Google Fonts link is in `<head>`; it is the only external request the page makes
besides the Esri satellite tiles.

### Colour, type, spacing → `app/v3.css`

- **Palette A ("Tapa grid")** — `:root` block, [v3.css:8](app/v3.css#L8). Seven inks,
  each with its measured contrast ratio in the comment above. Keep the ratios if you
  swap colours.
- **Palette B ("Petal deep")** — `:root[data-pal="petal"]`, [v3.css:43](app/v3.css#L43).
  Toggled at runtime; the choice is remembered in `localStorage`.
- **Type** — `--f-display` / `--f-hand` / `--f-body` / `--f-mono` in the same `:root`
  block. Changing a family here means changing the Google Fonts URL in `v3.html` too.
- **Measure and gutter** — `--measure:64ch`, `--gutter` at the end of `:root`.
- **Motion** — reveal animations at [v3.css:361](app/v3.css#L361). `#flat` in the URL
  hash shows every section at once, no scroll animation, for screenshots.

### Data, charts, maps → `app/v3.js`

Knobs worth knowing, near the top of their sections:

| What | Where |
|---|---|
| Satellite basemap URL | `SAT_URL` [v3.js:11](app/v3.js#L11) |
| Which site the method diagram uses | `SKETCH_SITE` [v3.js:161](app/v3.js#L161) |
| Histogram palettes | `HIST_PALETTES` [v3.js:227](app/v3.js#L227) |
| Waterfall copy | `WF_COPY` [v3.js:530](app/v3.js#L530) |
| Sub-region grouping | `SUBREGION` [v3.js:1274](app/v3.js#L1274) |
| Trail years on the maps | `TRAIL_FROM` / `TRAIL_TO` [v3.js:1282](app/v3.js#L1282) |
| Glyph grid sorts and filters | `GLYPH_SORT` / `GLYPH_KIND` [v3.js:1514](app/v3.js#L1514) |
| Drawer metric labels, colour ramp | `METRIC_LABEL` / `RAMP` [v3.js:1749](app/v3.js#L1749) |
| Scale comparisons ("as long as…") | `YARDSTICKS` [v3.js:2150](app/v3.js#L2150) |
| Hero cloth strip count | `CLOTH_IMG` [v3.js:2367](app/v3.js#L2367) |
| Which payloads load at boot | the `Promise.all` at [v3.js:2422](app/v3.js#L2422) |

Every fetch except `stats.json` has a `.catch()` fallback, so a missing payload
degrades that one component instead of blanking the page. `stats.json` is required.

MapLibre only accepts literal colours, so themed paint properties are re-resolved on a
palette flip ([v3.js:1224](app/v3.js#L1224)) rather than inheriting CSS variables.

### Rebuilding data instead of hand-editing

Run scripts in numeric order; they are chained by their file outputs, and each header
lists its `[ABR]` inputs. The v3-relevant tail:

```
02 -> 16 (hotspot frames -> year strips)
03 -> 04, 11, 13, 14, 18 (worldpop rasters)
04, 09, 10 -> 06 (the stats payload)
06 -> 08 (boundaries need the indicator table)
13 -> 15 (admin names onto the sites)
17 -> 18 (population onto the glyph sites)
07 -> data/dep_coastlines_slim.pmtiles (the served archive)
```

After any script that writes `app/data/*.json`, just reload the page — `serve.R` sends
`Cache-Control: no-store`, so there is nothing to bust.

---

## `archive/`

Nothing here is needed to run or rebuild v3. Kept, not deleted.

| Path | What it was |
|---|---|
| `app/index.html`, `app.js`, `app.css` | the v1 app v3 replaced |
| `app/fabric.*`, `heroes*.html` | design explorations |
| `app/_cap_*.html`, `_shot_*.html`, `_grab.html`, `_extract.html` | screenshot / extraction harnesses |
| `app/glyphs/satellite/` | satellite renders of the 200 glyphs, unused by v3 |
| `app/data/transects.parquet` (8 MB), `territories.parquet`, `places.geojson`, `overview_years.txt` | ad-hoc SQL and v1 leftovers |
| `R/05_export_web_json.R`, `geolibre.r` | a payload format nothing reads; a scratch note |
| `output/depth_web.json`, `depth_notebook*.html` | the Quarto notebook build |
| `output/hotspot_*.svg`, `glyph_preview*/` | print deliverables and preview renders |
| `output/change_2000_2021.csv`, `shoreline_length_by_year.csv`, `shoreline_glyphs.csv` | reporting tables, not pipeline inputs |
| `data/dep_ls_coastlines_0-7-0-55.pmtiles` (371 MB) | the unfiltered archive the slim one replaced |
| `data/build_scratch/` | GDAL intermediates from `14_` |
| `design/` | the Claude Design canvas and extracted SVGs |
| `content/` | the barkcloth and palette photographs the design was read off |
| `prompts.md`, `metadata_link.md` | session notes |

Two live references point into `archive/`: a comment in `v3.css` cites
`content/cloth/`, and `serve.R` falls back to `dep_ls_coastlines_0-7-0-55.pmtiles` if
the slim archive goes missing. Both are cosmetic — restore the folder if you need
either.
