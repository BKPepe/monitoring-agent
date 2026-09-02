#!/usr/bin/env python3
"""Asserts on the dry-run payloads of agent.sh and agent.py (two runs each)."""
import json
import sys

out = sys.argv[1]
failed = []


def check(label, cond):
    print(("ok   " if cond else "FAIL "), label)
    if not cond:
        failed.append(label)


for kind in ("sh", "py"):
    r1 = json.load(open(f"{out}/{kind}1.json"))
    r2 = json.load(open(f"{out}/{kind}2.json"))
    check(f"{kind}: first run has no CPU delta to report (null, not 0.0)", r1["cpu"] is None and r1["net"] is None)
    check(f"{kind}: second run measures CPU, RAM, disk", all(isinstance(r2[k], (int, float)) for k in ("cpu", "ram", "hdd")))
    check(f"{kind}: counters delta on the second run", isinstance(r2["fork_rate"], int) and isinstance(r2["net"], (int, float)))
    check(f"{kind}: unmeasured tools are null, not false/0", r2["tailscale_up"] is None and r2["zerotier_networks"] is None and r2["ups_status"] is None)
    check(f"{kind}: no value is the string 'null'", all(v != "null" for v in r2.values()))
    check(f"{kind}: process list and top lists present", isinstance(r2["processes"], list) and r2["processes"] and isinstance(r2["top_ram_processes"], list) and r2["top_ram_processes"])
    check(f"{kind}: version reported", isinstance(r2.get("version"), str) and r2["version"] != "")
    check(f"{kind}: uptime and boot_time consistent", isinstance(r2["uptime"], int) and isinstance(r2["boot_time"], int))

# TeamSpeak, asked over each transport the agents have.
for kind, label in (("sh2", "bash agent via python3"), ("sh3", "bash agent via nc"), ("py2", "python agent")):
    servers = json.load(open(f"{out}/{kind}.json")).get("teamspeak_servers") or []
    first = servers[0] if servers else {}
    check(
        f"teamspeak: {label} reads the virtual server",
        first.get("port") == 9987 and first.get("clients_online") == 7 and first.get("clients_max") == 32,
    )
    check(f"teamspeak: {label} decodes the escaped name", first.get("name") == "Blood Kings")

sh2 = json.load(open(f"{out}/sh2.json"))
top = sh2["top_cpu_processes"]
check("sh: the busy `yes` tops the CPU ranking", bool(top) and top[0]["name"] == "yes" and top[0]["cpu"] >= 50)
check("sh: top entries carry both cpu and ram_mb", all("cpu" in p and "ram_mb" in p for p in top))
print(f"{'all passed' if not failed else str(len(failed)) + ' failed'}")
sys.exit(1 if failed else 0)
