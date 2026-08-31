#######################################################################################
# Purpose : Download WorldPop 100 m constrained population (2020, R2024B) for every
#           EEZ territory present in the shoreline change results
#   Inputs
#   -------------------------------------------------------------------------
#   [CHG] output/change_2000_2021.csv   one row per territory; `territory` holds ISO3 codes
#   Outputs
#   -------------------------------------------------------------------------
#   data/worldpop/<iso3>_pop_2020_CN_100m_R2024B_v1.tif   one raster per territory
# LLM Disclaimer: Generated with the assistance of Claude Code (VSCode extension claude-opus-5)
#######################################################################################

library(readr)
library(dplyr)
library(purrr)

options(timeout = 1800)   # KIR is ~125 MB; the 60 s default aborts mid-download

out_dir <- "data/worldpop"
skip    <- c("PACIFIC (all)", "unassigned")

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

iso3 <- read_csv("output/change_2000_2021.csv", show_col_types = FALSE) |>
  filter(!territory %in% skip) |>
  pull(territory)

download_worldpop <- function(code) {
  lower <- tolower(code)
  file  <- sprintf("%s_pop_2020_CN_100m_R2024B_v1.tif", lower)
  dest  <- file.path(out_dir, file)
  url   <- sprintf(
    "https://data.worldpop.org/GIS/Population/Global_2015_2030/R2024B/2020/%s/v1/100m/constrained/%s",
    code, file
  )

  if (file.exists(dest)) {
    message(code, " - already downloaded")
  } else {
    message(code, " - downloading")
    download.file(url, dest, mode = "wb", quiet = TRUE)
  }
  tibble(territory = code, path = dest, size_mb = round(file.size(dest) / 1e6, 1))
}

downloads <- map(iso3, download_worldpop) |> list_rbind()

print(downloads, n = Inf)
message(sprintf("%d rasters, %.1f MB total", nrow(downloads), sum(downloads$size_mb)))
