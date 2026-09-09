#!/usr/bin/env bash
# Bulk-read load test: "retrieve a ton of objects" via the h3-distribute
# gateway's GET /points?timestamp=... (component-based, keys()-fan-out then
# get()-per-key under the hood) and, if NATIVE_URL is set, the native Go
# comparison distributor's identical query (single Watch() subscription,
# no shard fan-out) -- printed as a single side-by-side comparison table.
#
# Also runs a bulk by-key sample against both, to characterize the O(1)
# point-lookup path separately from the bulk scan path.
#
# Usage: ./load-query.sh TIMESTAMP [BY_KEY_SAMPLE_SIZE]
#   TIMESTAMP            required -- the timestamp written by load-ingest.sh
#   BY_KEY_SAMPLE_SIZE   default 200 -- how many individual by-key GETs to
#                        sample for the point-lookup latency distribution
#   NATIVE_URL           optional -- base URL of an already-running native
#                        distributor tunnel. If unset, this script starts
#                        its own `kubectl port-forward svc/h3-native-distributor`
#                        automatically (on a kubectl-chosen free local port)
#                        and tears it down on exit. Set NATIVE_URL yourself
#                        only if you already have a tunnel up, are pointing
#                        at a non-Kubernetes deployment of the native
#                        distributor, or want to force-skip native
#                        comparison (NATIVE_URL= ./load-query.sh ...).

# ./load-ingest.sh 40000 500
# ./load-query.sh
# ./load-cleanup.sh --all

set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

TIMESTAMP="${1:?usage: load-query.sh TIMESTAMP [BY_KEY_SAMPLE_SIZE]}"
BY_KEY_SAMPLE_SIZE="${2:-200}"

PORT_FORWARD_PID=""
cleanup() { [[ -n "$PORT_FORWARD_PID" ]] && kill "$PORT_FORWARD_PID" 2>/dev/null; }
trap cleanup EXIT

if [[ -z "${NATIVE_URL:-}" ]]; then
  pf_log=$(mktemp)
  kubectl -n twosix-dev port-forward svc/h3-native-distributor :8080 >"$pf_log" 2>&1 &
  PORT_FORWARD_PID=$!
  # Wait up to 10s for kubectl to report the port it picked and actually be ready.
  for _ in $(seq 1 50); do
    if port=$(grep -oE 'Forwarding from 127\.0\.0\.1:[0-9]+' "$pf_log" 2>/dev/null | head -1 | grep -oE '[0-9]+$'); then
      [[ -n "$port" ]] && break
    fi
    kill -0 "$PORT_FORWARD_PID" 2>/dev/null || break  # port-forward already died
    sleep 0.2
  done
  if [[ -n "${port:-}" ]] && curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${port}/points?timestamp=0000.00.00.00.00" ; then
    NATIVE_URL="http://127.0.0.1:${port}"
  else
    echo "note: couldn't auto-start a tunnel to h3-native-distributor (see $pf_log) -- proceeding without native comparison" >&2
    kill "$PORT_FORWARD_PID" 2>/dev/null; PORT_FORWARD_PID=""
  fi
  rm -f "$pf_log"
fi
HAVE_NATIVE=0; [[ -n "${NATIVE_URL:-}" ]] && HAVE_NATIVE=1

# nat_or_na VALUE -- VALUE if native comparison is enabled, else "n/a".
nat_or_na() { if (( HAVE_NATIVE )); then echo "$1"; else echo "n/a"; fi }
# nat_ratio COMPONENT NATIVE -- ratio_str if native comparison is enabled, else "-".
nat_ratio() { if (( HAVE_NATIVE )); then ratio_str "$1" "$2"; else echo "-"; fi }

echo "=== H3 Read Load Test ==="
echo "timestamp:      $TIMESTAMP"
echo "by-key samples: $BY_KEY_SAMPLE_SIZE"
if (( HAVE_NATIVE )); then
  echo "native compare: $NATIVE_URL"
else
  echo "native compare: not set -- export NATIVE_URL after"
  echo "                'kubectl -n twosix-dev port-forward svc/h3-native-distributor 18080:8080 &'"
  echo "                for a side-by-side comparison"
fi
echo ""

# ---- bulk scan: component ----
comp_start=$(now_ms)
comp_http=$(curl_distribute "/points?timestamp=${TIMESTAMP}" -o /tmp/h3-load-query-component.json -w '%{http_code}')
comp_wall=$(( $(now_ms) - comp_start ))
comp_size=$(wc -c </tmp/h3-load-query-component.json | tr -d ' ')
if [[ "$comp_http" == "200" ]]; then
  comp_count=$(read_json_field /tmp/h3-load-query-component.json count)
  if [[ "$comp_count" == "PARSE_ERROR" ]]; then
    comp_status="TRUNCATED (${comp_size}b, invalid JSON)"
    comp_count="-"; comp_server="-"
    comp_body_preview=$(tail -c 150 /tmp/h3-load-query-component.json 2>/dev/null)
  else
    comp_status="200 OK"
    comp_server=$(read_json_field /tmp/h3-load-query-component.json elapsedMs)
  fi
else
  comp_status="FAILED (HTTP $comp_http)"
  comp_count="-"; comp_server="-"
  comp_body_preview=$(head -c 200 /tmp/h3-load-query-component.json 2>/dev/null)
fi

