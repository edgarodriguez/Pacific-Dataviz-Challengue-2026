#######################################################################################
# Purpose : Attach a sub-national division to every country hotspot, so the site list
#           can be filtered by province or division rather than by ocean region.
#           Boundaries come from the OSM extracts already downloaded by 10_/13_.
#   Inputs
#   ──────────────────────────────────────────────────────────────────────
#   [OSM] data/osm/<country>-latest.osm.pbf   multipolygons, boundary=administrative
#   [HOT] output/country_hotspots.csv         up to 3 sites per territory, from 13_
#   Outputs
#   ──────────────────────────────────────────────────────────────────────
#   app/data/country_hotspots.json   the same sites, each carrying an `admin` name
# LLM Disclaimer: Generated with the assistance of Claude Code (VSCode extension claude-opus-5)
#######################################################################################

library(sf)
library(dplyr)
library(purrr)
library(readr)
library(jsonlite)

source("R/config.R")

sf_use_s2(FALSE)

osm_dir <- "data/osm"

sites <- read_csv("output/country_hotspots.csv", show_col_types = FALSE)

# level 4 is the province or division in every Pacific extract checked; 6 is the
# district beneath it, kept as a fallback for the countries that skip level 4
admin_for <- function(country) {
  pbf <- file.path(osm_dir, sprintf("%s-latest.osm.pbf", country))
  if (!file.exists(pbf)) return(NULL)
  g <- try(st_read(pbf, quiet = TRUE, query =
    "SELECT name, admin_level FROM multipolygons
     WHERE boundary = 'administrative' AND name IS NOT NULL
       AND admin_level IN ('4','6')"), silent = TRUE)
  if (inherits(g, "try-error") || nrow(g) == 0) return(NULL)
  st_make_valid(g)
}

admins <- set_names(unique(unname(geofabrik_of[sites$territory]))) |> map(admin_for)

name_at <- function(i) {
  ctry <- geofabrik_of[[sites$territory[i]]]
  g <- admins[[ctry]]
  if (is.null(g)) return(NA_character_)
  pt <- st_sfc(st_point(c(sites$lon[i], sites$lat[i])), crs = 4326)
  hit <- suppressMessages(st_intersects(g, pt, sparse = FALSE)[, 1])
  if (!any(hit)) return(NA_character_)
  # prefer the coarser division when a point falls inside both
  sub <- g[hit, ]
  sub$name[order(sub$admin_level)][1]
}

sites$admin <- map_chr(seq_len(nrow(sites)), name_at)

named <- sum(!is.na(sites$admin))
message(sprintf("%d of %d sites placed in a division", named, nrow(sites)))
print(sites |> filter(!is.na(admin)) |> select(territory, label, admin) |> head(12))

out <- sites |>
  mutate(admin = coalesce(admin, "Unassigned")) |>
  select(label, admin, place_km, lon, lat, rate_time, sig_time, confidence,
         shift_2013_2021_m, pop_near, territory)

write_app_json(split(select(out, -territory), out$territory), "app/data/country_hotspots.json")
write_csv(out, "output/country_hotspots.csv")

message(sprintf("\napp/data/country_hotspots.json  %.0f KB  |  %d divisions",
                file.size("app/data/country_hotspots.json") / 1024,
                n_distinct(out$admin)))
