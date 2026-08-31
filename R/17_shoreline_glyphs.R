#######################################################################################
# Purpose : Find every stretch of coast moving at least 5 m a year, in either direction,
#           and draw each one as a small SVG glyph - every
#           annual shoreline the record holds for that spot, stacked oldest to newest.
#           The two layers are joined the way the dataset intends: a rate-of-change
#           point sits on the 2023 shoreline, so snapping the points to a grid gives
#           a stretch of coast that can be cut out of shorelines_annual by extent.
#   Inputs
#   ──────────────────────────────────────────────────────────────────────
#   [CST] data/dep_ls_coastlines_0-7-0-55.gpkg   rates_of_change + shorelines_annual
#   [OSM] data/osm/<country>-latest.osm.pbf      places and admin boundaries, from 13_/15_
#   [POP] data/worldpop/<iso3>_pop_2020_CN_100m_R2024B_v1.tif   people near each site
#   [BND] data/reference/pac_political_bndry.geojson   to name the territory
#   [WIK] en.wikipedia.org API                   nearest article per site, optional
#   [SAT] Esri World Imagery export API          one picture per glyph frame
#   Outputs
#   ──────────────────────────────────────────────────────────────────────
#   app/glyphs/lines/<id>.svg     one per site, currentColor so a card can tint it
#   app/glyphs/satellite/<id>.svg the same frame over an Esri World Imagery picture
#   data/satellite/<id>.jpg       the fetched imagery, cached so a re-run is free
#   app/data/glyph_sites.json    the same table the app reads
#   output/shoreline_glyphs.csv  the card copy: place, division, rate, Wikipedia
# LLM Disclaimer: Generated with the assistance of Claude Code (VSCode extension claude-opus-5)
#######################################################################################

library(DBI)
library(duckdb)
library(sf)
library(terra)
library(dplyr)
library(purrr)
library(readr)
library(stringr)
library(jsonlite)
library(httr2)

source("R/config.R")

sf_use_s2(FALSE)

osm_dir  <- "data/osm"
pop_dir  <- "data/worldpop"
pop_win  <- 5              # 1 km cells, 5x5 box - the same reach 09_ and 13_ use
glyph_dir <- "app/glyphs"
crs_m    <- 3832            # PDC Mercator, the CRS the source is stored in
map_crs  <- 3857            # web mercator, to match the imagery the glyphs sit on
cell_m   <- 2000            # a site is one 2 km cell of coast
min_pts  <- 20              # ... holding at least 600 m of measured shore
rate_cut <- 5               # m/yr: every cell moving at least this fast, either way
win_m    <- 2600            # half-width of the window each glyph is drawn from
simp_m   <- 14              # at the full window; scaled down when the frame zooms in
min_half_m <- 260           # do not zoom in past a ~520 m frame
trim_q     <- 0.01          # shaved off each end of each axis, to drop stray outliers
frame_pad  <- 1.02          # barely any, so the shoreline reaches the border
reach_km <- 25              # how far to look for a name
# GLYPH_PREVIEW=n draws only the first n of each kind into output/glyph_preview and
# stops - for eyeballing a change before committing to the full set and the API calls
preview_n     <- as.integer(Sys.getenv("GLYPH_PREVIEW", "0"))
use_wikipedia <- TRUE
force_glyphs  <- FALSE      # TRUE to redraw glyphs that are already on disk
wiki_pause    <- 0.45       # en.wikipedia rate-limits hard above roughly this
wiki_dir      <- "data/wikipedia"   # answers cached per cell, so a re-run is free
frame_dir     <- "data/frames"      # the drawing frame per cell, likewise
# Two qualifying cells 500 m apart are drawn in frames five kilometres across, so they
# come out as the same picture twice. A site is dropped when this much of its frame is
# already covered by a stronger one that has been kept.
max_overlap   <- 0.30

dir.create(glyph_dir, recursive = TRUE, showWarnings = FALSE)

