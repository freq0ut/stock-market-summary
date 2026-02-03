#!/usr/bin/env bash
#
# Stock Market Summary Script
# Fetches market data, generates AI insights, and emails HTML reports
#
set -o pipefail

# Get script directory (where config files live)
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration - all files in same directory as script
config_file="$script_dir/stocksum.conf"
watchlist_file="$script_dir/watchlist.conf"
log_dir="$script_dir/logs"

# Defaults (overridden by config file)
email_to=""
email_from=""
anthropic_api_key=""

# Load config
if [[ -f "$config_file" ]]; then
  source "$config_file"
fi

# Retry settings
MAX_RETRIES=3
RETRY_DELAY=30

# Global summary variables
SUMMARY_BEST_TICKER=""
SUMMARY_BEST_TICKER_PCT=""
SUMMARY_WORST_TICKER=""
SUMMARY_WORST_TICKER_PCT=""
SUMMARY_BEST_CATEGORY=""
SUMMARY_BEST_CATEGORY_PCT=""
SUMMARY_WORST_CATEGORY=""
SUMMARY_WORST_CATEGORY_PCT=""
SUMMARY_ADVANCERS=0
SUMMARY_DECLINERS=0
SUMMARY_UNCHANGED=0
BREADTH_UP_PCT=0
BREADTH_DOWN_PCT=0
BREADTH_FLAT_PCT=0

# Temp file for HTML building
HTML_FILE=""

# Daily data file for tracking progression (open/midday/close)
DAILY_DATA_FILE=""
CURRENT_REPORT_TYPE=""

# Associative arrays for daily progression
declare -A DAILY_OPEN_AVG=()
declare -A DAILY_MIDDAY_AVG=()
declare -A DAILY_CLOSE_AVG=()
DAILY_DATA_SAVED=false

# ============================================
# Logging
# ============================================
log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S %Z')] $1"
}

log_error() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S %Z')] ERROR: $1" >&2
}

# ============================================
# US Market Holiday Detection
# ============================================
is_market_holiday() {
  local check_date="${1:-$(date +'%Y-%m-%d')}"
  local year=$(date -d "$check_date" +'%Y')

  # Helper: get observed date (Fri if Sat, Mon if Sun) - returns YYYY-MM-DD format
  get_observed() {
    local m=$1 d=$2 y=$3
    local target_date=$(printf "%04d-%02d-%02d" "$y" "$m" "$d")
    local target_dow=$(date -d "$target_date" +'%u' 2>/dev/null)
    if [[ "$target_dow" == "6" ]]; then
      date -d "$target_date -1 day" +'%Y-%m-%d'
    elif [[ "$target_dow" == "7" ]]; then
      date -d "$target_date +1 day" +'%Y-%m-%d'
    else
      echo "$target_date"
    fi
  }

  # Helper: get nth weekday of month (e.g., 3rd Monday) - returns YYYY-MM-DD format
  get_nth_weekday() {
    local n=$1 weekday=$2 m=$3 y=$4  # weekday: 1=Mon, 5=Fri
    local count=0
    for d in {1..31}; do
      local this_date=$(printf "%04d-%02d-%02d" "$y" "$m" "$d")
      local this_dow=$(date -d "$this_date" +'%u' 2>/dev/null) || continue
      if [[ "$this_dow" == "$weekday" ]]; then
        ((count++))
        if [[ $count -eq $n ]]; then
          echo "$this_date"
          return
        fi
      fi
    done
  }

  # Helper: get last weekday of month - returns YYYY-MM-DD format
  get_last_weekday() {
    local weekday=$1 m=$2 y=$3
    local last_day=$(date -d "$y-$m-01 +1 month -1 day" +'%-d')
    for ((d=last_day; d>=1; d--)); do
      local this_date=$(printf "%04d-%02d-%02d" "$y" "$m" "$d")
      local this_dow=$(date -d "$this_date" +'%u' 2>/dev/null)
      if [[ "$this_dow" == "$weekday" ]]; then
        echo "$this_date"
        return
      fi
    done
  }

  # Helper: calculate Easter Sunday (Anonymous Gregorian algorithm)
  get_easter() {
    local y=$1
    local a=$((y % 19))
    local b=$((y / 100))
    local c=$((y % 100))
    local d=$((b / 4))
    local e=$((b % 4))
    local f=$(((b + 8) / 25))
    local g=$(((b - f + 1) / 3))
    local h=$(((19 * a + b - d - g + 15) % 30))
    local i=$((c / 4))
    local k=$((c % 4))
    local l=$(((32 + 2 * e + 2 * i - h - k) % 7))
    local m=$(((a + 11 * h + 22 * l) / 451))
    local month=$(((h + l - 7 * m + 114) / 31))
    local day=$((((h + l - 7 * m + 114) % 31) + 1))
    printf "%04d-%02d-%02d" "$y" "$month" "$day"
  }

  # Build list of holidays for this year
  local holidays=()

  # New Year's Day (Jan 1, observed)
  holidays+=("$(get_observed 1 1 $year)")

  # MLK Day (3rd Monday of January)
  holidays+=("$(get_nth_weekday 3 1 1 $year)")

  # Presidents Day (3rd Monday of February)
  holidays+=("$(get_nth_weekday 3 1 2 $year)")

  # Good Friday (Friday before Easter)
  local easter=$(get_easter $year)
  holidays+=("$(date -d "$easter -2 days" +'%Y-%m-%d')")

  # Memorial Day (last Monday of May)
  holidays+=("$(get_last_weekday 1 5 $year)")

  # Juneteenth (June 19, observed)
  holidays+=("$(get_observed 6 19 $year)")

  # Independence Day (July 4, observed)
  holidays+=("$(get_observed 7 4 $year)")

  # Labor Day (1st Monday of September)
  holidays+=("$(get_nth_weekday 1 1 9 $year)")

  # Thanksgiving (4th Thursday of November)
  holidays+=("$(get_nth_weekday 4 4 11 $year)")

  # Christmas (Dec 25, observed)
  holidays+=("$(get_observed 12 25 $year)")

  # Check if today matches any holiday
  for holiday in "${holidays[@]}"; do
    if [[ "$check_date" == "$holiday" ]]; then
      return 0  # true, is a holiday
    fi
  done

  return 1  # false, not a holiday
}

