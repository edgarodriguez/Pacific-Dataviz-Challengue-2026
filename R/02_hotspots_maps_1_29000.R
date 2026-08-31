#######################################################################################
# Purpose : Locate the 5 worst shoreline-loss hotspots and package everything needed to
#           draw a 1:29,000 map of each - map frames, clipped shorelines, transects, stats
#   Inputs
#   -------------------------------------------------------------------------
#   [CST] data/dep_ls_coastlines_0-7-0-55.gpkg
#         hotspots_zoom_3   -> 125,697 points, 1 km aggregation radius, rate_time (m/yr)
#         shorelines_annual -> annual shoreline geometries 1999-2023
#         rates_of_change   -> transects at 30 m spacing, used for per-site statistics
#   Outputs
#   -------------------------------------------------------------------------
#   output/hotspots_2013_2021.csv    one row per hotspot: location, rates, measured retreat
#   output/hotspots_2013_2021.gpkg   map-ready layers (see MAP LAYERS below)
#   output/hotspot_<rank>_<uid>.svg  250 x 170 mm sheet, vector, true 1:29,000 at 100%
# LLM Disclaimer: Generated with the assistance of Claude Code (VSCode extension claude-opus-5)
#######################################################################################
#
# MAP LAYERS written to output/hotspots_2013_2021.gpkg, all EPSG:3832:
#   hotspot_points  5 pts    hotspot centre, rate_time, ranking
#   map_frames      5 polys  the 1:29,000 print extent - use as the map canvas
#   shorelines      lines    every annual shoreline clipped to each frame, is_focus flags 2013/2021
#   transects       points   good-certainty transects in each frame, rate_time for symbology
#
#######################################################################################

library(sf)
library(dplyr)
library(tibble)
library(purrr)
library(ggplot2)
library(readr)

source("R/config.R")

year_a      <- 2013
year_b      <- 2021
span_yr     <- year_b - year_a
n_hotspots  <- 5
map_scale   <- 29000
frame_mm_w  <- 250    # printable map area, A4 landscape less margins
frame_mm_h  <- 170
out_dir     <- "output"
out_gpkg    <- file.path(out_dir, "hotspots_2013_2021.gpkg")

frame_w_m  <- frame_mm_w / 1000 * map_scale   # 7250 m of ground at 1:29,000
frame_h_m  <- frame_mm_h / 1000 * map_scale   # 4930 m
min_sep_m  <- sqrt(frame_w_m^2 + frame_h_m^2) # frame diagonal - guarantees no overlap

dir.create(out_dir, showWarnings = FALSE)

# --- 1. Candidate hotspots ------------------------------------------------------------
# hotspots_zoom_3 already aggregates transect trends over a 1 km radius, so no clustering
# is needed here - only filtering and spatial thinning.

candidates <- st_read(
  gpkg,
  query = "SELECT uid, rate_time, sig_time, se_time, n, radius_m, certainty, geom
           FROM hotspots_zoom_3
           WHERE certainty = 'good' AND sig_time < 0.01 AND rate_time < 0
           ORDER BY rate_time",
  quiet = TRUE
)

# --- 2. Thin to distinct places -------------------------------------------------------
# The worst rates cluster inside single bays, so take the worst, drop everything within one
# frame diagonal of it, repeat. Distances are geodesic, not Mercator metres.
# ponytail: greedy loop over 5 picks, swap for a proper max-min dispersion if n_hotspots grows.

pick_dispersed <- function(pts, k, sep_m) {
  ll   <- st_transform(pts, 4326)
  keep <- integer(0)
  pool <- seq_len(nrow(pts))
  while (length(keep) < k && length(pool) > 0) {
    take <- pool[1]
    keep <- c(keep, take)
    d    <- as.numeric(st_distance(ll[pool, ], ll[take, ]))
    pool <- pool[d > sep_m]
  }
  pts[keep, ]
}

hotspots <- candidates |>
  pick_dispersed(n_hotspots, min_sep_m) |>
  mutate(rank = row_number())

stopifnot(nrow(hotspots) == n_hotspots)