# -- 1. snap the good, clearly-moving points into 2 km cells --------------------------
con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
dbExecute(con, "INSTALL spatial; LOAD spatial;")

sites <- dbGetQuery(con, sprintf("
  WITH pt AS (
    SELECT rate_time, sig_time, valid_span, eez_territory,
           floor(ST_X(geom) / %f) AS gx,
           floor(ST_Y(geom) / %f) AS gy,
           ST_X(geom) AS x, ST_Y(geom) AS y
    FROM st_read('%s', layer = 'rates_of_change')
    WHERE certainty = 'good' AND sig_time < %f AND rate_time IS NOT NULL
  )
  SELECT gx, gy,
         count(*)                          AS n_points,
         avg(rate_time)                    AS rate_m_yr,
         median(rate_time)                 AS rate_median_m_yr,
         avg(rate_time * (valid_span - 1)) AS shift_m,
         avg(x)                            AS x,
         avg(y)                            AS y,
         mode(eez_territory)               AS territory
  FROM pt GROUP BY gx, gy HAVING count(*) >= %d",
  cell_m, cell_m, gpkg, p_sig, min_pts))

message(sprintf("%s cells of coast with a clear trend", format(nrow(sites), big.mark = ",")))

# every cell over the threshold, not a fixed number of them: how many stretches of coast
# are moving this fast is itself the answer, and it is not the same on both sides
cand <- sites |>
  filter(abs(rate_m_yr) >= rate_cut) |>
  mutate(kind = if_else(rate_m_yr < 0, "retreat", "gain"),
         cell = sprintf("c%.0f_%.0f", gx, gy)) |>
  arrange(desc(abs(rate_m_yr)))

message(sprintf("%d cells at %.0f m/yr or faster", nrow(cand), rate_cut))
# -- 2. two SVGs per site: the shoreline alone, and the same over a satellite picture --
# The frame is cut around whatever shoreline the window actually holds, so the coast runs
# border to border rather than sitting in a corner of a fixed box. Both versions come off
# that one frame, so they are the same picture with and without the ground behind it.

TRAIL <- "#F2EDE4"      # the lines over imagery
HALO  <- "#10261F"      # laid under them so they survive bright sand

sat_px  <- 512          # pixels requested per side; the glyph is drawn at 220 units
sat_dir <- "data/satellite"
sat_pause <- 0.25       # between imagery requests; cached frames never reach here
w_new   <- 0.6          # stroke for the most recent shoreline
w_old   <- 0.2          # ... and for every earlier one

# Esri's World Imagery, asked for one picture of the exact frame rather than stitched
# tiles. Cached on disk, because the frame for a given site never moves.
# keyed by the grid cell, not the site id: the frame belongs to the place, so re-ranking
# or renumbering the sites must not throw the cache away
satellite_bg_path <- function(key, box) {
  dir.create(sat_dir, recursive = TRUE, showWarnings = FALSE)
  dest <- file.path(sat_dir, paste0(key, ".jpg"))
  if (file.exists(dest) && file.size(dest) > 2000) return(dest)
  url <- paste0(
    "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/export",
    sprintf("?bbox=%.3f,%.3f,%.3f,%.3f&bboxSR=3857&imageSR=3857&size=%d,%d&format=jpg&f=image",
            box[["xmin"]], box[["ymin"]], box[["xmax"]], box[["ymax"]], sat_px, sat_px))
  Sys.sleep(sat_pause)          # 200 sites in a burst is not a polite way to ask
  ok <- try(download.file(url, dest, mode = "wb", quiet = TRUE), silent = TRUE)
  if (inherits(ok, "try-error") || !file.exists(dest) || file.size(dest) < 2000) {
    unlink(dest); return(NULL)
  }
  dest
}

satellite_image <- function(key, box, S) {
  f <- satellite_bg_path(key, box)
  if (is.null(f)) return(NULL)
  b64 <- gsub("[\r\n]", "", jsonlite::base64_enc(readBin(f, "raw", file.size(f))))
  sprintf(paste0('<image x="0" y="0" width="%d" height="%d" ',
                 'preserveAspectRatio="none" href="data:image/jpeg;base64,%s"/>'),
          S, S, b64)
}