get_holiday_name() {
  local check_date="${1:-$(date +'%Y-%m-%d')}"
  local year=$(date -d "$check_date" +'%Y')

  # Same helper functions with consistent YYYY-MM-DD format
  get_observed() {
    local m=$1 d=$2 y=$3
    local target_date=$(printf "%04d-%02d-%02d" "$y" "$m" "$d")
    local target_dow=$(date -d "$target_date" +'%u' 2>/dev/null)
    if [[ "$target_dow" == "6" ]]; then
      date -d "$target_date -1 day" +'%Y-%m-%d'
    elif [[ "$target_dow" == "7" ]]; then
      date -d "$target_date +1 day" +'%Y-%m-%d'
    else
      echo "$target_date"
    fi
  }

  get_nth_weekday() {
    local n=$1 weekday=$2 m=$3 y=$4
    local count=0
    for d in {1..31}; do
      local this_date=$(printf "%04d-%02d-%02d" "$y" "$m" "$d")
      local this_dow=$(date -d "$this_date" +'%u' 2>/dev/null) || continue
      if [[ "$this_dow" == "$weekday" ]]; then
        ((count++))
        [[ $count -eq $n ]] && echo "$this_date" && return
      fi
    done
  }

  get_last_weekday() {
    local weekday=$1 m=$2 y=$3
    local last_day=$(date -d "$y-$m-01 +1 month -1 day" +'%-d')
    for ((d=last_day; d>=1; d--)); do
      local this_date=$(printf "%04d-%02d-%02d" "$y" "$m" "$d")
      local this_dow=$(date -d "$this_date" +'%u' 2>/dev/null)
      [[ "$this_dow" == "$weekday" ]] && echo "$this_date" && return
    done
  }

  get_easter() {
    local y=$1
    local a=$((y % 19)) b=$((y / 100)) c=$((y % 100))
    local d=$((b / 4)) e=$((b % 4)) f=$(((b + 8) / 25))
    local g=$(((b - f + 1) / 3))
    local h=$(((19 * a + b - d - g + 15) % 30))
    local i=$((c / 4)) k=$((c % 4))
    local l=$(((32 + 2 * e + 2 * i - h - k) % 7))
    local m=$(((a + 11 * h + 22 * l) / 451))
    local month=$(((h + l - 7 * m + 114) / 31))
    local day=$((((h + l - 7 * m + 114) % 31) + 1))
    printf "%04d-%02d-%02d" "$y" "$month" "$day"
  }

  [[ "$check_date" == "$(get_observed 1 1 $year)" ]] && echo "New Year's Day" && return
  [[ "$check_date" == "$(get_nth_weekday 3 1 1 $year)" ]] && echo "MLK Day" && return
  [[ "$check_date" == "$(get_nth_weekday 3 1 2 $year)" ]] && echo "Presidents Day" && return
  local easter=$(get_easter $year)
  [[ "$check_date" == "$(date -d "$easter -2 days" +'%Y-%m-%d')" ]] && echo "Good Friday" && return
  [[ "$check_date" == "$(get_last_weekday 1 5 $year)" ]] && echo "Memorial Day" && return
  [[ "$check_date" == "$(get_observed 6 19 $year)" ]] && echo "Juneteenth" && return
  [[ "$check_date" == "$(get_observed 7 4 $year)" ]] && echo "Independence Day" && return
  [[ "$check_date" == "$(get_nth_weekday 1 1 9 $year)" ]] && echo "Labor Day" && return
  [[ "$check_date" == "$(get_nth_weekday 4 4 11 $year)" ]] && echo "Thanksgiving" && return
  [[ "$check_date" == "$(get_observed 12 25 $year)" ]] && echo "Christmas" && return
  echo "Unknown Holiday"
}

