package main

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"go.bytecodealliance.org/pkg/wasihttp"

	"h3distgw/h3_pipeline_query"
)

// writeJSON encodes data to a buffer first, so an encoding error never
// leaves a partially written response.
//
// There is no response size cap: the ~1MiB truncation previously seen here
// was the response writer ignoring short stream writes, fixed in
// go.bytecodealliance.org/pkg by "call WriteAll for stream write".
func writeJSON(w http.ResponseWriter, status int, data any) {
	body, err := json.Marshal(data)
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(map[string]any{"error": "encode response: " + err.Error()})
		return
	}
	w.WriteHeader(status)
	if _, err := w.Write(body); err != nil {
		// Headers/status are already sent at this point -- nothing more we
		// can tell the client. Logging here would need a wasi:logging
		// import this component doesn't currently have.
		_ = err
	}
}

func init() {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /points/{h3Index}/{timestamp}", byKeyHandler)
	mux.HandleFunc("GET /points", byTimeHandler)
	mux.HandleFunc("GET /openapi.json", openapiHandler)
	mux.HandleFunc("GET /docs", swaggerHandler)
	wasihttp.Handle(mux)
}

func byKeyHandler(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	h3Index := r.PathValue("h3Index")
	timestamp := r.PathValue("timestamp")

	result := h3_pipeline_query.GetByKey(h3Index, timestamp)
	w.Header().Set("content-type", "application/json")
	if result.IsErr() {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": result.Err()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"point":     result.Ok(),
		"elapsedMs": time.Since(start).Milliseconds(),
	})
}

func byTimeHandler(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	timestamp := strings.TrimSpace(r.URL.Query().Get("timestamp"))
	if timestamp == "" {
		http.Error(w, "missing required query param: timestamp", http.StatusBadRequest)
		return
	}

	result := h3_pipeline_query.GetByTime(timestamp)
	w.Header().Set("content-type", "application/json")
	if result.IsErr() {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": result.Err()})
		return
	}
	points := result.Ok()
	writeJSON(w, http.StatusOK, map[string]any{
		"points":    points,
		"count":     len(points),
		"elapsedMs": time.Since(start).Milliseconds(),
	})
}

const openapiSpec = `{
  "openapi": "3.0.3",
  "info": {"title": "H3 Distribute Gateway", "version": "0.1.0"},
  "paths": {
    "/points/{h3Index}/{timestamp}": {
      "get": {"summary": "Get one point by key", "parameters": [
        {"name": "h3Index", "in": "path", "required": true,
         "description": "15-character hex H3 index string, resolution 3.",
         "schema": {"type": "string", "pattern": "^[0-9a-f]{15}$", "default": "831453fffffffff", "example": "831453fffffffff"}},
        {"name": "timestamp", "in": "path", "required": true,
         "description": "Time bucket key: YYYY.MM.DD.HH.mm, zero-padded, dot-separated, UTC (no timezone offset). Matches the NATS KV key's time-token prefix exactly.",
         "schema": {"type": "string", "pattern": "^\\d{4}\\.\\d{2}\\.\\d{2}\\.\\d{2}\\.\\d{2}$", "default": "2026.09.09.03.00", "example": "2026.09.09.03.00"}}
      ], "responses": {"200": {"description": "OK"}}}
    },
    "/points": {
      "get": {"summary": "Get all H3 cells at one timestamp", "parameters": [
        {"name": "timestamp", "in": "query", "required": true,
         "description": "Time bucket key: YYYY.MM.DD.HH.mm, zero-padded, dot-separated, UTC (no timezone offset). Matches the NATS KV key's time-token prefix exactly.",
         "schema": {"type": "string", "pattern": "^\\d{4}\\.\\d{2}\\.\\d{2}\\.\\d{2}\\.\\d{2}$", "default": "2026.09.09.03.00", "example": "2026.09.09.03.00"}}
      ], "responses": {"200": {"description": "OK"}}}
    }
  }
}`

func openapiHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("content-type", "application/json")
	w.Write([]byte(openapiSpec))
}

const swaggerPage = `<!DOCTYPE html><html><head><title>H3 Distribute Gateway</title>
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
