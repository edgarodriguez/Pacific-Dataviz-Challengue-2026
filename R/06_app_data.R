#######################################################################################
# Purpose : Build the local app payload with DuckDB - aggregates 2.06 M transects
#           straight out of the GeoPackage in SQL, no sf, no geometry in the output.
#           Map geometry is served separately from the PMTiles archive.
#   Inputs
#   ──────────────────────────────────────────────────────────────────────
#   [CST] data/dep_ls_coastlines_0-7-0-55.gpkg   rates_of_change (2,057,082 transects)
#                                                shorelines_annual (22,444 features)
#   [POP] output/population_exposure.csv         WorldPop 2020 exposure, from 04_
#   [HOT] output/hotspots_population_named.csv  the 5 most-populated retreating
#                                               coasts, from 09_ and 10_
#   Outputs
#   ──────────────────────────────────────────────────────────────────────
#   app/data/territories.parquet   one row per territory, change + population + bbox
#   app/data/transects.parquet     per-transect trend + territory, for ad-hoc SQL
#   app/data/stats.json            the app payload (~30 KB, no coordinates)
# LLM Disclaimer: Generated with the assistance of Claude Code (VSCode extension claude-opus-5)
#######################################################################################

library(DBI)
library(duckdb)
library(dplyr)
library(readr)
library(purrr)
library(rlang)
library(jsonlite)

source("R/config.R")

out_dir    <- "app/data"
transect_m <- 30   # alongshore length each transect represents (median NN = 30.34 m)

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
dbExecute(con, "INSTALL spatial; LOAD spatial;")

# -- one pass over the GeoPackage: classify every good transect, project its trend to area
dbExecute(con, sprintf("
  CREATE TABLE transects AS
  SELECT
    coalesce(eez_territory, 'unassigned')     AS territory,
    rate_time,
    sig_time,
    coalesce(valid_span, 25) - 1              AS years_spanned,
    -- rate_time is fitted across every year the transect has, 1999 to 2023, so the
    -- distance it implies is the rate times that transect's own elapsed years. A fixed
    -- 21 was understating the whole region by about a ninth.
    rate_time * (coalesce(valid_span, 25) - 1) * %d / 1e6   AS area_km2,
    CASE WHEN sig_time >= %f    THEN 'stable'
         WHEN rate_time <  0    THEN 'retreat'
         ELSE                        'advance' END AS trend
  FROM st_read('%s', layer = 'rates_of_change')
  WHERE certainty = 'good' AND rate_time IS NOT NULL",
  transect_m, p_sig, gpkg))