# ============================================
# HTML Helper - get color for percentage
# ============================================
get_color() {
  local pct="$1"
  local result=$(echo "$pct" | awk '{if ($1 > 0.05) print "#22c55e"; else if ($1 < -0.05) print "#ef4444"; else print "#6b7280"}')
  echo "$result"
}

# ============================================
# HTML Helper - write to file
# ============================================
html_write() {
  echo -n "$1" >> "$HTML_FILE"
}

html_line() {
  echo "$1" >> "$HTML_FILE"
}

# ============================================
# Daily Data - Load previous runs from today
# ============================================
load_daily_data() {
  DAILY_OPEN_AVG=()
  DAILY_MIDDAY_AVG=()
  DAILY_CLOSE_AVG=()

  if [[ ! -f "$DAILY_DATA_FILE" ]]; then
    return 0
  fi

  while IFS='|' read -r category report_type avg_pct; do
    [[ -z "$category" || "$category" == "#"* ]] && continue
    case "$report_type" in
      open)   DAILY_OPEN_AVG["$category"]="$avg_pct" ;;
      midday) DAILY_MIDDAY_AVG["$category"]="$avg_pct" ;;
      close)  DAILY_CLOSE_AVG["$category"]="$avg_pct" ;;
    esac
  done < "$DAILY_DATA_FILE"
}

# ============================================
# Daily Data - Save category average
# ============================================
save_category_avg() {
  local category="$1"
  local avg_pct="$2"

  # Only save on first call (build_html_report is called twice)
  if [[ "$DAILY_DATA_SAVED" == "true" ]]; then
    return 0
  fi

  # Append to daily data file
  echo "${category}|${CURRENT_REPORT_TYPE}|${avg_pct}" >> "$DAILY_DATA_FILE"
}

# ============================================
# Daily Data - Build progression HTML for category (multi-line)
# ============================================
get_category_progression_html() {
  local category="$1"
  local progression_html=""

  # Get previous values
  local open_val="${DAILY_OPEN_AVG[$category]:-}"
  local midday_val="${DAILY_MIDDAY_AVG[$category]:-}"

  case "$CURRENT_REPORT_TYPE" in
    open)
      # First report of day - no previous data
      ;;
    midday)
      # Show open if available
      if [[ -n "$open_val" ]]; then
        local open_sign=""
        [[ "${open_val:0:1}" != "-" ]] && open_sign="+"
        local open_color=$(get_color "$open_val")
        progression_html="<div style=\"font-size:13px;color:#6b7280;margin-top:4px\">Open: <span style=\"color:${open_color};font-weight:500\">${open_sign}${open_val}%</span></div>"
      fi
      ;;
    close)
      # Show midday then open (descending chronological order)
      if [[ -n "$midday_val" ]]; then
        local mid_sign=""
        [[ "${midday_val:0:1}" != "-" ]] && mid_sign="+"
        local mid_color=$(get_color "$midday_val")
        progression_html+="<div style=\"font-size:13px;color:#6b7280;margin-top:4px\">Midday: <span style=\"color:${mid_color};font-weight:500\">${mid_sign}${midday_val}%</span></div>"
      fi
      if [[ -n "$open_val" ]]; then
        local open_sign=""
        [[ "${open_val:0:1}" != "-" ]] && open_sign="+"
        local open_color=$(get_color "$open_val")
        progression_html+="<div style=\"font-size:13px;color:#6b7280;margin-top:2px\">Open: <span style=\"color:${open_color};font-weight:500\">${open_sign}${open_val}%</span></div>"
      fi
      ;;
  esac

  echo "$progression_html"
}

