// Native comparison distributor: plain Go, direct nats.go client, no WIT/
// wasmCloud SDK. Demonstrates that native NATS can answer "all H3 cells at
// time T" via a single Watch() subscription (full entries incl. values, no
// 1000-key cap, no shard fan-out needed) versus the component-based
// distributor's keys()-then-get()-per-key fan-out required to work around
// wasmcloud:nats's host-imposed cap.
package main

import (
	"encoding/json"
	"hash/fnv"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/nats-io/nats.go"
)

const bucketName = "h3-points"

type dataPoint struct {
	H3Index   string  `json:"h3Index"`
	Timestamp string  `json:"timestamp"`
	Value     float64 `json:"value"`
}

var kv nats.KeyValue

func main() {
	url := os.Getenv("NATS_URL")
	if url == "" {
		url = "nats://nats.twosix-dev.svc.cluster.local:4222"
	}
	opts := []nats.Option{}
	if caPath := os.Getenv("NATS_CA_FILE"); caPath != "" {
		opts = append(opts, nats.RootCAs(caPath))
	}
	nc, err := nats.Connect(url, opts...)
	if err != nil {
		log.Fatalf("connect to NATS: %v", err)
	}
	defer nc.Close()

	js, err := nc.JetStream()
	if err != nil {
		log.Fatalf("jetstream context: %v", err)
	}
	kv, err = js.KeyValue(bucketName)
	if err != nil {
		log.Fatalf("open bucket %s: %v", bucketName, err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /points/{h3Index}/{timestamp}", byKeyHandler)
	mux.HandleFunc("GET /points", byTimeHandler)
	log.Println("native h3 distributor listening on :8080")
	log.Fatal(http.ListenAndServe(":8080", mux))
}

// shard mirrors shardutil.Shard exactly (FNV-1a % 64) purely for by-key
// symmetry with the component-based path -- the by-time path below needs no
// shard knowledge at all, unlike the component-based reader.
func shard(h3Index string) string {
	h := fnv.New32a()
	h.Write([]byte(h3Index))
	n := h.Sum32() % 64
	const hex = "0123456789abcdef"
	return string([]byte{hex[(n>>4)&0xf], hex[n&0xf]})
}

func byKeyHandler(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	h3Index := r.PathValue("h3Index")
	timestamp := r.PathValue("timestamp")
	key := timestamp + "." + shard(h3Index) + "." + h3Index

	entry, err := kv.Get(key)
	w.Header().Set("content-type", "application/json")
	if err != nil {
		w.WriteHeader(http.StatusNotFound)
		json.NewEncoder(w).Encode(map[string]any{"error": err.Error()})
		return
	}
	var p dataPoint
	if err := json.Unmarshal(entry.Value(), &p); err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(map[string]any{"error": err.Error()})
		return
	}
	json.NewEncoder(w).Encode(map[string]any{
		"point":     p,
		"elapsedMs": time.Since(start).Milliseconds(),
	})
}

// byTimeHandler answers "all H3 cells at time T" with a single Watch()
// subscription over "<time>.>" -- no shard fan-out, no 1000-key cap, no
// per-key get() round trips. Full values are delivered directly since
// MetaOnly() is not set.
func byTimeHandler(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	timestamp := r.URL.Query().Get("timestamp")
	if timestamp == "" {
		http.Error(w, "missing required query param: timestamp", http.StatusBadRequest)
		return
	}

	watcher, err := kv.Watch(timestamp + ".>")
	w.Header().Set("content-type", "application/json")
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(map[string]any{"error": err.Error()})
		return
	}
	defer watcher.Stop()

	var points []dataPoint
	for entry := range watcher.Updates() {
		if entry == nil {
			// nil marks "caught up with initial state" -- stop draining.
			break
		}
		var p dataPoint
		if err := json.Unmarshal(entry.Value(), &p); err != nil {
			continue
		}
		points = append(points, p)
	}

	json.NewEncoder(w).Encode(map[string]any{
		"points":    points,
		"count":     len(points),
		"elapsedMs": time.Since(start).Milliseconds(),
	})
}
