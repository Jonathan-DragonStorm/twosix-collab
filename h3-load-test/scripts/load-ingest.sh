#!/usr/bin/env bash
# Bulk-write load test: "drop a ton of objects" via POST /ingest on the
# h3-ingest gateway, batched, timing both the client-observed wall time and
# the server-reported elapsedMs per batch.
#
# Usage: ./load-ingest.sh [TOTAL_POINTS] [BATCH_SIZE] [TIMESTAMP]
#   TOTAL_POINTS  default 40000 (matches the strategy doc's ~40k H3 res-3
#                 cell target; capped at 121*7*7*7=41,846 distinct synthetic
#                 indices this generator can produce)
#   BATCH_SIZE    default 500 (points per POST /ingest request)
#   TIMESTAMP     default current UTC minute, YYYY.MM.DD.HH.mm

# ./load-ingest.sh 40000 500
# ./load-query.sh
# ./load-cleanup.sh --all

set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

TOTAL_POINTS="${1:-40000}"
BATCH_SIZE="${2:-500}"
TIMESTAMP="${3:-$(date -u +%Y.%m.%d.%H.%M)}"
MAX_DISTINCT=$((122 * 7 * 7 * 7))

if (( TOTAL_POINTS > MAX_DISTINCT )); then
  echo "TOTAL_POINTS=$TOTAL_POINTS exceeds the $MAX_DISTINCT distinct synthetic H3 indices this generator can produce; capping." >&2
  TOTAL_POINTS=$MAX_DISTINCT
fi

total_batches=$(( (TOTAL_POINTS + BATCH_SIZE - 1) / BATCH_SIZE ))

echo "=== H3 Write Load Test ==="
echo "target points: $TOTAL_POINTS"
echo "batch size:    $BATCH_SIZE"
echo "timestamp:     $TIMESTAMP"
echo ""

server_ms_values=""
client_s_values=""
generated=0
batch_num=0
start_ms=$(now_ms)

base=0; d1=0; d2=0; d3=0
while (( generated < TOTAL_POINTS )); do
  this_batch=$(( TOTAL_POINTS - generated < BATCH_SIZE ? TOTAL_POINTS - generated : BATCH_SIZE ))
  batch_num=$((batch_num + 1))

  # Build the batch JSON body.
  body='{"points":['
  first=1
  for ((i = 0; i < this_batch; i++)); do
    h3=$(gen_h3 "$base" "$d1" "$d2" "$d3")
    value=$(( (base * 49) + (d1 * 7 * 7) + (d2 * 7) + d3 ))  # deterministic, not random -- reproducible runs
    if (( first )); then first=0; else body+=','; fi
    body+="{\"h3Index\":\"${h3}\",\"timestamp\":\"${TIMESTAMP}\",\"value\":${value}}"

    d3=$((d3 + 1)); if (( d3 > 6 )); then d3=0; d2=$((d2 + 1)); fi
    if (( d2 > 6 )); then d2=0; d1=$((d1 + 1)); fi
    if (( d1 > 6 )); then d1=0; base=$((base + 1)); fi
  done
  body+=']}'

  resp=$(curl_ingest /ingest -X POST -H "Content-Type: application/json" \
    --data-binary "$body" -w '\n%{time_total}' 2>/dev/null || true)
  # Split the response body (JSON) from the trailing curl timing line.
  client_s=$(tail -n1 <<<"$resp")
  json=$(sed '$d' <<<"$resp")
  server_ms=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('elapsedMs', -1))" <<<"$json" 2>/dev/null || echo -1)

  server_ms_values+=" $server_ms"
  client_s_values+=" $client_s"
  generated=$((generated + this_batch))

  if (( batch_num % 10 == 0 || generated >= TOTAL_POINTS )); then
    printf "  batch %3d/%-3d  %6d/%-6d points  last batch: %sms\n" \
      "$batch_num" "$total_batches" "$generated" "$TOTAL_POINTS" "$server_ms"
  fi
done

end_ms=$(now_ms)
total_elapsed_ms=$((end_ms - start_ms))
client_ms_values=$(awk '{for(i=1;i<=NF;i++) printf "%.1f ", $i*1000}' <<<"$client_s_values")

echo ""
echo "RESULTS"
kv_table_header
kv_table_row "Total points ingested" "$generated"
kv_table_row "Batches" "$batch_num (batch size $BATCH_SIZE)"
kv_table_row "Total wall time" "$(awk -v ms="$total_elapsed_ms" 'BEGIN{printf "%.3fs", ms/1000}')"
kv_table_row "Throughput" "$(awk -v c="$generated" -v ms="$total_elapsed_ms" 'BEGIN{printf "%.1f points/s", c/(ms/1000)}')"
kv_table_row "Per-batch server time" "$(stats_ms "$server_ms_values")"
kv_table_row "Per-batch client time" "$(stats_ms "$client_ms_values")"
echo ""
echo "Data ingested at timestamp=$TIMESTAMP -- use load-query.sh $TIMESTAMP to read it back."