# ============================================
# Yahoo Finance API
# ============================================
fetch_quote() {
  local ticker="$1"
  local url="https://query1.finance.yahoo.com/v8/finance/chart/${ticker}?interval=1d&range=1d"
  local user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"

  local response
  response=$(curl -s -A "$user_agent" "$url" 2>/dev/null)

  if [[ -z "$response" || "$response" == *"Too Many Requests"* ]]; then
    echo "ERROR"
    return 1
  fi

  local price prev_close

  price=$(echo "$response" | jq -r '.chart.result[0].meta.regularMarketPrice // empty' 2>/dev/null)
  prev_close=$(echo "$response" | jq -r '.chart.result[0].meta.previousClose // .chart.result[0].meta.chartPreviousClose // empty' 2>/dev/null)

  if [[ -z "$price" || -z "$prev_close" ]]; then
    echo "ERROR"
    return 1
  fi

  local change_pct
  change_pct=$(echo "$price $prev_close" | awk '{if($2!=0) printf "%.2f", (($1 - $2) / $2) * 100; else print "0"}')

  echo "${ticker}|${price}|${change_pct}"
}

# ============================================
# Parse watchlist
# ============================================
parse_watchlist() {
  if [[ ! -f "$watchlist_file" ]]; then
    log_error "Watchlist not found: $watchlist_file"
    return 1
  fi
  grep -v '^#' "$watchlist_file" | grep -v '^$'
}

# ============================================
# Fetch all data
# ============================================
fetch_all_data() {
  local -n categories_ref=$1
  local -n data_ref=$2

  local watchlist
  watchlist=$(parse_watchlist)

  if [[ -z "$watchlist" ]]; then
    log_error "Empty watchlist"
    return 1
  fi

  while IFS=':' read -r category tickers; do
    [[ -z "$category" || -z "$tickers" ]] && continue
    categories_ref+=("$category")

    IFS=',' read -ra ticker_array <<< "$tickers"
    for ticker in "${ticker_array[@]}"; do
      ticker=$(echo "$ticker" | tr -d ' ')
      [[ -z "$ticker" ]] && continue

      log "Fetching $ticker..."
      local quote
      quote=$(fetch_quote "$ticker")

      if [[ "$quote" != "ERROR" ]]; then
        data_ref["${category}:${ticker}"]="$quote"
      else
        log_error "Failed to fetch $ticker"
      fi
      sleep 0.5
    done
  done <<< "$watchlist"
}

