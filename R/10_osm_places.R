#######################################################################################
# Purpose : Download OpenStreetMap extracts for the territories holding the erosion
#           sites, pull the named settlements out, and give every site a place name
#           instead of a geohash id. The place points double as a label layer on the
#           site maps.
#
#           Source note: pacific-data.sprep.org/resource/osm-download-link-pacific sits
#           behind a Cloudflare challenge that refuses scripted requests, so this pulls
#           the same per-country extracts straight from Geofabrik, which is what that
#           SPREP record links out to.
#   Inputs
#   ──────────────────────────────────────────────────────────────────────
#   [OSM] https://download.geofabrik.de/australia-oceania/<country>-latest.osm.pbf
#   [HOT] output/hotspots_population.csv   the 5 sites from 09_
#   Outputs
#   ──────────────────────────────────────────────────────────────────────
#   data/osm/<country>-latest.osm.pbf     cached extracts
#   app/data/places.geojson               named settlements near the sites, for labels
#   output/hotspots_population_named.csv  the sites with an OSM place name attached
# LLM Disclaimer: Generated with the assistance of Claude Code (VSCode extension claude-opus-5)
#######################################################################################

library(sf)
library(dplyr)
library(purrr)
library(readr)

source("R/config.R")

sf_use_s2(FALSE)

osm_dir  <- "data/osm"
base_url <- "https://download.geofabrik.de/australia-oceania"
label_km <- 25      # settlements to keep around each site, for the map label layer
options(timeout = 1800)

dir.create(osm_dir, recursive = TRUE, showWarnings = FALSE)

sites <- read_csv("output/hotspots_population.csv", show_col_types = FALSE)
need  <- unique(unname(geofabrik_of[sites$territory]))

fetch <- function(country) {
  dest <- file.path(osm_dir, sprintf("%s-latest.osm.pbf", country))
  if (file.exists(dest)) {
    message(sprintf("  %-20s cached  %.1f MB", country, file.size(dest) / 1e6))
  } else {
    message(sprintf("  %-20s downloading", country))
    download.file(sprintf("%s/%s-latest.osm.pbf", base_url, country), dest,
                  mode = "wb", quiet = TRUE)
    message(sprintf("  %-20s %.1f MB", country, file.size(dest) / 1e6))
  }
  dest
}

message("OSM extracts:")
pbfs <- set_names(map_chr(need, fetch), need)

# -- named settlements ---------------------------------------------------------------
# GDAL's OSM driver exposes `place` and `name` as columns on the points layer
read_places <- function(pbf) {
  st_read(pbf, layer = "points", quiet = TRUE,
          query = "SELECT osm_id, name, place FROM points
                   WHERE place IS NOT NULL AND name IS NOT NULL") |>
    filter(place %in% c("city", "town", "village", "suburb", "hamlet",
                        "island", "islet", "locality"))
}

places <- map(pbfs, read_places) |> list_rbind() |> st_as_sf()
message(sprintf("%d named places across %d extracts", nrow(places), length(pbfs)))

site_sf <- st_as_sf(sites, coords = c("lon", "lat"), crs = 4326, remove = FALSE)

# -- nearest settlement to each site, preferring somewhere people would recognise -----
nearest_name <- function(i) {
  d  <- as.numeric(st_distance(places, site_sf[i, ]))
  in_reach <- which(d < label_km * 1000)
  if (!length(in_reach)) return(tibble(place_name = NA_character_,
                                       place_type = NA_character_,
                                       place_km   = NA_real_))
  cand <- tibble(name = places$name[in_reach], type = places$place[in_reach],
                 km = d[in_reach] / 1000) |>
    mutate(score = unname(rank_of[type]) * 2 + km / 5) |>
    arrange(score)
  tibble(place_name = cand$name[1], place_type = cand$type[1],
         place_km = round(cand$km[1], 1))
}

named <- sites |>
  bind_cols(map(seq_len(nrow(sites)), nearest_name) |> list_rbind()) |>
  mutate(label = coalesce(place_name, paste0(territory, " ", round(lat, 2), ", ",
                                             round(lon, 2))))

write_csv(named, "output/hotspots_population_named.csv")

# -- label layer: settlements within reach of any site --------------------------------
near_any <- map(seq_len(nrow(site_sf)),
                \(i) which(as.numeric(st_distance(places, site_sf[i, ])) < label_km * 1000)) |>
  unlist() |> unique()

places |>
  slice(near_any) |>
  filter(place %in% c("city", "town", "village", "suburb")) |>
  select(name, place) |>
  st_write("app/data/places.geojson", delete_dsn = TRUE, quiet = TRUE)

print(select(named, rank, territory, label, place_type, place_km, pop_near, rate_time))
message(sprintf("\napp/data/places.geojson  %.0f KB",
                file.size("app/data/places.geojson") / 1024))
