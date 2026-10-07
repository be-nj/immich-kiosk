#!/usr/bin/env bash
# Three-way comparison of what Kiosk actually puts on screen.
#
#   baseline  upstream/main, no stack filter at all
#   new off   the branch with show_stack_children=false (the new default)
#   new on    the branch with show_stack_children=true  (the escape hatch)
#
# "new on" should match "baseline": that is what shows the option really is an
# opt-out and not a behaviour change nobody can undo.
#
# Same live Immich, same person query, same slide count for all three, so the
# filter is the only variable.
#
# Usage:
#   export KIOSK_IMMICH_URL=https://immich.example.net
#   export KIOSK_IMMICH_API_KEY=...
#   ./stack-compare.sh <slides> <personId> [personId ...]
#
# The API key is read from the environment and never printed.

set -euo pipefail

: "${KIOSK_IMMICH_URL:?set KIOSK_IMMICH_URL}"
: "${KIOSK_IMMICH_API_KEY:?set KIOSK_IMMICH_API_KEY}"
[[ $# -ge 2 ]] || { echo "usage: $0 <slides> <personId> [personId ...]" >&2; exit 1; }

: "${KIOSK_NEW_BINARY:?set KIOSK_NEW_BINARY to the kiosk build under test}"
# Defaults to comparing a build against itself with the option flipped, which
# isolates the filter. Point KIOSK_OLD_BINARY at an older build to compare two.
old_binary="${KIOSK_OLD_BINARY:-$KIOSK_NEW_BINARY}"
new_binary="$KIOSK_NEW_BINARY"
for b in "$old_binary" "$new_binary"; do
  [[ -x "$b" ]] || { echo "not executable: $b" >&2; exit 1; }
done

slides="$1"; shift
immich="${KIOSK_IMMICH_URL%/}"
port="${KIOSK_TEST_PORT:-3999}"

tmp="$(mktemp -d)"
kiosk_pid=""
cleanup() {
  [[ -n "$kiosk_pid" ]] && kill "$kiosk_pid" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

# --- stack reference data, straight from Immich ---------------------------
stacks="$(curl -sS --fail-with-body "$immich/api/stacks" \
  -H "x-api-key: $KIOSK_IMMICH_API_KEY" -H 'Accept: application/json')"
jq -r '.[] | . as $s | .assets[]?.id + " " + $s.id' <<<"$stacks" | sort > "$tmp/member2stack"
jq -r '.[] | . as $s | .assets[]? | select(.id != $s.primaryAssetId) | .id' <<<"$stacks" | sort -u > "$tmp/children"

echo "stack children in library: $(wc -l < "$tmp/children")"
echo "slides per run:            $slides"
echo

# max_additional_people is a fork-only option, absent from this upstream-based
# branch, so it is left out rather than silently ignored.
query=""
for id in "$@"; do query+="person=$id&"; done
query+="require_all_people=true&duration=30"
# Extra options for the run, e.g. max_additional_people once the fork feature
# is present. KIOSK_BASELINE_EXTRA is what the baseline run adds on top.
query+="${KIOSK_EXTRA_QUERY:+&$KIOSK_EXTRA_QUERY}"

start_kiosk() {
  local binary="$1"
  KIOSK_PORT="$port" KIOSK_CACHE=true "$binary" >"$tmp/kiosk.log" 2>&1 &
  kiosk_pid=$!

  for _ in $(seq 60); do
    curl -sf "http://localhost:$port/health" >/dev/null 2>&1 && return 0
    kill -0 "$kiosk_pid" 2>/dev/null || break
    sleep 0.5
  done

  echo "kiosk failed to start:" >&2
  tail -20 "$tmp/kiosk.log" >&2
  return 1
}

stop_kiosk() {
  [[ -n "$kiosk_pid" ]] || return 0
  kill "$kiosk_pid" 2>/dev/null || true
  wait "$kiosk_pid" 2>/dev/null || true
  kiosk_pid=""
}

# Asks Kiosk for one slide at a time and records the asset it served. With no
# history posted back, the history form holds exactly the current asset.
collect() {
  local extra="$1" out="$2" device="$3"
  local q="$query${extra:+&$extra}"
  local page="http://localhost:$port/?$q"

  : > "$out"
  for _ in $(seq "$slides"); do
    # The options have to travel in the form body: echo binds only the body on
    # POST, so a query string on /asset/new is silently ignored and Kiosk falls
    # back to an unfiltered random asset.
    curl -sS -X POST "http://localhost:$port/asset/new" \
      -H "Referer: $page" \
      -H "kiosk-device-id: $device" \
      -H 'HX-Request: true' \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data "$q" \
    | grep -o 'class="kiosk-history--entry"[^>]*value="[^"]*"' \
    | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
    | head -1 >> "$out" || true
  done
}

report() {
  local label="$1" file="$2"
  local served unique children repeats stacks_hit

  served="$(grep -c . "$file" || true)"
  if [[ "$served" -eq 0 ]]; then
    echo "$label: no assets served -- see $tmp/kiosk.log"
    return
  fi

  sort -u "$file" > "$file.unique"
  unique="$(wc -l < "$file.unique")"
  children="$(comm -12 "$file.unique" "$tmp/children" | wc -l)"
  repeats=$(( served - unique ))
  stacks_hit="$(join "$file.unique" "$tmp/member2stack" | awk '{print $2}' | sort | uniq -d | wc -l)"

  printf '%-12s slides=%-4s distinct=%-4s repeats=%-4s children=%-4s multi-stacks=%s\n' \
    "$label" "$served" "$unique" "$repeats" "$children" "$stacks_hit"
}

run() {
  local label="$1" binary="$2" extra="$3"
  start_kiosk "$binary"
  collect "$extra" "$tmp/$label" "compare-$label"
  stop_kiosk
}

baseline_extra="${KIOSK_BASELINE_EXTRA-show_stack_children=true}"
run baseline "$old_binary" "$baseline_extra"
run new-off  "$new_binary" "show_stack_children=false"
run new-on   "$new_binary" "show_stack_children=true"

echo "results"
report baseline "$tmp/baseline"
report new-off  "$tmp/new-off"
report new-on   "$tmp/new-on"
echo

echo "overlap between baseline and new-on (the escape hatch should match):"
printf '  shared assets: %s\n' "$(comm -12 "$tmp/baseline.unique" "$tmp/new-on.unique" | wc -l)"
printf '  only baseline: %s\n' "$(comm -23 "$tmp/baseline.unique" "$tmp/new-on.unique" | wc -l)"
printf '  only new-on:   %s\n' "$(comm -13 "$tmp/baseline.unique" "$tmp/new-on.unique" | wc -l)"
echo
echo "children served by new-off must be 0, and multi-stacks must be 0."
echo "random selection means the two sets will not match exactly; what matters"
echo "is that new-on shows children like baseline does, and new-off shows none."