# ============================================
# Build HTML report (writes to HTML_FILE)
# ============================================
build_html_report() {
  local -n categories_ref=$1
  local -n data_ref=$2

  local total_up=0
  local total_down=0
  local total_unchanged=0

  local best_ticker="" best_ticker_pct=-9999
  local worst_ticker="" worst_ticker_pct=9999
  local best_category="" best_category_pct=-9999
  local worst_category="" worst_category_pct=9999

  # Start Market Overview
  cat >> "$HTML_FILE" << 'HTMLBLOCK'
<div style="margin-bottom:30px">
<h2 style="color:#1f2937;border-bottom:2px solid #3b82f6;padding-bottom:8px;margin-bottom:15px">Market Overview</h2>
<table style="border-collapse:collapse;width:100%;margin-bottom:20px">
<tr><th style="background-color:#1f2937;color:#ffffff;padding:12px 8px;text-align:left;font-size:14px">Index</th><th style="background-color:#1f2937;color:#ffffff;padding:12px 8px;text-align:left;font-size:14px">Price</th><th style="background-color:#1f2937;color:#ffffff;padding:12px 8px;text-align:left;font-size:14px">Change</th></tr>
HTMLBLOCK

  for key in "${!data_ref[@]}"; do
    if [[ "$key" == INDICES:* ]]; then
      local ticker price change_pct
      IFS='|' read -r ticker price change_pct <<< "${data_ref[$key]}"
      local sign=""
      [[ "${change_pct:0:1}" != "-" ]] && sign="+"
      local color=$(get_color "$change_pct")
      cat >> "$HTML_FILE" << HTMLROW
<tr><td style="padding:10px 8px;border-bottom:1px solid #e5e7eb;font-size:14px"><strong>${ticker}</strong></td><td style="padding:10px 8px;border-bottom:1px solid #e5e7eb;font-size:14px">\$${price}</td><td style="padding:10px 8px;border-bottom:1px solid #e5e7eb;font-size:14px"><span style="color:${color};font-weight:600">${sign}${change_pct}%</span></td></tr>
HTMLROW
    fi
  done

  cat >> "$HTML_FILE" << 'HTMLBLOCK'
</table>
</div>
<div style="margin-bottom:30px">
<h2 style="color:#1f2937;border-bottom:2px solid #3b82f6;padding-bottom:8px;margin-bottom:15px">Categories</h2>
HTMLBLOCK

  # Process each category
  for category in "${categories_ref[@]}"; do
    [[ "$category" == "INDICES" ]] && continue

    local -a cat_items=()
    local cat_total_pct=0
    local cat_count=0

    for key in "${!data_ref[@]}"; do
      if [[ "$key" == "${category}:"* ]]; then
        local ticker price change_pct
        IFS='|' read -r ticker price change_pct <<< "${data_ref[$key]}"

        cat_items+=("${change_pct}|${ticker}|${price}")
        cat_total_pct=$(echo "$cat_total_pct + $change_pct" | bc -l)
        ((cat_count++))

        # Track overall best/worst
        if (( $(echo "$change_pct > $best_ticker_pct" | bc -l) )); then
          best_ticker_pct="$change_pct"
          best_ticker="$ticker"
        fi
        if (( $(echo "$change_pct < $worst_ticker_pct" | bc -l) )); then
          worst_ticker_pct="$change_pct"
          worst_ticker="$ticker"
        fi

        # Track breadth
        if (( $(echo "$change_pct > 0.05" | bc -l) )); then
          ((total_up++))
        elif (( $(echo "$change_pct < -0.05" | bc -l) )); then
          ((total_down++))
        else
          ((total_unchanged++))
        fi
      fi
    done

    if (( cat_count > 0 )); then
      local avg_pct=$(printf "%.2f" $(echo "scale=4; $cat_total_pct / $cat_count" | bc -l))

      # Track best/worst category
      if (( $(echo "$avg_pct > $best_category_pct" | bc -l) )); then
        best_category_pct="$avg_pct"
        best_category="$category"
      fi
      if (( $(echo "$avg_pct < $worst_category_pct" | bc -l) )); then
        worst_category_pct="$avg_pct"
        worst_category="$category"
      fi

      local avg_sign=""
      [[ "${avg_pct:0:1}" != "-" && "$avg_pct" != "0"* ]] && avg_sign="+"
      [[ "$avg_pct" == "."* ]] && avg_sign="+"
      local avg_color=$(get_color "$avg_pct")

      # Save this category's average to daily data file
      save_category_avg "$category" "$avg_pct"

      # Get progression HTML from earlier today (midday, open - in descending order)
      local progression_html=$(get_category_progression_html "$category")

      cat >> "$HTML_FILE" << HTMLCAT
<div style="margin-top:20px;margin-bottom:10px">
<h3 style="color:#374151;margin:0">${category} <span style="color:${avg_color};font-weight:600">${avg_sign}${avg_pct}%</span></h3>
${progression_html}
</div>
<table style="border-collapse:collapse;width:100%;margin-bottom:20px">
<tr><th style="background-color:#1f2937;color:#ffffff;padding:12px 8px;text-align:left;font-size:14px">Ticker</th><th style="background-color:#1f2937;color:#ffffff;padding:12px 8px;text-align:left;font-size:14px">Price</th><th style="background-color:#1f2937;color:#ffffff;padding:12px 8px;text-align:left;font-size:14px">Change</th></tr>
HTMLCAT

      # Sort by change % descending and output rows
      printf '%s\n' "${cat_items[@]}" | sort -t'|' -k1 -rn | while IFS='|' read -r pct ticker price; do
        [[ -z "$ticker" ]] && continue
        local sign=""
        [[ "${pct:0:1}" != "-" ]] && sign="+"
        local color=$(get_color "$pct")
        cat >> "$HTML_FILE" << HTMLROW
<tr><td style="padding:10px 8px;border-bottom:1px solid #e5e7eb;font-size:14px">${ticker}</td><td style="padding:10px 8px;border-bottom:1px solid #e5e7eb;font-size:14px">\$${price}</td><td style="padding:10px 8px;border-bottom:1px solid #e5e7eb;font-size:14px"><span style="color:${color};font-weight:600">${sign}${pct}%</span></td></tr>
HTMLROW
      done

      echo "</table>" >> "$HTML_FILE"
    fi
  done

  echo "</div>" >> "$HTML_FILE"

  # Set global summary variables
  local best_sign="" worst_sign="" best_cat_sign="" worst_cat_sign=""
  [[ "${best_ticker_pct:0:1}" != "-" ]] && best_sign="+"
  [[ "${worst_ticker_pct:0:1}" != "-" ]] && worst_sign="+"
  [[ "${best_category_pct:0:1}" != "-" && "$best_category_pct" != "0"* ]] && best_cat_sign="+"
  [[ "${worst_category_pct:0:1}" != "-" && "$worst_category_pct" != "0"* ]] && worst_cat_sign="+"
  [[ "$best_category_pct" == "."* ]] && best_cat_sign="+"
  [[ "$worst_category_pct" == "."* ]] && worst_cat_sign="+"

  SUMMARY_BEST_TICKER="$best_ticker"
  SUMMARY_BEST_TICKER_PCT="${best_sign}${best_ticker_pct}%"
  SUMMARY_WORST_TICKER="$worst_ticker"
  SUMMARY_WORST_TICKER_PCT="${worst_sign}${worst_ticker_pct}%"
  SUMMARY_BEST_CATEGORY="$best_category"
  SUMMARY_BEST_CATEGORY_PCT="${best_cat_sign}${best_category_pct}%"
  SUMMARY_WORST_CATEGORY="$worst_category"
  SUMMARY_WORST_CATEGORY_PCT="${worst_cat_sign}${worst_category_pct}%"
  SUMMARY_ADVANCERS="$total_up"
  SUMMARY_DECLINERS="$total_down"
  SUMMARY_UNCHANGED="$total_unchanged"

  # Calculate breadth percentages for the bar
  local total_breadth=$((total_up + total_down + total_unchanged))
  if (( total_breadth > 0 )); then
    BREADTH_UP_PCT=$(printf "%.0f" $(echo "scale=2; $total_up * 100 / $total_breadth" | bc -l))
    BREADTH_DOWN_PCT=$(printf "%.0f" $(echo "scale=2; $total_down * 100 / $total_breadth" | bc -l))
    BREADTH_FLAT_PCT=$((100 - BREADTH_UP_PCT - BREADTH_DOWN_PCT))
  fi
}

