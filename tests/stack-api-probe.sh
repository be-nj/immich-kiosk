#!/usr/bin/env bash
# Re-measure withStacked against Immich's NEW filter-based search API.
#
# The earlier probes used the old flat request body. Kiosk upstream has since
# moved to the filter API (filter.personIds.all, filter.type.in, ...), so the
# measurement has to be repeated on the shape Kiosk actually sends now.
#
# Usage:
#   export KIOSK_IMMICH_URL=https://immich.example.net
#   export KIOSK_IMMICH_API_KEY=...      # the key for the user in ?user=
#   ./stack-probe5.sh <personId> [personId ...]
#
# The API key is read from the environment and never printed.

set -euo pipefail

: "${KIOSK_IMMICH_URL:?set KIOSK_IMMICH_URL}"
: "${KIOSK_IMMICH_API_KEY:?set KIOSK_IMMICH_API_KEY}"
[[ $# -gt 0 ]] || { echo "usage: $0 <personId> [personId ...]" >&2; exit 1; }

base="${KIOSK_IMMICH_URL%/}"
ids_json="$(printf '%s\n' "$@" | jq -R . | jq -sc .)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

stacks="$(curl -sS --fail-with-body "$base/api/stacks" \
  -H "x-api-key: $KIOSK_IMMICH_API_KEY" -H 'Accept: application/json')"

jq -r '.[] | . as $s | .assets[]?.id + " " + $s.id' <<<"$stacks" | sort > "$tmp/member2stack"
jq -r '.[] | . as $s | .assets[]? | select(.id != $s.primaryAssetId) | .id' <<<"$stacks" | sort -u > "$tmp/children"
jq -r '.[].primaryAssetId' <<<"$stacks" | sort -u > "$tmp/primaries"

echo "stack members:   $(wc -l < "$tmp/member2stack")"
echo "stack children:  $(wc -l < "$tmp/children")"
echo "stack primaries: $(wc -l < "$tmp/primaries")"
echo "people queried:  $*"
echo

# The body Kiosk builds now: a filter object rather than flat fields.
probe() {
  local label="$1" with_stacked="$2" body payload

  payload="$(jq -nc --argjson ids "$ids_json" --argjson ws "$with_stacked" '
    {
      size: 1000,
      withExif: true,
      withPeople: true,
      filter: {
        personIds: { all: $ids },
        type:       { in: ["IMAGE"] },
        visibility: { in: ["timeline"] }
      }
    }
    | if $ws == null then . else . + {withStacked: $ws} end')"

  body="$(curl -sS --fail-with-body -X POST "$base/api/search/random" \
    -H "x-api-key: $KIOSK_IMMICH_API_KEY" -H 'Content-Type: application/json' \
    -d "$payload")"

  if ! jq -e 'type == "array" or has("assets")' >/dev/null 2>&1 <<<"$body"; then
    echo "$label: unexpected response"
    jq -c . <<<"$body" 2>/dev/null | head -c 400 || head -c 400 <<<"$body"
    echo
    return
  fi

  jq -r 'if type == "array" then .[].id else .assets.items[].id end' <<<"$body" | sort -u > "$tmp/ids"

  local total children primaries unstacked dupes
  total="$(wc -l < "$tmp/ids")"
  children="$(comm -12 "$tmp/ids" "$tmp/children"  | wc -l)"
  primaries="$(comm -12 "$tmp/ids" "$tmp/primaries" | wc -l)"
  unstacked=$(( total - children - primaries ))
  dupes="$(join "$tmp/ids" "$tmp/member2stack" | awk '{print $2}' | sort | uniq -d | wc -l)"

  echo "$label"
  echo "  total:                        $total"
  echo "  stack children:               $children"
  echo "  stack primaries:              $primaries"
  echo "  in no stack:                  $unstacked"
  echo "  stacks contributing >1 asset: $dupes"
  echo
}

probe "withStacked omitted"      null
probe "withStacked true"         true
probe "withStacked false"        false

cat <<'HINT'
What this has to confirm before the fix can be trusted:
  withStacked true  -> children present   (Kiosk sets true and filters them itself)
  withStacked false -> primaries also gone (the reason the filter lives in Kiosk)
If false now keeps the primaries, Immich changed and the Kiosk-side filter is
no longer the right approach.
HINT
