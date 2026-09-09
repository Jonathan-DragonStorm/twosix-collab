#!/usr/bin/env bash
# Shared helpers for the h3-load-test scripts. Source, don't execute.
#
# All requests go through 127.0.0.1 with an explicit Host header, matching
# how this whole session's dev cluster has been reached (no /etc/hosts
# write access in this environment) -- the Traefik NodePort mapping to host
# port 80 still applies unchanged if /etc/hosts *is* writable in your
# environment; just drop the -H "Host: ..." and hit the real hostname.
INGEST_HOST="${INGEST_HOST:-h3-ingest.localhost.cosmonic.sh}"
DISTRIBUTE_HOST="${DISTRIBUTE_HOST:-h3-distribute.localhost.cosmonic.sh}"
BASE_URL="${BASE_URL:-http://127.0.0.1}"
NATIVE_URL="${NATIVE_URL:-}" # set via kubectl port-forward svc/h3-native-distributor <port>:8080; empty skips native comparison

# curl_ingest PATH [extra curl args...] -- PATH is appended to BASE_URL, e.g.
# curl_ingest /ingest -X POST -d "$body"
curl_ingest() {
  local path=$1; shift
  curl -s -H "Host: ${INGEST_HOST}" "$@" "${BASE_URL}${path}"
}
curl_distribute() {
  local path=$1; shift
  curl -s -H "Host: ${DISTRIBUTE_HOST}" "$@" "${BASE_URL}${path}"
}

# gen_h3 BASE_CELL D1 D2 D3 -- prints a syntactically valid resolution-3 H3
# index (15 hex chars), matching h3fmt.Generate's bit layout exactly:
# mode=1 (bits 59-62), resolution=3 (bits 52-55), base cell (bits 45-51,
# 0-121), three resolution-path digits (bits 36-44, each 0-6), digits
# beyond the resolution fixed at the "unused" marker 7 (bits 0-35, all 1s
# since three 7s in a row is 36 ones = 0xFFFFFFFFF).
gen_h3() {
  local base=$1 d1=$2 d2=$3 d3=$4
  local v=$(( (1<<59) | (3<<52) | ((base & 127) << 45) | ((d1 & 7) << 42) | ((d2 & 7) << 39) | ((d3 & 7) << 36) | 0xFFFFFFFFF ))
  printf '%015x' "$v"
}

# now_ms -- current epoch time in milliseconds, for wall-clock spans.
# `date +%s%3N` is GNU-only (BSD/macOS date has no %N) -- python3 is
# portable across both and already used elsewhere in these scripts.
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

# fmt_rate COUNT ELAPSED_MS LABEL -- prints "COUNT LABEL in X.XXXs (Y.Y LABEL/s)".
fmt_rate() {
  local count=$1 elapsed_ms=$2 label=$3
  awk -v c="$count" -v ms="$elapsed_ms" -v l="$label" 'BEGIN {
    s = ms / 1000.0
    rate = (s > 0) ? c / s : 0
    printf "%d %s in %.3fs (%.1f %s/s)\n", c, l, s, rate, l
  }'
}

# stats_ms "v1 v2 v3 ..." -- prints min/p50/p95/max/mean over a whitespace-
# separated list of millisecond values (e.g. per-request curl timings).
# Sorts externally via `sort -n` rather than an awk-internal sort, since
# BSD awk (macOS default) has no asort().
stats_ms() {
  tr ' ' '\n' <<<"$1" | grep -v '^$' | sort -n | awk '{
    a[NR] = $1
    sum += $1
    n = NR
  } END {
    p50 = a[int(n * 0.50) < 1 ? 1 : int(n * 0.50)]
    p95 = a[int(n * 0.95) < 1 ? 1 : int(n * 0.95)]
    printf "min=%.1fms p50=%.1fms p95=%.1fms max=%.1fms mean=%.1fms (n=%d)\n", a[1], p50, p95, a[n], sum/n, n
  }'
}

# stats_ms_fields "v1 v2 ..." -- like stats_ms but prints just the raw
# numbers "min p50 p95 max mean n", for building comparison tables.
stats_ms_fields() {
  tr ' ' '\n' <<<"$1" | grep -v '^$' | sort -n | awk '{
    a[NR] = $1
    sum += $1
    n = NR
  } END {
    p50 = a[int(n * 0.50) < 1 ? 1 : int(n * 0.50)]
    p95 = a[int(n * 0.95) < 1 ? 1 : int(n * 0.95)]
    printf "%.1f %.1f %.1f %.1f %.1f %d\n", a[1], p50, p95, a[n], sum/n, n
  }'
}

# read_json_field FILE FIELD -- prints the field's value from a JSON file,
# or "PARSE_ERROR" (stderr gets the detail) if the body isn't valid JSON --
# e.g. a response silently truncated at a fixed byte-size cap still returns
# HTTP 200, but the body is cut off mid-object and won't parse.
read_json_field() {
  python3 -c "
import json, sys
try:
    d = json.load(open('$1'))
    print(d.get('$2', ''))
except json.JSONDecodeError as e:
    print('PARSE_ERROR', file=sys.stderr)
    print(str(e), file=sys.stderr)
    sys.exit(1)
" 2>/tmp/h3-load-query-parse-error.txt || echo "PARSE_ERROR"
}

# ratio_str COMPONENT_VAL NATIVE_VAL -- "N.Nx slower"/"N.Nx faster" for the
# component value relative to native, or "-" if either side is missing/zero.
ratio_str() {
  local c=$1 n=$2
  if [[ -z "$c" || -z "$n" || "$c" == "-" || "$n" == "-" ]]; then echo "-"; return; fi
  awk -v c="$c" -v n="$n" 'BEGIN {
    if (n == 0) { print "-"; exit }
    r = c / n
    if (r >= 1) printf "%.1fx slower\n", r
    else printf "%.1fx faster\n", 1/r
  }'
}

TABLE_FMT="  %-22s %-19s %-19s %-14s\n"
table_header() { printf "$TABLE_FMT" "$1" "Component-based" "Native" "Difference"; printf "  %s\n" "$(printf -- '-%.0s' {1..76})"; }
table_row() { printf "$TABLE_FMT" "$1" "$2" "$3" "$4"; }

# Generic two-column label/value table, for results with no side-by-side
# comparison target (e.g. the ingest load test's own summary stats).
KV_TABLE_FMT="  %-28s %s\n"
kv_table_header() { printf "$KV_TABLE_FMT" "Metric" "Value"; printf "  %s\n" "$(printf -- '-%.0s' {1..70})"; }
kv_table_row() { printf "$KV_TABLE_FMT" "$1" "$2"; }