# ============================================
# Build Summary HTML
# ============================================
build_summary_html() {
  cat >> "$HTML_FILE" << HTMLSUMMARY
<div style="background:linear-gradient(135deg,#1e3a5f 0%,#2d5a87 100%);color:white;padding:20px;border-radius:12px;margin-bottom:25px">
<h2 style="margin:0 0 10px 0;font-size:20px">Summary</h2>
<div style="display:grid;grid-template-columns:1fr 1fr;gap:15px;margin-top:15px">
<div style="background:rgba(255,255,255,0.1);padding:12px;border-radius:8px">
<div style="font-size:12px;opacity:0.8;margin-bottom:4px">Best Ticker</div>
<div style="font-size:16px;font-weight:600">${SUMMARY_BEST_TICKER} <span style="color:#4ade80">${SUMMARY_BEST_TICKER_PCT}</span></div>
</div>
<div style="background:rgba(255,255,255,0.1);padding:12px;border-radius:8px">
<div style="font-size:12px;opacity:0.8;margin-bottom:4px">Worst Ticker</div>
<div style="font-size:16px;font-weight:600">${SUMMARY_WORST_TICKER} <span style="color:#f87171">${SUMMARY_WORST_TICKER_PCT}</span></div>
</div>
<div style="background:rgba(255,255,255,0.1);padding:12px;border-radius:8px">
<div style="font-size:12px;opacity:0.8;margin-bottom:4px">Best Category</div>
<div style="font-size:16px;font-weight:600">${SUMMARY_BEST_CATEGORY} <span style="color:#4ade80">${SUMMARY_BEST_CATEGORY_PCT}</span></div>
</div>
<div style="background:rgba(255,255,255,0.1);padding:12px;border-radius:8px">
<div style="font-size:12px;opacity:0.8;margin-bottom:4px">Worst Category</div>
<div style="font-size:16px;font-weight:600">${SUMMARY_WORST_CATEGORY} <span style="color:#f87171">${SUMMARY_WORST_CATEGORY_PCT}</span></div>
</div>
</div>
<div style="margin-top:15px">
<div style="font-size:12px;opacity:0.8;margin-bottom:4px">Market Breadth</div>
<div style="background:#374151;border-radius:4px;height:20px;overflow:hidden;display:flex;margin-top:8px">
<div style="background:#22c55e;width:${BREADTH_UP_PCT}%;height:100%"></div>
<div style="background:#6b7280;width:${BREADTH_FLAT_PCT}%;height:100%"></div>
<div style="background:#ef4444;width:${BREADTH_DOWN_PCT}%;height:100%"></div>
</div>
<div style="font-size:12px;margin-top:5px;display:flex;justify-content:space-between">
<span style="color:#4ade80">${SUMMARY_ADVANCERS} up</span>
<span style="color:#9ca3af">${SUMMARY_UNCHANGED} flat</span>
<span style="color:#f87171">${SUMMARY_DECLINERS} down</span>
</div>
</div>
</div>
HTMLSUMMARY
}

