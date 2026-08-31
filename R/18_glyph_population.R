#######################################################################################
# Purpose : Add "people within about 2 km" to the 200 glyph sites, so the cards on
#           p.04 can say who lives at each stretch of coast. Same reach and same
#           focal window 09_ and 13_ use, so the three agree with each other.
#   Inputs
#   ──────────────────────────────────────────────────────────────────────
#   [GLY] app/data/glyph_sites.json                 200 sites from 17_
#   [POP] data/worldpop/<iso3>_pop_2020_CN_100m_R2024B_v1.tif
#   Outputs
#   ──────────────────────────────────────────────────────────────────────
#   app/data/glyph_sites.json     the same table, with pop_near added
#   output/shoreline_glyphs.csv   the card copy, with pop_near added
# LLM Disclaimer: Generated with the assistance of Claude Code (VSCode extension claude-opus-5)
#######################################################################################

library(sf)
library(terra)
library(dplyr)
library(purrr)
library(readr)
library(jsonlite)

source("R/config.R")   # for write_app_json()

sf_use_s2(FALSE)

glyph_json <- "app/data/glyph_sites.json"
glyph_csv  <- "output/shoreline_glyphs.csv"
pop_dir    <- "data/worldpop"
pop_win    <- 5    # 1 km cells, 5x5 box - the same reach 09_ and 13_ use

sites <- fromJSON(glyph_json, simplifyDataFrame = TRUE)
message(sprintf("%d glyph sites", nrow(sites)))

# -- people within ~2 km of each site -------------------------------------------------
# The rasters are per country and large, so open each one once and extract every site
# in that country from it.
people_near <- function(code) {
  tif <- file.path(pop_dir, sprintf("%s_pop_2020_CN_100m_R2024B_v1.tif", tolower(code)))
  rows <- which(sites$territory == code)
  if (!file.exists(tif) || !length(rows))
    return(tibble(id = sites$id[rows], pop_near = NA_real_))
  sm <- focal(aggregate(rast(tif), fact = 10, fun = "sum", na.rm = TRUE),
              w = pop_win, fun = "sum", na.rm = TRUE)
  pts <- st_as_sf(sites[rows, c("id", "lon", "lat")],
                  coords = c("lon", "lat"), crs = 4326)
  tibble(id = sites$id[rows],
         pop_near = as.numeric(terra::extract(sm, vect(pts))[, 2]))
}

codes <- sort(unique(sites$territory))
pop <- map(codes, \(c) { message("  ", c); people_near(c) }) |> list_rbind()

sites <- sites |>
  left_join(pop, by = join_by(id)) |>
  mutate(pop_near = round(coalesce(pop_near, 0)))

write_app_json(sites, glyph_json)

if (file.exists(glyph_csv)) {
  read_csv(glyph_csv, show_col_types = FALSE) |>
    select(-any_of("pop_near")) |>
    left_join(select(sites, id, pop_near), by = join_by(id)) |>
    write_csv(glyph_csv)
}

message(sprintf("pop_near: median %s, max %s across %d sites",
                format(median(sites$pop_near), big.mark = ","),
                format(max(sites$pop_near), big.mark = ","), nrow(sites)))
