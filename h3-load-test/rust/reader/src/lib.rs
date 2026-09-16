//! Rust implementation of the h3 reader: `h3:pipeline/query`.

mod bindings {
    wit_bindgen::generate!({
        path: "wit",
        world: "reader",
        generate_all,
    });
}

use std::rc::Rc;
use std::time::Instant;

use bindings::exports::h3::pipeline::query::{DataPoint, Guest};
use bindings::wasmcloud::nats::kv;
use bindings::wit_stream;
use futures::stream::{self, StreamExt, TryStreamExt};
use h3_common::{BUCKET, NUM_SHARDS, StoredPoint};
use wit_bindgen::StreamReader;

/// How many shard key listings are in flight at once.
const KEYS_CONCURRENCY: usize = 16;
/// How many gets are in flight at once.
const GET_CONCURRENCY: usize = 32;
/// Writes to the output stream are batched to about this size.
const STREAM_BUFFER_BYTES: usize = 64 * 1024;

struct Reader;

bindings::export!(Reader with_types_in bindings);

async fn open_bucket() -> Result<kv::Bucket, String> {
    kv::open(BUCKET.to_string())
        .await
        .map_err(|e| format!("open {BUCKET}: {e:?}"))
}

impl Guest for Reader {
    async fn get_by_key(h3_index: String, timestamp: String) -> Result<DataPoint, String> {
        let bucket = open_bucket().await?;
        let key = h3_common::key(&timestamp, &h3_index);
        let entry = bucket
            .get(key.clone())
            .await
            .map_err(|e| format!("get {key}: {e:?}"))?;
        let point: StoredPoint =
            serde_json::from_slice(&entry.value).map_err(|e| format!("decode {key}: {e}"))?;
        Ok(DataPoint {
            h3_index: point.h3_index,
            timestamp: point.timestamp,
            value: point.value,
        })
    }

    /// Lists every shard (kv.keys is capped at 1000 results per call), then
    /// streams `{"points":[...],"count":N,"elapsedMs":MS}` while issuing the
    /// per-key gets concurrently. Each stored value is already a JSON-encoded
    /// point, so it is copied through as-is. A failed get ends the stream
    /// early (see get-by-time in the WIT).
    async fn get_by_time(timestamp: String) -> Result<StreamReader<u8>, String> {
        let start = Instant::now();
        let bucket = Rc::new(open_bucket().await?);

        let pages: Vec<Vec<String>> = stream::iter(0..NUM_SHARDS)
            .map(|shard| {
                let bucket = Rc::clone(&bucket);
                let filter = format!("{timestamp}.{shard:02x}.>");
                async move {
                    let page = bucket
                        .keys(filter.clone())
                        .await
                        .map_err(|e| format!("keys {filter}: {e:?}"))?;
                    if page.truncated {
                        return Err(format!(
                            "shard {shard:02x} truncated at 1000 keys -- raise NUM_SHARDS"
                        ));
                    }
                    Ok(page.keys)
                }
            })
            .buffered(KEYS_CONCURRENCY)
            .try_collect()
            .await?;
        let keys: Vec<String> = pages.into_iter().flatten().collect();

        let (mut tx, rx) = wit_stream::new::<u8>();
        wit_bindgen::spawn_local(async move {
            let mut buf = Vec::with_capacity(STREAM_BUFFER_BYTES + 1024);
            buf.extend_from_slice(br#"{"points":["#);
            let mut count = 0usize;
            let mut gets = stream::iter(keys)
                .map(|key| {
                    let bucket = Rc::clone(&bucket);
                    async move { bucket.get(key).await }
                })
                .buffer_unordered(GET_CONCURRENCY);
            while let Some(result) = gets.next().await {
                let Ok(entry) = result else { return };
                // Validate without building a value, like Go's json.Valid.
                if serde_json::from_slice::<serde::de::IgnoredAny>(&entry.value).is_err() {
                    return;
                }
                if count > 0 {
                    buf.push(b',');
                }
                buf.extend_from_slice(&entry.value);
                count += 1;
                if buf.len() >= STREAM_BUFFER_BYTES {
                    buf = tx.write_all(buf).await;
                    if !buf.is_empty() {
                        return; // the reader went away
                    }
                }
            }
            let trailer = format!(
                r#"],"count":{count},"elapsedMs":{}}}"#,
                start.elapsed().as_millis()
            );
            buf.extend_from_slice(trailer.as_bytes());
            let _ = tx.write_all(buf).await;
        });
        Ok(rx)
    }
}