# ---- bulk scan: native ----
nat_status="n/a"; nat_count="-"; nat_server="-"; nat_wall="-"
if (( HAVE_NATIVE )); then
  nat_start=$(now_ms)
  nat_http=$(curl -s "${NATIVE_URL}/points?timestamp=${TIMESTAMP}" -o /tmp/h3-load-query-native.json -w '%{http_code}')
  nat_wall=$(( $(now_ms) - nat_start ))
  nat_size=$(wc -c </tmp/h3-load-query-native.json | tr -d ' ')
  if [[ "$nat_http" == "200" ]]; then
    nat_count=$(read_json_field /tmp/h3-load-query-native.json count)
    if [[ "$nat_count" == "PARSE_ERROR" ]]; then
      nat_status="TRUNCATED (${nat_size}b, invalid JSON)"
      nat_count="-"; nat_server="-"
      nat_body_preview=$(tail -c 150 /tmp/h3-load-query-native.json 2>/dev/null)
    else
      nat_status="200 OK"
      nat_server=$(read_json_field /tmp/h3-load-query-native.json elapsedMs)
    fi
  else
    nat_status="FAILED (HTTP $nat_http)"
    nat_body_preview=$(head -c 200 /tmp/h3-load-query-native.json 2>/dev/null)
  fi
fi

echo "BULK SCAN -- GET /points?timestamp=$TIMESTAMP"
table_header "Metric"
table_row "Status" "$comp_status" "$nat_status" ""
table_row "Response size (bytes)" "$comp_size" "$(nat_or_na "${nat_size:--}")" ""
table_row "Points returned" "$comp_count" "$(nat_or_na "$nat_count")" ""
table_row "Server time (ms)" "$comp_server" "$(nat_or_na "$nat_server")" "$(nat_ratio "$comp_server" "$nat_server")"
table_row "Wall time (ms)" "$comp_wall" "$(nat_or_na "$nat_wall")" "$(nat_ratio "$comp_wall" "$nat_wall")"
echo ""
comp_bad=0; [[ "$comp_count" == "-" ]] && comp_bad=1
nat_bad=0; (( HAVE_NATIVE )) && [[ "$nat_count" == "-" ]] && nat_bad=1
if (( comp_bad )); then echo "  component body preview (tail): ${comp_body_preview:-<empty>}"; fi
if (( nat_bad )); then echo "  native body preview (tail): ${nat_body_preview:-<empty>}"; fi
if (( comp_bad )) || (( nat_bad )); then
  echo "  (check 'kubectl -n twosix-dev logs deploy/hostgroup-h3' for host-side errors --"
  echo "   HTTP 200 with an unparseable body usually means the response was silently"
  echo "   truncated at a fixed size cap, not a crash)"
  echo ""
fi

# ---- by-key sample: component ----
comp_ms_values=""
base=0; d1=0; d2=0; d3=0
for ((i = 0; i < BY_KEY_SAMPLE_SIZE; i++)); do
  h3=$(gen_h3 "$base" "$d1" "$d2" "$d3")
  t=$(curl_distribute "/points/${h3}/${TIMESTAMP}" -o /dev/null -w '%{time_total}')
  comp_ms_values+=" $(awk -v t="$t" 'BEGIN{printf "%.1f", t*1000}')"
  d3=$((d3 + 1)); if (( d3 > 6 )); then d3=0; d2=$((d2 + 1)); fi
  if (( d2 > 6 )); then d2=0; d1=$((d1 + 1)); fi
  if (( d1 > 6 )); then d1=0; base=$((base + 1)); fi
done
read -r comp_min comp_p50 comp_p95 comp_max comp_mean comp_n <<<"$(stats_ms_fields "$comp_ms_values")"

# ---- by-key sample: native ----
nat_min="-"; nat_p50="-"; nat_p95="-"; nat_max="-"; nat_mean="-"
if (( HAVE_NATIVE )); then
  native_ms_values=""
  base=0; d1=0; d2=0; d3=0
  for ((i = 0; i < BY_KEY_SAMPLE_SIZE; i++)); do
    h3=$(gen_h3 "$base" "$d1" "$d2" "$d3")
    t=$(curl -s "${NATIVE_URL}/points/${h3}/${TIMESTAMP}" -o /dev/null -w '%{time_total}')
    native_ms_values+=" $(awk -v t="$t" 'BEGIN{printf "%.1f", t*1000}')"
    d3=$((d3 + 1)); if (( d3 > 6 )); then d3=0; d2=$((d2 + 1)); fi
    if (( d2 > 6 )); then d2=0; d1=$((d1 + 1)); fi
    if (( d1 > 6 )); then d1=0; base=$((base + 1)); fi
  done
  read -r nat_min nat_p50 nat_p95 nat_max nat_mean nat_n <<<"$(stats_ms_fields "$native_ms_values")"
fi

echo "BY-KEY LOOKUPS (n=$comp_n sample) -- GET /points/{h3Index}/{timestamp}"
table_header "Metric"
table_row "min (ms)"  "$comp_min"  "$(nat_or_na "$nat_min")"  "$(nat_ratio "$comp_min" "$nat_min")"
table_row "p50 (ms)"  "$comp_p50"  "$(nat_or_na "$nat_p50")"  "$(nat_ratio "$comp_p50" "$nat_p50")"
table_row "p95 (ms)"  "$comp_p95"  "$(nat_or_na "$nat_p95")"  "$(nat_ratio "$comp_p95" "$nat_p95")"
table_row "max (ms)"  "$comp_max"  "$(nat_or_na "$nat_max")"  "$(nat_ratio "$comp_max" "$nat_max")"
table_row "mean (ms)" "$comp_mean" "$(nat_or_na "$nat_mean")" "$(nat_ratio "$comp_mean" "$nat_mean")"
