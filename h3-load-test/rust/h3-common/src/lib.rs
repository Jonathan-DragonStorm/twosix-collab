//! Logic shared by the Rust h3 components.
//!
//! This mirrors the Go components' `shardutil` and `h3fmt` packages and their
//! stored value encoding, so the Rust and Go implementations read and write
//! the same keys and values in the same bucket.

use serde::{Deserialize, Serialize};

pub const BUCKET: &str = "h3-points";

/// Must match `shardutil.NumShards` in the Go components.
pub const NUM_SHARDS: u32 = 64;

/// The shard an index is stored under: FNV-1a (32-bit) of the index modulo
/// [`NUM_SHARDS`], as two lowercase hex digits (`shardutil.Shard`).
pub fn shard(h3_index: &str) -> String {
    let mut hash: u32 = 0x811c_9dc5;
    for byte in h3_index.bytes() {
        hash ^= u32::from(byte);
        hash = hash.wrapping_mul(0x0100_0193);
    }
    format!("{:02x}", hash % NUM_SHARDS)
}

/// The KV key a point is stored under: `<timestamp>.<shard>.<h3Index>`.
pub fn key(timestamp: &str, h3_index: &str) -> String {
    format!("{timestamp}.{}.{h3_index}", shard(h3_index))
}

/// Validates a syntactically well-formed resolution-3 H3 cell index
/// (`h3fmt.Validate`).
pub fn validate(s: &str) -> Result<(), String> {
    const MODE_CELL: u64 = 1;
    const RESOLUTION: u64 = 3;
    const MAX_BASE_CELL: u64 = 121;
    const UNUSED_DIGIT: u64 = 7;

    if s.len() != 15 {
        return Err(format!("h3 index must be 15 hex chars, got {}", s.len()));
    }
    let v = u64::from_str_radix(s, 16).map_err(|e| format!("not valid hex: {e}"))?;
    if (v >> 63) & 1 != 0 {
        return Err("reserved bit 63 must be 0".into());
    }
    if (v >> 56) & 0x7 != 0 {
        return Err("reserved bits 56-58 must be 0".into());
    }
    let mode = (v >> 59) & 0xf;
    if mode != MODE_CELL {
        return Err(format!("mode must be {MODE_CELL} (cell), got {mode}"));
    }
    let resolution = (v >> 52) & 0xf;
    if resolution != RESOLUTION {
        return Err(format!("resolution must be {RESOLUTION}, got {resolution}"));
    }
    let base_cell = (v >> 45) & 0x7f;
    if base_cell > MAX_BASE_CELL {
        return Err(format!("base cell {base_cell} exceeds max {MAX_BASE_CELL}"));
    }
    for digit in 0..15u64 {
        let d = (v >> (42 - digit * 3)) & 0x7;
        if digit < RESOLUTION {
            if d > 6 {
                return Err(format!("digit {digit} must be 0-6 within resolution, got {d}"));
            }
        } else if d != UNUSED_DIGIT {
            return Err(format!(
                "digit {digit} beyond resolution must be unused marker {UNUSED_DIGIT}, got {d}"
            ));
        }
    }
    Ok(())
}

/// A point as stored in the bucket, using the field names Go's
/// `encoding/json` produces for `h3_pipeline_types.DataPoint`.
#[derive(Serialize, Deserialize)]
pub struct StoredPoint {
    #[serde(rename = "H3Index")]
    pub h3_index: String,
    #[serde(rename = "Timestamp")]
    pub timestamp: String,
    #[serde(rename = "Value", serialize_with = "go_float")]
    pub value: f64,
}

impl StoredPoint {
    /// Encodes the point exactly as the Go ingester does.
    pub fn to_json(&self) -> Vec<u8> {
        serde_json::to_vec(self).expect("a point always encodes")
    }
}

/// Serializes a float like Go's `encoding/json` for the values this harness
/// stores: integral values without serde_json's trailing `.0`. (Go also
/// switches to exponent form outside [1e-6, 1e21); that edge is not mirrored.)
fn go_float<S: serde::Serializer>(v: &f64, s: S) -> Result<S::Ok, S::Error> {
    if v.fract() == 0.0 && v.abs() < 9e15 {
        s.serialize_i64(*v as i64)
    } else {
        s.serialize_f64(*v)
    }
}

/// A point in an ingest request or NATS message. Go's decoder matches field
/// names case-insensitively; accept both spellings in use.
#[derive(Deserialize)]
pub struct InputPoint {
    #[serde(rename = "h3Index", alias = "H3Index")]
    pub h3_index: String,
    #[serde(rename = "timestamp", alias = "Timestamp")]
    pub timestamp: String,
    #[serde(rename = "value", alias = "Value")]
    pub value: f64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shard_matches_go() {
        // Expected values from shardutil.Shard in the Go components.
        for (index, expected) in GO_SHARDS {
            assert_eq!(shard(index), *expected, "{index}");
        }
    }

    const GO_SHARDS: &[(&str, &str)] = &[
        ("830028fffffffff", "00"),
        ("831453fffffffff", "29"),
        ("8374dcfffffffff", "30"),
        ("83f2d6fffffffff", "2c"),
        ("", "05"),
    ];

    #[test]
    fn validates_generated_indices() {
        assert!(validate("830028fffffffff").is_ok());
        assert!(validate("831453fffffffff").is_ok());
        assert!(validate("830028ffffffff").is_err());
    }

    #[test]
    fn encodes_like_go() {
        let p = StoredPoint { h3_index: "830028fffffffff".into(), timestamp: "t".into(), value: 35.0 };
        assert_eq!(p.to_json(), br#"{"H3Index":"830028fffffffff","Timestamp":"t","Value":35}"#);
        let p = StoredPoint { value: 1.5, ..p };
        assert_eq!(p.to_json(), br#"{"H3Index":"830028fffffffff","Timestamp":"t","Value":1.5}"#);
    }
}