# st_crop hands back a GEOMETRYCOLLECTION wherever it clipped through a vertex, and an
# empty one wherever it clipped everything away; both poison st_bbox.
clean_lines <- function(g) {
  if (is.null(g) || nrow(g) == 0) return(NULL)
  if (any(as.character(st_geometry_type(g)) == "GEOMETRYCOLLECTION"))
    g <- suppressWarnings(st_collection_extract(g, "LINESTRING", warn = FALSE))
  g <- g[!st_is_empty(g), ]
  g <- g[as.character(st_geometry_type(g)) %in% c("LINESTRING", "MULTILINESTRING"), ]
  if (nrow(g) == 0) return(NULL)
  # subsetting leaves a mixed sfc_GEOMETRY, which st_coordinates will not touch
  suppressWarnings(st_cast(g, "MULTILINESTRING"))
}

# The frame a site would be drawn in, worked out on its own so overlapping sites can be
# weeded out before anything is drawn. Cached per cell, like the imagery.
glyph_frame <- function(row) {
  f <- file.path(frame_dir, paste0(row$cell, ".json"))
  if (file.exists(f)) {
    v <- unlist(fromJSON(f))
    if (length(v) == 4 && all(is.finite(v)))
      return(st_bbox(c(xmin = v[1], ymin = v[2], xmax = v[3], ymax = v[4]),
                     crs = st_crs(map_crs)))
    return(NULL)
  }
  box <- frame_of(row)
  dir.create(frame_dir, recursive = TRUE, showWarnings = FALSE)
  write_json(if (is.null(box)) list() else unname(as.numeric(box[c("xmin","ymin","xmax","ymax")])),
             f, auto_unbox = FALSE)
  box
}

