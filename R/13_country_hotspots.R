#######################################################################################
# Purpose : For every territory, the three retreating stretches of coast with the most
#           people near them, each named from OpenStreetMap. Feeds the country filter
#           in the drawer, which needs a per-country answer rather than the region-wide
#           top five that 09_ produces.
#   Inputs
#   ──────────────────────────────────────────────────────────────────────
#   [CST] data/dep_ls_coastlines_0-7-0-55.gpkg   hotspots_zoom_3
#   [POP] data/worldpop/<iso3>_pop_2020_CN_100m_R2024B_v1.tif
#   [BND] data/reference/pac_political_bndry.geojson   to assign a territory
#   [OSM] data/osm/<country>-latest.osm.pbf     downloaded on demand, from Geofabrik
#   Outputs
#   ──────────────────────────────────────────────────────────────────────
#   output/country_hotspots.csv   up to 3 rows per territory, pop within ~2 km
#   app/data/country_hotspots.json
# LLM Disclaimer: Generated with the assistance of Claude Code (VSCode extension claude-opus-5)
#######################################################################################

library(sf)
library(terra)
library(dplyr)
library(purrr)
library(readr)
library(jsonlite)

source("R/config.R")

sf_use_s2(FALSE)
options(timeout = 1800)

pop_dir <- "data/worldpop"
osm_dir <- "data/osm"
base    <- "https://download.geofabrik.de/australia-oceania"
per_ctry <- 3
apart_m  <- 12000    # distinct places within a country
reach_km <- 25       # how far to look for a name
pop_win  <- 5        # 1 km cells, 5x5 box - the same reach 09_ uses, so the two agree

dir.create(osm_dir, recursive = TRUE, showWarnings = FALSE)

bnd <- st_read("data/reference/pac_political_bndry.geojson", quiet = TRUE) |>
  mutate(territory = unname(iso3_of[admin])) |>
  filter(!is.na(territory)) |>
  select(territory)

# Five territories - Guam, N. Marianas, Nauru, Pitcairn, Wallis - have retreating coast
# but nothing reaching p < 0.01, so a strict filter dropped them from the map entirely.
# Keep every retreating candidate and grade it instead, so all 22 appear and the page can
# say how much weight each one carries.
candidates <- st_read(
  gpkg, quiet = TRUE,
  query = "SELECT uid, rate_time, sig_time, se_time, n, geom FROM hotspots_zoom_3
           WHERE certainty = 'good' AND rate_time < 0") |>
  st_transform(4326) |>
  st_join(bnd, join = st_intersects) |>
  filter(!is.na(territory)) |>
  mutate(confidence = case_when(sig_time <  0.01 ~ "clear",
                                sig_time <  0.10 ~ "tentative",
                                TRUE             ~ "unclear"))

message(sprintf("%s retreating candidates", format(nrow(candidates), big.mark = ",")))

# -- people within ~3 km of each candidate ------------------------------------------
people_near <- function(code) {
  tif <- file.path(pop_dir, sprintf("%s_pop_2020_CN_100m_R2024B_v1.tif", tolower(code)))
  pts <- filter(candidates, territory == code)
  if (!file.exists(tif) || nrow(pts) == 0) return(tibble(uid = pts$uid, pop_near = NA_real_))
  sm <- focal(aggregate(rast(tif), fact = 10, fun = "sum", na.rm = TRUE),
              w = pop_win, fun = "sum", na.rm = TRUE)
  tibble(uid = pts$uid, pop_near = as.numeric(terra::extract(sm, vect(pts))[, 2]))
}

codes <- sort(unique(candidates$territory))
pop <- map(codes, people_near) |> list_rbind()

ranked <- candidates |>
  left_join(pop, by = join_by(uid)) |>
  mutate(pop_near = coalesce(pop_near, 0))

# -- up to three distinct places per territory ---------------------------------------
# prefer clear sites, fall back through tentative to unclear so nowhere is left out
conf_rank <- c(clear = 1, tentative = 2, unclear = 3)

pick_for <- function(code) {
  pool <- ranked |>
    filter(territory == code) |>
    arrange(conf_rank[confidence], desc(pop_near), rate_time)
  keep <- pool[0, ]
  while (nrow(keep) < per_ctry && nrow(pool) > 0) {
    keep <- bind_rows(keep, pool[1, ])
    pool <- pool[as.numeric(st_distance(pool, pool[1, ])) > apart_m, ]
  }
  keep
}

picked <- map(codes, pick_for) |> bind_rows()
message(sprintf("%d sites across %d territories", nrow(picked), n_distinct(picked$territory)))
print(count(st_drop_geometry(picked), confidence))

# -- OSM names ------------------------------------------------------------------------
need <- unique(unname(geofabrik_of[unique(picked$territory)]))
fetch <- function(country) {
  dest <- file.path(osm_dir, sprintf("%s-latest.osm.pbf", country))
  if (!file.exists(dest)) {
    message(sprintf("  downloading %s", country))
    try(download.file(sprintf("%s/%s-latest.osm.pbf", base, country), dest,
                      mode = "wb", quiet = TRUE), silent = TRUE)
  }
  if (file.exists(dest)) dest else NA_character_
}
pbfs <- set_names(map_chr(need, fetch), need) |> discard(is.na)

read_places <- function(pbf) {
  out <- try(st_read(pbf, quiet = TRUE,
    query = "SELECT name, place FROM points WHERE place IS NOT NULL AND name IS NOT NULL"),
    silent = TRUE)
  if (inherits(out, "try-error")) return(NULL)
  filter(out, place %in% c("city", "town", "village", "suburb", "hamlet",
                           "island", "islet", "locality"))
}
places <- map(pbfs, read_places) |> compact() |> bind_rows() |> st_as_sf()
message(sprintf("%s named OSM places", format(nrow(places), big.mark = ",")))

name_at <- function(i) {
  d <- as.numeric(st_distance(places, picked[i, ]))
  near <- which(d < reach_km * 1000)
  if (!length(near)) return(tibble(place = NA_character_, place_km = NA_real_))
  tibble(name = places$name[near], type = places$place[near], km = d[near] / 1000) |>
    mutate(score = unname(rank_of[type]) * 2 + km / 5) |>
    arrange(score) |>
    slice(1) |>
    transmute(place = name, place_km = round(km, 1))
}

xy <- st_coordinates(picked)
out <- picked |>
  st_drop_geometry() |>
  bind_cols(map(seq_len(nrow(picked)), name_at) |> list_rbind()) |>
  mutate(lon = round(xy[, 1], 5), lat = round(xy[, 2], 5),
         pop_near = round(pop_near),
         rate_time = round(rate_time, 2),
         sig_time = signif(sig_time, 3),
         shift_2013_2021_m = round(rate_time * 8, 1),
         label = coalesce(place, sprintf("%.2f, %.2f", lat, lon))) |>
  select(territory, label, place_km, lon, lat, rate_time, sig_time, confidence,
         shift_2013_2021_m, pop_near) |>
  arrange(territory, conf_rank[confidence], desc(pop_near))

write_csv(out, "output/country_hotspots.csv")
write_app_json(split(select(out, -territory), out$territory), "app/data/country_hotspots.json")

print(head(out, 12))
message(sprintf("\napp/data/country_hotspots.json  %.0f KB  |  %d territories",
                file.size("app/data/country_hotspots.json") / 1024, n_distinct(out$territory)))