# --- 3. Locate each hotspot and size its frame ----------------------------------------
# EPSG:3832 is a Mercator: one projected metre is only cos(latitude) ground metres. A frame
# of 7250 projected metres would print at 1:29,000 nominal but 1:27,000 true at 20 S, so the
# frame is widened by 1/cos(lat) to cover a true 7250 m of ground.

lonlat <- st_coordinates(st_transform(hotspots, 4326))

hotspots <- hotspots |>
  mutate(
    lon         = lonlat[, "X"],
    lat         = lonlat[, "Y"],
    mercator_k  = 1 / cos(lat * pi / 180),
    utm_epsg    = ifelse(lat >= 0, 32600, 32700) + floor((lon + 180) / 6) + 1,
    frame_w_m   = frame_w_m,
    frame_h_m   = frame_h_m,
    map_scale   = map_scale
  )

xy <- unname(st_coordinates(hotspots))   # named cells would corrupt the st_bbox() names

make_frame <- function(i) {
  half_w <- frame_w_m * hotspots$mercator_k[i] / 2
  half_h <- frame_h_m * hotspots$mercator_k[i] / 2
  st_bbox(
    c(xmin = xy[i, 1] - half_w, ymin = xy[i, 2] - half_h,
      xmax = xy[i, 1] + half_w, ymax = xy[i, 2] + half_h),
    crs = st_crs(hotspots)
  ) |> st_as_sfc()
}

map_frames <- hotspots |>
  st_drop_geometry() |>
  st_set_geometry(do.call(c, map(seq_len(n_hotspots), make_frame)))

# --- 4. Clip the map content to each frame --------------------------------------------
# wkt_filter pushes the bounding box into GDAL's spatial index, so the 2 M transect points
# are never loaded into R.

clip_layer <- function(layer, where = NULL) {
  map(seq_len(n_hotspots), \(i) {
    frame <- st_geometry(map_frames)[i]
    feats <- st_read(gpkg, layer, wkt_filter = st_as_text(frame), quiet = TRUE)
    if (!is.null(where)) feats <- filter(feats, !!rlang::parse_expr(where))
    if (nrow(feats) == 0) return(NULL)
    suppressWarnings(st_intersection(feats, frame)) |>
      mutate(rank = i, uid_hotspot = hotspots$uid[i])
  }) |>
    list_rbind() |>
    st_as_sf()
}

shorelines <- clip_layer("shorelines_annual") |>
  mutate(
    year     = as.integer(year),
    is_focus = year %in% c(year_a, year_b),
    length_m = as.numeric(st_length(geom))
  )

transects <- clip_layer("rates_of_change", where = 'certainty == "good"') |>
  mutate(shift_m = rate_time * span_yr)

# --- 5. Measured 2013 vs 2021 separation ----------------------------------------------
# rates_of_change carries no per-year positions, so the only true two-epoch measurement is
# geometric: how far the 2021 shoreline sits from the 2013 one. Measured inside the hotspot
# radius, not the whole frame - across a 7 km frame the median is dominated by unrelated
# coast. Unsigned by construction; read it next to shift_hotspot_m for direction.

# The buffer is the 1 km aggregation radius widened by the projected travel distance -
# at 60 m/yr the shoreline leaves a fixed 1 km core entirely and the two epochs never meet.

site_context <- function(i) {
  reach <- hotspots$radius_m[i] + abs(hotspots$rate_time[i] * span_yr)
  core  <- st_buffer(st_geometry(hotspots)[i], reach)
  sl    <- suppressWarnings(st_intersection(filter(shorelines, rank == i), core))
  a     <- filter(sl, year == year_a)
  b     <- filter(sl, year == year_b)
  tibble(
    core_reach_m   = reach,
    core_n_years   = n_distinct(sl$year),
    core_year_min  = if (nrow(sl) > 0) min(sl$year) else NA_integer_,
    core_has_a     = nrow(a) > 0,
    core_has_b     = nrow(b) > 0,
    measured_gap_m = if (nrow(a) > 0 && nrow(b) > 0) {
      median(as.numeric(st_distance(st_cast(st_geometry(b), "POINT"),
                                    st_union(st_geometry(a)))))
    } else NA_real_
  )
}

