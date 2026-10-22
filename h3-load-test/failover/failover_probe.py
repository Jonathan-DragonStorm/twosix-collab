#!/usr/bin/env python3
"""Run one failover scenario against the h3 ingest/distribute endpoints.

Drives continuous traffic at both endpoints, force-kills one pod partway
through, and records how long each endpoint took to return to healthy
operation and whether points acknowledged by ingest reached the KV store
(the ingest path is asynchronous over core NATS). Writes a CSV of every
request and a JSON summary that report.py aggregates.

    # kill the h3 host pod that is serving h3-ingest
    ./failover_probe.py --scenario host --kill-workload-host h3-ingest

    # kill the Envoy ingress pod
    ./failover_probe.py --scenario envoy --kill-selector cosmonic.io/name=envoy --watch-prefix envoy-

Python 3 standard library only; shells out to kubectl for the kill and
for the control-plane timeline. See README.md for the full suite.
"""
import argparse
import csv
import json
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

NS = os.environ.get("NAMESPACE", "twosix-dev")
BASE_URL = os.environ.get("BASE_URL", "http://127.0.0.1")
INGEST_HOST = os.environ.get("INGEST_HOST", "h3-ingest.localhost.cosmonic.sh")
DISTRIBUTE_HOST = os.environ.get("DISTRIBUTE_HOST", "h3-distribute.localhost.cosmonic.sh")
ENDPOINTS = ("ingest", "distribute")


def gen_h3(seq):
    """Unique resolution-3 index for seq in [0, 41846), matching scripts/lib.sh gen_h3."""
    base, rest = divmod(seq, 343)
    d1, rest = divmod(rest, 49)
    d2, d3 = divmod(rest, 7)
    v = (1 << 59) | (3 << 52) | ((base & 127) << 45) | (d1 << 42) | (d2 << 39) | (d3 << 36) | 0xFFFFFFFFF
    return "%015x" % v


def request(host, path, method="GET", body=None, timeout=2.0):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE_URL + path, data=data, method=method, headers={"Host": host})
    if data is not None:
        req.add_header("Content-Type", "application/json")
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, (time.time() - t0) * 1000, r.read()
    except urllib.error.HTTPError as e:
        return e.code, (time.time() - t0) * 1000, e.read()
    except Exception as e:  # timeouts, connection resets
        return f"ERR:{type(e).__name__}", (time.time() - t0) * 1000, b""


def kubectl_json(*args):
    out = subprocess.run(["kubectl", "-n", NS, *args, "-o", "json"], capture_output=True, text=True, timeout=10)
    return json.loads(out.stdout) if out.returncode == 0 else None


def ready(obj):
    for c in obj.get("status", {}).get("conditions", []):
        if c.get("type") == "Ready":
            return c.get("status") == "True"
    return False


def live(items):
    return [i for i in items if not i["metadata"].get("deletionTimestamp")]


def lease_holder(name):
    """Pod name holding a controller-runtime leader lease ('' if none, None if no lease)."""
    obj = kubectl_json("get", "lease", name)
    if obj is None:
        return None
    return (obj["spec"].get("holderIdentity") or "").split("_")[0]


def placement(workloads):
    """[(workload replica, host CR name, pod name)] for the given WorkloadDeployments."""
    hosts = {h["hostId"]: h for h in kubectl_json("get", "hosts")["items"]}
    pods = {p["status"].get("podIP"): p["metadata"]["name"] for p in live(kubectl_json("get", "pods")["items"])}
    rows = []
    for w in kubectl_json("get", "workloads")["items"]:
        # Workloads are named <WorkloadDeployment>-<replicaset hash>-<hash> and carry no labels.
        if w["metadata"]["name"].rsplit("-", 2)[0] not in workloads:
            continue
        h = hosts.get(w.get("status", {}).get("hostId"))
        rows.append((w["metadata"]["name"], h["metadata"]["name"] if h else None,
                     pods.get(h.get("hostname")) if h else None))
    return sorted(rows)


