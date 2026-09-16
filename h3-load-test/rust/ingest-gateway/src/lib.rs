//! Rust implementation of the h3 ingest gateway: HTTP in front of
//! `h3:pipeline/ingest`.

mod bindings {
    wit_bindgen::generate!({
        path: "wit",
        world: "gateway",
        generate_all,
    });
}

use std::time::Instant;

use bindings::exports::wasi::http::handler::Guest;
use bindings::h3::pipeline::ingest;
use bindings::h3::pipeline::types::DataPoint;
use bindings::wasi::http::types::{ErrorCode, Fields, Method, Request, Response};
use bindings::{wit_future, wit_stream};
use h3_common::InputPoint;
use serde::Deserialize;
use serde_json::json;

struct Gateway;

bindings::export!(Gateway with_types_in bindings);

#[derive(Deserialize)]
struct IngestRequest {
    #[serde(rename = "points", alias = "Points")]
    points: Vec<InputPoint>,
}

impl Guest for Gateway {
    async fn handle(request: Request) -> Result<Response, ErrorCode> {
        let method = request.get_method();
        let path_with_query = request.get_path_with_query().unwrap_or_default();
        let (path, query) = path_with_query
            .split_once('?')
            .unwrap_or((path_with_query.as_str(), ""));
        let segments: Vec<String> = path.trim_start_matches('/').split('/').map(String::from).collect();
        let query = query.to_string();

        match (method, segments.iter().map(String::as_str).collect::<Vec<_>>().as_slice()) {
            (Method::Post, ["ingest"]) => ingest_handler(request).await,
            (Method::Delete, ["points", h3_index, timestamp]) => {
                delete_by_key(h3_index, timestamp).await
            }
            (Method::Delete, ["points"]) => delete_by_time_or_all(&query).await,
            (Method::Get, ["openapi.json"]) => respond(200, "application/json", OPENAPI_SPEC),
            (Method::Get, ["docs"]) => respond(200, "text/html", SWAGGER_PAGE),
            _ => respond(404, "text/plain; charset=utf-8", "404 page not found\n"),
        }
    }
}

async fn ingest_handler(request: Request) -> Result<Response, ErrorCode> {
    let start = Instant::now();
    let (_, done) = wit_future::new(|| Ok(()));
    let (body, _trailers) = Request::consume_body(request, done);
    let body = body.collect().await;
    let request: IngestRequest = match serde_json::from_slice(&body) {
        Ok(request) => request,
        Err(e) => {
            return respond(400, "text/plain; charset=utf-8", format!("invalid JSON body: {e}\n"));
        }
    };
    let points = request
        .points
        .into_iter()
        .map(|p| DataPoint {
            h3_index: p.h3_index,
            timestamp: p.timestamp,
            value: p.value,
        })
        .collect();
    match ingest::ingest_batch(points).await {
        Ok(count) => respond_json(
            200,
            &json!({ "ingested": count, "elapsedMs": start.elapsed().as_millis() }),
        ),
        Err(error) => respond_json(500, &json!({ "error": error })),
    }
}

async fn delete_by_key(h3_index: &str, timestamp: &str) -> Result<Response, ErrorCode> {
    let start = Instant::now();
    match ingest::delete_by_key(h3_index.to_string(), timestamp.to_string()).await {
        Ok(()) => respond_json(
            200,
            &json!({ "deleted": true, "elapsedMs": start.elapsed().as_millis() }),
        ),
        Err(error) => respond_json(500, &json!({ "error": error })),
    }
}

/// With a `timestamp` query param, deletes every point at that timestamp;
/// without one, deletes everything in the bucket.
async fn delete_by_time_or_all(query: &str) -> Result<Response, ErrorCode> {
    let start = Instant::now();
    let timestamp = query_param(query, "timestamp").unwrap_or_default();
    let timestamp = timestamp.trim();
    let result = if timestamp.is_empty() {
        ingest::delete_all().await
    } else {
        ingest::delete_by_time(timestamp.to_string()).await
    };
    match result {
        Ok(count) => respond_json(
            200,
            &json!({ "deleted": count, "elapsedMs": start.elapsed().as_millis() }),
        ),
        Err(error) => respond_json(500, &json!({ "error": error })),
    }
}

fn respond_json(status: u16, body: &serde_json::Value) -> Result<Response, ErrorCode> {
    respond(status, "application/json", body.to_string())
}

fn respond(status: u16, content_type: &str, body: impl Into<Vec<u8>>) -> Result<Response, ErrorCode> {
    let (mut tx, rx) = wit_stream::new::<u8>();
    let body = body.into();
    wit_bindgen::spawn_local(async move {
        let _ = tx.write_all(body).await;
    });
    let headers = Fields::from_list(&[("content-type".to_string(), content_type.as_bytes().to_vec())])
        .map_err(|e| ErrorCode::InternalError(Some(format!("{e:?}"))))?;
    let (_, trailers) = wit_future::new(|| Ok(None));
    let (response, _) = Response::new(headers, Some(rx), trailers);
    response
        .set_status_code(status)
        .map_err(|()| ErrorCode::InternalError(Some(format!("invalid status {status}"))))?;
    Ok(response)
}

/// Returns the (percent-decoded) value of `name` in a query string.
fn query_param(query: &str, name: &str) -> Option<String> {
    query.split('&').find_map(|pair| {
        let (key, value) = pair.split_once('=').unwrap_or((pair, ""));
        (key == name).then(|| percent_decode(value))
    })
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let hex = bytes
            .get(i + 1..i + 3)
            .and_then(|h| std::str::from_utf8(h).ok())
            .and_then(|h| u8::from_str_radix(h, 16).ok());
        match (bytes[i], hex) {
            (b'%', Some(b)) => {
                out.push(b);
                i += 3;
            }
            (b'+', _) => {
                out.push(b' ');
                i += 1;
            }
            (b, _) => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

const OPENAPI_SPEC: &str = r#"{
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
}"#;

const SWAGGER_PAGE: &str = r##"<!DOCTYPE html><html><head><title>H3 Ingest Gateway</title>
<link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css"></head>
<body><div id="swagger-ui"></div>
<script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
<script>window.onload = () => SwaggerUIBundle({url: "/openapi.json", dom_id: "#swagger-ui"});</script>
</body></html>"##;
