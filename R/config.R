#######################################################################################
# Purpose : Shared constants, lookup tables, and small helpers sourced by the numbered
#           pipeline scripts - one definition each for the dataset version, the
#           significance threshold, and the territory/place lookups that used to be
#           hand-copied into every script that needed them.
#   Inputs
#   ──────────────────────────────────────────────────────────────────────
#   none
#   Outputs
#   ──────────────────────────────────────────────────────────────────────
#   values and functions only - sourced, not run standalone
# LLM Disclaimer: Generated with the assistance of Claude Code (VSCode extension claude-sonnet-5)
#######################################################################################

library(jsonlite)

dep_version <- "0-7-0-55"
gpkg        <- file.path("data", paste0("dep_ls_coastlines_", dep_version, ".gpkg"))

# DEA/DEP Coastlines convention for a significant trend
p_sig <- 0.01

# PacIOOS labels territories by name; DEP labels them by ISO3
iso3_of <- c(
  "American Samoa" = "ASM", "Cook Islands" = "COK",
  "Federated States of Micronesia" = "FSM", "Fiji" = "FJI",
  "French Polynesia" = "PYF", "Guam" = "GUM", "Kiribati" = "KIR",
  "Marshall Islands" = "MHL", "Nauru" = "NRU", "New Caledonia" = "NCL",
  "Niue" = "NIU", "Northern Mariana Islands" = "MNP", "Palau" = "PLW",
  "Papua New Guinea" = "PNG", "Pitcairn" = "PCN", "Samoa" = "WSM",
  "Solomon Islands" = "SLB", "Tokelau" = "TKL", "Tonga" = "TON",
  "Tuvalu" = "TUV", "Vanuatu" = "VUT", "Wallis and Futuna" = "WLF"
)

# Geofabrik names its extracts by country, not ISO3
geofabrik_of <- c(
  ASM = "american-oceania", GUM = "american-oceania", MNP = "american-oceania",
  COK = "cook-islands",     FJI = "fiji",             KIR = "kiribati",
  MHL = "marshall-islands", FSM = "micronesia",       NRU = "nauru",
  NCL = "new-caledonia",    NIU = "niue",             PLW = "palau",
  PNG = "papua-new-guinea", PCN = "pitcairn-islands", PYF = "polynesie-francaise",
  WSM = "samoa",            SLB = "solomon-islands",  TKL = "tokelau",
  TON = "tonga",            TUV = "tuvalu",           VUT = "vanuatu",
  WLF = "wallis-et-futuna"
)

# nearest-place scoring: prefer a recognisable settlement over raw distance
rank_of <- c(city = 1, town = 2, suburb = 3, village = 4,
             hamlet = 5, island = 6, islet = 7, locality = 8)

# flatten a coordinate matrix to [x1,y1,x2,y2,...] for the JS-side glyph/strip paths
flat <- function(m) as.vector(t(round(m, 4)))

# split a (multi)linestring into one coordinate matrix per part
parts_of <- function(g) {
  cc <- st_coordinates(st_cast(g, "LINESTRING", warn = FALSE))
  split(cc[, c("X", "Y")], cc[, "L1"]) |> map(\(v) matrix(v, ncol = 2))
}

# the app/data/*.json write options every payload but population_ramp.json shares
write_app_json <- function(x, path) write_json(x, path, auto_unbox = TRUE, digits = NA, na = "null")