site_stats <- map(seq_len(n_hotspots), \(i) {
  tr <- filter(transects, rank == i)
  sl <- filter(shorelines, rank == i)
  tibble(
    rank                   = i,
    territory              = names(sort(table(tr$eez_territory), decreasing = TRUE))[1],
    frame_n_transects      = nrow(tr),
    frame_coast_km         = nrow(tr) * 30 / 1000,
    frame_pct_retreating   = 100 * mean(tr$sig_time < p_sig & tr$rate_time < 0),
    frame_rate_median_m_yr = median(tr$rate_time, na.rm = TRUE),
    frame_rate_p10_m_yr    = quantile(tr$rate_time, 0.10, na.rm = TRUE, names = FALSE),
    frame_area_lost_km2    = -sum(pmin(tr$shift_m, 0) * 30, na.rm = TRUE) / 1e6,
    shoreline_km_a         = sum(sl$length_m[sl$year == year_a]) / 1000,
    shoreline_km_b         = sum(sl$length_m[sl$year == year_b]) / 1000
  ) |>
    bind_cols(site_context(i))
}) |>
  list_rbind()

hotspot_tbl <- hotspots |>
  st_drop_geometry() |>
  as_tibble() |>
  mutate(
    shift_hotspot_m = rate_time * span_yr,
    t_ratio         = rate_time / se_time   # trend consistency: |t| < ~6 means a wobbling feature
  ) |>
  left_join(site_stats, by = join_by(rank)) |>
  relocate(rank, uid, territory, lon, lat, rate_time, shift_hotspot_m)

# --- 6. Write -------------------------------------------------------------------------

if (file.exists(out_gpkg)) file.remove(out_gpkg)
write_sf(hotspots,   out_gpkg, "hotspot_points")
write_sf(map_frames, out_gpkg, "map_frames")
write_sf(shorelines, out_gpkg, "shorelines")
write_sf(transects,  out_gpkg, "transects")
write_csv(hotspot_tbl, file.path(out_dir, "hotspots_2013_2021.csv"))

# --- 7. Preview maps at true 1:29,000 -------------------------------------------------
# theme_void() with zero margins makes the panel the whole image, so a 250 x 170 mm sheet
# printed at 100% is exactly 1:29,000. Legend and scale bar sit inside the neatline.
# Two focus years only - 25 hues would be a rainbow. Context years share one recessive gray,
# and linetype repeats the year distinction so identity never rests on colour alone.

ink_context <- "#c3c2b7"
ink_year_a  <- "#2a78d6"   # validated categorical pair, CVD dE 24.7 on a #fcfcfb surface
ink_year_b  <- "#eb6834"

epoch_levels <- c(paste(min(shorelines$year), max(shorelines$year), sep = "-"),
                  as.character(year_a), as.character(year_b))

draw_site <- function(i) {
  frame <- st_bbox(st_geometry(map_frames)[i])
  k     <- hotspots$mercator_k[i]
  bar_m <- 1000 * k                                  # 1 km of ground in projected metres
  pad   <- (frame$xmax - frame$xmin) * 0.04

  sl <- shorelines |>
    filter(rank == i) |>
    mutate(epoch = factor(case_when(year == year_a ~ as.character(year_a),
                                    year == year_b ~ as.character(year_b),
                                    .default = epoch_levels[1]), levels = epoch_levels)) |>
    arrange(epoch)

  ggplot(sl) +
    geom_sf(aes(colour = epoch, linewidth = epoch, linetype = epoch)) +
    geom_sf(data = hotspots[i, ], shape = 21, size = 4, stroke = 1.1,
            colour = "#0b0b0b", fill = NA) +
    annotate("segment", x = frame$xmin + pad, xend = frame$xmin + pad + bar_m,
             y = frame$ymin + pad, yend = frame$ymin + pad, linewidth = 1.1,
             colour = "#0b0b0b") +
    annotate("text", x = frame$xmin + pad + bar_m / 2, y = frame$ymin + pad * 1.35,
             label = "1 km", size = 3.2, colour = "#52514e", vjust = 0) +
    annotate("text", x = frame$xmin + pad, y = frame$ymax - pad, hjust = 0, vjust = 1,
             size = 4.4, colour = "#0b0b0b", fontface = "bold",
             label = sprintf("%d. %s  %s", i, hotspot_tbl$territory[i], hotspot_tbl$uid[i])) +
    annotate("text", x = frame$xmin + pad, y = frame$ymax - pad * 1.9, hjust = 0, vjust = 1,
             size = 3.2, colour = "#52514e",
             label = sprintf("%.1f m/yr  |  %.0f m projected %d-%d  |  1:%s",
                             hotspot_tbl$rate_time[i], hotspot_tbl$shift_hotspot_m[i],
                             year_a, year_b, format(map_scale, big.mark = ","))) +
    scale_colour_manual(values = setNames(c(ink_context, ink_year_a, ink_year_b), epoch_levels)) +
    scale_linewidth_manual(values = setNames(c(0.25, 0.9, 0.9), epoch_levels)) +
    scale_linetype_manual(values = setNames(c("solid", "22", "solid"), epoch_levels)) +
    coord_sf(xlim = c(frame$xmin, frame$xmax), ylim = c(frame$ymin, frame$ymax),
             expand = FALSE, datum = NA) +
    theme_void(base_size = 11) +
    theme(
      legend.position          = "inside",
      legend.position.inside   = c(0.99, 0.02),
      legend.justification     = c(1, 0),
      legend.title             = element_blank(),
      legend.key               = element_rect(fill = "#fcfcfb", colour = NA),
      legend.background        = element_rect(fill = "#fcfcfb", colour = "#e1e0d9"),
      legend.margin            = margin(6, 8, 6, 8),
      plot.background          = element_rect(fill = "#fcfcfb", colour = NA),
      plot.margin              = margin(0, 0, 0, 0)
    )
}

