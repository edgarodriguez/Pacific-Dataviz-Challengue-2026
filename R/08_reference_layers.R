#######################################################################################
# Purpose : Fetch the political boundary polygons the app uses for the choropleth and
#           join them to the DEP territory codes.
#   Inputs
#   ──────────────────────────────────────────────────────────────────────
#   [PIO] PacIOOS GeoServer WFS - PACIOOS:pac_rd_political_bndry
#         22 MultiPolygons, one per Oceania territory, EPSG:4326
#   [CHG] app/data/stats.json   territory codes + indicators, from 06_
#   Outputs
#   ──────────────────────────────────────────────────────────────────────
#   data/reference/pac_political_bndry.geojson   raw WFS response, cached
#   app/data/boundaries.geojson                  joined to ISO3 + every indicator
# LLM Disclaimer: Generated with the assistance of Claude Code (VSCode extension claude-opus-5)
#######################################################################################

library(sf)
library(dplyr)
library(jsonlite)

source("R/config.R")

sf_use_s2(FALSE)

wfs <- paste0("https://geo.pacioos.hawaii.edu/geoserver/PACIOOS/pac_rd_political_bndry/ows",
              "?service=WFS&version=1.0.0&request=GetFeature",
              "&typeName=PACIOOS:pac_rd_political_bndry&outputFormat=application/json")

raw_dir <- "data/reference"
raw     <- file.path(raw_dir, "pac_political_bndry.geojson")
out     <- "app/data/boundaries.geojson"

dir.create(raw_dir, recursive = TRUE, showWarnings = FALSE)

if (!file.exists(raw)) {
  message("downloading PacIOOS political boundaries")
  download.file(wfs, raw, mode = "wb", quiet = TRUE)
} else {
  message("using cached ", raw)
}

bnd <- st_read(raw, quiet = TRUE) |>
  mutate(territory = unname(iso3_of[admin])) |>
  filter(!is.na(territory))

stopifnot(nrow(bnd) == 22, !any(duplicated(bnd$territory)))

stats <- fromJSON("app/data/stats.json")$territories

# carry every indicator on the polygon so the choropleth can switch without a join
bnd <- bnd |>
  select(territory, admin, country) |>
  left_join(
    stats |> select(territory, name, pct_coast_retreat, area_lost_km2, area_gained_km2,
                    area_net_km2, coast_km_assessed, coast_km_retreat, rate_median_m_yr,
                    pop_total, pop_coastal_1km, pop_retreat_1km, pct_coastal, pct_retreat),
    by = join_by(territory)
  ) |>
  st_wrap_dateline(options = c("WRAPDATELINE=YES", "DATELINEOFFSET=180"))

st_write(bnd, out, delete_dsn = TRUE, quiet = TRUE)

message(sprintf("%s  %.0f KB, %d territories", out, file.size(out) / 1024, nrow(bnd)))
message("  bbox: ", paste(round(st_bbox(bnd), 2), collapse = ", "))
