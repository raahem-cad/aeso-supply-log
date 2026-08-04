#!/usr/bin/env bash
# ==============================================================================
# Append one AESO Current Supply Demand snapshot to snapshots/YYYY-MM.csv
# ==============================================================================
# The CSD endpoint takes no date parameter: it only ever returns "now". AESO
# stopped publishing 5-minute CSD data in 2023, so at sub-hourly grain this log
# is the only record that will exist for today forward. Nothing captured here is
# recoverable, which is why this runs on a schedule and never deletes.
#
# This script is a PURE TRANSCRIPTION of the API response. No rollups, no
# renaming, no derived columns. AESO reports the four gas sub-types
# (COGENERATION, COMBINED CYCLE, GAS FIRED STEAM, SIMPLE CYCLE) in `fuel_type`
# and has no "GAS" bucket; rolling those up is the reader's job in supply.R.
# Re-implementing that lookup here is how it silently goes stale the first time
# AESO adds a fuel type.
#
# Needs curl and jq (both preinstalled on ubuntu-latest) and $AESO_API_KEY.
# ==============================================================================
set -euo pipefail

URL="https://apimgw.aeso.ca/public/currentsupplydemand-api/v2/csd/summary/current"
HEADER="effective_utc,fuel_type,net_generation_mw,max_capability_mw,alberta_internal_load,net_actual_interchange"

: "${AESO_API_KEY:?AESO_API_KEY is not set}"

# Strip whitespace and newlines. `gh secret set` reading from a prompt or a
# piped file readily captures a trailing newline, which turns the header into
# "API-KEY: abc\n" and earns a 401 that looks exactly like a wrong key. The R
# poller has always done trimws() on this for the same reason.
key="${AESO_API_KEY//[$'\r\n\t ']/}"

# Length only, never the value: 401s here are nearly always a mangled secret
# rather than a revoked key, and comparing this against the real key's length is
# the fastest way to tell the two apart.
echo "using API key of length ${#key}"

if ! resp=$(curl -sS --fail --retry 3 --retry-delay 5 --max-time 30 \
                 -H "API-KEY: ${key}" "$URL" 2>&1); then
  echo "AESO request failed: $resp" >&2
  echo "A 401 means the AESO_API_KEY secret is wrong or mangled. Reset it with:" >&2
  echo "  gh secret set AESO_API_KEY --repo raahem-cad/aeso-supply-log" >&2
  exit 1
fi

# AESO returns "2026-08-04 19:45" (UTC, no seconds). Normalise to ISO 8601 so
# readr::col_datetime() parses it without a format string.
stamp=$(jq -er '.return.effective_datetime_utc' <<<"$resp")
if [[ ! $stamp =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]; then
  echo "unexpected timestamp format: '$stamp'" >&2
  exit 1
fi
stamp_iso="${stamp/ /T}:00Z"

# Partition by the SNAPSHOT's month, not the wall clock, so a poll landing
# either side of a month boundary files with the data it describes.
file="snapshots/supply_snapshots_${stamp:0:7}.csv"

# A repeat stamp means AESO's feed stalled between polls. The reader dedupes
# anyway, but skipping here stops every stalled cycle producing a junk commit.
if [[ -f $file ]] && tail -1 "$file" | grep -q "^${stamp_iso},"; then
  echo "stamp $stamp_iso already logged, skipping"
  exit 0
fi

mkdir -p snapshots
[[ -f $file ]] || echo "$HEADER" > "$file"

# join(",") rather than @csv: fuel type values contain spaces but never commas,
# so this stays unquoted and matches the existing files byte for byte.
jq -er --arg ts "$stamp_iso" '
  .return as $r
  | $r.generation_data_list[]
  | [ $ts,
      .fuel_type,
      (.aggregated_net_generation     | tostring),
      (.aggregated_maximum_capability | tostring),
      ($r.alberta_internal_load       | tostring),
      ($r.net_actual_interchange      | tostring)
    ] | join(",")
' <<<"$resp" >> "$file"

echo "appended $stamp_iso to $file"
