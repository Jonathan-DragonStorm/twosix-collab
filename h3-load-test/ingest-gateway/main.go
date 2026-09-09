package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	witTypes "go.bytecodealliance.org/pkg/wit/types"

	"go.bytecodealliance.org/pkg/wasihttp"

	"h3ingestgw/h3_pipeline_ingest"
	"h3ingestgw/h3_pipeline_types"
)

// maxResponseBodyBytes is a conservative margin under the ~1MiB
// (1,048,576 byte) response-body cap confirmed this session on the
// wasmCloud host's wasi:http outgoing-body stream (verified: not Envoy,
// not our own SDK's response writer -- which genuinely streams via a real
// wasi:http v0.3 StreamWriter, no internal buffering -- and not
// configurable via any control-host flag, per `control-host --help`).
// Ingest/delete responses here are always tiny (a count + elapsedMs), so
// this guard is defense-in-depth rather than something expected to fire,
// but it keeps this component consistent with distribute-gateway.
const maxResponseBodyBytes = 1_000_000

// writeJSON encodes data to a buffer first (never partially written on
// error), and refuses to write a response likely to hit the host's body
// cap, returning a clear error instead of letting it truncate silently.
func writeJSON(w http.ResponseWriter, status int, data any) {
	body, err := json.Marshal(data)
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(map[string]any{"error": "encode response: " + err.Error()})
		return
	}
	if len(body) > maxResponseBodyBytes {
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(map[string]any{
			"error": fmt.Sprintf(
				"response too large: %d bytes exceeds this host's ~1MiB response-body limit "+
					"(confirmed non-configurable in Cosmonic Control 0.10.0)",
				len(body)),
		})
		return
	}
	w.WriteHeader(status)
	if _, err := w.Write(body); err != nil {
		_ = err // headers/status already sent; nothing more to tell the client
	}
}

type pointJSON struct {
	H3Index   string  `json:"h3Index"`
	Timestamp string  `json:"timestamp"`
	Value     float64 `json:"value"`
}

type ingestRequest struct {
	Points []pointJSON `json:"points"`
}

func init() {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /ingest", ingestHandler)
	mux.HandleFunc("DELETE /points/{h3Index}/{timestamp}", deleteByKeyHandler)
	mux.HandleFunc("DELETE /points", deleteByTimeOrAllHandler)
	mux.HandleFunc("GET /openapi.json", openapiHandler)
	mux.HandleFunc("GET /docs", swaggerHandler)
	wasihttp.Handle(mux)
}

func ingestHandler(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	var req ingestRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid JSON body: "+err.Error(), http.StatusBadRequest)
		return
	}

	points := make([]h3_pipeline_types.DataPoint, len(req.Points))
	for i, p := range req.Points {
		points[i] = h3_pipeline_types.DataPoint{H3Index: p.H3Index, Timestamp: p.Timestamp, Value: p.Value}
	}

	result := h3_pipeline_ingest.IngestBatch(points)
	w.Header().Set("content-type", "application/json")
	if result.IsErr() {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": result.Err()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ingested":  result.Ok(),
		"elapsedMs": time.Since(start).Milliseconds(),
	})
}

func deleteByKeyHandler(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	h3Index := r.PathValue("h3Index")
	timestamp := r.PathValue("timestamp")

	result := h3_pipeline_ingest.DeleteByKey(h3Index, timestamp)
	w.Header().Set("content-type", "application/json")
	if result.IsErr() {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": result.Err()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"deleted":   true,
		"elapsedMs": time.Since(start).Milliseconds(),
	})
}