frame_of <- function(row) {
  look <- st_bbox(c(xmin = row$x - win_m, xmax = row$x + win_m,
                    ymin = row$y - win_m, ymax = row$y + win_m),
                  crs = st_crs(crs_m))
  g <- try(st_read(gpkg, quiet = TRUE, wkt_filter = st_as_text(st_as_sfc(look)),
                   query = "SELECT year, geom FROM shorelines_annual
                            WHERE certainty = 'good'"), silent = TRUE)
  if (inherits(g, "try-error") || nrow(g) == 0) return(NULL)
  g <- clean_lines(suppressWarnings(st_crop(st_zm(g), look)))
  if (is.null(g)) return(NULL)
  # The imagery is served in web mercator, so the frame is built there whether or not a
  # picture is drawn behind it - that way the two versions of a glyph share one frame.
  g <- st_transform(g, map_crs)

  # -- centre and zoom: square up on the shoreline that is actually here --
  # Frame the shoreline itself, edge to edge. Trimming a little off each axis drops a
  # stray islet in a far corner without shrinking everything else, and the centre is the
  # middle of what survives - a median vertex sat wherever the line happened to be
  # densest, which cropped the top of one coast while leaving the bottom empty. The pad
  # is nearly nothing so the line runs into the border rather than stopping short of it.
  cs <- st_coordinates(g)[, c("X", "Y"), drop = FALSE]
  if (!nrow(cs)) return(NULL)
  qx <- stats::quantile(cs[, 1], c(trim_q, 1 - trim_q), names = FALSE)
  qy <- stats::quantile(cs[, 2], c(trim_q, 1 - trim_q), names = FALSE)
  cx <- mean(qx); cy <- mean(qy)
  half <- max(diff(qx), diff(qy)) / 2 * frame_pad
  if (!all(is.finite(c(cx, cy, half)))) return(NULL)
  half <- min(max(half, min_half_m), win_m)
  st_bbox(c(xmin = cx - half, xmax = cx + half,
            ymin = cy - half, ymax = cy + half), crs = st_crs(map_crs))
}

glyph_geometry <- function(row, box) {
  if (is.null(box)) return(NULL)
  look <- st_bbox(st_transform(st_as_sfc(box), crs_m))
  g <- try(st_read(gpkg, quiet = TRUE, wkt_filter = st_as_text(st_as_sfc(look)),
                   query = "SELECT year, geom FROM shorelines_annual
                            WHERE certainty = 'good'"), silent = TRUE)
  if (inherits(g, "try-error") || nrow(g) == 0) return(NULL)
  g <- clean_lines(suppressWarnings(st_crop(st_zm(g), look)))
  if (is.null(g)) return(NULL)
  g <- st_transform(g, map_crs)
  half <- as.numeric(box[["xmax"]] - box[["xmin"]]) / 2

  g <- clean_lines(suppressWarnings(st_crop(g, box)))
  if (is.null(g)) return(NULL)

  # the source has a vertex roughly every 30 m; at this size that is far more detail
  # than the glyph can show. Cast first - simplifying a MULTILINESTRING shreds it.
  g <- suppressWarnings(st_cast(g, "LINESTRING", warn = FALSE)) |>
    st_simplify(dTolerance = max(4, simp_m * half / win_m), preserveTopology = TRUE)
  g <- g[!st_is_empty(g), ]
  if (nrow(g) == 0) return(NULL)

  yrs <- sort(unique(g$year))
  S <- 220
  list(g = g, box = box, half = half, yrs = yrs, S = S,
       sx = \(v) (v - box[["xmin"]]) / (2 * half) * S,
       sy = \(v) S - (v - box[["ymin"]]) / (2 * half) * S)
}

# st_coordinates gives L1 for a LINESTRING and L1/L2 for a MULTILINESTRING, so the
# grouping key has to be whichever of those actually came back
path_for <- function(geom, sx, sy) {
  cs <- st_coordinates(geom)
  if (!nrow(cs)) return("")
  lcol <- grep("^L", colnames(cs), value = TRUE)
  key <- if (length(lcol)) interaction(as.data.frame(cs[, lcol, drop = FALSE]), drop = TRUE)
         else factor(rep(1L, nrow(cs)))
  split(as.data.frame(cs), key) |>
    keep(\(p) nrow(p) > 1) |>
    map_chr(\(p) paste0("M", paste(sprintf("%.1f %.1f", sx(p$X), sy(p$Y)),
                                   collapse = "L"))) |>
    paste(collapse = "")
}

render_glyph <- function(row, geo, sat) {
  g <- geo$g; yrs <- geo$yrs; S <- geo$S; sx <- geo$sx; sy <- geo$sy

  ground <- if (sat) satellite_image(row$cell, geo$box, S) else NULL
  if (sat && is.null(ground)) return(NULL)

  lines <- map_chr(seq_along(yrs), function(i) {
    d <- path_for(st_union(g$geom[g$year == yrs[i]]), sx, sy)
    if (!nzchar(d)) return("")
    # oldest faint, newest solid: the glyph reads as a direction, not a tangle
    o <- 0.30 + 0.70 * ((i - 1) / max(1, length(yrs) - 1))^1.7
    w <- if (i == length(yrs)) w_new else w_old
    if (!sat)
      return(sprintf('<path d="%s" fill="none" stroke="currentColor" stroke-opacity="%.3f" stroke-width="%.2f"/>',
                     d, o, w))
    # over imagery a thin white line vanishes against bright sand, so each one is laid on
    # a darker copy of itself - the line stays as thin as it looks
    sprintf(paste0('<path d="%s" fill="none" stroke="%s" stroke-opacity="%.3f" stroke-width="%.2f"/>',
                   '<path d="%s" fill="none" stroke="%s" stroke-opacity="%.3f" stroke-width="%.2f"/>'),
            d, HALO, o * 0.5, w + 0.7, d, TRAIL, o, w)
  })

  sprintf(paste0('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" ',
                 'role="img" aria-label="%s: the shoreline in each year from %d to %d%s">\n',
                 '<title>%s</title>\n<desc>%s</desc>\n%s\n</svg>\n'),
          S, S, row$id, min(yrs), max(yrs),
          if (sat) ", over a satellite picture of the same ground" else "",
          row$id,
          if (sat)
            "Shorelines: Digital Earth Pacific Coastlines. Imagery: Esri World Imagery."
          else "Shorelines: Digital Earth Pacific Coastlines.",
          paste(c(ground, lines[nzchar(lines)]), collapse = "\n"))
}

# -- 2b. one glyph per stretch of coast, not one per cell ------------------------------
# The grid cells are 2 km but a glyph is drawn from a window up to 5.2 km across, and a
# cell's centre is the mean of its own points - so two neighbouring cells whose points
# hug the shared edge can end up 500 m apart and draw the same coast twice. Work down
# from the fastest and drop any candidate whose frame is already mostly covered.
message("framing candidates...")
boxes <- map(seq_len(nrow(cand)), function(i) {
  if (i %% 50 == 0) message(sprintf("  frame %d / %d", i, nrow(cand)))
  glyph_frame(cand[i, ])
})

ok <- !map_lgl(boxes, is.null)
keep <- rep(FALSE, nrow(cand))
kept_box <- list()
for (i in which(ok)) {
  b <- boxes[[i]]
  covered <- FALSE
  for (kb in kept_box) {
    ix <- max(0, min(b[["xmax"]], kb[["xmax"]]) - max(b[["xmin"]], kb[["xmin"]]))
    iy <- max(0, min(b[["ymax"]], kb[["ymax"]]) - max(b[["ymin"]], kb[["ymin"]]))
    if (ix * iy == 0) next
    area <- \(z) (z[["xmax"]] - z[["xmin"]]) * (z[["ymax"]] - z[["ymin"]])
    if (ix * iy / min(area(b), area(kb)) > max_overlap) { covered <- TRUE; break }
  }
  if (!covered) { keep[i] <- TRUE; kept_box[[length(kept_box) + 1]] <- b }
}

picked <- cand[keep, ]
picked$box <- boxes[keep]
message(sprintf("%d of %d cells kept: %d overlapped a stronger one, %d had no shoreline",
                sum(keep), nrow(cand), sum(ok) - sum(keep), sum(!ok)))

picked <- picked |>
  arrange(kind, desc(abs(rate_m_yr))) |>
  mutate(id = sprintf("%s-%03d", kind, ave(seq_along(kind), kind, FUN = seq_along)))

message(sprintf("%d sites: %d retreating, %d building out", nrow(picked),
                sum(picked$kind == "retreat"), sum(picked$kind == "gain")))
message(sprintf("  worst retreat %.1f m/yr, biggest gain %+.1f m/yr",
                min(picked$rate_m_yr), max(picked$rate_m_yr)))
print(count(picked, territory, kind) |> tidyr::pivot_wider(names_from = kind,
      values_from = n, values_fill = 0L) |> arrange(desc(retreat + gain)))

# -- both versions, off one frame ----------------------------------------------------
if (preview_n > 0) {
  picked <- picked |> slice_head(n = preview_n, by = kind)
  glyph_dir <- "output/glyph_preview"
  force_glyphs <- TRUE
  message(sprintf("preview: %d sites", nrow(picked)))
}

variants <- list(lines = FALSE, satellite = TRUE)
dirs <- setNames(file.path(glyph_dir, names(variants)), names(variants))
walk(dirs, \(d) dir.create(d, recursive = TRUE, showWarnings = FALSE))
dest_of <- function(v, id) file.path(dirs[[v]], paste0(id, ".svg"))

# thinning changes both the set and the numbering, so anything on disk that is not in
# the final list is a leftover from an earlier run and would be served as a real site
walk(names(variants), function(v) {
  want <- basename(dest_of(v, picked$id))
  gone <- setdiff(list.files(dirs[[v]], "\\.svg$"), want)
  if (length(gone)) unlink(file.path(dirs[[v]], gone))
  if (length(gone)) message(sprintf("  cleared %d stale glyphs from %s", length(gone), dirs[[v]]))
})

have <- Reduce(`&`, map(names(variants), \(v) file.exists(dest_of(v, picked$id))))
todo <- if (force_glyphs) seq_len(nrow(picked)) else which(!have)
if (length(todo)) {
  message(sprintf("drawing %d sites x %d versions (%d already on disk)",
                  length(todo), length(variants), nrow(picked) - length(todo)))
  walk(todo, function(i) {
    if (i %% 25 == 0) message(sprintf("  glyph %d / %d", i, nrow(picked)))
    # the geometry is the slow half, so it is cut once and rendered twice
    geo <- glyph_geometry(picked[i, ], picked$box[[i]])
    if (is.null(geo)) return(invisible())
    iwalk(variants, function(sat, v) {
      out <- render_glyph(picked[i, ], geo, sat = sat)
      if (!is.null(out)) writeLines(out, dest_of(v, picked$id[i]))
    })
  })
}

# a site is kept only if the plain version drew - the satellite one can be missing when
# the imagery service declines, and a card can fall back to lines
keep <- file.exists(dest_of("lines", picked$id))
picked <- picked[keep, ]

# a window can catch almost no shoreline - a fast rate on a tiny reclaimed islet, say -
# and that makes a card with nothing in it. Count what actually got drawn so the card
# builder can tell a rich glyph from a bare one. One path per line, so counting lines
# that start a path is counting years drawn.
picked$glyph_paths <- map_int(dest_of("lines", picked$id),
                              \(f) sum(startsWith(readLines(f, warn = FALSE), "<path")))
picked$glyph_bytes <- as.integer(file.size(dest_of("lines", picked$id)))
picked$has_satellite <- file.exists(dest_of("satellite", picked$id))

if (preview_n > 0) {
  iwalk(dirs, \(d, v) message(sprintf("%-28s %d glyphs, %.0f KB",
    d, sum(file.exists(dest_of(v, picked$id))),
    sum(file.size(dest_of(v, picked$id)), na.rm = TRUE) / 1024)))
  quit(save = "no")
}

message(sprintf("%d sites drawn; %d with imagery; %d thin (under 5 lines)",
                nrow(picked), sum(picked$has_satellite), sum(picked$glyph_paths < 5)))

# -- 3. where each one is: territory, nearest place, division ------------------------
pts <- st_as_sf(picked, coords = c("x", "y"), crs = crs_m) |> st_transform(4326)
xy  <- st_coordinates(pts)
picked$lon <- round(xy[, 1], 5)
picked$lat <- round(xy[, 2], 5)

country_of <- setNames(names(iso3_of), iso3_of)

read_places <- function(country) {
  pbf <- file.path(osm_dir, sprintf("%s-latest.osm.pbf", country))
  if (!file.exists(pbf)) return(NULL)
  g <- try(st_read(pbf, quiet = TRUE, query =
    "SELECT name, place FROM points WHERE place IS NOT NULL AND name IS NOT NULL"),
    silent = TRUE)
  if (inherits(g, "try-error")) return(NULL)
  filter(g, place %in% c("city", "town", "village", "suburb", "hamlet",
                         "island", "islet", "locality"))
}
read_admin <- function(country) {
  pbf <- file.path(osm_dir, sprintf("%s-latest.osm.pbf", country))
  if (!file.exists(pbf)) return(NULL)
  g <- try(st_read(pbf, quiet = TRUE, query =
    "SELECT name, admin_level FROM multipolygons
     WHERE boundary = 'administrative' AND name IS NOT NULL
       AND admin_level IN ('4','6')"), silent = TRUE)
  if (inherits(g, "try-error") || nrow(g) == 0) return(NULL)
  st_make_valid(g)
}

need   <- unique(unname(geofabrik_of[unique(picked$territory)])) |> discard(is.na)
places <- set_names(need) |> map(read_places)
admins <- set_names(need) |> map(read_admin)

place_at <- function(i) {
  ctry <- geofabrik_of[[picked$territory[i]]]
  g <- places[[ctry]]
  blank <- tibble(place = NA_character_, place_type = NA_character_, place_km = NA_real_)
  if (is.null(g)) return(blank)
  d <- as.numeric(st_distance(g, pts[i, ]))
  near <- which(d < reach_km * 1000)
  if (!length(near)) return(blank)
  tibble(name = g$name[near], type = g$place[near], km = d[near] / 1000) |>
    mutate(score = unname(rank_of[type]) * 2 + km / 5) |>
    slice_min(score, n = 1, with_ties = FALSE) |>
    transmute(place = name, place_type = type, place_km = round(km, 1))
}

admin_at <- function(i) {
  ctry <- geofabrik_of[[picked$territory[i]]]
  g <- admins[[ctry]]
  if (is.null(g)) return(NA_character_)
  hit <- suppressMessages(st_intersects(g, pts[i, ], sparse = FALSE)[, 1])
  if (!any(hit)) return(NA_character_)
  sub <- g[hit, ]
  sub$name[order(sub$admin_level)][1]
}

# -- how many people live beside each one ---------------------------------------------
# Same window as 09_ and 13_, so "people within about 2 km" means one thing on every page
people_near <- function(code) {
  tif <- file.path(pop_dir, sprintf("%s_pop_2020_CN_100m_R2024B_v1.tif", tolower(code)))
  who <- which(picked$territory == code)
  if (!file.exists(tif) || !length(who)) return(tibble(i = who, pop_near = NA_real_))
  sm <- focal(aggregate(rast(tif), fact = 10, fun = "sum", na.rm = TRUE),
              w = pop_win, fun = "sum", na.rm = TRUE)
  tibble(i = who, pop_near = as.numeric(terra::extract(sm, vect(pts[who, ]))[, 2]))
}
pop <- map(sort(unique(picked$territory)), people_near) |> list_rbind() |> arrange(i)
picked$pop_near <- 0
picked$pop_near[pop$i] <- round(coalesce(pop$pop_near, 0))
message(sprintf("%d of %d sites have someone living within about 2 km",
                sum(picked$pop_near > 0), nrow(picked)))

located <- map(seq_len(nrow(picked)), place_at) |> list_rbind()
located$admin <- map_chr(seq_len(nrow(picked)), admin_at)
message(sprintf("%d of %d sites got a name from OpenStreetMap",
                sum(!is.na(located$place)), nrow(picked)))

# -- 4. the nearest Wikipedia article, for the card ----------------------------------
# Two public calls per site, throttled. Anything that fails stays NA; the card is
# expected to cope with a site nobody has written about.
# a cached answer comes back with NULLs where the lookup found nothing, which is not a
# shape tibble() will take - coerce every field to a length-one column of the right type
wiki_row <- function(x) {
  chr <- \(v) if (is.null(v) || !length(v)) NA_character_ else as.character(v)[1]
  num <- \(v) if (is.null(v) || !length(v)) NA_real_ else as.numeric(v)[1]
  tibble(wiki_title = chr(x$wiki_title), wiki_url = chr(x$wiki_url),
         wiki_km = num(x$wiki_km), wiki_extract = chr(x$wiki_extract))
}

wiki_at <- function(lat, lon) {
  blank <- tibble(wiki_title = NA_character_, wiki_url = NA_character_,
                  wiki_km = NA_real_, wiki_extract = NA_character_)
  if (!use_wikipedia) return(blank)

  # geosearch as a generator, so the article and its opening paragraph arrive together -
  # two calls per site got this rate-limited into minute-long backoffs
  res <- try(request("https://en.wikipedia.org/w/api.php") |>
    req_user_agent("pacific-coastlines/1.0 (coastal change data visualisation)") |>
    req_url_query(action = "query", format = "json", formatversion = 2,
                  generator = "geosearch",
                  ggscoord = sprintf("%f|%f", lat, lon),
                  ggsradius = 10000, ggslimit = 1,
                  prop = "extracts|coordinates", exintro = 1, explaintext = 1,
                  exchars = 500) |>
    req_retry(max_tries = 3, backoff = \(i) min(8, 2 ^ i)) |>
    req_timeout(25) |> req_perform() |> resp_body_json(),
    silent = TRUE)
  if (inherits(res, "try-error") || !length(res$query$pages)) return(blank)

  pg <- res$query$pages[[1]]
  if (is.null(pg$title)) return(blank)
  tibble(wiki_title = pg$title,
         wiki_url = paste0("https://en.wikipedia.org/wiki/",
                           gsub(" ", "_", pg$title, fixed = TRUE)),
         wiki_km = NA_real_,
         wiki_extract = if (is.null(pg$extract)) NA_character_
                        else str_trunc(pg$extract, 420, ellipsis = "…"))
}

# cached per cell for the same reason the imagery is: the article nearest a place does
# not change because the site list was re-ranked, and this is the slowest step in the run
dir.create(wiki_dir, recursive = TRUE, showWarnings = FALSE)
wiki <- map(seq_len(nrow(picked)), function(i) {
  f <- file.path(wiki_dir, paste0(picked$cell[i], ".json"))
  if (file.exists(f)) return(wiki_row(fromJSON(f)))
  if (i %% 25 == 0) message(sprintf("  wikipedia %d / %d", i, nrow(picked)))
  Sys.sleep(wiki_pause)
  got <- wiki_at(picked$lat[i], picked$lon[i])
  write_json(got, f, auto_unbox = TRUE, na = "null")
  got
}) |> list_rbind()
message(sprintf("%d of %d sites matched a Wikipedia article",
                sum(!is.na(wiki$wiki_title)), nrow(picked)))

# -- 5. the card table ---------------------------------------------------------------
cards <- picked |>
  bind_cols(located, wiki) |>
  transmute(
    id, kind, cell,
    territory,
    country = unname(country_of[territory]),
    place, place_type, place_km,
    admin = coalesce(admin, "Unassigned"),
    lon, lat,
    rate_m_yr = round(rate_m_yr, 2),
    rate_median_m_yr = round(rate_median_m_yr, 2),
    # The cell rate is a mean, so a few fast transects can carry a stretch of coast that
    # is mostly still. Where the median clears the same bar the reading is representative;
    # where it does not, a card should say so rather than claim the mean as the truth.
    rate_robust = abs(rate_median_m_yr) >= rate_cut,
    shift_m = round(shift_m, 1),
    n_points,
    coast_m = n_points * 30,
    pop_near,
    glyph = file.path("glyphs", "lines", paste0(id, ".svg")),
    glyph_satellite = ifelse(has_satellite,
                             file.path("glyphs", "satellite", paste0(id, ".svg")), NA),
    glyph_paths, glyph_bytes,
    wiki_title, wiki_km, wiki_url, wiki_extract
  ) |>
  arrange(kind, desc(abs(rate_m_yr)))

write_csv(cards, "output/shoreline_glyphs.csv")
write_app_json(cards, "app/data/glyph_sites.json")

print(cards |> select(id, country, place, admin, rate_m_yr, wiki_title) |> head(12))
message(sprintf("\noutput/shoreline_glyphs.csv  |  %d cards", nrow(cards)))
iwalk(dirs, \(d, v) message(sprintf("%-22s %3d glyphs  %6.1f MB", d,
  length(list.files(d, "\\.svg$")),
  sum(file.size(list.files(d, "\\.svg$", full.names = TRUE))) / 1e6)))
message(sprintf("%-22s %3d files   %6.1f MB  (cached, a re-run refetches nothing)", sat_dir,
  length(list.files(sat_dir, "\\.jpg$")),
  sum(file.size(list.files(sat_dir, "\\.jpg$", full.names = TRUE))) / 1e6))
