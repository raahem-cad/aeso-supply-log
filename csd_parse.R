# ==============================================================================
# Parse one AESO "CSD Generation (Hourly)" file into hourly totals by sub-fuel.
# ==============================================================================
# This is the whole of the ingest side. It is deliberately the only R in this
# repo that carries logic: build_hourly.R just loops over files and writes CSVs.
#
# Kept here rather than in the analysis project because the CI job needs it and
# this repo is public, while the analysis code is not. Having exactly one copy
# is the point: the MST-to-UTC handling below is the subtle part of the whole
# pipeline, and a second implementation is how it goes stale unnoticed.
#
# Run test_csd_parse.R after touching anything in here.
# ==============================================================================

library(readr)
library(dplyr)
library(lubridate)

# AESO's "Date (MST)" column is a fixed UTC-7 offset that never observes DST, so
# it is gapless and unambiguous. The companion "Date (MPT)" column is NOT: on the
# November fall-back day its two 01:00 hours have identical digits and would
# collide under any distinct()/join keyed on local time, and on the March
# spring-forward day 02:00 does not exist at all. So MST is the column we read
# and UTC is what we store; local time is derived for display only.
TZ_MST <- "Etc/GMT+7"   # POSIX sign convention: "GMT+7" means UTC-7
TZ_MPT <- "America/Edmonton"

# The published files and the live CSD API describe the same sub-types with
# different strings, so one side has to be normalised or the two cannot be
# compared. Measured across 2015, 2024 and 2026 files:
#
#   files     COGENERATION  COMBINED_CYCLE  GAS_FIRED_STEAM  SIMPLE_CYCLE
#   live API  COGENERATION  COMBINED CYCLE  GAS FIRED STEAM  SIMPLE CYCLE
#
# so underscores-to-spaces reconciles the gas four exactly. The files also split
# OTHER six ways (Biomass, Gas, Gas cogen, Oil/Gas, Wood/Refuse, Composite) in
# mixed case, where the API reports one undifferentiated OTHER. Upper-casing
# keeps those consistent with everything else; the asymmetry itself is real and
# stays, because it is what AESO publishes.
normalize_sub_fuel <- function(x) gsub("_", " ", toupper(x), fixed = TRUE)

# Reads one "CSD Generation (Hourly) - YYYY-MM" file (.csv or .zip) and collapses
# ~230 assets down to one row per (hour, fuel type, sub fuel type).
#
# Validated against `Gen Table_Full Data_data.csv` (AESO's Tableau export, an
# independent derivation of the same data): over 914 month-fuel cells the system
# total and every individual fuel reconcile to 0.0000%, EXCEPT the GAS/OTHER
# split, where the two products bucket some gas-fired assets differently
# (GAS+OTHER combined reconciles to 0.0000%). The file's own `Fuel Type` column
# is authoritative here; expect that one discrepancy if you compare these
# numbers to the Tableau export.
#
# Only 5 of the 12 columns are read: the asset name/grouping/region columns are
# what make these files 20 MB, and nothing downstream uses them.
read_csd_month <- function(path) {
  raw <- readr::read_csv(
    path,
    col_select = c(`Date (MST)`, `Fuel Type`, `Sub Fuel Type`, Volume,
                   `Maximum Capability`),
    col_types  = readr::cols_only(
      `Date (MST)`         = readr::col_datetime("%Y-%m-%d %H:%M:%S"),
      `Fuel Type`          = readr::col_character(),
      `Sub Fuel Type`      = readr::col_character(),
      Volume               = readr::col_double(),
      `Maximum Capability` = readr::col_double()
    ),
    progress = FALSE
  )

  raw |>
    mutate(
      # read_csv labels the parsed stamp UTC while preserving the wall-clock
      # digits; force_tz relabels those digits as MST, with_tz then converts.
      begin_datetime_utc = with_tz(force_tz(`Date (MST)`, TZ_MST), "UTC"),
      fuel_type          = `Fuel Type`,
      sub_fuel_type      = normalize_sub_fuel(`Sub Fuel Type`)
    ) |>
    summarise(
      # na.rm: an individual asset occasionally has no metered value for an hour.
      # Dropping it is right (it contributes no generation); letting one NA turn
      # the whole fuel type's hourly total into NA is not.
      net_generation_mw = sum(Volume, na.rm = TRUE),
      max_capability_mw = sum(`Maximum Capability`, na.rm = TRUE),
      .by = c(begin_datetime_utc, fuel_type, sub_fuel_type)
    ) |>
    arrange(begin_datetime_utc, fuel_type, sub_fuel_type)
}
