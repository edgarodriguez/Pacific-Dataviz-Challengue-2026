#######################################################################################
# Purpose : Run the coastal-change visualisation on localhost. Two servers, one
#           command - `pmtiles serve` hands out z/x/y vector tiles from the archive,
#           httpuv serves the app. No geometry is bundled into the page.
#   Inputs
#   ──────────────────────────────────────────────────────────────────────
#   [TIL] data/dep_ls_coastlines_0-7-0-55.pmtiles   5 vector layers, z0-13
#   [APP] app/index.html, app.js, app.css, vendor/, data/stats.json
#   Outputs
#   ──────────────────────────────────────────────────────────────────────
#   http://127.0.0.1:8000   the app
#   http://127.0.0.1:8081   tiles  (/<archive>/{z}/{x}/{y}.mvt)
#   app/data/tiles.json     the tile endpoint, so the port is not hard-coded in the JS
#
#   Usage : Rscript app/serve.R [app_port] [tile_port]
# LLM Disclaimer: Generated with the assistance of Claude Code (VSCode extension claude-opus-5)
#######################################################################################

library(httpuv)
library(jsonlite)

args      <- commandArgs(trailingOnly = TRUE)
app_port  <- as.integer(if (length(args) >= 1) args[1] else 8000)
tile_port <- as.integer(if (length(args) >= 2) args[2] else 8081)

# prefer the slim archive from 07_slim_tiles.R when it is there - same layer names,
# a fraction of the bytes per tile - and fall back to the full DEP one otherwise
archive_name <- if (file.exists("data/dep_coastlines_slim.pmtiles"))
  "dep_coastlines_slim" else "dep_ls_coastlines_0-7-0-55"
archive      <- file.path("data", paste0(archive_name, ".pmtiles"))
stats        <- "app/data/stats.json"

if (!dir.exists("app"))    stop("run from the project root:  Rscript app/serve.R")
if (!file.exists(archive)) stop("missing ", archive)
if (!file.exists(stats))   stop("missing ", stats, " - run:  Rscript R/06_app_data.R")
if (!nzchar(Sys.which("pmtiles")))
  stop("`pmtiles` is not on PATH. Install it with:  brew install pmtiles\n",
       "       or:  go install github.com/protomaps/go-pmtiles@latest")

in_use <- function(p) !inherits(try(suppressWarnings(
  close(socketConnection("127.0.0.1", p, open = "r+", timeout = 1))), silent = TRUE), "try-error")

for (p in c(app_port, tile_port))
  if (in_use(p)) stop("port ", p, " is busy - try:  Rscript app/serve.R ",
                      app_port + 10, " ", tile_port + 10)

# -- tiles: Go, concurrent, 256 MB in-memory tile cache ------------------------------
# shQuote the "*" - system2 hands the arguments to a shell, which would otherwise
# glob-expand it against the working directory and hand pmtiles a list of filenames
tile_log <- file.path(tempdir(), "pmtiles.log")
system2("pmtiles",
        c("serve", "data", "--port", tile_port, "--cors", shQuote("*"),
          "--cache-size", "256"),
        stdout = tile_log, stderr = tile_log, wait = FALSE)

on.exit(suppressWarnings(system2("pkill",
  c("-f", sprintf("pmtiles serve data --port %d", tile_port)),
  stdout = FALSE, stderr = FALSE)), add = TRUE)

for (i in 1:40) { Sys.sleep(0.25); if (in_use(tile_port)) break }
if (!in_use(tile_port))
  stop("the tile server did not come up on port ", tile_port, ".\n",
       paste(readLines(tile_log, warn = FALSE), collapse = "\n"))

# the slim archive is already filtered to certainty 'good' and p < 0.01, so it does
# not carry those columns - the page must not filter on what is not there
archive_exists <- \(name) file.exists(file.path("data", paste0(name, ".pmtiles")))
pop_archive  <- "pac_population_1km"
popr_archive <- "pac_population_raster"
has_pop  <- archive_exists(pop_archive)
has_popr <- archive_exists(popr_archive)

write_json(list(
  tiles       = sprintf("http://127.0.0.1:%d/%s/{z}/{x}/{y}.mvt", tile_port, archive_name),
  maxzoom     = 13,
  archive     = archive_name,
  prefiltered = archive_name == "dep_coastlines_slim",
  population  = if (has_pop)
    sprintf("http://127.0.0.1:%d/%s/{z}/{x}/{y}.mvt", tile_port, pop_archive) else NULL,
  populationRaster = if (has_popr)
    sprintf("http://127.0.0.1:%d/%s/{z}/{x}/{y}.png", tile_port, popr_archive) else NULL,
  populationRasterMaxzoom = 7
), "app/data/tiles.json", auto_unbox = TRUE, null = "null")

# no-cache, or an edited stylesheet keeps being served from the browser's cache
server <- startServer("127.0.0.1", app_port, list(
  staticPaths = list("/" = "app"),
  staticPathOptions = staticPathOptions(headers = list("Cache-Control" = "no-store"))
))
on.exit(stopServer(server), add = TRUE)

meta <- fromJSON(stats)$meta
cat(sprintf("
  Field Notes on a Moving Coast - Pacific, 2000-2021
  ------------------------------------------------------------------
  app      http://127.0.0.1:%d
  tiles    http://127.0.0.1:%d/%s/{z}/{x}/{y}.mvt
  payload  %s   %.0f KB, built %s
  archive  %s   %.0f MB

  Ctrl-C stops both servers.

", app_port, tile_port, archive_name,
   stats, file.size(stats) / 1024, meta$built,
   archive, file.size(archive) / 1e6))

while (TRUE) later::run_now(0.25)
