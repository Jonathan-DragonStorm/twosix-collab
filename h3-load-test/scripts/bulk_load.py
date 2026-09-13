#!/usr/bin/env python3
"""Concurrent bulk-scan load test for the h3-distribute gateway.

Fires REQUESTS `GET /points?timestamp=...` calls (round-robin over the given
timestamps) with CONCURRENCY of them in flight at once, validates every
response, and prints one summary line: successes, points and bytes returned,
latency, and throughput.

This replaces backgrounding curl from bash for concurrent runs, which hung
waiting on finished jobs in our test environment.

Usage:
  ./bulk_load.py [--concurrency N] [--requests N] [--expect POINTS] TIMESTAMP [TIMESTAMP ...]

Examples:
  # One query at a time against a single timestamp
  ./bulk_load.py 2026.09.13.00.00

  # 32 in flight, 64 total, round-robin over five fully populated timestamps
  ./bulk_load.py -c 32 -n 64 --expect 41846 \
    2026.09.13.00.00 2026.09.13.00.01 2026.09.13.00.02 2026.09.13.00.03 2026.09.13.00.04

Environment (same as lib.sh):
  BASE_URL         default http://127.0.0.1
  DISTRIBUTE_HOST  default h3-distribute.localhost.cosmonic.sh
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

BASE_URL = os.environ.get("BASE_URL", "http://127.0.0.1")
DISTRIBUTE_HOST = os.environ.get("DISTRIBUTE_HOST", "h3-distribute.localhost.cosmonic.sh")


def query(timestamp, expect, timeout):
    """Returns (ok, seconds, points, bytes, error)."""
    req = urllib.request.Request(
        f"{BASE_URL}/points?timestamp={timestamp}", headers={"Host": DISTRIBUTE_HOST}
    )
    start = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            code, body = resp.status, resp.read()
    except urllib.error.HTTPError as e:
        code, body = e.code, e.read()
    except Exception as e:  # connection reset, timeout, ...
        return False, time.monotonic() - start, 0, 0, f"{type(e).__name__}: {e}"
    elapsed = time.monotonic() - start

    try:
        doc = json.loads(body)
    except ValueError:
        return False, elapsed, 0, len(body), f"HTTP {code}, invalid JSON ({len(body)} bytes): {body[:80]!r}"
    if code != 200:
        return False, elapsed, 0, len(body), f"HTTP {code}: {str(doc.get('error', doc))[:120]}"

    count, points = doc.get("count"), len(doc.get("points") or [])
    if count != points:
        return False, elapsed, points, len(body), f"count={count} but {points} points returned"
    if expect is not None and points != expect:
        return False, elapsed, points, len(body), f"expected {expect} points, got {points}"
    return True, elapsed, points, len(body), None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("timestamps", nargs="+", metavar="TIMESTAMP")
    parser.add_argument("-c", "--concurrency", type=int, default=1, help="requests in flight at once (default 1)")
    parser.add_argument("-n", "--requests", type=int, help="total requests (default: one per timestamp)")
    parser.add_argument("--expect", type=int, help="fail any response without exactly this many points")
    parser.add_argument("--timeout", type=float, default=600, help="per-request timeout in seconds (default 600)")
    args = parser.parse_args()

    total = args.requests or len(args.timestamps)
    stamps = [args.timestamps[i % len(args.timestamps)] for i in range(total)]

    started = time.strftime("%H:%M:%S")
    wall = time.monotonic()
    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        results = list(pool.map(lambda ts: query(ts, args.expect, args.timeout), stamps))
    wall = time.monotonic() - wall

    ok = [r for r in results if r[0]]
    points = sum(r[2] for r in ok)
    latency = sorted(r[1] for r in results)
    print(
        f"[{started}-{time.strftime('%H:%M:%S')}] concurrency={args.concurrency} requests={total} "
        f"ok={len(ok)} failed={total - len(ok)} points={points:,} MB={sum(r[3] for r in ok) / 1e6:.1f} "
        f"wall={wall:.1f}s latency min={latency[0]:.1f}s p50={latency[len(latency) // 2]:.1f}s "
        f"max={latency[-1]:.1f}s throughput={points / wall:,.0f} points/s"
    )

    errors = {}
    for r in results:
        if not r[0]:
            errors[r[4]] = errors.get(r[4], 0) + 1
    for message, n in errors.items():
        print(f"  {n}x {message}")
    return 0 if len(ok) == total else 1


if __name__ == "__main__":
    sys.exit(main())
