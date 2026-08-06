# aeso-supply-log

Alberta generation data, kept current without anyone's laptop being on. Two
datasets:

| | grain | cadence | source |
|---|---|---|---|
| `snapshots/` | ~10 min x sub-fuel | every 10 min | CSD API |
| `hourly/` | 1 hour x sub-fuel | monthly | AESO's published files |

Together they are the whole picture: `hourly/` is settled and authoritative back
to 2015-01 but runs ~5 weeks in arrears, and `snapshots/` covers the gap between
its last month and now, at a resolution nothing else has.

## Why this exists

The [CSD API](https://apimgw.aeso.ca/public/currentsupplydemand-api/v2/csd/summary/current)
takes no date parameter. It only ever returns *right now*, so there is no way to
ask it what wind was doing at 3am. Any historical view has to be accumulated as
it happens.

AESO publishes hourly generation files monthly, roughly five weeks in arrears,
so those eventually supersede this log **at hourly grain**. But AESO stopped
publishing its 5-minute CSD dataset in 2023, so at sub-hourly grain nothing
supersedes it. Every snapshot not captured while it was current is gone.

That is why this repo polls on a schedule and never deletes anything.

## Layout

```
poll.sh                                  curl + jq, ~5s, no R
fetch_box.sh                             curl + grep, downloads new monthly files
build_hourly.R                           zip -> one CSV per month, via supply.R
supply.R                                 shared reader/parser, copied from the analysis project
.github/workflows/poll.yml               every 10 min (triggered externally)
.github/workflows/backfill.yml           daily check, acts only when a month lands
snapshots/supply_snapshots_YYYY-MM.csv   the live log
hourly/supply_hourly_YYYY-MM.csv         the settled history, 2015-01 onward
```

Monthly partitions mean the snapshot writer only ever appends: no read, no
rewrite, so a poll costs the same in year ten as on day one. It also keeps every
file around 2 MB, far below GitHub's 100 MB per-file limit.

## Where the monthly files come from

AESO publishes settled hourly generation to a public [Box
folder](https://aeso.box.com/s/qofgn9axnnw6uq3ip1goiq2ngb11txe5), roughly five
weeks after each month ends, on no fixed day. `fetch_box.sh` reads that folder
with plain `curl` (no credentials: the listing is embedded in the shared page's
HTML and each file has a stable id-keyed download URL) and downloads only the
months `hourly/` does not already cover.

Comparing full lists rather than looking for "last month" makes it self-healing:
a run GitHub's scheduler skips just means the file lands a day later, and a gap
from any cause closes itself on the next run. That is why `backfill.yml` needs no
external trigger, while `poll.yml` does.

`build_hourly.R` sources `supply.R` rather than reimplementing the parse. The
MST-to-UTC handling is the subtle part of this project (a wall-clock dedupe eats
one hour every November fall-back) and a second implementation is how that goes
stale unnoticed. Running R once a month is cheap; running it every 10 minutes is
what the free Actions allowance cannot cover, which is why `poll.sh` is bash.

### `hourly/`

| column | notes |
|---|---|
| `begin_datetime_utc` | hour beginning, UTC. Parsed from the files' `Date (MST)` |
| `fuel_type` | `GAS`, `WIND`, `SOLAR`, `HYDRO`, `OTHER`, `ENERGY STORAGE`, and `COAL`/`DUAL FUEL` before 2024 |
| `sub_fuel_type` | normalised to the API's spelling (see below) |
| `net_generation_mw` | sum of asset `Volume` |
| `max_capability_mw` | sum of asset `Maximum Capability` |

Keyed on UTC deliberately: the files' `Date (MPT)` column cannot represent DST,
since the two 01:00 hours on the November fall-back day have identical digits.
A correct month has 24 hours per day, 25 on the fall-back day and 23 on the
spring-forward day.

**`sub_fuel_type` is normalised, unlike `snapshots/`.** The published files spell
the gas sub-types `COMBINED_CYCLE`/`SIMPLE_CYCLE`/`GAS_FIRED_STEAM` with
underscores where the API uses spaces, so underscores are converted and the
value upper-cased. Without that the live and historic sides cannot be compared.
The files also split `OTHER` six ways (`BIOMASS`, `GAS`, `GAS COGEN`, `OIL/GAS`,
`WOOD/REFUSE`, `COMPOSITE`) where the API reports one undifferentiated `OTHER`;
that asymmetry is real and is left alone.

Asset-level detail is dropped: 230 assets per hour is what makes the source
files 20 MB each, and nothing downstream uses it. Re-run `build_hourly.R`
against the archive if it is ever needed.

### `snapshots/`

| column | notes |
|---|---|
| `effective_utc` | AESO's `effective_datetime_utc`, normalised to ISO 8601 |
| `fuel_type` | **verbatim from the API** (see below) |
| `net_generation_mw` | `aggregated_net_generation` |
| `max_capability_mw` | `aggregated_maximum_capability` |
| `alberta_internal_load` | system total, repeated on each row |
| `net_actual_interchange` | system total, repeated. Positive = export |

**`fuel_type` is what AESO said, not a tidied category.** The API reports the
four gas sub-types individually (`COGENERATION`, `COMBINED CYCLE`,
`GAS FIRED STEAM`, `SIMPLE CYCLE`) and has no `GAS` bucket at all, which is
*different from AESO's own historical hourly files*, where those four appear in
`Sub Fuel Type` and `Fuel Type` holds `GAS`. Rolling them up is deliberately the
reader's job (`CSD_FUEL_ROLLUP` in `supply.R`), so the mapping lives in one
language rather than silently going stale here the next time AESO adds a fuel.

`COAL` and `DUAL FUEL` never appear: Alberta retired those units in 2024.

Duplicate `effective_utc` values can occur when AESO's feed stalls between
polls. Dedupe on `(effective_utc, fuel_type)` when reading.

## Reading it

`supply.R` has readers for both, which handle the month-to-URL construction, the
sub-fuel rollup and the dedupe:

```r
read_snapshots()                          # live log, current + previous month
read_hourly(all_months("2024-01"))        # settled history, fuel grain
read_hourly("2026-06", grain = "sub_fuel")
```

Or read a partition directly:

```r
readr::read_csv(paste0(
  "https://raw.githubusercontent.com/raahem-cad/aeso-supply-log/main/",
  "hourly/supply_hourly_2026-06.csv"
))
```

`raw.githubusercontent.com` has a CDN cache of roughly five minutes, so the
newest snapshot can lag slightly. HTTP cannot list a directory, so which months
to fetch is derived from the range you ask for rather than discovered.

## Setup

The poller needs one repository secret, `AESO_API_KEY`, from the
[AESO developer portal](https://developer-apim.aeso.ca/). Nothing else does:
`backfill.yml` reads a public Box link, and reading either dataset back needs no
credentials at all.

## Data source

Generation data is published by the [Alberta Electric System
Operator](https://www.aeso.ca/). This repo only transcribes API responses; check
AESO's API terms before relying on redistribution.
