#!/usr/bin/env bash
# ==============================================================================
# Download any AESO monthly CSD archive that hourly/ does not already cover.
# ==============================================================================
# AESO publishes the settled hourly generation files to a public Box shared
# folder, roughly five weeks after each month ends. The folder needs no
# credentials: the listing is a JSON blob embedded in the shared page's HTML,
# and each file has a stable download URL keyed by its Box file id.
#
# This script compares the months Box advertises against the months already
# committed under hourly/ and fetches only the difference. Comparing full lists
# rather than looking for "last month" is what makes it self-healing: a skipped
# run just means the file lands a day later, a month AESO republishes gets
# picked up, and a gap from any cause closes itself on the next run. That is
# why this needs no reliable scheduler.
#
# Writes zips to raw/ and prints nothing but the months it took. Exits 0 having
# done nothing when there is nothing new, which is most days.
# ==============================================================================
set -euo pipefail

SHARED_NAME="qofgn9axnnw6uq3ip1goiq2ngb11txe5"
HOURLY_FOLDER_ID="196178549071"   # the "Hourly" subfolder of "Generation Data"
BASE="https://aeso.app.box.com"
UA="Mozilla/5.0"

mkdir -p raw hourly

get_page() {
  curl -sSL --fail --retry 3 --retry-delay 5 --max-time 60 -A "$UA" \
       "$BASE/s/$SHARED_NAME/folder/$HOURLY_FOLDER_ID?page=$1"
}

# Box paginates the listing and its sort order is not chronological: in 2026-10
# page 1 held 2015-2017 and 2021 onward while 2018-2020 sat on page 2. Reading
# only page 1 would silently stop picking up new months the day one lands on a
# later page, so walk every page the listing advertises.
listing=$(get_page 1)
pages=$(grep -oE '"pageCount":[0-9]+' <<<"$listing" | head -1 | grep -oE '[0-9]+$' || true)
for ((p = 2; p <= ${pages:-1}; p++)); do
  listing+=$(get_page "$p")
done

# Pull "<file id> <YYYY-MM>" for single-month archives only. The 2015-2022 files
# are six-month bundles ("... - 2015-01 to 2015-06.zip") and were backfilled
# once by hand; AESO has published one file per month since 2026-01, so going
# forward only this pattern appears. A bundle reappearing is ignored rather than
# mis-parsed.
mapfile -t available < <(
  grep -oE '"typedID":"f_[0-9]+"[^}]*"name":"CSD Generation \(Hourly\) - [0-9]{4}-[0-9]{2}\.zip"' \
    <<<"$listing" |
  sed -E 's/.*"typedID":"f_([0-9]+)".*- ([0-9]{4}-[0-9]{2})\.zip"/\1 \2/'
)

if [[ ${#available[@]} -eq 0 ]]; then
  echo "no single-month archives found in the Box listing" >&2
  echo "(the shared link or folder id may have changed: $BASE/s/$SHARED_NAME)" >&2
  exit 1
fi

took=0
for entry in "${available[@]}"; do
  file_id="${entry%% *}"
  month="${entry##* }"

  if [[ -f "hourly/supply_hourly_${month}.csv" ]]; then
    continue
  fi

  echo "fetching $month"
  curl -sSL --fail --retry 3 --retry-delay 5 --max-time 600 -A "$UA" \
       -o "raw/${month}.zip" \
       "$BASE/index.php?rm=box_download_shared_file&shared_name=${SHARED_NAME}&file_id=f_${file_id}"

  # Box serves an HTML error page with a 200 when a link goes stale, so check
  # that what landed is actually an archive before handing it to R. Magic bytes
  # rather than `unzip -t`: this has to run unchanged in the R container, which
  # is not guaranteed to carry unzip.
  if [[ $(head -c 2 "raw/${month}.zip") != "PK" ]]; then
    echo "downloaded file for $month is not a zip (Box likely served an error page)" >&2
    exit 1
  fi
  took=$((took + 1))
done

echo "new months downloaded: $took"
