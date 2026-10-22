#!/usr/bin/env python3
"""report.py RESULTS_DIR -- aggregate failover_probe.py output into report.md.

Reads environment.json (written by run_suite.sh, optional) and every
<profile>-<scenario>.json / .csv pair in RESULTS_DIR.
"""
import csv
import glob
import json
import os
import sys

ENDPOINTS = ("ingest", "distribute")
STRIP_FROM, STRIP_TO = -5, 60  # seconds around the kill shown in availability strips


def fmt_s(v):
    return "—" if v is None else f"{v:.1f}s"


def downtime(ep):
    if ep["recovered_s"] is None:
        return "**did not recover**"
    if not ep["outage"]:
        return "none"
    return fmt_s(ep["recovered_s"])


def strip(csv_path, endpoint):
    """One character per second: █ all ok, ▒ some failed, ░ all failed, ' ' no samples."""
    buckets = {}
    with open(csv_path) as f:
        for row in csv.DictReader(f):
            if row["endpoint"] != endpoint:
                continue
            s = int(float(row["t_rel_s"]) // 1)
            if STRIP_FROM <= s < STRIP_TO:
                buckets.setdefault(s, []).append(row["ok"] == "1")
    out = []
    for s in range(STRIP_FROM, STRIP_TO):
        b = buckets.get(s)
        out.append(" " if not b else "█" if all(b) else "░" if not any(b) else "▒")
    return "".join(out)


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else "."
    env_path = os.path.join(d, "environment.json")
    env = json.load(open(env_path)) if os.path.exists(env_path) else {}
    profiles = env.get("profiles", {})
    runs = []
    for path in sorted(glob.glob(os.path.join(d, "*.json"))):
        if os.path.basename(path) == "environment.json":
            continue
        r = json.load(open(path))
        r["_csv"] = path[:-5] + ".csv"
        runs.append(r)
    if not runs:
        sys.exit(f"no scenario results in {d}")
    order = {p: i for i, p in enumerate(profiles)}
    scen_order = {s: i for i, s in enumerate(env.get("scenarios", []))}
    runs.sort(key=lambda r: (order.get(r["profile"], 99), scen_order.get(r["scenario"], 99), r["kill_epoch"]))

    def scale(profile):
        p = profiles.get(profile)
        if not p:
            return "?"
        return (f"{p['hosts']}×{p['replicas']} · E{p.get('envoy', 1)} "
                f"N{p.get('nexus', 1)} O{p.get('operator', 1)}")

    def reconcile(r):
        c = r.get("canary")
        if not c:
            return "—"
        if c.get("reconciled_s") is None:
            return "**not within max-wait**" if "error" not in c else c["error"]
        return f"{c['reconciled_s']:.1f}s"

    L = []
    L.append("# h3 failover test report\n")
    if env:
        charts = ", ".join(f"`{k}` {v}" for k, v in sorted(env.get("charts", {}).items()))
        L.append(f"- **Run started:** {env.get('started')}  ")
        L.append(f"- **Cluster:** `{env.get('context')}` (Kubernetes {env.get('kubernetes')}), namespace `{env.get('namespace')}`  ")
        L.append(f"- **Host runtime:** {env.get('host_version')}; charts: {charts}  ")
        L.append(f"- **Workloads probed:** {', '.join(env.get('workloads', []))}  ")
        L.append("- **Profiles** (`H×R · E N O` = h3 host pods × workload replicas · Envoy, Nexus, operator pods):")
        for p, v in profiles.items():
            L.append(f"  - `{p}`: {v['hosts']} host pod(s) × {v['replicas']} replica(s), envoy {v.get('envoy', 1)}, "
                     f"nexus {v.get('nexus', 1)}, operator {v.get('operator', 1)}")
        if env.get("canary"):
            L.append(f"- **Reconcile canary:** `{env['canary']}`")
        if env.get("probe_args"):
            L.append(f"- **Extra probe args:** `{env['probe_args']}`")
    r0 = runs[0]
    L.append(f"\nEach scenario sends one request per endpoint every {r0['interval_s']}s, force-deletes one pod "
             f"(`--grace-period=0 --force`), and counts an endpoint as recovered at the first success that "
             f"starts a run of {r0['stable']} consecutive successes. *Downtime* is kill → recovery. "
             "*Lost* counts points the ingest endpoint acknowledged (HTTP 200) that never became readable. "
             "*Control-plane reconcile* (control-plane scenarios only): right after the kill one replica of the "
             "unprobed canary workload is deleted, and this is kill → its replacement placed and Ready, i.e. how "
             "long the control plane cannot act.\n")

    L.append("## Summary\n")
    L.append("| Profile | Scale | Scenario | Killed pod | Ingest downtime | Distribute downtime "
             "| Failed req (ingest / distribute) | Failures after recovery | Acked points lost | Control-plane reconcile |")
    L.append("|---|---|---|---|---|---|---|---|---|---|")
    for r in runs:
        i, ds = r["ingest"], r["distribute"]
        flaps = i["failed_after_recovery"] + ds["failed_after_recovery"]
        lost = f"{r['data']['lost']} / {r['data']['acked']}"
        L.append(f"| {r['profile']} | {scale(r['profile'])} | {r['scenario']} | `{r['victim']}` | {downtime(i)} "
                 f"| {downtime(ds)} | {i['failed_requests']} / {ds['failed_requests']} | {flaps} | "
                 f"{'**' + lost + '**' if r['data']['lost'] else lost} | {reconcile(r)} |")

    by_scen = {}
    for r in runs:
        by_scen.setdefault(r["scenario"], []).append(r)
    if len({r["profile"] for r in runs}) > 1:
        L.append("\n## Comparison by scenario\n")
        for scen, rs in by_scen.items():
            L.append(f"**{scen}**\n")
            L.append("| Profile | Scale | Ingest downtime | Distribute downtime | Failed requests (total) | Control-plane reconcile |")
            L.append("|---|---|---|---|---|---|")
            for r in rs:
                total = sum(r[e]["failed_requests"] + r[e]["failed_after_recovery"] for e in ENDPOINTS)
                L.append(f"| {r['profile']} | {scale(r['profile'])} | {downtime(r['ingest'])} "
                         f"| {downtime(r['distribute'])} | {total} | {reconcile(r)} |")
            L.append("")

    L.append("\n## Availability around the kill\n")
    L.append(f"One character per second from {STRIP_FROM}s to +{STRIP_TO}s (kill at `|`): "
             "`█` all requests ok, `▒` some failed, `░` all failed.\n")
    L.append("```")
    width = max(len(f"{r['profile']}/{r['scenario']} {e}") for r in runs for e in ENDPOINTS)
    for r in runs:
        if not os.path.exists(r["_csv"]):
            continue
        for e in ENDPOINTS:
            s = strip(r["_csv"], e)
            k = -STRIP_FROM
            L.append(f"{(r['profile'] + '/' + r['scenario'] + ' ' + e).ljust(width)}  {s[:k]}|{s[k:]}")
    L.append("```")

    L.append("\n## Scenario details\n")
    for r in runs:
        L.append(f"### {r['profile']} / {r['scenario']}\n")
        L.append(f"Killed `pod/{r['victim']}`.\n")
        ol = r.get("operator_leader") or {}
        if ol.get("before"):
            moved = "unchanged" if ol.get("before") == ol.get("after") else f"→ `{ol.get('after')}`"
            L.append(f"Operator leader: `{ol['before']}` {moved}.\n")
        if r.get("canary"):
            L.append(f"Control-plane reconcile: {reconcile(r)} (canary `{r['canary'].get('deleted')}`).\n")
        L.append("| Endpoint | Baseline ok | First failure | Recovered | Failed requests | After recovery "
                 "| Failure statuses | Slowest failure |")
        L.append("|---|---|---|---|---|---|---|---|")
        for e in ENDPOINTS:
            x = r[e]
            st = ", ".join(f"{k}×{v}" for k, v in sorted(x["failure_statuses"].items())) or "—"
            first = "—" if x["first_failure_s"] is None else f"+{x['first_failure_s']:.1f}s"
            L.append(f"| {e} | {x['baseline_ok']}/{x['baseline_total']} | {first} | {downtime(x)} "
                     f"| {x['failed_requests']} | {x['failed_after_recovery']} | {st} | {x['max_failed_latency_ms']}ms |")
        data = r["data"]
        lw = f" (sent between {data['lost_window_s'][0]:+.1f}s and {data['lost_window_s'][1]:+.1f}s)" if data["lost"] else ""
        L.append(f"\nData: {data['acked']} points acknowledged, {data['lost']} lost{lw}.\n")
        for label, key in (("Placement before kill", "placement_before"), ("Placement after recovery", "placement_after")):
            L.append(f"{label}:\n")
            L.append("```")
            for w, h, p in r[key]:
                L.append(f"{w:45s} host={h}  pod={p}")
            L.append("```")
        L.append("Timeline:\n")
        L.append("```")
        for t, ev in r["timeline"]:
            L.append(f"{t:+7.2f}s  {ev}")
        L.append("```\n")

    out = os.path.join(d, "report.md")
    with open(out, "w") as f:
        f.write("\n".join(L) + "\n")
    print(out)


if __name__ == "__main__":
    main()
