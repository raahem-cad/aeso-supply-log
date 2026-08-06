# Checks for csd_parse.R. Run: Rscript test_csd_parse.R
# assert-based, no framework. Each stopifnot() is one claim about the parse.

suppressMessages(source("csd_parse.R"))

pass <- function(msg) cat("  ok  ", msg, "\n")

# as.Date.POSIXct defaults to tz="UTC" and ignores the object's tzone, which
# silently shifts every stamp before 07:00 MPT onto the previous day. Always
# name the zone.
mpt_date <- function(x) as.Date(x, tz = TZ_MPT)

# MST is a fixed offset, so a "seq of MST hours" is unambiguous to construct.
mst_seq <- function(from, to) {
  seq(as.POSIXct(from, tz = TZ_MST), as.POSIXct(to, tz = TZ_MST), by = "hour")
}

# Writes a synthetic CSD file with the 5 columns read_csd_month() consumes.
# `subs` defaults to the fuel name, which is what AESO does for every fuel
# except GAS and OTHER.
fake_csd <- function(mst_stamps, fuels = c("GAS", "WIND"), volume = 100,
                     subs = NULL) {
  path <- tempfile(fileext = ".csv")
  stamps <- format(mst_stamps, "%Y-%m-%d %H:%M:%S")
  g <- if (is.null(subs)) {
    d <- expand.grid(`Date (MST)` = stamps, `Fuel Type` = fuels,
                     stringsAsFactors = FALSE)
    d[["Sub Fuel Type"]] <- d[["Fuel Type"]]
    d
  } else {
    # Crossed, not recycled: every sub-type must appear in every hour, which is
    # what makes the roll-up assertion below mean anything.
    expand.grid(`Date (MST)` = stamps, `Fuel Type` = fuels,
                `Sub Fuel Type` = subs, stringsAsFactors = FALSE)
  }
  readr::write_csv(
    transform(g, Volume = volume, `Maximum Capability` = 500, check.names = FALSE),
    path
  )
  path
}

cat("\nread_csd_month()\n")

# 1. A plain 2-day month yields days x 24 distinct hours, one row per (hour, fuel).
m <- read_csd_month(fake_csd(mst_seq("2026-06-01 00:00:00", "2026-06-02 23:00:00")))
stopifnot(n_distinct(m$begin_datetime_utc) == 48, nrow(m) == 48 * 2)
pass("2 days x 2 fuels -> 48 hours, 96 rows")

# 2. Assets are summed within a fuel type, not carried through as separate rows.
m2 <- read_csd_month(fake_csd(rep(mst_seq("2026-06-01 00:00:00", "2026-06-01 02:00:00"), 3)))
stopifnot(nrow(m2) == 3 * 2, all(m2$net_generation_mw == 300))
pass("3 assets x 100 MW -> one 300 MW row per (hour, fuel)")

# 3. THE ONE THAT FAILS SILENTLY: the November fall-back day has 25 real hours.
#    Keying on local wall-clock digits collapses the two 01:00 hours into one and
#    this returns 24. Keying on UTC (what csd_parse.R does) returns 25.
nov <- read_csd_month(fake_csd(mst_seq("2026-10-31 23:00:00", "2026-11-01 23:00:00")))
stopifnot(n_distinct(nov$begin_datetime_utc) == 25,
          all(mpt_date(nov$begin_datetime_utc) == as.Date("2026-11-01")))
pass("fall-back day -> 25 distinct hours, all on one MPT date")

# 4. ...and the March spring-forward day has 23. (MPT Mar 8 runs 00:00 MST to
#    22:00 MST, because the clock jumps forward at 02:00; the fall-back day above
#    starts an hour earlier in MST for the mirror-image reason.)
mar <- read_csd_month(fake_csd(mst_seq("2026-03-08 00:00:00", "2026-03-08 22:00:00")))
stopifnot(n_distinct(mar$begin_datetime_utc) == 23,
          all(mpt_date(mar$begin_datetime_utc) == as.Date("2026-03-08")))
pass("spring-forward day -> 23 distinct hours, all on one MPT date")

# 5. One asset missing its metered value must not NA out the whole fuel type.
p <- fake_csd(mst_seq("2026-06-01 00:00:00", "2026-06-01 00:00:00"))
d <- readr::read_csv(p, show_col_types = FALSE)
d$Volume[1] <- NA
readr::write_csv(d, p)
stopifnot(!any(is.na(suppressWarnings(read_csd_month(p))$net_generation_mw)))
pass("NA volume on one asset does not NA out the fuel type total")

cat("\nsub-fuel handling\n")

# 6. The files spell the gas sub-types with underscores and split OTHER in mixed
# case; the live API uses spaces. These have to land on the same strings or the
# published history cannot be compared to the live snapshot at all.
stopifnot(identical(normalize_sub_fuel(c("SIMPLE_CYCLE", "COMBINED_CYCLE",
                                         "GAS_FIRED_STEAM", "Wood/Refuse")),
                    c("SIMPLE CYCLE", "COMBINED CYCLE",
                      "GAS FIRED STEAM", "WOOD/REFUSE")))
pass("sub-fuel strings normalise onto the live API's spelling")

# 7. Sub-fuels stay separate, and summing them recovers the fuel-grain figure.
sf <- read_csd_month(fake_csd(mst_seq("2026-06-01 00:00:00", "2026-06-01 01:00:00"),
                              fuels = "GAS",
                              subs = c("COGENERATION", "SIMPLE_CYCLE")))
stopifnot(nrow(sf) == 4,                                   # 2 hours x 2 sub-types
          setequal(sf$sub_fuel_type, c("COGENERATION", "SIMPLE CYCLE")),
          all(sf$fuel_type == "GAS"))
rolled <- sf |>
  summarise(mw = sum(net_generation_mw), .by = c(begin_datetime_utc, fuel_type))
stopifnot(nrow(rolled) == 2, all(rolled$mw == 200))
pass("sub-fuels kept separate and sum back to the fuel-grain total")

cat("\nall checks passed\n")
