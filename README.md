# aeso-supply-log

A running log of Alberta generation snapshots, polled every 10 minutes from the
AESO Current Supply Demand API.

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
.github/workflows/poll.yml               cron "*/10 * * * *"
snapshots/supply_snapshots_YYYY-MM.csv   the data, one file per month
```

Monthly partitions mean the writer only ever appends: no read, no rewrite, so a
poll costs the same in year ten as on day one. It also keeps every file around
2 MB, far below GitHub's 100 MB per-file limit.

## Schema

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

```r
readr::read_csv(paste0(
  "https://raw.githubusercontent.com/raahem-cad/aeso-supply-log/main/",
  "snapshots/supply_snapshots_2026-08.csv"
))
```

`raw.githubusercontent.com` has a CDN cache of roughly five minutes, so the
newest snapshot can lag slightly.

## Setup

Requires one repository secret, `AESO_API_KEY`, from the
[AESO developer portal](https://developer-apim.aeso.ca/).

## Data source

Generation data is published by the [Alberta Electric System
Operator](https://www.aeso.ca/). This repo only transcribes API responses; check
AESO's API terms before relying on redistribution.