# -- map extent per territory, on a 0-360 longitude axis so the region does not
#    split at the antimeridian (Fiji, Tuvalu and Kiribati all straddle it)
dbExecute(con, sprintf("
  CREATE TABLE extents AS
  WITH pts AS (
    SELECT eez_territory AS territory,
           CASE WHEN ST_X(g) < 0 THEN ST_X(g) + 360 ELSE ST_X(g) END AS lon,
           ST_Y(g) AS lat
    FROM (
      SELECT eez_territory,
             UNNEST(ST_Dump(ST_Points(
               ST_Transform(geom, 'EPSG:3832', 'EPSG:4326', always_xy := true)
             ))).geom AS g
      FROM st_read('%s', layer = 'shorelines_annual')
      WHERE year = 2021 AND certainty = 'good'
    )
  )
  SELECT territory,
         min(lon) AS w, min(lat) AS s, max(lon) AS e, max(lat) AS n
  FROM pts GROUP BY territory", gpkg))

agg <- "
  SELECT
    %s                                                                AS territory,
    count(*)                                                          AS n_transects,
    count(*) * 30 / 1000.0                                            AS coast_km_assessed,
    count(*) FILTER (trend = 'retreat') * 30 / 1000.0                 AS coast_km_retreat,
    count(*) FILTER (trend = 'advance') * 30 / 1000.0                 AS coast_km_advance,
    count(*) FILTER (trend = 'stable')  * 30 / 1000.0                 AS coast_km_stable,
    100.0 * count(*) FILTER (trend = 'retreat') / count(*)            AS pct_coast_retreat,
    -sum(area_km2) FILTER (area_km2 < 0)                              AS area_lost_km2,
     sum(area_km2) FILTER (area_km2 > 0)                              AS area_gained_km2,
     sum(area_km2)                                                    AS area_net_km2,
    -sum(area_km2) FILTER (trend = 'retreat')                         AS area_lost_sig_km2,
     sum(area_km2) FILTER (trend <> 'stable')                         AS area_net_sig_km2,
    median(rate_time)                                                 AS rate_median_m_yr,
    median(years_spanned)                                             AS years_spanned_median
  FROM transects %s"

span <- dbGetQuery(con, "SELECT median(years_spanned) med, min(years_spanned) lo,
                          max(years_spanned) hi FROM transects")

# -- distribution of the trends themselves, for the histogram on p.01 --------------
# Only a good, clearly significant transect gets to keep its rate; everything else is
# one grey column in the middle, because "we could not tell" is its own answer.
dbExecute(con, sprintf("
  CREATE TABLE rates AS
  SELECT CASE WHEN certainty = 'good' AND sig_time <= %f THEN rate_time ELSE 0 END AS r,
         (certainty = 'good' AND sig_time <= %f)                                  AS told
  FROM st_read('%s', layer = 'rates_of_change')
  WHERE rate_time IS NOT NULL", p_sig, p_sig, gpkg))

cap  <- 5      # m/yr: beyond this the bars become open-ended tails
nbin <- 5      # equal-count bins between the cap and zero, each side

edges_for <- function(lo, hi) {
  qs <- seq(0, 1, length.out = nbin + 1)[-c(1, nbin + 1)]
  q <- dbGetQuery(con, sprintf(
    "SELECT %s FROM rates WHERE told AND r >= %f AND r < %f",
    paste(sprintf("quantile_cont(r, %f) q%d", qs, seq_along(qs)), collapse = ", "),
    lo, hi))
  c(lo, unlist(q, use.names = FALSE), hi)
}

count_between <- function(lo, hi, open_lo = FALSE, open_hi = FALSE) {
  where <- if (open_lo) sprintf("r < %f", hi)
           else if (open_hi) sprintf("r >= %f", lo)
           else sprintf("r >= %f AND r < %f", lo, hi)
  dbGetQuery(con, sprintf("SELECT count(*) n FROM rates WHERE told AND %s", where))$n
}

bins_side <- function(edges, side) {
  map(seq_len(length(edges) - 1), \(i) list(
    lo = edges[i], hi = edges[i + 1], side = side,
    n = count_between(edges[i], edges[i + 1])))
}

retreat <- bins_side(edges_for(-cap, 0), "retreat")
advance <- bins_side(edges_for(0, cap), "advance")

# the tails need their real extent, not an infinity - the bars are drawn as a density
# and an open-ended bar has no height
ends <- dbGetQuery(con, "SELECT min(r) lo, max(r) hi FROM rates WHERE told")

# centre of the told points, for the two reference lines drawn on the histogram
centre <- dbGetQuery(con, "
  SELECT count(*) n, avg(r) mean, quantile_cont(r, 0.5) med FROM rates WHERE told")

# The equal-count bins above answer "where do the points sit"; they cannot answer
# "what shape is this". Fixed-width bins over the same points can, so the page draws
# both, one under the other.
even_step <- 0.5
even <- dbGetQuery(con, sprintf("
  SELECT floor(r / %f) * %f AS lo, count(*) AS n
  FROM rates WHERE told AND r >= -%f AND r < %f
  GROUP BY 1 ORDER BY 1", even_step, even_step, cap, cap))
even_tails <- dbGetQuery(con, sprintf("
  SELECT count(*) FILTER (r < -%f) AS lo_n, count(*) FILTER (r >= %f) AS hi_n
  FROM rates WHERE told", cap, cap))
rate_hist_even <- list(
  step = even_step, cap = cap,
  lo_n = even_tails$lo_n, hi_n = even_tails$hi_n,
  bins = map(seq_len(nrow(even)), \(i) list(lo = even$lo[i], n = even$n[i]))
)

# the same bins again, per territory, so the drawer can show one country against the
# region on an axis that does not move. Counts only - the edges are step and cap.
nb <- as.integer(2 * cap / even_step)
by_bin <- dbGetQuery(con, sprintf("
  SELECT territory,
         least(greatest(cast(floor((rate_time + %f) / %f) as int), 0), %d) AS b,
         count(*) AS n
  FROM transects
  WHERE sig_time <= %f AND rate_time >= -%f AND rate_time < %f
  GROUP BY 1, 2", cap, even_step, nb - 1L, p_sig, cap, cap))
by_tail <- dbGetQuery(con, sprintf("
  SELECT territory,
         count(*) FILTER (rate_time < -%f) AS lo_n,
         count(*) FILTER (rate_time >= %f)  AS hi_n,
         count(*)                            AS told
  FROM transects WHERE sig_time <= %f GROUP BY 1", cap, cap, p_sig))

rate_hist <- c(
  list(list(lo = ends$lo, hi = -cap, side = "retreat", tail = TRUE,
            n = count_between(NA, -cap, open_lo = TRUE))),
  retreat,
  list(list(lo = 0, hi = 0, side = "unclear",
            n = dbGetQuery(con, "SELECT count(*) n FROM rates WHERE NOT told")$n)),
  advance,
  list(list(lo = cap, hi = ends$hi, side = "advance", tail = TRUE,
            n = count_between(cap, NA, open_hi = TRUE)))
)

# and again against the equal-count edges the regional histogram uses, so the drawer can
# show either shape for one country without the axis moving under it
count_parts <- vapply(seq_along(rate_hist), function(i) {
  b <- rate_hist[[i]]
  if (isTRUE(b$tail)) {
    if (b$side == "retreat") sprintf("count(*) FILTER (rate_time < %f) AS b%d", b$hi, i)
    else sprintf("count(*) FILTER (rate_time >= %f) AS b%d", b$lo, i)
  } else if (b$side == "unclear") sprintf("0 AS b%d", i)
  else sprintf("count(*) FILTER (rate_time >= %f AND rate_time < %f) AS b%d", b$lo, b$hi, i)
}, character(1))
by_count <- dbGetQuery(con, sprintf("
  SELECT territory, %s, count(*) AS told FROM transects WHERE sig_time <= %f GROUP BY 1",
  paste(count_parts, collapse = ", "), p_sig))
rate_hist_terr_count <- list(terr = set_names(
  map(setdiff(by_count$territory, "unassigned"), \(code) {
    r <- filter(by_count, territory == code)
    list(n = unname(as.integer(r[1, sprintf("b%d", seq_along(rate_hist))])), told = r$told)
  }),
  setdiff(by_count$territory, "unassigned")))

rate_hist_terr <- list(step = even_step, cap = cap, terr = set_names(
  map(setdiff(sort(unique(by_tail$territory)), "unassigned"), \(code) {
    v <- integer(nb)
    sub <- filter(by_bin, territory == code)
    if (nrow(sub)) v[sub$b + 1L] <- sub$n
    tl <- filter(by_tail, territory == code)
    list(n = v, lo_n = tl$lo_n, hi_n = tl$hi_n, told = tl$told)
  }),
  setdiff(sort(unique(by_tail$territory)), "unassigned")))

# Every rate point, quality check or not. n x 30 m is the closest the record comes to a
# total coastline length, so it is the honest denominator for "share of coast retreating" -
# the kept points alone only measure two thirds of the shore.
points_all <- dbGetQuery(con, sprintf("
  SELECT coalesce(eez_territory, 'unassigned') AS territory,
         count(*)                              AS n_points_all,
         count(*) * %d / 1000.0                AS coast_km_total
  FROM st_read('%s', layer = 'rates_of_change')
  GROUP BY 1", transect_m, gpkg))

by_territory <- dbGetQuery(con, sprintf(agg, "territory", "GROUP BY territory")) |>
  left_join(points_all, by = join_by(territory))
pacific      <- c(as.list(dbGetQuery(con, sprintf(agg, "'PACIFIC (all)'", ""))),
                  list(n_points_all   = sum(points_all$n_points_all),
                       coast_km_total = sum(points_all$coast_km_total)))

names_lookup <- c(
  ASM = "American Samoa", COK = "Cook Islands", FJI = "Fiji", FSM = "Micronesia",
  GUM = "Guam", KIR = "Kiribati", MHL = "Marshall Islands", MNP = "N. Mariana Is.",
  NCL = "New Caledonia", NIU = "Niue", NRU = "Nauru", PCN = "Pitcairn Is.",
  PLW = "Palau", PNG = "Papua New Guinea", PYF = "French Polynesia",
  SLB = "Solomon Islands", TKL = "Tokelau", TON = "Tonga", TUV = "Tuvalu",
  VUT = "Vanuatu", WLF = "Wallis & Futuna", WSM = "Samoa"
)

territories <- by_territory |>
  filter(territory != "unassigned") |>
  left_join(read_csv("output/population_exposure.csv", show_col_types = FALSE),
            by = join_by(territory)) |>
  left_join(dbReadTable(con, "extents"), by = join_by(territory)) |>
  mutate(name = unname(names_lookup[territory]),
         across(where(is.numeric), \(x) round(x, 4))) |>
  arrange(desc(area_lost_km2))

dbWriteTable(con, "territories", territories, overwrite = TRUE)
dbExecute(con, sprintf("COPY territories TO '%s/territories.parquet' (FORMAT parquet)", out_dir))
dbExecute(con, sprintf("COPY transects   TO '%s/transects.parquet'   (FORMAT parquet, COMPRESSION zstd)", out_dir))

# the sites people live on, from 09_/10_, not the fastest-moving ones from 02_
hotspots <- read_csv("output/hotspots_population_named.csv", show_col_types = FALSE) |>
  select(rank, uid, territory, lon, lat, rate_time, se_time, t_ratio, sig_time, n,
         pop_near, shift_2013_2021_m, place_name, place_type, place_km, label) |>
  mutate(across(where(is.numeric), \(x) round(x, 4)))

write_app_json(
  list(
    pacific     = pacific,
    territories = territories,
    hotspots    = hotspots,
    rate_hist   = rate_hist,
    rate_hist_even = rate_hist_even,
    rate_hist_terr = rate_hist_terr,
    rate_hist_terr_count = rate_hist_terr_count,
    rate_centre = list(n = centre$n,
                       mean = round(centre$mean, 4),
                       median = round(centre$med, 4)),
    meta = list(
      built       = format(Sys.time(), "%Y-%m-%d %H:%M"),
      span_years  = span$med,
      span_years_min = span$lo, span_years_max = span$hi,
      p_sig       = p_sig,
      transect_m  = transect_m,
      hist_cap_m_yr = cap,
      pmtiles     = paste0("dep_ls_coastlines_", dep_version),
      year_min    = 1999, year_max = 2023
    )
  ),
  file.path(out_dir, "stats.json")
)

message(sprintf("%s/stats.json  %.0f KB  |  %d territories, %d hotspots",
                out_dir, file.size(file.path(out_dir, "stats.json")) / 1024,
                nrow(territories), nrow(hotspots)))
message(sprintf("%s/territories.parquet  %.0f KB   %s/transects.parquet  %.1f MB",
                out_dir, file.size(file.path(out_dir, "territories.parquet")) / 1024,
                out_dir, file.size(file.path(out_dir, "transects.parquet")) / 1e6))
