#######################################################################################
# Purpose : Exploratory analysis of Pacific coastal change (DEP Coastlines v0.7.0-55)
#           1. Coastal loss 2000 vs 2021 - lineal (km) and areal (km2), global + per country
#           2. Temporal analysis - shoreline length per year, global + per country
#   Inputs
#   -------------------------------------------------------------------------
#   [CST] data/dep_ls_coastlines_0-7-0-55.gpkg
#         shorelines_annual -> 22,444 annual shoreline geometries, 1999-2023, 22 EEZ territories
#         rates_of_change   -> 2,057,082 transects at 30 m spacing; rate_time (m/yr), sig_time (p)
#   Outputs
#   -------------------------------------------------------------------------
#   output/change_2000_2021.csv          area + lineal change, global row + one row per territory
#   output/shoreline_length_by_year.csv  mapped shoreline km per year, global + per territory
# LLM Disclaimer: Generated with the assistance of Claude Code (VSCode extension claude-opus-5)
#######################################################################################

library(sf)
library(dplyr)
library(tibble)
library(tidyr)
library(readr)

gpkg       <- "data/dep_ls_coastlines_0-7-0-55.gpkg"
year_from  <- 2000
year_to    <- 2021
span_yr    <- year_to - year_from
transect_m <- 30      # verified: median nearest-neighbour spacing of rates_of_change points
p_sig      <- 0.01    # DEA/DEP Coastlines convention for a significant trend
global_tag <- "PACIFIC (all)"
out_dir    <- "output"

dir.create(out_dir, showWarnings = FALSE)

with_global <- function(d, f) bind_rows(f(mutate(d, territory = global_tag)), f(d))

# --- 1. Lineal: mapped shoreline length per year -------------------------------------

shorelines <- st_read(gpkg, "shorelines_annual", quiet = TRUE)

shoreline_tbl <- shorelines |>
  st_drop_geometry() |>
  as_tibble() |>
  mutate(
    territory = coalesce(eez_territory, "unassigned"),
    year      = as.integer(year),
    length_km = as.numeric(st_length(shorelines)) / 1000
  )

rm(shorelines)
invisible(gc())

summarise_length <- function(d) {
  d |>
    summarise(
      n_features     = n(),
      length_km_good = sum(length_km[certainty == "good"]),
      length_km      = sum(length_km),
      .by = c(territory, year)
    )
}

length_by_year <- shoreline_tbl |>
  with_global(summarise_length) |>
  arrange(territory, year) |>
  mutate(
    delta_km_yoy = length_km - lag(length_km),
    index_2000   = 100 * length_km / length_km[year == year_from][1],
    .by = territory
  )

# --- 2. Areal: land area change over the 2000-2021 window ----------------------------
# Each transect represents 30 m of coastline. Area swept = trend (m/yr) x years x 30 m.

rates <- st_read(
  gpkg,
  query = "SELECT eez_territory, rate_time, sig_time, nsm, sce, valid_obs, certainty
           FROM rates_of_change",
  quiet = TRUE
)

transects <- rates |>
  as_tibble() |>
  filter(certainty == "good", !is.na(rate_time)) |>
  mutate(
    territory = coalesce(eez_territory, "unassigned"),
    shift_m   = rate_time * span_yr,
    area_m2   = shift_m * transect_m,
    trend     = case_when(
      sig_time >= p_sig ~ "stable",
      rate_time < 0     ~ "retreat",
      .default          = "advance"
    )
  )

rm(rates)
invisible(gc())

summarise_change <- function(d) {
  d |>
    summarise(
      n_transects        = n(),
      coast_km_assessed  = n() * transect_m / 1000,
      coast_km_retreat   = sum(trend == "retreat") * transect_m / 1000,
      coast_km_advance   = sum(trend == "advance") * transect_m / 1000,
      coast_km_stable    = sum(trend == "stable") * transect_m / 1000,
      pct_coast_retreat  = 100 * sum(trend == "retreat") / n(),
      area_lost_km2      = -sum(pmin(area_m2, 0)) / 1e6,
      area_gained_km2    = sum(pmax(area_m2, 0)) / 1e6,
      area_net_km2       = sum(area_m2) / 1e6,
      area_lost_sig_km2  = -sum(area_m2[trend == "retreat"]) / 1e6,
      area_net_sig_km2   = sum(area_m2[trend != "stable"]) / 1e6,
      rate_median_m_yr   = median(rate_time),
      nsm_median_m       = median(nsm, na.rm = TRUE),
      .by = territory
    )
}

# mapped_km_* is how much coastline the satellite record resolves in that year, not land
# extent - Landsat coverage grows 51k -> 63k km over 1999-2023, so mapped_km_delta is an
# observation artefact. The real lineal loss figure is coast_km_retreat.
lineal_endpoints <- length_by_year |>
  filter(year %in% c(year_from, year_to)) |>
  select(territory, year, length_km) |>
  pivot_wider(names_from = year, values_from = length_km, names_prefix = "mapped_km_") |>
  mutate(mapped_km_delta = .data[[paste0("mapped_km_", year_to)]] -
                           .data[[paste0("mapped_km_", year_from)]])

change_2000_2021 <- transects |>
  with_global(summarise_change) |>
  left_join(lineal_endpoints, by = join_by(territory)) |>
  arrange(desc(territory == global_tag), desc(area_lost_km2))

# --- Write + report -------------------------------------------------------------------

write_csv(change_2000_2021, file.path(out_dir, "change_2000_2021.csv"))
write_csv(length_by_year,   file.path(out_dir, "shoreline_length_by_year.csv"))

cat("\n== Coastal change", year_from, "->", year_to, "(", span_yr, "yr ) ==\n")
change_2000_2021 |>
  select(territory, coast_km_assessed, coast_km_retreat, pct_coast_retreat,
         area_lost_km2, area_gained_km2, area_net_km2) |>
  print(n = Inf)

cat("\n== Mapped shoreline length per year, Pacific-wide ==\n")
length_by_year |>
  filter(territory == global_tag) |>
  select(year, length_km, length_km_good, delta_km_yoy, index_2000) |>
  print(n = Inf)

# --- Self-check -----------------------------------------------------------------------
# Transect count x 30 m must reconcile with independently measured shoreline length,
# and the area components must decompose the net figure.

check <- filter(change_2000_2021, territory == global_tag)
mapped_km_to <- pull(check, paste0("mapped_km_", year_to))

stopifnot(
  abs(check$area_net_km2 - (check$area_gained_km2 - check$area_lost_km2)) < 1e-6,
  check$coast_km_assessed < mapped_km_to,
  check$coast_km_assessed > 0.5 * mapped_km_to,
  all.equal(
    check$coast_km_retreat + check$coast_km_advance + check$coast_km_stable,
    check$coast_km_assessed
  ),
  nrow(length_by_year) > 0,
  !anyNA(length_by_year$length_km_good),
  all(length_by_year$length_km_good <= length_by_year$length_km)
)
cat("\nself-check OK\n")
