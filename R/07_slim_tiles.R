#######################################################################################
# Purpose : Re-tile the coastline archive down to just what the app draws. The shipped
#           PMTiles is 389 MB and every tile carries three unused hotspot layers plus
#           all 25 shoreline years - measured at 430-540 KB per tile at every zoom.
#           DuckDB filters, tippecanoe re-tiles with zoom-aware simplification.
#   Inputs
#   ──────────────────────────────────────────────────────────────────────
#   [CST] data/dep_ls_coastlines_0-7-0-55.gpkg
#         shorelines_annual -> certainty 'good', all years (the year slider needs them)
#         rates_of_change   -> certainty 'good', sig_time < 0.01 (the trend dots)
#   Outputs
#   ──────────────────────────────────────────────────────────────────────
#   data/dep_coastlines_slim.pmtiles   same two layer names, a fraction of the bytes
#
#   Needs tippecanoe + tile-join on PATH:  brew install tippecanoe
#   Optional - app/serve.R uses this archive when it exists, the 389 MB one otherwise.
# LLM Disclaimer: Generated with the assistance of Claude Code (VSCode extension claude-opus-5)
#######################################################################################

library(DBI)
library(duckdb)

source("R/config.R")

out <- "data/dep_coastlines_slim.pmtiles"
tmp <- tempdir()
src <- "'EPSG:3832', 'EPSG:4326', always_xy := true"

for (bin in c("tippecanoe", "tile-join"))
  if (!nzchar(Sys.which(bin))) stop("`", bin, "` not on PATH - brew install tippecanoe")

run <- function(cmd, args) {
  status <- system2(cmd, args)
  if (status != 0) stop(cmd, " failed (exit ", status, ")")
}
mb <- function(f) file.size(f) / 1e6

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
dbExecute(con, "INSTALL spatial; LOAD spatial;")

export <- function(sql, file) {
  dbExecute(con, sprintf("COPY (%s) TO '%s' (FORMAT GDAL, DRIVER 'GeoJSONSeq')", sql, file))
  message(sprintf("  %-14s %6.1f MB", basename(file), mb(file)))
}

shore_js <- file.path(tmp, "shorelines.geojsonseq")
trend_js <- file.path(tmp, "transects.geojsonseq")

message("1/3  filtering with DuckDB")
# Split the multilinestrings and drop the 155 parts (of 603,562) that straddle 180
# degrees. In EPSG:4326 their vertices jump from +179.9 to -179.9, and tippecanoe
# draws that as a line right across the map - the stripe the first build produced.
export(sprintf(
  "SELECT year, geom FROM (
     SELECT CAST(year AS INTEGER) AS year,
            UNNEST(ST_Dump(ST_Transform(geom, %s))).geom AS geom
     FROM st_read('%s', layer = 'shorelines_annual')
     WHERE certainty = 'good'
   ) WHERE ST_XMax(geom) - ST_XMin(geom) <= 180", src, gpkg), shore_js)

export(sprintf(
  "SELECT round(rate_time, 2) AS rate_time, ST_Transform(geom, %s) AS geom
   FROM st_read('%s', layer = 'rates_of_change')
   WHERE certainty = 'good' AND sig_time < %f AND rate_time IS NOT NULL",
  src, gpkg, p_sig), trend_js)

message("2/3  tiling")
shore_pm <- file.path(tmp, "shore.pmtiles")
trend_pm <- file.path(tmp, "trend.pmtiles")

# Below z8 keep only the two years the overview actually draws. Carrying all 25
# put 127,775 features in a single z2 tile - the whole reason the first build
# crawled. The slider gets every year from z8 up, where it is legible anyway.
overview_years <- c(2000, 2021)
filt <- sprintf('{"shorelines_annual": ["any", [">=", "$zoom", 8], ["in", "year", %s]]}',
                paste(overview_years, collapse = ", "))

run("tippecanoe", c("-o", shore_pm, "--force", "-l", "shorelines_annual",
                    "-Z0", "-z13", "--simplification=4",
                    "-j", shQuote(filt),
                    "--drop-densest-as-needed",
                    "--maximum-tile-bytes=250000", "--quiet", shore_js))

# Points: nothing below z6, where half a million dots is an unreadable smear anyway
run("tippecanoe", c("-o", trend_pm, "--force", "-l", "rates_of_change",
                    "-Z6", "-z13", "--drop-densest-as-needed",
                    "--maximum-tile-bytes=250000", "--quiet", trend_js))

message("3/3  joining")
run("tile-join", c("-o", out, "--force", "--quiet", shore_pm, trend_pm))

message(sprintf(
  "\n%s\n  %.0f MB   (was %.0f MB, %.0f%% smaller)\n  layers: shorelines_annual, rates_of_change\n  restart app/serve.R to pick it up\n",
  out, mb(out), mb("data/dep_ls_coastlines_0-7-0-55.pmtiles"),
  100 * (1 - mb(out) / mb("data/dep_ls_coastlines_0-7-0-55.pmtiles"))))

writeLines(as.character(min(overview_years)), "app/data/overview_years.txt")
message(sprintf("  years below z8: %s   all 25 years from z8 up\n",
                paste(overview_years, collapse = ", ")))
