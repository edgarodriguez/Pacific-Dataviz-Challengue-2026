#######################################################################################
# Purpose : Turn the WorldPop rasters into a vector tile layer so the site maps can
#           show where people actually live under the retreating coastline.
#           100 m cells summed to a 1 km grid, populated cells only, one point each.
#   Inputs
#   ──────────────────────────────────────────────────────────────────────
#   [POP] data/worldpop/<iso3>_pop_2020_CN_100m_R2024B_v1.tif   WorldPop R2024B 2020
#   Outputs
#   ──────────────────────────────────────────────────────────────────────
#   data/pac_population_1km.pmtiles   layer `population`, attribute `pop`, z4-13
#
#   Needs tippecanoe on PATH:  brew install tippecanoe
# LLM Disclaimer: Generated with the assistance of Claude Code (VSCode extension claude-opus-5)
#######################################################################################

library(terra)
library(sf)
library(dplyr)
library(purrr)

pop_dir  <- "data/worldpop"
out      <- "data/pac_population_1km.pmtiles"
tmp      <- tempdir()
geo      <- file.path(tmp, "population.geojsonseq")
min_pop  <- 1        # a cell has to hold at least one person to be worth a tile

if (!nzchar(Sys.which("tippecanoe")))
  stop("`tippecanoe` not on PATH - brew install tippecanoe")

tifs <- list.files(pop_dir, pattern = "\\.tif$", full.names = TRUE)
stopifnot(length(tifs) > 0)

grid_points <- function(tif) {
  km  <- aggregate(rast(tif), fact = 10, fun = "sum", na.rm = TRUE)
  pts <- as.points(km, values = TRUE, na.rm = TRUE)
  if (nrow(pts) == 0) return(NULL)
  d <- st_as_sf(pts) |> setNames(c("pop", "geometry")) |> st_set_geometry("geometry")
  d <- d[d$pop >= min_pop, ]
  if (nrow(d) == 0) return(NULL)
  d$pop <- round(d$pop)
  message(sprintf("  %-6s %7s populated cells", toupper(substr(basename(tif), 1, 3)),
                  format(nrow(d), big.mark = ",")))
  d
}

message("gridding WorldPop to 1 km:")
cells <- map(tifs, grid_points) |> compact() |> bind_rows() |> st_as_sf()
message(sprintf("%s cells, %s people",
                format(nrow(cells), big.mark = ","),
                format(round(sum(cells$pop)), big.mark = ",")))

st_write(cells, geo, driver = "GeoJSONSeq", delete_dsn = TRUE, quiet = TRUE)
message(sprintf("  %.1f MB of GeoJSON", file.size(geo) / 1e6))

status <- system2("tippecanoe",
  c("-o", out, "--force", "-l", "population",
    "-Z4", "-z13",
    "--drop-densest-as-needed", "--extend-zooms-if-still-dropping",
    "--maximum-tile-bytes=250000", "--quiet", geo))
if (status != 0) stop("tippecanoe failed (exit ", status, ")")

message(sprintf("\n%s  %.0f MB  |  layer `population`, attribute `pop`, z4-13\n",
                out, file.size(out) / 1e6))