class Probe:
    def __init__(self, args):
        self.args = args
        self.stop = threading.Event()
        self.lock = threading.Lock()
        self.samples = []   # (t, endpoint, status, latency_ms, ok)
        self.acked = []     # (t, h3) acknowledged by ingest
        self.timeline = []  # (t, event)
        self.seq = 1        # 0 is the distribute probe's seed point
        self.canary_result = None

    def record(self, *row):
        with self.lock:
            self.samples.append(row)

    def ingest_loop(self):
        while not self.stop.is_set():
            t = time.time()
            h3 = gen_h3(self.seq)
            self.seq += 1
            body = {"points": [{"h3Index": h3, "timestamp": self.args.timestamp, "value": t}]}
            status, ms, _ = request(INGEST_HOST, "/ingest", "POST", body)
            self.record(t, "ingest", status, ms, status == 200)
            if status == 200:
                with self.lock:
                    self.acked.append((t, h3))
            time.sleep(max(0, self.args.interval - (time.time() - t)))

    def distribute_loop(self):
        path = f"/points/{gen_h3(0)}/{self.args.timestamp}"
        while not self.stop.is_set():
            t = time.time()
            status, ms, _ = request(DISTRIBUTE_HOST, path)
            self.record(t, "distribute", status, ms, status == 200)
            time.sleep(max(0, self.args.interval - (time.time() - t)))

    def state_loop(self):
        """Poll pod / Host / WorkloadDeployment readiness, logging transitions."""
        last = {}
        while not self.stop.is_set():
            t = time.time()
            state = {}
            pods = kubectl_json("get", "pods")
            if pods:
                for p in pods["items"]:
                    name = p["metadata"]["name"]
                    if name.startswith(tuple(self.args.watch_prefix)):
                        phase = "Terminating" if p["metadata"].get("deletionTimestamp") else p["status"].get("phase")
                        cs = p["status"].get("containerStatuses") or [{}]
                        state[f"pod/{name}"] = f"{phase} ready={all(c.get('ready') for c in cs)}"
            hosts = kubectl_json("get", "hosts")
            if hosts:
                for h in hosts["items"]:
                    state[f"host/{h['metadata']['name']}"] = f"ready={ready(h)}"
            for wd in self.args.workloads:
                obj = kubectl_json("get", "workloaddeployment", wd)
                if obj:
                    r = obj.get("status", {}).get("replicas", {})
                    state[f"wd/{wd}"] = f"ready={ready(obj)} replicas={r.get('ready', 0)}/{r.get('expected', '?')}"
            if self.args.lease:
                holder = lease_holder(self.args.lease)
                if holder is not None:
                    state[f"lease/{self.args.lease}"] = f"holder={holder or '-'}"
            for k, v in state.items():
                if last.get(k) != v:
                    self.timeline.append((t, f"{k} {v}"))
            for k in last:
                if k not in state:
                    self.timeline.append((t, f"{k} gone"))
            last = state
            time.sleep(0.5)

    def canary(self, t_kill):
        """Delete one replica of the canary workload just after the kill and time
        how long the control plane takes to place a Ready replacement."""
        wd = self.args.canary
        want = kubectl_json("get", "workloaddeployment", wd)["spec"]["replicas"]
        mine = [w for w in live(kubectl_json("get", "workloads")["items"])
                if w["metadata"]["name"].rsplit("-", 2)[0] == wd]
        if not mine:
            self.canary_result = {"workload": wd, "error": "no replica to delete"}
            return
        victim = sorted(w["metadata"]["name"] for w in mine)[0]
        subprocess.run(["kubectl", "-n", NS, "delete", "workload", victim, "--wait=false"],
                       capture_output=True, timeout=30)
        t_del = time.time()
        self.timeline.append((t_del, f"CANARY delete workload/{victim}"))
        deadline = t_del + self.args.max_wait
        while time.time() < deadline and not self.stop.is_set():
            ws = [w for w in live(kubectl_json("get", "workloads")["items"])
                  if w["metadata"]["name"].rsplit("-", 2)[0] == wd and w["metadata"]["name"] != victim
                  and w.get("status", {}).get("hostId") and ready(w)]
            if len(ws) >= want:
                t = time.time()
                self.timeline.append((t, f"CANARY {wd} back to {want} Ready replica(s)"))
                self.canary_result = {"workload": wd, "deleted": victim,
                                      "reconciled_s": round(t - t_kill, 2)}
                return
            time.sleep(0.5)
        self.canary_result = {"workload": wd, "deleted": victim, "reconciled_s": None}

    def pick_victim(self):
        a = self.args
        if a.kill_workload_host:
            pods = sorted({pod for _, _, pod in placement([a.kill_workload_host]) if pod})
        elif a.kill_lease:
            holder = lease_holder(a.kill_lease)
            pods = [holder] if holder else []
        else:
            pods = sorted(p["metadata"]["name"] for p in live(kubectl_json("get", "pods", "-l", a.kill_selector)["items"]))
        if not pods:
            sys.exit("no pod matched the kill target")
        return pods[0]

    def kill(self, pod):
        t = time.time()
        self.timeline.append((t, f"KILL pod/{pod}"))
        subprocess.run(["kubectl", "-n", NS, "delete", "pod", pod, "--grace-period=0", "--force"],
                       capture_output=True, timeout=30)
        return t

    def analyse(self, endpoint, t_kill):
        """Recovery = first success after the kill followed by `stable` consecutive successes."""
        rows = sorted((r for r in self.samples if r[1] == endpoint and r[0] >= t_kill), key=lambda r: r[0])
        t_rec = None
        for i, r in enumerate(rows):
            window = rows[i:i + self.args.stable]
            if len(window) == self.args.stable and all(w[4] for w in window):
                t_rec = r[0]
                break
        return t_rec, rows


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--scenario", required=True, help="name of this scenario, e.g. host, envoy, operator")
    ap.add_argument("--profile", default="adhoc", help="name of the scale profile, e.g. single, ha")
    target = ap.add_mutually_exclusive_group(required=True)
    target.add_argument("--kill-selector", help="label selector; the first matching pod is force-deleted")
    target.add_argument("--kill-workload-host", metavar="WD",
                        help="force-delete the host pod running a replica of this WorkloadDeployment")
    target.add_argument("--kill-lease", metavar="LEASE", help="force-delete the pod holding this leader lease")
    ap.add_argument("--watch-prefix", nargs="+", default=["hostgroup-h3"],
                    help="pod name prefix(es) to include in the timeline")
    ap.add_argument("--lease", default="d34db3ef.cosmonic.io",
                    help="leader lease to track in the timeline (the operator's); '' to skip")
    ap.add_argument("--canary", metavar="WD",
                    help="right after the kill, delete one replica of this WorkloadDeployment and time "
                         "how long the control plane takes to replace it (pick one that is not probed)")
    ap.add_argument("--workloads", nargs="*", default=["h3-ingest", "h3-distribute"])
    ap.add_argument("--timestamp", default="2026.10.22.23.59", help="dedicated timestamp for probe points")
    ap.add_argument("--interval", type=float, default=0.2, help="seconds between requests per endpoint")
    ap.add_argument("--baseline", type=float, default=15, help="seconds of traffic before the kill")
    ap.add_argument("--stable", type=int, default=10, help="consecutive successes that count as recovered")
    ap.add_argument("--settle", type=float, default=30, help="seconds of traffic after both endpoints recover")
    ap.add_argument("--max-wait", type=float, default=300, help="give up waiting for recovery after this long")
    ap.add_argument("--out", default="results")
    args = ap.parse_args()

    # Seed the point the distribute probe reads, and confirm the path works end to end.
    status, _, body = request(INGEST_HOST, "/ingest", "POST",
                              {"points": [{"h3Index": gen_h3(0), "timestamp": args.timestamp, "value": 0}]})
    if status != 200:
        sys.exit(f"seed ingest failed: {status} {body[:200]}")
    for _ in range(50):
        if request(DISTRIBUTE_HOST, f"/points/{gen_h3(0)}/{args.timestamp}")[0] == 200:
            break
        time.sleep(0.2)
    else:
        sys.exit("seed point never became readable")

    tag = f"{args.profile}/{args.scenario}"
    p = Probe(args)
    threads = [threading.Thread(target=f, daemon=True) for f in (p.ingest_loop, p.distribute_loop, p.state_loop)]
    for th in threads:
        th.start()
    print(f"[{tag}] baseline {args.baseline:.0f}s ...", flush=True)
    time.sleep(args.baseline)
    before = placement(args.workloads)
    victim = p.pick_victim()
    leader_before = lease_holder(args.lease) if args.lease else None
    t_kill = p.kill(victim)
    print(f"[{tag}] killed pod/{victim}; waiting for recovery ...", flush=True)
    canary = threading.Thread(target=p.canary, args=(t_kill,), daemon=True) if args.canary else None
    if canary:
        canary.start()

    deadline = t_kill + args.max_wait
    while time.time() < deadline:
        time.sleep(1)
        with p.lock:
            done = all(p.analyse(e, t_kill)[0] for e in ENDPOINTS)
        if done and not (canary and canary.is_alive()):
            break
    time.sleep(args.settle)
    p.stop.set()
    for th in threads + ([canary] if canary else []):
        th.join(timeout=5)
    after = placement(args.workloads)
    leader_after = lease_holder(args.lease) if args.lease else None

    # Which acknowledged points made it to KV? Allow the async path a moment to drain.
    time.sleep(3)
    lost = [(t, h3) for t, h3 in p.acked
            if request(DISTRIBUTE_HOST, f"/points/{h3}/{args.timestamp}")[0] != 200]

    summary = {
        "profile": args.profile, "scenario": args.scenario, "victim": victim, "kill_epoch": t_kill,
        "interval_s": args.interval, "stable": args.stable, "timestamp": args.timestamp,
        "placement_before": before, "placement_after": after,
        "operator_leader": {"before": leader_before, "after": leader_after},
        "canary": p.canary_result,
    }
    for e in ENDPOINTS:
        t_rec, rows = p.analyse(e, t_kill)
        outage = [r for r in rows if not r[4] and (t_rec is None or r[0] < t_rec)]
        flaps = [r for r in rows if not r[4] and t_rec is not None and r[0] >= t_rec]
        statuses = {}
        for r in outage + flaps:
            statuses[str(r[2])] = statuses.get(str(r[2]), 0) + 1
        pre = [r for r in p.samples if r[1] == e and r[0] < t_kill]
        summary[e] = {
            "baseline_ok": sum(r[4] for r in pre), "baseline_total": len(pre),
            "outage": bool(outage),
            "first_failure_s": round(outage[0][0] - t_kill, 2) if outage else None,
            "recovered_s": (round(t_rec - t_kill, 2) if outage else 0.0) if t_rec else None,
            "failed_requests": len(outage),
            "failed_after_recovery": len(flaps),
            "failure_statuses": statuses,
            "max_failed_latency_ms": round(max((r[3] for r in outage + flaps), default=0)),
        }
    summary["data"] = {
        "acked": len(p.acked), "lost": len(lost),
        "lost_window_s": [round(lost[0][0] - t_kill, 2), round(lost[-1][0] - t_kill, 2)] if lost else None,
    }
    summary["timeline"] = [(round(t - t_kill, 2), ev) for t, ev in sorted(p.timeline) if t >= t_kill - 1]

    os.makedirs(args.out, exist_ok=True)
    stem = os.path.join(args.out, f"{args.profile}-{args.scenario}")
    with open(stem + ".csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["t_rel_s", "endpoint", "status", "latency_ms", "ok"])
        for r in sorted(p.samples):
            w.writerow([f"{r[0] - t_kill:.3f}", r[1], r[2], f"{r[3]:.1f}", int(r[4])])
    with open(stem + ".json", "w") as f:
        json.dump(summary, f, indent=2)

    print(f"\n=== {tag} (killed pod/{victim}) ===")
    for t, ev in summary["timeline"]:
        print(f"  {t:+7.2f}s  {ev}")
    for e in ENDPOINTS:
        print(f"{e}: " + ", ".join(f"{k}={v}" for k, v in summary[e].items()))
    print("data: " + ", ".join(f"{k}={v}" for k, v in summary["data"].items()))
    if p.canary_result:
        print("canary: " + ", ".join(f"{k}={v}" for k, v in p.canary_result.items()))
    print(f"wrote {stem}.json, {stem}.csv")


if __name__ == "__main__":
    main()
