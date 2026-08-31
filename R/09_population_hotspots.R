#######################################################################################
# Purpose : Pick the erosion sites that affect the most people, not the ones with the
#           fastest retreat. 02_ ranked on rate_time and every site landed in an
#           uninhabited PNG river delta; this ranks the same candidates on the WorldPop
#           count living within ~2 km of the retreating coast.
#   Inputs
#   ──────────────────────────────────────────────────────────────────────
#   [CST] data/dep_ls_coastlines_0-7-0-55.gpkg
#         hotspots_zoom_3 -> 125,697 points, each already aggregating transects over 1 km
#   [POP] data/worldpop/<iso3>_pop_2020_CN_100m_R2024B_v1.tif   WorldPop R2024B 2020
#   Outputs
#   ──────────────────────────────────────────────────────────────────────
#   output/hotspots_population.csv   the ranked sites, one row each
# LLM Disclaimer: Generated with the assistance of Claude Code (VSCode extension claude-opus-5)
#######################################################################################

library(sf)
library(terra)
library(dplyr)
library(purrr)
library(readr)

sf_use_s2(FALSE)

source("R/config.R")

pop_dir  <- "data/worldpop"
n_sites  <- 5
reach_m  <- 3000    # rounds to a 5x5 box of 1 km cells, so about 2 km each way
apart_m  <- 20000   # keep the sites in distinct places, not 5 points in one lagoon

# hotspots_zoom_3 carries no territory column, so the EEZ polygons from 08_ assign it
bnd <- st_read("data/reference/pac_political_bndry.geojson", quiet = TRUE) |>
  mutate(eez_territory = unname(iso3_of[admin])) |>
  select(eez_territory)

candidates <- st_read(
  gpkg, quiet = TRUE,
  query = sprintf("SELECT uid, rate_time, sig_time, se_time, n, geom
                   FROM hotspots_zoom_3
                   WHERE certainty = 'good' AND sig_time < %f AND rate_time < 0", p_sig)
) |>
  st_transform(4326) |>
  st_join(bnd, join = st_intersects) |>
  filter(!is.na(eez_territory))

message(sprintf("%d retreating candidates across %d territories",
                nrow(candidates), n_distinct(candidates$eez_territory)))

# -- people within reach of each candidate ------------------------------------------
# WorldPop 100 m summed to 1 km, then a focal sum, so a point lookup returns the
# population of the surrounding few km rather than of one cell. 13_ uses the same window.
people_near <- function(code) {
  tif <- file.path(pop_dir, sprintf("%s_pop_2020_CN_100m_R2024B_v1.tif", tolower(code)))
  pts <- filter(candidates, eez_territory == code)
  if (!file.exists(tif) || nrow(pts) == 0) return(tibble(uid = pts$uid, pop_near = NA_real_))

  km  <- aggregate(rast(tif), fact = 10, fun = "sum", na.rm = TRUE)
  win <- max(3, 2 * round(reach_m / 1000 / 2) + 1)
  sm  <- focal(km, w = win, fun = "sum", na.rm = TRUE)

  tibble(uid = pts$uid,
         pop_near = as.numeric(terra::extract(sm, vect(pts))[, 2]))
}

pop <- map(sort(unique(candidates$eez_territory)), people_near) |> list_rbind()

ranked <- candidates |>
  left_join(pop, by = join_by(uid)) |>
  mutate(pop_near = coalesce(pop_near, 0),
         t_ratio  = round(rate_time / se_time, 2)) |>
  arrange(desc(pop_near), rate_time)

# -- thin to distinct places --------------------------------------------------------
keep <- integer(0)
pool <- ranked
while (length(keep) < n_sites && nrow(pool) > 0) {
  keep <- c(keep, pool$uid[1])
  far  <- as.numeric(st_distance(pool, pool[1, ])) > apart_m
  pool <- pool[far, ]
}

picked <- ranked |> filter(uid %in% keep) |> arrange(desc(pop_near))
xy <- st_coordinates(picked)   # the gpkg names its geometry column `geom`, not `geometry`

sites <- picked |>
  st_drop_geometry() |>
  mutate(
    rank = row_number(),
    lon  = round(xy[, 1], 5),
    lat  = round(xy[, 2], 5),
    shift_2013_2021_m = round(rate_time * 8, 1),
    pop_near = round(pop_near),
    across(where(is.numeric), \(x) round(x, 4))
  ) |>
  select(rank, uid, territory = eez_territory, lon, lat, rate_time, se_time, t_ratio,
         sig_time, n, pop_near, shift_2013_2021_m)

write_csv(sites, "output/hotspots_population.csv")
print(sites)
message(sprintf("\noutput/hotspots_population.csv - %d sites, %s to %s people within %d km",
                nrow(sites), format(min(sites$pop_near), big.mark = ","),
                format(max(sites$pop_near), big.mark = ","), reach_m / 1000))
