#!/usr/bin/env bash
set -euo pipefail

VERSION="1.0.0"

# --- Defaults ---
SITEMAPS=""
DELAY_MS=1500
TIMEOUT_SEC=30
VERBOSE=false

# --- Helpers ---
separator() {
  printf '%0.s─' {1..65}
  echo
}

usage() {
  echo "Usage: $0 -sitemaps <url[,url,...]> [-delay <ms>] [-timeout <sec>] [-verbose] [-version]"
  echo ""
  echo "  -sitemaps   Comma-separated sitemap URLs (required)"
  echo "  -delay      Delay between requests in milliseconds (default: 1500)"
  echo "  -timeout    HTTP request timeout in seconds (default: 30)"
  echo "  -verbose    Show response times in milliseconds"
  echo "  -version    Print version and exit"
  exit 1
}

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -sitemaps)  SITEMAPS="$2";    shift 2 ;;
    -delay)     DELAY_MS="$2";    shift 2 ;;
    -timeout)   TIMEOUT_SEC="$2"; shift 2 ;;
    -verbose)   VERBOSE=true;     shift   ;;
    -version)   echo "cache-warmer $VERSION"; exit 0 ;;
    -help|--help|-h) usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

if [[ -z "$SITEMAPS" ]]; then
  echo "Error: -sitemaps flag is required" >&2
  echo "Example: $0 -sitemaps https://example.com/sitemap.xml" >&2
  exit 1
fi

# --- XML parsing ---
# Extract <loc> values from sitemap XML using grep/sed (no xmllint required)
extract_locs() {
  grep -oP '(?<=<loc>)[^<]+' 2>/dev/null || grep -oE '<loc>[^<]+</loc>' | sed 's|<loc>||;s|</loc>||'
}

# Returns 0 if body looks like a sitemap index, 1 otherwise
is_sitemap_index() {
  echo "$1" | grep -q '<sitemapindex'
}

# --- Sitemap fetching ---
DEPTH_LIMIT=4

fetch_sitemap() {
  local url="$1"
  local depth="${2:-0}"

  if (( depth > DEPTH_LIMIT )); then
    echo "   ❌ Sitemap nesting too deep, skipping: $url" >&2
    return 1
  fi

  local body
  body=$(curl -sS --max-time "$TIMEOUT_SEC" \
    -A "Mozilla/5.0 (compatible; CacheWarmer/$VERSION)" \
    -L --max-redirs 5 \
    "$url") || { echo "   ❌ Failed to fetch sitemap: $url" >&2; return 1; }

  if is_sitemap_index "$body"; then
    local child_urls
    child_urls=$(echo "$body" | extract_locs)
    local count
    count=$(echo "$child_urls" | grep -c . 2>/dev/null || echo 0)
    echo "   Sitemap index found — $count child sitemaps"
    while IFS= read -r child; do
      child=$(echo "$child" | tr -d '[:space:]')
      [[ -z "$child" ]] && continue
      echo "     📄 $child"
      fetch_sitemap "$child" $(( depth + 1 ))
    done <<< "$child_urls"
  else
    echo "$body" | extract_locs | while IFS= read -r loc; do
      loc=$(echo "$loc" | tr -d '[:space:]')
      [[ -n "$loc" ]] && echo "$loc"
    done
  fi
}

# --- Cache warming ---
warm_url() {
  local url="$1"
  local index="$2"
  local total="$3"

  local start_ms
  start_ms=$(date +%s%3N 2>/dev/null || python3 -c "import time; print(int(time.time()*1000))")

  local http_code
  http_code=$(curl -sS --max-time "$TIMEOUT_SEC" \
    -A "Mozilla/5.0 (compatible; CacheWarmer/$VERSION)" \
    -L --max-redirs 5 \
    -o /dev/null \
    -w "%{http_code}" \
    "$url" 2>/dev/null) || { echo "  ❌ [$index/$total] ERROR — $url (request failed)"; return; }

  local end_ms
  end_ms=$(date +%s%3N 2>/dev/null || python3 -c "import time; print(int(time.time()*1000))")
  local elapsed_ms=$(( end_ms - start_ms ))
  local elapsed_s
  elapsed_s=$(awk "BEGIN {printf \"%.2f\", $elapsed_ms/1000}")

  local symbol="✅"
  if (( http_code >= 400 )); then
    symbol="⚠️ "
  elif (( http_code >= 300 )); then
    symbol="↪️ "
  fi

  if [[ "$VERBOSE" == "true" ]]; then
    echo "  $symbol [$index/$total] $http_code (${elapsed_ms}ms) — $url"
  else
    echo "  $symbol [$index/$total] $http_code (${elapsed_s}s) — $url"
  fi

  echo "$http_code"
}

# --- Main ---
separator
echo "  🔥 Cache Warmer $VERSION"
echo "  Started : $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Delay   : ${DELAY_MS}ms between requests"
echo "  Timeout : ${TIMEOUT_SEC}s per request"
separator

TOTAL_VISITED=0
TOTAL_SUCCESS=0
TOTAL_FAILED=0

IFS=',' read -ra SITEMAP_LIST <<< "$SITEMAPS"

for sitemap_url in "${SITEMAP_LIST[@]}"; do
  sitemap_url=$(echo "$sitemap_url" | tr -d '[:space:]')
  [[ -z "$sitemap_url" ]] && continue

  echo ""
  echo "📄 Fetching sitemap: $sitemap_url"

  mapfile -t urls < <(fetch_sitemap "$sitemap_url" 0)

  if [[ ${#urls[@]} -eq 0 ]]; then
    echo "   ❌ No URLs found or sitemap fetch failed"
    continue
  fi

  echo "   Found ${#urls[@]} URLs — warming now..."
  echo ""

  sitemap_success=0
  total=${#urls[@]}

  for i in "${!urls[@]}"; do
    url="${urls[$i]}"
    index=$(( i + 1 ))

    # warm_url prints the result line and echoes the http_code as the last line
    output=$(warm_url "$url" "$index" "$total")
    result_line=$(echo "$output" | head -n -1)
    http_code=$(echo "$output" | tail -n 1)

    echo "$result_line"

    TOTAL_VISITED=$(( TOTAL_VISITED + 1 ))
    if [[ "$http_code" =~ ^[0-9]+$ ]] && (( http_code < 400 )); then
      TOTAL_SUCCESS=$(( TOTAL_SUCCESS + 1 ))
      sitemap_success=$(( sitemap_success + 1 ))
    else
      TOTAL_FAILED=$(( TOTAL_FAILED + 1 ))
    fi

    if (( i < total - 1 )); then
      sleep "$(awk "BEGIN {printf \"%.3f\", $DELAY_MS/1000}")"
    fi
  done

  echo ""
  echo "   ✔ Sitemap complete: $sitemap_success/$total succeeded"
done

echo ""
separator
echo "  ✅ Done! $TOTAL_SUCCESS/$TOTAL_VISITED pages warmed successfully"
if (( TOTAL_FAILED > 0 )); then
  echo "  ⚠️  $TOTAL_FAILED pages failed"
fi
echo "  Finished: $(date '+%Y-%m-%d %H:%M:%S')"
separator
