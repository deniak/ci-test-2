#!/usr/bin/env bash
# =============================================================================
# Cloudflare Enterprise Analytics — /WoT/ Path CSV Exporter
# =============================================================================
# USAGE:
#   export CF_API_TOKEN="your_token_here"
#   export CF_ZONE_ID="your_zone_id_here"
#   bash cf_wot_analytics.sh [YYYY-MM-DD] [YYYY-MM-DD]
#
#   Defaults to the last 7 days if no dates are provided.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
CF_API_TOKEN="${CF_API_TOKEN:?ERROR: CF_API_TOKEN env var not set}"
CF_ZONE_ID="${CF_ZONE_ID:?ERROR: CF_ZONE_ID env var not set}"
CF_GQL="https://api.cloudflare.com/client/v4/graphql"
PATH_PREFIX="/WoT/"
EXCLUDE_PREFIX="/WoT/IG/wiki/"

DATE_END="${2:-$(date -u +%Y-%m-%d)}"
DATE_START="${1:-$(date -u -d '7 days ago' +%Y-%m-%d 2>/dev/null || date -u -v-7d +%Y-%m-%d)}"
DATETIME_START="${DATE_START}T00:00:00Z"
DATETIME_END="${DATE_END}T23:59:59Z"

OUTPUT_DIR="./cf_analytics_$(date +%Y%m%d)"
mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "[$(date +%H:%M:%S)] WARNING: $*" >&2; }

gql_query() {
  local query="$1"
  local response
  response=$(curl -s -X POST "$CF_GQL" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data-raw "{\"query\": $(echo "$query" | jq -Rs .)}")

  local errors
  errors=$(echo "$response" | jq -r '.errors // [] | .[].message // empty' 2>/dev/null || true)
  if [[ -n "$errors" ]]; then
    warn "GraphQL errors: $errors"
    warn "Full response: $response"
    return 1
  fi

  echo "$response"
}

to_csv_row() {
  local IFS=$'\t'
  local fields=($1)
  local out=""
  for f in "${fields[@]}"; do
    f="${f//\"/\"\"}"
    out+="\"${f}\","
  done
  echo "${out%,}"
}

write_csv() {
  local file="$1"
  local header="$2"
  local data="$3"

  echo "$header" > "$file"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    to_csv_row "$line" >> "$file"
  done <<< "$data"

  local rows
  rows=$(wc -l < "$file")
  log "  → $(basename "$file")  ($((rows - 1)) data rows)"
}

