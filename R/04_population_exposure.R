#######################################################################################
# Purpose : Population exposed to coastal change - joins WorldPop 100 m to the DEP
#           shoreline record on a 1 km grid, per EEZ territory
#   Inputs
#   -------------------------------------------------------------------------
#   [POP] data/worldpop/<iso3>_pop_2020_CN_100m_R2024B_v1.tif   WorldPop R2024B constrained 2020
#         one per EEZ territory - this set is also the territory list
#   [CST] data/dep_ls_coastlines_0-7-0-55.gpkg
#         shorelines_annual -> 2021 shoreline, certainty == "good"
#         rates_of_change   -> transects, certainty == "good", sig_time < 0.01,
#                              rate_time < 0 (retreating) and rate_time <= -5 (fast)
#   Outputs
#   -------------------------------------------------------------------------
#   output/population_exposure.csv   one row per territory
# LLM Disclaimer: Generated with the assistance of Claude Code (VSCode extension claude-opus-5)
#######################################################################################

library(sf)
library(terra)
library(dplyr)
library(purrr)
library(readr)

source("R/config.R")

pop_dir  <- "data/worldpop"
fast_cut <- -5    # m/yr - the "retreating fast" band, a subset of the retreating one

sum_pop <- function(pop, geom) {
  if (nrow(geom) == 0) return(0)
  mask <- rasterize(vect(geom), pop, touches = TRUE)
  total <- as.numeric(global(mask * pop, "sum", na.rm = TRUE))
  if (is.na(total)) 0 else total
}

exposure_for <- function(code) {
  tif <- file.path(pop_dir, sprintf("%s_pop_2020_CN_100m_R2024B_v1.tif", tolower(code)))
  pop <- aggregate(rast(tif), fact = 10, fun = "sum", na.rm = TRUE)

  shore <- st_read(
    gpkg, quiet = TRUE,
    query = sprintf("SELECT geom FROM shorelines_annual
                     WHERE year = 2021 AND certainty = 'good' AND eez_territory = '%s'", code)
  ) |> st_transform(4326)

  retreat_at <- function(cut) st_read(
    gpkg, quiet = TRUE,
    query = sprintf("SELECT geom FROM rates_of_change
                     WHERE certainty = 'good' AND rate_time < %s AND sig_time < %s
                       AND eez_territory = '%s'", cut, p_sig, code)
  ) |> st_transform(4326)

  retreat <- retreat_at(0)
  fast    <- retreat_at(fast_cut)

  message(code, " - ", nrow(shore), " shoreline features, ", nrow(retreat),
          " retreating transects, ", nrow(fast), " of them faster than ",
          abs(fast_cut), " m/yr")

  tibble(
    territory       = code,
    pop_total       = as.numeric(global(pop, "sum", na.rm = TRUE)),
    pop_coastal_1km = sum_pop(pop, shore),
    pop_retreat_1km = sum_pop(pop, retreat),
    pop_fast_1km    = sum_pop(pop, fast)
  )
}

# The territory list is the set of rasters on disk - one per EEZ territory. It used to
# come from change_2000_2021.csv, which no longer exists.
iso3 <- list.files(pop_dir, pattern = "_pop_2020_CN_100m_R2024B_v1\\.tif$") |>
  substr(1, 3) |>
  toupper() |>
  sort()

exposure <- map(iso3, exposure_for) |>
  list_rbind() |>
  mutate(
    pct_coastal = 100 * pop_coastal_1km / pop_total,
    pct_retreat = 100 * pop_retreat_1km / pop_total,
    pct_fast    = 100 * pop_fast_1km / pop_total,
    across(starts_with("pop_"), \(x) round(x)),
    across(starts_with("pct_"), \(x) round(x, 1))
  ) |>
  arrange(desc(pop_retreat_1km))

write_csv(exposure, "output/population_exposure.csv")
print(exposure, n = Inf)
message(sprintf(
  "Pacific: %s people, %s in a coastal cell (%.0f%%), %s on retreating coast (%.0f%%), %s on coast retreating faster than %s m/yr (%.1f%%)",
  format(sum(exposure$pop_total), big.mark = ","),
  format(sum(exposure$pop_coastal_1km), big.mark = ","),
  100 * sum(exposure$pop_coastal_1km) / sum(exposure$pop_total),
  format(sum(exposure$pop_retreat_1km), big.mark = ","),
  100 * sum(exposure$pop_retreat_1km) / sum(exposure$pop_total),
  format(sum(exposure$pop_fast_1km), big.mark = ","),
  abs(fast_cut),
  100 * sum(exposure$pop_fast_1km) / sum(exposure$pop_total)
))
