#######################################################################################
# Purpose : Pull the shorelines from hotspots 3 and 4 - the two sites whose trend is
#           clearest, t = -21 and -23 - and normalise them into repeating strips for
#           the cloth background. These are the two places where the 2013 and 2021
#           lines separate cleanly, so the pattern carries a real reading rather than
#           an ornament.
#   Inputs
#   ──────────────────────────────────────────────────────────────────────
#   [GPK] output/hotspots_2013_2021.gpkg   shorelines clipped to each 1:29,000 frame
#   [HOT] output/hotspots_2013_2021.csv    rate, t ratio and frame context
#   Outputs
#   ──────────────────────────────────────────────────────────────────────
#   app/data/background_lines.json   per-site year strips, ready to tile
# LLM Disclaimer: Generated with the assistance of Claude Code (VSCode extension claude-opus-5)
#######################################################################################

library(sf)
library(dplyr)
library(purrr)
library(readr)
library(jsonlite)

source("R/config.R")   # for flat(); this script's own gpkg (below) is not the DEP archive

sf_use_s2(FALSE)

gpkg  <- "output/hotspots_2013_2021.gpkg"
ranks <- c(3, 4)
years <- c(2013, 2017, 2021)   # start, middle, end - enough to show the walk
simplify_m <- 45

frames <- st_read(gpkg, "map_frames", quiet = TRUE)
shores <- st_read(gpkg, "shorelines", quiet = TRUE)
meta   <- read_csv("output/hotspots_2013_2021.csv", show_col_types = FALSE)

# each frame becomes a unit strip: x runs 0-1 across the frame, y 0-1 down it
strip_for <- function(rk, yr) {
  box <- st_bbox(filter(frames, rank == rk))
  g <- shores |>
    filter(rank == rk, year == yr) |>
    st_simplify(dTolerance = simplify_m, preserveTopology = TRUE) |>
    st_cast("LINESTRING", warn = FALSE)
  if (nrow(g) == 0) return(list())
  parts_of(g) |>
    keep(\(m) nrow(m) >= 4) |>
    map(\(m) flat(cbind(
      (m[, 1] - box[["xmin"]]) / (box[["xmax"]] - box[["xmin"]]),
      (box[["ymax"]] - m[, 2]) / (box[["ymax"]] - box[["ymin"]])
    ))) |>
    unname()
}

sites <- map(ranks, function(rk) {
  m <- filter(meta, rank == rk)
  bands <- set_names(map(years, \(y) strip_for(rk, y)), years)
  message(sprintf("  site %d  %s  t=%.1f  bands: %s", rk, m$uid, m$t_ratio,
                  paste(years, map_int(bands, length), sep = ":", collapse = " ")))
  list(
    rank = rk, uid = m$uid, territory = m$territory,
    lon = round(m$lon, 4), lat = round(m$lat, 4),
    rate_time = round(m$rate_time, 1),
    t_ratio = round(m$t_ratio, 1),
    measured_gap_m = round(m$measured_gap_m),
    frame_w_m = m$frame_w_m,
    pct_retreating = round(m$frame_pct_retreating, 1),
    years = years,
    bands = bands
  )
})

message("extracting background strips:")
write_app_json(list(sites = sites, note = paste(
  "Shorelines at the two sites whose retreat trend is clearest in the record.",
  "Each strip is one 7,250 m frame, normalised."
)), "app/data/background_lines.json")

message(sprintf("\napp/data/background_lines.json  %.0f KB",
                file.size("app/data/background_lines.json") / 1024))