# ============================================
# Generate AI insights
# ============================================
generate_ai_insights() {
  local market_data="$1"
  local report_type="$2"

  if [[ -z "$anthropic_api_key" ]]; then
    echo "AI insights unavailable (no API key configured)"
    return 0
  fi

  local time_context=""
  case "$report_type" in
    open)   time_context="This is the MARKET OPEN report. Focus on overnight developments and what to watch today." ;;
    midday) time_context="This is the MIDDAY report. Focus on morning momentum and sector rotation." ;;
    close)  time_context="This is the MARKET CLOSE report. Summarize the day's action and key takeaways." ;;
  esac

  local prompt="You are a concise market analyst. Analyze this data and provide insights.

${time_context}

DATA:
${market_data}

Provide analysis (150-200 words) covering:
1. Overall sentiment
2. Notable movers
3. Sector observations
4. One key insight

Be direct. Use **bold** for emphasis."

  local json_payload
  json_payload=$(jq -n \
    --arg model "claude-sonnet-4-20250514" \
    --arg prompt "$prompt" \
    '{model: $model, max_tokens: 500, messages: [{role: "user", content: $prompt}]}')

  local response
  response=$(curl -s --max-time 30 \
    "https://api.anthropic.com/v1/messages" \
    -H "x-api-key: ${anthropic_api_key}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "$json_payload" 2>/dev/null)

  if [[ -z "$response" ]]; then
    echo "AI insights unavailable (API request failed)"
    return 0
  fi

  local content
  content=$(echo "$response" | jq -r '.content[0].text // empty' 2>/dev/null)

  if [[ -n "$content" ]]; then
    echo "$content" | sed 's/\*\*\([^*]*\)\*\*/<strong>\1<\/strong>/g'
  else
    echo "AI insights unavailable"
  fi
}

# ============================================
# Send HTML email
# ============================================
send_email() {
  local subject="$1"
  local body="$2"

  if [[ -z "$email_to" ]]; then
    log_error "No email recipient configured"
    return 1
  fi

  # Convert comma-separated emails to space-separated for msmtp
  local recipients="${email_to//,/ }"

  msmtp -a gmail $recipients << MAIL
From: $email_from
To: $email_to
Subject: $subject
MIME-Version: 1.0
Content-Type: text/html; charset=UTF-8

$body
MAIL
}

# ============================================
# Main function
# ============================================
run_summary() {
  local report_type="${1:-close}"
  local test_mode="${2:-false}"

  local ts="$(date +'%Y-%m-%d_%H%M%S')"
  local ts_display="$(date +'%Y-%m-%d %H:%M %Z')"

  # Check for market holidays (skip unless test mode)
  if [[ "$report_type" != "test" ]] && is_market_holiday; then
    local holiday_name=$(get_holiday_name)
    log "Market closed for $holiday_name - skipping report"
    exit 0
  fi

  case "$report_type" in
    open|midday|close|test) ;;
    *)
      log_error "Invalid report type: $report_type"
      exit 1
      ;;
  esac

  if [[ "$report_type" == "test" ]]; then
    test_mode="true"
    report_type="close"
  fi

  mkdir -p "$log_dir" 2>/dev/null || true
  local log_file="${log_dir}/run_${ts}.log"

  # Initialize daily data file for progression tracking
  local today=$(date +'%Y-%m-%d')
  DAILY_DATA_FILE="${log_dir}/daily_${today}.dat"
  CURRENT_REPORT_TYPE="$report_type"

  # Load any existing data from earlier today
  load_daily_data

  if [[ "$test_mode" != "true" ]]; then
    exec > >(tee -a "$log_file") 2>&1
  fi

  log "Stock Summary Started - Type: $report_type"

  if [[ ! -f "$watchlist_file" ]]; then
    log_error "Watchlist not found: $watchlist_file"
    exit 1
  fi

  declare -a categories=()
  declare -A market_data=()

  log "Fetching market data..."
  if ! fetch_all_data categories market_data; then
    log_error "Failed to fetch market data"
    exit 1
  fi

  # Create temp file for HTML
  HTML_FILE=$(mktemp)
  trap "rm -f $HTML_FILE" EXIT

  log "Building report..."
  DAILY_DATA_SAVED=false
  build_html_report categories market_data
  DAILY_DATA_SAVED=true

  log "Generating AI insights..."
  local plain_data=""
  for key in "${!market_data[@]}"; do
    IFS='|' read -r ticker price pct <<< "${market_data[$key]}"
    plain_data+="${key}: \$${price} (${pct}%)"$'\n'
  done

  local ai_insights
  ai_insights=$(generate_ai_insights "$plain_data" "$report_type")
  local ai_html=$(echo "$ai_insights" | sed 's/$/<br>/g')

  # Build summary HTML (needs global vars set by build_html_report)
  local summary_file=$(mktemp)
  HTML_FILE="$summary_file"
  build_summary_html
  local summary_html=$(cat "$summary_file")
  rm -f "$summary_file"

  # Read report HTML
  HTML_FILE=$(mktemp)
  build_html_report categories market_data
  local report_html=$(cat "$HTML_FILE")
  rm -f "$HTML_FILE"

  # Build full email
  local full_html="<!DOCTYPE html>
