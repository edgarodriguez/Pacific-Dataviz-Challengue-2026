#######################################################################################
# Purpose : Turn real coastline geometry into stampable motifs for the barkcloth variant.
#           Each territory contributes a handful of its own 2021 shoreline segments,
#           normalised into a unit box so the page can repeat them like carved stamps.
#           Nothing here is a drawn ornament - every mark is Pacific coast.
#   Inputs
#   ──────────────────────────────────────────────────────────────────────
#   [CST] data/dep_ls_coastlines_0-7-0-55.gpkg
#         shorelines_annual -> 2021 and 2013-2021, certainty 'good'
#   [HOT] output/hotspots_population_named.csv   the 5 towns, for the year registers
#   Outputs
#   ──────────────────────────────────────────────────────────────────────
#   app/data/motifs.json   per-territory stamps + a year sequence for one town
# LLM Disclaimer: Generated with the assistance of Claude Code (VSCode extension claude-opus-5)
#######################################################################################

library(sf)
library(dplyr)
library(purrr)
library(readr)
library(jsonlite)

source("R/config.R")

sf_use_s2(FALSE)

simplify_m <- 120     # a stamp is a few centimetres wide; pixel detail is wasted on it
n_stamps   <- 4       # motifs per territory
stamp_pts  <- 26      # vertices per motif, resampled to a fixed count

# -- resample a line to a fixed number of evenly spaced vertices --------------------
resample <- function(m, n) {
  d <- c(0, cumsum(sqrt(rowSums(diff(m)^2))))
  if (max(d) <= 0) return(NULL)
  at <- seq(0, max(d), length.out = n)
  cbind(approx(d, m[, 1], at)$y, approx(d, m[, 2], at)$y)
}

# -- fit into a unit box, keeping the aspect ratio so the coast is not distorted -----
normalise <- function(m) {
  rx <- range(m[, 1]); ry <- range(m[, 2])
  span <- max(diff(rx), diff(ry))
  if (!is.finite(span) || span <= 0) return(NULL)
  cbind((m[, 1] - mean(rx)) / span + .5, (mean(ry) - m[, 2]) / span + .5)
}

# -- one territory's stamps ---------------------------------------------------------
# Small islands lose every part at the coarse tolerance - Niue is one ring a few km
# across - so drop to a finer one when a territory comes back short.
stamps_at <- function(code, tol, min_pts) {
  g <- st_read(gpkg, quiet = TRUE,
    query = sprintf("SELECT geom FROM shorelines_annual
                     WHERE year = 2021 AND certainty = 'good' AND eez_territory = '%s'", code)) |>
    st_cast("LINESTRING", warn = FALSE) |>
    st_simplify(dTolerance = tol, preserveTopology = TRUE) |>
    st_transform(4326)

  parts <- parts_of(g) |> keep(\(m) nrow(m) >= min_pts)
  if (!length(parts)) return(list())

  # the longest segments carry the most recognisable coast
  span <- map_dbl(parts, \(m) max(diff(range(m[, 1])), diff(range(m[, 2]))))
  parts <- parts[order(-span)][seq_len(min(n_stamps, length(parts)))]

  parts |>
    map(\(m) { r <- resample(m, stamp_pts); if (is.null(r)) NULL else normalise(r) }) |>
    compact() |>
    map(flat) |>
    unname()
}

stamps_for <- function(code) {
  out <- stamps_at(code, simplify_m, 8)
  if (length(out) < 2) out <- stamps_at(code, 25, 4)
  out
}

territories <- fromJSON("app/data/stats.json")$territories

message("stamping coastlines:")
motifs <- map(territories$territory, \(code) {
  s <- stamps_for(code)
  message(sprintf("  %-4s %d motifs", code, length(s)))
  s
})
names(motifs) <- territories$territory

# -- the year register: one town's shoreline, 2013 to 2021 --------------------------
site <- read_csv("output/hotspots_population_named.csv", show_col_types = FALSE) |> slice(1)
box  <- st_bbox(st_buffer(
  st_sfc(st_point(c(site$lon, site$lat)), crs = 4326) |> st_transform(3832),
  2600)) |> st_as_sfc() |> st_transform(4326) |> st_bbox()

year_band <- function(yr) {
  g <- st_read(gpkg, quiet = TRUE,
    query = sprintf("SELECT geom FROM shorelines_annual
                     WHERE year = %d AND certainty = 'good' AND eez_territory = '%s'",
                    yr, site$territory)) |>
    st_transform(4326) |>
    st_crop(box) |>
    st_simplify(dTolerance = 0.00012, preserveTopology = TRUE)
  if (nrow(g) == 0) return(NULL)
  parts_of(g) |>
    keep(\(m) nrow(m) >= 4) |>
    map(\(m) flat(cbind((m[, 1] - box[["xmin"]]) / (box[["xmax"]] - box[["xmin"]]),
                        (box[["ymax"]] - m[, 2]) / (box[["ymax"]] - box[["ymin"]])))) |>
    unname()
}

years <- 2013:2021
bands <- map(years, year_band)
names(bands) <- years
message(sprintf("\n%s year bands: %s",
                site$label, paste(years, map_int(bands, length), sep = ":", collapse = " ")))

write_app_json(
  list(
    motifs = motifs,
    site   = list(label = site$label, territory = site$territory,
                  lon = site$lon, lat = site$lat,
                  pop_near = site$pop_near, rate_time = site$rate_time,
                  years = years, bands = bands)
  ),
  "app/data/motifs.json"
)

message(sprintf("\napp/data/motifs.json  %.0f KB",
                file.size("app/data/motifs.json") / 1024))
