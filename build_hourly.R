# ==============================================================================
# Turn the zips fetch_box.sh downloaded into one CSV per month under hourly/.
# ==============================================================================
# Deliberately thin. The parse lives in csd_parse.R and is sourced, not
# reimplemented: the MST-to-UTC handling is the subtle part of this whole
# pipeline (a wall-clock dedupe silently eats one hour every November
# fall-back), and a second implementation is how that goes stale without anyone
# noticing. poll.sh refuses to do the fuel rollup for the same reason.
#
# Running R here costs a few minutes once a month. The reason the poller is bash
# is that 4,320 runs/month of R would blow the free Actions allowance; that
# arithmetic does not apply at monthly cadence.
# ==============================================================================
suppressMessages(source("csd_parse.R"))

zips <- list.files("raw", pattern = "^\\d{4}-\\d{2}\\.zip$", full.names = TRUE)
if (!length(zips)) {
  message("no new archives in raw/, nothing to build")
  quit(save = "no", status = 0)
}

dir.create("hourly", showWarnings = FALSE)

for (z in zips) {
  month <- sub("\\.zip$", "", basename(z))
  message("building ", month)

  d <- read_csd_month(z) |>
    # Partition by the MPT calendar month the data describes. An AESO file is
    # one calendar month, but the UTC stamps at each end spill into the
    # neighbouring month, so filtering on the stamp is what keeps a partition
    # from carrying seven stray hours of its neighbour.
    filter(format(with_tz(begin_datetime_utc, TZ_MPT), "%Y-%m") == month)

  if (!nrow(d)) stop("archive ", basename(z), " held no rows for ", month)

  # A full month is 24 hours x days, or 23/25 on a DST changeover day.
  hrs <- n_distinct(d$begin_datetime_utc)
  days <- as.integer(format(seq(as.Date(paste0(month, "-01")), by = "month",
                                length.out = 2)[2] - 1, "%d"))
  if (!hrs %in% (days * 24 + c(-1, 0, 1))) {
    stop(month, " has ", hrs, " hours, expected about ", days * 24)
  }

  readr::write_csv(d, file.path("hourly", paste0("supply_hourly_", month, ".csv")))
}

message("built ", length(zips), " month(s)")