<html>
<head><meta charset=\"UTF-8\"></head>
<body style=\"margin:0;padding:20px;background-color:#f3f4f6;font-family:Arial,sans-serif\">
<div style=\"max-width:800px;margin:0 auto;background:white;border-radius:12px;overflow:hidden;box-shadow:0 4px 6px rgba(0,0,0,0.1)\">
<div style=\"background:linear-gradient(135deg,#1e40af 0%,#3b82f6 100%);color:white;padding:25px;text-align:center\">
<h1 style=\"margin:0;font-size:24px\">Stock Market Summary</h1>
<p style=\"margin:8px 0 0 0;opacity:0.9\">${report_type^^} Report - ${ts_display}</p>
</div>
<div style=\"padding:25px\">
${summary_html}
${report_html}
<div style=\"background:#f8fafc;border-left:4px solid #3b82f6;padding:20px;margin-top:25px;border-radius:0 8px 8px 0\">
<h2 style=\"color:#1e40af;margin:0 0 15px 0;font-size:18px\">AI Insights</h2>
<div style=\"color:#374151;line-height:1.6\">${ai_html}</div>
</div>
</div>
<div style=\"background:#1f2937;color:#9ca3af;padding:15px;text-align:center;font-size:12px\">
Generated: ${ts_display}
</div>
</div>
</body>
</html>"

  # Build subject line: [Stocks]: Day-of-week Report-type
  local day_of_week=$(date +'%A')
  local report_label=""
  case "$CURRENT_REPORT_TYPE" in
    open)   report_label="Open" ;;
    midday) report_label="Mid-day" ;;
    close)  report_label="Close" ;;
    *)      report_label="${CURRENT_REPORT_TYPE^}" ;;
  esac

  local subject="[Stocks]: ${day_of_week} ${report_label}"

  if [[ "$test_mode" == "true" ]]; then
    echo "=========================================="
    echo "TEST MODE"
    echo "=========================================="
    echo "To: $email_to"
    echo "Subject: $subject"
    echo ""
    echo "Summary:"
    echo "  Best Ticker: ${SUMMARY_BEST_TICKER} ${SUMMARY_BEST_TICKER_PCT}"
    echo "  Worst Ticker: ${SUMMARY_WORST_TICKER} ${SUMMARY_WORST_TICKER_PCT}"
    echo "  Best Category: ${SUMMARY_BEST_CATEGORY} ${SUMMARY_BEST_CATEGORY_PCT}"
    echo "  Worst Category: ${SUMMARY_WORST_CATEGORY} ${SUMMARY_WORST_CATEGORY_PCT}"
    echo "  Breadth: ${SUMMARY_ADVANCERS} up / ${SUMMARY_DECLINERS} down / ${SUMMARY_UNCHANGED} flat"
    echo ""
    echo "AI Insights:"
    echo "$ai_insights"
    echo "=========================================="
  else
    log "Sending email..."
    if send_email "$subject" "$full_html"; then
      log "Email sent to: $email_to"
      log "Summary complete"
    else
      log_error "Failed to send email"
    fi
  fi
}

# ============================================
# Entry point
# ============================================
main() {
  local report_type="${1:-close}"
  local attempt=1

  while (( attempt <= MAX_RETRIES )); do
    if [[ "$report_type" == "test" ]]; then
      run_summary "$report_type"
      exit $?
    fi

    if run_summary "$report_type"; then
      exit 0
    else
      log_error "Attempt $attempt failed"
      if (( attempt < MAX_RETRIES )); then
        log "Retrying in $RETRY_DELAY seconds..."
        sleep $RETRY_DELAY
      fi
    fi
    ((attempt++))
  done

  log_error "All retry attempts failed"
  exit 1
}

main "$@"