walk(seq_len(n_hotspots), \(i) {
  # SVG, not PNG: the sheet is line work at a fixed scale, so it should stay vector.
  # 250 x 170 mm still prints true 1:29,000 at 100%, and now scales without resampling.
  ggsave(file.path(out_dir, sprintf("hotspot_%d_%s.svg", i, hotspot_tbl$uid[i])),
         draw_site(i), width = frame_mm_w, height = frame_mm_h, units = "mm",
         device = if (requireNamespace("svglite", quietly = TRUE)) svglite::svglite else "svg")
})

cat("\n== Top", n_hotspots, "shoreline-loss hotspots,", year_a, "vs", year_b, "==\n")
hotspot_tbl |>
  select(rank, uid, territory, lon, lat, rate_time, se_time, t_ratio, shift_hotspot_m,
         measured_gap_m, core_has_a, core_has_b, frame_pct_retreating, frame_coast_km,
         utm_epsg) |>
  print(n = Inf, width = Inf)

cat("\n== Frames ==", sprintf("\n1:%s over %.0f x %.0f m of ground (%.0f x %.0f mm on paper)\n",
    format(map_scale, big.mark = ","), frame_w_m, frame_h_m, frame_mm_w, frame_mm_h))
cat("shorelines clipped:", nrow(shorelines), "features |", year_a, "&", year_b, "flagged is_focus\n")
cat("transects clipped :", nrow(transects), "points\n")

# --- Self-check -----------------------------------------------------------------------
# The frames must cover a true 7250 m of ground once the Mercator correction is applied,
# and every hotspot must be a genuinely separate place.

corners  <- st_transform(map_frames, 4326)
widths_m <- map_dbl(seq_len(n_hotspots), \(i) {
  b <- st_bbox(corners[i, ])
  as.numeric(st_distance(
    st_sfc(st_point(c(b$xmin, (b$ymin + b$ymax) / 2)), crs = 4326),
    st_sfc(st_point(c(b$xmax, (b$ymin + b$ymax) / 2)), crs = 4326)
  ))
})

sep_m <- st_distance(st_transform(hotspots, 4326)) |> as.numeric()

stopifnot(
  max(abs(widths_m - frame_w_m)) / frame_w_m < 0.01,
  min(sep_m[sep_m > 0]) > min_sep_m,
  all(hotspot_tbl$rate_time < 0),
  all(hotspot_tbl$shift_hotspot_m < 0),
  nrow(shorelines) > 0,
  nrow(transects) > 0,
  sum(shorelines$is_focus) > 0
)
cat("\nself-check OK - frame ground width", round(mean(widths_m)), "m (target", frame_w_m, "m )\n")
