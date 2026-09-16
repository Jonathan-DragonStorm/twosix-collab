//! Rust implementation of the h3 ingester: `h3:pipeline/ingest` plus the
//! `h3.ingest.raw` NATS subscription. Mirrors the Go ingester's persist logic
//! (sequential puts and purges) so the two can be compared directly.

mod bindings {
    wit_bindgen::generate!({
        path: "wit",
        world: "ingester",
        generate_all,
    });
}

use bindings::exports::h3::pipeline::ingest::{self, DataPoint};
use bindings::exports::wasmcloud::nats::core_handler;
use bindings::wasmcloud::nats::kv;
use bindings::wasmcloud::nats::types::NatsMessage;
use h3_common::{BUCKET, InputPoint, NUM_SHARDS, StoredPoint};

struct Ingester;

bindings::export!(Ingester with_types_in bindings);

async fn open_bucket() -> Result<kv::Bucket, String> {
    kv::open(BUCKET.to_string())
        .await
        .map_err(|e| format!("open {BUCKET}: {e:?}"))
}

async fn persist(points: Vec<StoredPoint>) -> Result<u32, String> {
    let bucket = open_bucket().await?;
    let mut count = 0;
    for point in points {
        h3_common::validate(&point.h3_index)
            .map_err(|e| format!("invalid h3 index {:?}: {e}", point.h3_index))?;
        let key = h3_common::key(&point.timestamp, &point.h3_index);
        bucket
            .put(key.clone(), point.to_json())
            .await
            .map_err(|e| format!("put {key}: {e:?}"))?;
        count += 1;
    }
    Ok(count)
}

/// Purges every key matching `<prefix>.<shard>.>` across all shards
/// (kv.keys is capped at 1000 results per call).
async fn purge_matching(prefix: &str) -> Result<u32, String> {
    let bucket = open_bucket().await?;
    let mut count = 0;
    for shard in 0..NUM_SHARDS {
        let filter = format!("{prefix}.{shard:02x}.>");
        let page = bucket
            .keys(filter.clone())
            .await
            .map_err(|e| format!("keys {filter}: {e:?}"))?;
        if page.truncated {
            return Err(format!("shard {shard:02x} truncated at 1000 keys -- raise NUM_SHARDS"));
        }
        for key in page.keys {
            bucket
                .purge(key.clone())
                .await
                .map_err(|e| format!("purge {key}: {e:?}"))?;
            count += 1;
        }
    }
    Ok(count)
}

impl ingest::Guest for Ingester {
    async fn ingest_batch(points: Vec<DataPoint>) -> Result<u32, String> {
        persist(
            points
                .into_iter()
                .map(|p| StoredPoint {
                    h3_index: p.h3_index,
                    timestamp: p.timestamp,
                    value: p.value,
                })
                .collect(),
        )
        .await
    }

    async fn delete_by_key(h3_index: String, timestamp: String) -> Result<(), String> {
        let bucket = open_bucket().await?;
        let key = h3_common::key(&timestamp, &h3_index);
        bucket
            .purge(key.clone())
            .await
            .map_err(|e| format!("purge {key}: {e:?}"))
    }

    async fn delete_by_time(timestamp: String) -> Result<u32, String> {
        purge_matching(&timestamp).await
    }

    async fn delete_all() -> Result<u32, String> {
        // Wildcards the five time tokens (YYYY.MM.DD.HH.mm).
        purge_matching("*.*.*.*.*").await
    }
}

impl core_handler::Guest for Ingester {
    async fn handle_message(msg: NatsMessage) -> Result<(), String> {
        let point: InputPoint =
            serde_json::from_slice(&msg.body).map_err(|e| format!("invalid JSON body: {e}"))?;
        persist(vec![StoredPoint {
            h3_index: point.h3_index,
            timestamp: point.timestamp,
            value: point.value,
        }])
        .await
        .map(|_| ())
    }
}