# ---------------------------------------------------------------------------
# Confirmed valid sum fields for httpRequestsAdaptiveGroups:
#   edgeRequestBytes, edgeResponseBytes, visits,
#   edgeDnsResponseTimeMs, edgeTimeToFirstByteMs,
#   originResponseDurationMs, originResponseHeaderReceiveDurationMs,
#   originTcpHandshakeDurationMs, originTlsHandshakeDurationMs,
#   crossZoneSubrequests
# No cachedBytes/cachedRequests/encryptedBytes in sum — use count only.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 1. Traffic Overview — counts, bytes, visits (hourly)
# ---------------------------------------------------------------------------
export_traffic_overview() {
  log "Exporting: Traffic Overview (hourly)"

  local query='
  {
    viewer {
      zones(filter: { zoneTag: "'"$CF_ZONE_ID"'" }) {
        httpRequestsAdaptiveGroups(
          filter: {
            datetime_geq: "'"$DATETIME_START"'"
            datetime_leq: "'"$DATETIME_END"'"
            clientRequestPath_like: "'"$PATH_PREFIX"'%"
            clientRequestPath_notlike: "'"$EXCLUDE_PREFIX"'%"
          }
          limit: 10000
          orderBy: [datetimeHour_ASC]
        ) {
          sum { visits }
          dimensions {
            datetimeHour
          }
        }
      }
    }
  }'

  local response
  response=$(gql_query "$query") || return

  local data
  data=$(echo "$response" | jq -r '
    .data.viewer.zones[0].httpRequestsAdaptiveGroups[] |
    [
      .dimensions.datetimeHour,
      (.sum.visits | tostring)
    ] | @tsv
  ')

  write_csv "$OUTPUT_DIR/01_traffic_overview_hourly.csv" \
    "datetime_hour,visits" \
    "$data"
}

# ---------------------------------------------------------------------------
# 2. Requests by Country
# ---------------------------------------------------------------------------
export_by_country() {
  log "Exporting: Requests by Country"

  local query='
  {
    viewer {
      zones(filter: { zoneTag: "'"$CF_ZONE_ID"'" }) {
        httpRequestsAdaptiveGroups(
          filter: {
            datetime_geq: "'"$DATETIME_START"'"
            datetime_leq: "'"$DATETIME_END"'"
            clientRequestPath_like: "'"$PATH_PREFIX"'%"
            clientRequestPath_notlike: "'"$EXCLUDE_PREFIX"'%"
          }
          limit: 500
          orderBy: [count_DESC]
        ) {
          sum { visits }
          dimensions {
            clientCountryName
          }
        }
      }
    }
  }'

  local response
  response=$(gql_query "$query") || return

  local data
  data=$(echo "$response" | jq -r '
    .data.viewer.zones[0].httpRequestsAdaptiveGroups[] |
    [
      (.dimensions.clientCountryName // "Unknown"),
      (.sum.visits                   | tostring)
    ] | @tsv
  ')

  write_csv "$OUTPUT_DIR/02_requests_by_country.csv" \
    "country,visits" \
    "$data"
}
# ---------------------------------------------------------------------------
# 7. Top Paths under /WoT/
# ---------------------------------------------------------------------------
export_top_paths() {
  log "Exporting: Top Paths under /WoT/"

  local query='
  {
    viewer {
      zones(filter: { zoneTag: "'"$CF_ZONE_ID"'" }) {
        httpRequestsAdaptiveGroups(
          filter: {
            datetime_geq: "'"$DATETIME_START"'"
            datetime_leq: "'"$DATETIME_END"'"
            clientRequestPath_like: "'"$PATH_PREFIX"'%"
            clientRequestPath_notlike: "'"$EXCLUDE_PREFIX"'%"
          }
          limit: 1000
          orderBy: [count_DESC]
        ) {
          sum { visits }
          dimensions {
            clientRequestPath
          }
        }
      }
    }
  }'

  local response
  response=$(gql_query "$query") || return

  local data
  data=$(echo "$response" | jq -r '
    .data.viewer.zones[0].httpRequestsAdaptiveGroups[] |
    [
      (.dimensions.clientRequestPath // "(root)"),
      (.sum.visits                   | tostring)
    ] | @tsv
  ')

  write_csv "$OUTPUT_DIR/03_top_paths.csv" \
    "path,visits" \
    "$data"
}

# ---------------------------------------------------------------------------
# 8. Browser + OS Breakdown
# ---------------------------------------------------------------------------
export_by_useragent() {
  log "Exporting: User Agent Breakdown"

  local query='
  {
    viewer {
      zones(filter: { zoneTag: "'"$CF_ZONE_ID"'" }) {
        httpRequestsAdaptiveGroups(
          filter: {
            datetime_geq: "'"$DATETIME_START"'"
            datetime_leq: "'"$DATETIME_END"'"
            clientRequestPath_like: "'"$PATH_PREFIX"'%"
            clientRequestPath_notlike: "'"$EXCLUDE_PREFIX"'%"
          }
          limit: 500
          orderBy: [count_DESC]
        ) {
          sum { visits }
          dimensions {
            userAgentBrowser
            userAgentOS
          }
        }
      }
    }
  }'

  local response
  response=$(gql_query "$query") || return

  local data
  data=$(echo "$response" | jq -r '
    .data.viewer.zones[0].httpRequestsAdaptiveGroups[] |
    [
      (.dimensions.userAgentBrowser // "Unknown"),
      (.dimensions.userAgentOS     // "Unknown"),
      (.sum.visits                 | tostring)
    ] | @tsv
  ')

  write_csv "$OUTPUT_DIR/04_user_agents.csv" \
    "browser,os,visits" \
    "$data"
}

# ---------------------------------------------------------------------------
# 9. Device Type Breakdown
# ---------------------------------------------------------------------------
export_by_device() {
  log "Exporting: Device Type Breakdown"

  local query='
  {
    viewer {
      zones(filter: { zoneTag: "'"$CF_ZONE_ID"'" }) {
        httpRequestsAdaptiveGroups(
          filter: {
            datetime_geq: "'"$DATETIME_START"'"
            datetime_leq: "'"$DATETIME_END"'"
            clientRequestPath_like: "'"$PATH_PREFIX"'%"
            clientRequestPath_notlike: "'"$EXCLUDE_PREFIX"'%"
          }
          limit: 50
          orderBy: [count_DESC]
        ) {
          sum { visits }
          dimensions {
            clientDeviceType
          }
        }
      }
    }
  }'

  local response
  response=$(gql_query "$query") || return

  local data
  data=$(echo "$response" | jq -r '
    .data.viewer.zones[0].httpRequestsAdaptiveGroups[] |
    [
      (.dimensions.clientDeviceType // "Unknown"),
      (.sum.visits                  | tostring)
    ] | @tsv
  ')

  write_csv "$OUTPUT_DIR/05_device_types.csv" \
    "device_type,visits" \
    "$data"
}

# ---------------------------------------------------------------------------
# 10. ASN / ISP Breakdown
# ---------------------------------------------------------------------------
export_by_asn() {
  log "Exporting: ASN / ISP Breakdown"

  local query='
  {
    viewer {
      zones(filter: { zoneTag: "'"$CF_ZONE_ID"'" }) {
        httpRequestsAdaptiveGroups(
          filter: {
            datetime_geq: "'"$DATETIME_START"'"
            datetime_leq: "'"$DATETIME_END"'"
            clientRequestPath_like: "'"$PATH_PREFIX"'%"
            clientRequestPath_notlike: "'"$EXCLUDE_PREFIX"'%"
          }
          limit: 500
          orderBy: [count_DESC]
        ) {
          sum { visits }
          dimensions {
            clientAsn
            clientASNDescription
          }
        }
      }
    }
  }'

  local response
  response=$(gql_query "$query") || return

  local data
  data=$(echo "$response" | jq -r '
    .data.viewer.zones[0].httpRequestsAdaptiveGroups[] |
    [
      (.dimensions.clientAsn            | tostring),
      (.dimensions.clientASNDescription // "Unknown"),
      (.sum.visits                      | tostring)
    ] | @tsv
  ')

  write_csv "$OUTPUT_DIR/06_asn_breakdown.csv" \
    "asn,asn_description,visits" \
    "$data"
}
# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log "======================================================"
  log "Cloudflare Analytics Export — /WoT/ path"
  log "Range:  ${DATETIME_START}  →  ${DATETIME_END}"
  log "Output: ${OUTPUT_DIR}/"
  log "======================================================"

  export_traffic_overview
  export_by_country
  export_top_paths
  export_by_useragent
  export_by_device
  export_by_asn

  log "======================================================"
  log "Done! CSVs written to: ${OUTPUT_DIR}/"
  ls -1 "$OUTPUT_DIR"
  log "======================================================"
}

main "$@"
