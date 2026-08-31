#######################################################################################
# Purpose : Build the population layer as raster tiles rather than points. The vector
#           build (11_) turned every 1 km cell into a circle, which reads as a scatter
#           however it is styled. This keeps the grid a grid: WorldPop summed to 1 km,
#           coloured on a fixed ramp, tiled, and packed into a PMTiles archive.
#   Inputs
#   ──────────────────────────────────────────────────────────────────────
#   [POP] data/worldpop/<iso3>_pop_2020_CN_100m_R2024B_v1.tif   WorldPop R2024B 2020
#   Outputs
#   ──────────────────────────────────────────────────────────────────────
#   data/pac_population_raster.pmtiles   RGBA raster tiles, z3-12, 1 km grid
#   app/data/population_ramp.json        the breaks, so the page can draw a legend
#
#   Needs GDAL and the pmtiles CLI:  brew install gdal pmtiles
# LLM Disclaimer: Generated with the assistance of Claude Code (VSCode extension claude-opus-5)
#######################################################################################

library(terra)
library(purrr)
library(jsonlite)

pop_dir <- "data/worldpop"
out     <- "data/pac_population_raster.pmtiles"
tmp     <- "data/.build"   # persistent, so a failed step can be inspected
zmin    <- 3
zmax    <- 12

dir.create(tmp, recursive = TRUE, showWarnings = FALSE)

for (bin in c("gdalbuildvrt", "gdal_translate", "gdaldem", "gdalwarp", "pmtiles"))
  if (!nzchar(Sys.which(bin))) stop("`", bin, "` not on PATH")

run <- function(cmd, args) {
  res <- system2(cmd, args, stdout = TRUE, stderr = TRUE)
  st <- attr(res, "status")
  if (!is.null(st) && st != 0)
    stop(cmd, " failed (exit ", st, ")\n", paste(utils::tail(res, 12), collapse = "\n"))
  invisible(res)
}

tifs <- list.files(pop_dir, pattern = "\\.tif$", full.names = TRUE)
stopifnot(length(tifs) > 0)

# -- 1 km grid, one file per territory ------------------------------------------------
message("1/5  summing 100 m cells to a 1 km grid")
km_dir <- file.path(tmp, "km1")
dir.create(km_dir, showWarnings = FALSE)

km_files <- map_chr(tifs, function(f) {
  dest <- file.path(km_dir, sub("\\.tif$", "_1km.tif", basename(f)))
  if (!file.exists(dest)) {
    r <- aggregate(rast(f), fact = 10, fun = "sum", na.rm = TRUE)
    r[is.na(r)] <- 0
    writeRaster(r, dest, overwrite = TRUE, datatype = "FLT4S",
                gdal = c("COMPRESS=DEFLATE", "TILED=YES"))
  }
  dest
})
message(sprintf("     %d territories gridded", length(km_files)))

# -- mosaic, then reproject to web mercator ------------------------------------------
message("2/5  mosaicking and reprojecting")
vrt <- file.path(tmp, "pop.vrt")
run("gdalbuildvrt", c("-overwrite", "-srcnodata", "0", "-vrtnodata", "0", vrt, km_files))

merc <- file.path(tmp, "pop_3857.tif")
run("gdalwarp", c("-t_srs", "EPSG:3857", "-r", "near", "-dstnodata", "0",
                  "-co", "COMPRESS=DEFLATE", "-co", "TILED=YES",
                  "-overwrite", vrt, merc))

# -- a fixed ramp, so the legend on the page matches the pixels -----------------------
# people per square kilometre; the top class holds dense urban coast
breaks <- c(1, 5, 25, 100, 500, 2000, 10000)
ramp <- data.frame(
  value = c(0, breaks),
  r = c(0, 245, 240, 232, 214, 190, 158, 120),
  g = c(0, 232, 205, 165, 118,  74,  41,  20),
  b = c(0, 205, 150, 106,  71,  52,  40,  30),
  a = c(0, 105, 140, 175, 205, 228, 242, 255)
)
ramp_file <- file.path(tmp, "ramp.txt")
writeLines(c("nv 0 0 0 0",
             apply(ramp, 1, \(x) paste(x, collapse = " "))), ramp_file)

message("3/5  colouring")
rgba <- file.path(tmp, "pop_rgba.tif")
run("gdaldem", c("color-relief", merc, ramp_file, rgba, "-alpha",
                 "-co", "COMPRESS=DEFLATE", "-co", "TILED=YES"))

# -- tile ------------------------------------------------------------------------------
message("4/5  tiling")
mb <- file.path(tmp, "pop.mbtiles")
if (file.exists(mb)) unlink(mb)
# every -co has to arrive as one argument; a bare `MINZOOM=` and an unquoted name both
# get split by the shell and gdal_translate just prints its usage
run("gdal_translate", c("-of", "MBTILES",
                        "-co", "TILE_FORMAT=PNG",
                        "-co", paste0("MINZOOM=", zmin),
                        "-co", paste0("MAXZOOM=", zmax),
                        "-co", shQuote("NAME=Pacific population 1 km"),
                        "-co", "RESAMPLING=NEAREST",
                        rgba, mb))
run("gdaladdo", c("-r", "nearest", mb, as.character(2 ^ seq_len(zmax - zmin))))

message("5/5  packing")
if (file.exists(out)) unlink(out)
run("pmtiles", c("convert", mb, out))

# A 1 km grid cannot carry detail past its own resolution, so gdaladdo only builds
# coarser overviews and the archive tops out around z7. That is correct: the map
# overzooms it with nearest-neighbour, which is what makes the cells read as a grid.
write_json(list(
  breaks = breaks,
  colours = sprintf("rgba(%d,%d,%d,%.2f)", ramp$r[-1], ramp$g[-1], ramp$b[-1], ramp$a[-1] / 255),
  unit = "people per km²",
  minzoom = 0, maxzoom = 7
), "app/data/population_ramp.json", auto_unbox = TRUE)

message(sprintf("\n%s  %.0f MB  |  raster, z%d-%d, 1 km grid\n",
                out, file.size(out) / 1e6, zmin, zmax))
