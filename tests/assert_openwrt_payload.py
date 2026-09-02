#!/usr/bin/env python3
"""Asserts on the two dry-run payloads produced by run_openwrt_e2e.sh.

Every expectation here matches the canned tool output in openwrt-stubs/bin;
a failing check means a parser in agent_openwrt.sh reads the wrong column,
fabricates a value, or emits invalid JSON."""
import json
import sys

out = sys.argv[1]
d1 = json.load(open(f"{out}/r1.json"))
d = json.load(open(f"{out}/r2.json"))
d3 = json.load(open(f"{out}/r3.json"))  # no "wan" interface at all
wg = d["wireguard_peers"]
radios = {r["radio"]: r for r in d["wifi_radios"]}
checks = {
    "wireguard: the interface line is skipped, two peers remain": len(wg) == 2,
    "wireguard: public_key is the peer's key, not the private key": wg[0]["public_key"].startswith("PEERONEpubke"),
    "wireguard: handshake/rx/tx come from the right columns": (wg[0]["latest_handshake"], wg[0]["rx_bytes"], wg[0]["tx_bytes"]) == (1725000000, 12345, 67890),
    "wireguard: IPv6 endpoint without port and brackets": wg[1]["endpoint"] == "2001:db8::1",
    "mwan3: active gateway is the online interface": d["mwan3_active_gw"] == "wan",
    "mwan3: interface list online/offline": [(p["interface"], p["status"]) for p in d["mwan3_policies"]] == [("wan", "online"), ("wwan", "offline")],
    "sqm: dropped read after the word, ecn not measured": d["sqm_dropped"] == 12 and d["sqm_ecn"] is None,
    "service restarts counted from one logread": d["service_restarts"] == {"dnsmasq": 2, "uhttpd": 1},
    "log errors counted": d["log_errors_24h"] == 2,
    "wifi: enabled radio has channel, clients, ssid, power, noise": radios["wlan0"]["channel"] == 6 and radios["wlan0"]["clients"] == 2 and radios["wlan0"]["ssid"] == "Home" and radios["wlan0"]["tx_power"] == 20 and radios["wlan0"]["noise"] == -95,
    "wifi: disabled radio reports null, not channel 0 at 0 dBm": radios["wlan1"]["channel"] is None and radios["wlan1"]["tx_power"] is None and radios["wlan1"]["noise"] is None and radios["wlan1"]["ssid"] is None and radios["wlan1"]["clients"] == 0,
    "wifi_clients_count is the sum over radios": d["wifi_clients_count"] == 2,
    "firewall: accept/drop/reject sums and enabled from one ruleset": (d["fw_accepted"], d["fw_dropped"], d["fw_rejected"], d["firewall_enabled"]) == (200, 5, 3, True),
    "wan: interface up and the bound echo answered": d["wan_up"] is True and d["wan_internet"] is True,
    "dhcp: no lease file is unknown, reservations counted": d["dhcp_leases_count"] is None and d["dhcp_reservations_count"] == 3,
    "cpu: null on the first run, a number on the second": d1["cpu"] is None and isinstance(d["cpu"], (int, float)),
    "oom_kills is a number": isinstance(d["oom_kills"], int),
    "no value is the string 'null'": all(v != "null" for v in d.values()),
    "no wan interface: wan_up and wan_internet are null, not false": d3["wan_up"] is None and d3["wan_internet"] is None and d3["wan_proto"] is None,
    "version reported": isinstance(d.get("version"), str) and d["version"] != "",
}
failed = [k for k, v in checks.items() if not v]
for k, v in checks.items():
    print(("ok   " if v else "FAIL "), k)
print(f"{len(checks) - len(failed)}/{len(checks)} passed")
sys.exit(1 if failed else 0)