// deleteByTimeOrAllHandler answers DELETE /points -- with a `timestamp`
// query param it deletes every point at that timestamp; without one it
// deletes everything in the bucket. Same disambiguation-by-query-param
// pattern the distribute-gateway's GET /points would use for a hypothetical
// "all timestamps" mode.
func deleteByTimeOrAllHandler(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	timestamp := strings.TrimSpace(r.URL.Query().Get("timestamp"))

	var result witTypes.Result[uint32, string]
	if timestamp != "" {
		result = h3_pipeline_ingest.DeleteByTime(timestamp)
	} else {
		result = h3_pipeline_ingest.DeleteAll()
	}

	w.Header().Set("content-type", "application/json")
	if result.IsErr() {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": result.Err()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"deleted":   result.Ok(),
		"elapsedMs": time.Since(start).Milliseconds(),
	})
}

const openapiSpec = `{
  "openapi": "3.0.3",
  "info": {"title": "H3 Ingest Gateway", "version": "0.1.0"},
  "paths": {
    "/ingest": {
      "post": {
        "summary": "Batch-ingest H3 data points",
        "requestBody": {
          "required": true,
          "content": {"application/json": {"schema": {
            "type": "object",
            "properties": {"points": {"type": "array", "items": {
              "type": "object",
              "properties": {
                "h3Index": {"type": "string", "description": "15-character hex H3 index string, resolution 3.", "default": "831453fffffffff", "example": "831453fffffffff"},
                "timestamp": {"type": "string", "description": "Time bucket key: YYYY.MM.DD.HH.mm, zero-padded, dot-separated, UTC (no timezone offset). Matches the NATS KV key's time-token prefix exactly.", "pattern": "^\\d{4}\\.\\d{2}\\.\\d{2}\\.\\d{2}\\.\\d{2}$", "default": "2026.09.09.03.00", "example": "2026.09.09.03.00"},
                "value": {"type": "number", "default": 1.5, "example": 1.5}
              },
              "required": ["h3Index", "timestamp", "value"]
            }}}
          }}}
        },
        "responses": {"200": {"description": "OK"}}
      }
    },
    "/points/{h3Index}/{timestamp}": {
      "delete": {
        "summary": "Delete one point by key",
        "parameters": [
          {"name": "h3Index", "in": "path", "required": true,
           "description": "15-character hex H3 index string, resolution 3.",
           "schema": {"type": "string", "pattern": "^[0-9a-f]{15}$", "default": "831453fffffffff", "example": "831453fffffffff"}},
          {"name": "timestamp", "in": "path", "required": true,
           "description": "Time bucket key: YYYY.MM.DD.HH.mm, zero-padded, dot-separated, UTC (no timezone offset).",
           "schema": {"type": "string", "pattern": "^\\d{4}\\.\\d{2}\\.\\d{2}\\.\\d{2}\\.\\d{2}$", "default": "2026.09.09.03.00", "example": "2026.09.09.03.00"}}
        ],
        "responses": {"200": {"description": "OK"}}
      }
    },
    "/points": {
      "delete": {
        "summary": "Delete all points at one timestamp, or every point in the bucket if timestamp is omitted",
        "parameters": [
          {"name": "timestamp", "in": "query", "required": false,
           "description": "Time bucket key: YYYY.MM.DD.HH.mm, zero-padded, dot-separated, UTC (no timezone offset). Omit to delete every point in the bucket, regardless of timestamp.",
           "schema": {"type": "string", "pattern": "^\\d{4}\\.\\d{2}\\.\\d{2}\\.\\d{2}\\.\\d{2}$", "example": "2026.09.09.03.00"}}
        ],
        "responses": {"200": {"description": "OK"}}
      }
    }
  }
}`

func openapiHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("content-type", "application/json")
	w.Write([]byte(openapiSpec))
}

const swaggerPage = `<!DOCTYPE html><html><head><title>H3 Ingest Gateway</title>
<link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css"></head>
<body><div id="swagger-ui"></div>
<script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
<script>window.onload = () => SwaggerUIBundle({url: "/openapi.json", dom_id: "#swagger-ui"});</script>
</body></html>`

func swaggerHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("content-type", "text/html")
	w.Write([]byte(swaggerPage))
}

func main() {}
